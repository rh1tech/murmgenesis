/*
 * murmgenesis - I2S Audio Driver with Chained DMA
 * 
 * Uses two DMA channels in ping-pong configuration:
 * - Channel A plays buffer 0, then triggers channel B
 * - Channel B plays buffer 1, then triggers channel A
 * - This provides gapless audio playback with no underruns
 */

#include "audio.h"
#include "board_config.h"
#include "audio_i2s.pio.h"

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"
#include "hardware/gpio.h"
#include "hardware/dma.h"
#include "hardware/clocks.h"
#include "hardware/sync.h"  // For memory barriers
#include "hardware/resets.h"  // For reset_block

// Genesis sound chip headers
#include "sound/ym2612.h"
#include "sound/gwenesis_sn76489.h"

//=============================================================================
// State - Ring buffer DMA (no chaining, no IRQ, continuous playback)
//=============================================================================

// RING BUFFER:
// - Single large circular buffer (power of 2 size)
// - DMA reads continuously in a ring, wrapping automatically
// - CPU writes ahead of DMA read position
// - No IRQ, no chaining - just check DMA's current position

#define DMA_RING_BITS 12  // 4096 samples = 2^12
#define DMA_RING_SIZE (1 << DMA_RING_BITS)  // Must be power of 2
static uint32_t __attribute__((aligned(DMA_RING_SIZE * 4))) dma_ring_buffer[DMA_RING_SIZE];

// Write position in ring buffer (in samples)
static volatile uint32_t ring_write_pos = 0;

// Pre-roll: buffer this many frames before starting DMA
#define PREROLL_FRAMES 3
static volatile int preroll_count = 0;

static int dma_channel = -1;
static PIO audio_pio;
static uint audio_sm;
static uint32_t dma_transfer_count;

static volatile bool audio_running = false;

// Forward declarations for DMA position tracking
static inline uint32_t get_dma_read_pos(void);
static inline int32_t get_buffer_headroom(void);

//=============================================================================
// I2S Implementation
//=============================================================================

i2s_config_t i2s_get_default_config(void) {
    // Use 888 samples per frame for 60fps audio timing
    // This matches TARGET_SAMPLES_NTSC for consistent DMA transfers
    i2s_config_t config = {
        .sample_freq = AUDIO_SAMPLE_RATE,
        .channel_count = 2,
        .data_pin = I2S_DATA_PIN,
        .clock_pin_base = I2S_CLOCK_PIN_BASE,
        .pio = pio0,
        .sm = 0,
        .dma_channel = 0,
        .dma_trans_count = 888,
        .dma_buf = NULL,
        .volume = 0,
    };
    return config;
}

void i2s_init(i2s_config_t *config) {
    printf("Audio: Initializing I2S with ring buffer DMA...\n");
    printf("Audio: Sample rate: %lu Hz, Ring size: %d samples\n", 
           config->sample_freq, DMA_RING_SIZE);
    
    audio_pio = config->pio;
    dma_transfer_count = config->dma_trans_count;
    
    // CRITICAL: Full hardware reset of PIO0 (but NOT DMA - HDMI uses DMA!)
    reset_block(RESETS_RESET_PIO0_BITS);
    unreset_block_wait(RESETS_RESET_PIO0_BITS);
    
    // Clear all DMA IRQ flags
    dma_hw->ints0 = 0xFFFF;
    dma_hw->ints1 = 0xFFFF;
    
    // Configure GPIO for PIO
    gpio_set_function(config->data_pin, GPIO_FUNC_PIO0);
    gpio_set_function(config->clock_pin_base, GPIO_FUNC_PIO0);
    gpio_set_function(config->clock_pin_base + 1, GPIO_FUNC_PIO0);
    
    gpio_set_drive_strength(config->data_pin, GPIO_DRIVE_STRENGTH_12MA);
    gpio_set_drive_strength(config->clock_pin_base, GPIO_DRIVE_STRENGTH_12MA);
    gpio_set_drive_strength(config->clock_pin_base + 1, GPIO_DRIVE_STRENGTH_12MA);
    
    // Claim state machine
    audio_sm = pio_claim_unused_sm(audio_pio, true);
    config->sm = audio_sm;
    printf("Audio: Using PIO0 SM%d\n", audio_sm);
    
    // Add PIO program
    uint offset = pio_add_program(audio_pio, &audio_i2s_program);
    audio_i2s_program_init(audio_pio, audio_sm, offset, 
                           config->data_pin, config->clock_pin_base);
    
    // Drain the TX FIFO
    pio_sm_clear_fifos(audio_pio, audio_sm);
    
    // Set clock divider for sample rate
    uint32_t sys_clk = clock_get_hz(clk_sys);
    uint32_t divider = sys_clk * 4 / config->sample_freq;
    pio_sm_set_clkdiv_int_frac(audio_pio, audio_sm, divider >> 8u, divider & 0xffu);
    printf("Audio: Clock divider: %lu.%lu (sys=%lu MHz)\n", 
           divider >> 8u, divider & 0xffu, sys_clk / 1000000);
    
    // Initialize ring buffer with silence
    memset(dma_ring_buffer, 0, sizeof(dma_ring_buffer));
    config->dma_buf = (uint16_t *)dma_ring_buffer;
    
    // Use fixed DMA channel 10 for audio
    dma_channel_abort(10);
    while (dma_channel_is_busy(10)) {
        tight_loop_contents();
    }
    
    dma_channel_unclaim(10);
    dma_channel_claim(10);
    dma_channel = 10;
    config->dma_channel = dma_channel;
    printf("Audio: Using DMA channel %d with ring buffer\n", dma_channel);
    
    // Configure DMA channel with ring buffer mode
    dma_channel_config cfg = dma_channel_get_default_config(dma_channel);
    channel_config_set_read_increment(&cfg, true);
    channel_config_set_write_increment(&cfg, false);
    channel_config_set_transfer_data_size(&cfg, DMA_SIZE_32);
    channel_config_set_dreq(&cfg, pio_get_dreq(audio_pio, audio_sm, true));
    // Ring on read side: wrap every DMA_RING_SIZE * 4 bytes
    channel_config_set_ring(&cfg, false, DMA_RING_BITS + 2);  // +2 because 4 bytes per sample
    
    dma_channel_configure(
        dma_channel,
        &cfg,
        &audio_pio->txf[audio_sm],
        dma_ring_buffer,
        0xFFFFFFFF,  // Transfer "forever" - ring wraps read address
        false  // Don't start yet
    );
    
    // Enable PIO state machine
    pio_sm_set_enabled(audio_pio, audio_sm, true);
    
    // Initialize state
    ring_write_pos = 0;
    preroll_count = 0;
    audio_running = false;
    
    printf("Audio: I2S ready (ring buffer DMA with %d frame pre-roll)\n", PREROLL_FRAMES);
}

void i2s_dma_write_count(i2s_config_t *config, const int16_t *samples, uint32_t sample_count) {
    // RING BUFFER:
    // - DMA reads continuously from ring buffer
    // - CPU writes ahead of DMA read position
    // - Must not overwrite samples DMA hasn't read yet!
    
    if (sample_count > dma_transfer_count) sample_count = dma_transfer_count;
    if (sample_count == 0) sample_count = 1;
    
    // CRITICAL: Wait if buffer is too full (prevents overwriting unread samples)
    // Leave at least 2 frames of headroom margin
    if (audio_running) {
        const int32_t max_headroom = DMA_RING_SIZE - (sample_count * 2);
        while (get_buffer_headroom() > max_headroom) {
            tight_loop_contents();
        }
    }
    
    // Write samples to ring buffer at current write position
    uint32_t *write_ptr = &dma_ring_buffer[ring_write_pos];
    
    if (config->volume == 0) {
        // Simple copy - need to handle wrap-around
        uint32_t first_chunk = DMA_RING_SIZE - ring_write_pos;
        if (first_chunk >= sample_count) {
            memcpy(write_ptr, samples, sample_count * sizeof(uint32_t));
        } else {
            memcpy(write_ptr, samples, first_chunk * sizeof(uint32_t));
            memcpy(dma_ring_buffer, &samples[first_chunk * 2], (sample_count - first_chunk) * sizeof(uint32_t));
        }
    } else {
        // Volume adjustment with wrap-around handling
        int16_t *buf16 = (int16_t *)write_ptr;
        for (uint32_t i = 0; i < sample_count * 2; i++) {
            uint32_t idx = (ring_write_pos * 2 + i) & ((DMA_RING_SIZE * 2) - 1);
            ((int16_t *)dma_ring_buffer)[idx] = samples[i] >> config->volume;
        }
    }
    
    // Memory barrier to ensure writes are visible before DMA reads
    __dmb();
    
    // Advance write position (wrap around)
    ring_write_pos = (ring_write_pos + sample_count) & (DMA_RING_SIZE - 1);
    
    if (!audio_running) {
        preroll_count++;
        if (preroll_count >= PREROLL_FRAMES) {
            // We've buffered enough frames ahead - NOW start DMA
            // DMA will start reading from position 0, but we've already
            // written PREROLL_FRAMES worth of data ahead
            dma_channel_start(dma_channel);
            audio_running = true;
        }
    }
}

void i2s_dma_write(i2s_config_t *config, const int16_t *samples) {
    i2s_dma_write_count(config, samples, dma_transfer_count);
}

void i2s_volume(i2s_config_t *config, uint8_t volume) {
    if (volume > 16) volume = 16;
    config->volume = volume;
}

void i2s_increase_volume(i2s_config_t *config) {
    if (config->volume > 0) config->volume--;
}

void i2s_decrease_volume(i2s_config_t *config) {
    if (config->volume < 16) config->volume++;
}

//=============================================================================
// High-level Audio API
//=============================================================================

static bool audio_initialized = false;
static bool audio_enabled = true;
static int master_volume = 100;  // 0-128
static i2s_config_t i2s_config;

// Startup mute: output silence for first N frames to let hardware settle
#define STARTUP_FADE_FRAMES 120  // 2 seconds at 60fps
static int startup_frame_counter = 0;

// Low-pass filter state (declared here so audio_init can reset it)
static int32_t lpf_state = 0;

// Mixed stereo buffer
static int16_t __attribute__((aligned(4))) mixed_buffer[AUDIO_BUFFER_SAMPLES * 2];

static inline int16_t clamp_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

bool audio_init(void) {
    // ALWAYS reinitialize - don't trust static state after hard reset
    // Reset all state variables first
    audio_initialized = false;
    audio_running = false;
    lpf_state = 0;
    dma_channel = -1;
    ring_write_pos = 0;
    preroll_count = 0;
    startup_frame_counter = 0;
    
    i2s_config = i2s_get_default_config();
    i2s_init(&i2s_config);
    
    audio_initialized = true;
    lpf_state = 0;
    
    return true;
}

void audio_shutdown(void) {
    if (!audio_initialized) return;
    pio_sm_set_enabled(audio_pio, audio_sm, false);
    audio_initialized = false;
}

bool audio_is_initialized(void) {
    return audio_initialized;
}

// Target samples per frame for consistent DMA timing
#define TARGET_SAMPLES_NTSC 888
#define FADE_SAMPLES 32  // Samples to crossfade at frame boundary (increased for smoother transition)

// Simple 1-pole low-pass filter coefficient (256 = no filter, lower = more smoothing)
// 192/256 = 0.75 - stronger filtering to reduce clicks
#define LPF_ALPHA 192

// Click detection threshold - suppress sudden jumps greater than this
#define CLICK_THRESHOLD 2000

// 3-sample history for median filter (catches single-sample noise spikes)
static int16_t sample_history[3] = {0, 0, 0};
static int history_idx = 0;

// Simple median of 3 values
static inline int16_t median3(int16_t a, int16_t b, int16_t c) {
    if (a > b) {
        if (b > c) return b;      // a > b > c
        else if (a > c) return c; // a > c >= b
        else return a;            // c >= a > b
    } else {
        if (a > c) return a;      // b >= a > c
        else if (b > c) return c; // b > c >= a
        else return b;            // c >= b >= a
    }
}

// Soft limiter threshold - compress signals above this to reduce clicks
#define SOFT_LIMIT_THRESHOLD 12000
#define SOFT_LIMIT_RATIO 2  // Compress by 2:1 above threshold

// External: saved sample counts from Core 0
extern volatile int saved_ym_samples;
extern volatile int saved_sn_samples;
extern volatile int16_t last_frame_sample;

// External: read buffer pointers from Core 0 (double-buffered)
extern int16_t *audio_read_sn76489;
extern int16_t *audio_read_ym2612;

// Soft limiter function - compresses loud signals
static inline int16_t soft_limit(int32_t sample) {
    if (sample > SOFT_LIMIT_THRESHOLD) {
        // Compress positive signals above threshold
        return SOFT_LIMIT_THRESHOLD + (sample - SOFT_LIMIT_THRESHOLD) / SOFT_LIMIT_RATIO;
    } else if (sample < -SOFT_LIMIT_THRESHOLD) {
        // Compress negative signals below threshold
        return -SOFT_LIMIT_THRESHOLD + (sample + SOFT_LIMIT_THRESHOLD) / SOFT_LIMIT_RATIO;
    }
    return (int16_t)sample;
}

// Debug: track audio stats
static uint32_t audio_frame_count = 0;
static uint32_t click_count = 0;
static int32_t max_jump = 0;
static int16_t prev_sample = 0;
static int32_t first_click_idx = -1;
static int16_t click_before = 0, click_after = 0;

// Get DMA read position from hardware
static inline uint32_t get_dma_read_pos(void) {
    if (dma_channel < 0) return 0;
    // DMA read address tells us where it's reading from
    uint32_t read_addr = dma_channel_hw_addr(dma_channel)->read_addr;
    uint32_t base = (uint32_t)dma_ring_buffer;
    // Convert byte offset to sample index
    return ((read_addr - base) >> 2) & (DMA_RING_SIZE - 1);
}

// Calculate samples ahead of DMA (positive = good, negative = DMA caught up)
static inline int32_t get_buffer_headroom(void) {
    if (!audio_running) return DMA_RING_SIZE;
    uint32_t read_pos = get_dma_read_pos();
    int32_t ahead = (int32_t)ring_write_pos - (int32_t)read_pos;
    if (ahead < 0) ahead += DMA_RING_SIZE;
    return ahead;
}

void audio_submit(void) {
    if (!audio_initialized) return;
    
    // Memory barrier to ensure we see Core 0's writes
    __dmb();
    
    // Read buffer pointers and counts ONCE with local copies
    int16_t *ym_buffer = audio_read_ym2612;
    int16_t *sn_buffer = audio_read_sn76489;
    int ym_samples = saved_ym_samples;
    int sn_samples = saved_sn_samples;
    
    // Memory barrier after reading shared data
    __dmb();
    
    // Sanity check: make sure sample counts are reasonable
    if (ym_samples < 0 || ym_samples > AUDIO_BUFFER_SAMPLES) ym_samples = 0;
    if (sn_samples < 0 || sn_samples > AUDIO_BUFFER_SAMPLES) sn_samples = 0;
    
    int available = (ym_samples > sn_samples) ? ym_samples : sn_samples;
    if (available > TARGET_SAMPLES_NTSC) available = TARGET_SAMPLES_NTSC;
    
    if (!audio_enabled || available == 0 || !ym_buffer || !sn_buffer) {
        // Output silence - fade to zero to avoid click
        for (int i = 0; i < TARGET_SAMPLES_NTSC; i++) {
            int16_t sample = (lpf_state * 250) >> 8;  // Fade toward zero
            lpf_state = sample;
            mixed_buffer[i * 2] = sample;
            mixed_buffer[i * 2 + 1] = sample;
        }
        i2s_dma_write_count(&i2s_config, mixed_buffer, TARGET_SAMPLES_NTSC);
        return;
    }
    
    // Simple mixing without complex filtering
    int16_t last_sample = 0;
    int16_t prev_frame_last = last_frame_sample;
    
    for (int i = 0; i < available; i++) {
        int32_t mixed = 0;
        
        // Only read from valid indices
        if (i < ym_samples && ym_buffer) mixed += ym_buffer[i];
        if (i < sn_samples && sn_buffer) mixed += sn_buffer[i];
        
        mixed = (mixed * master_volume) >> 7;
        
        // Clamp to 16-bit range
        if (mixed > 32767) mixed = 32767;
        if (mixed < -32768) mixed = -32768;
        
        int16_t current_sample = (int16_t)mixed;
        
        // Detect sudden drops (end of PCM sample) and smooth them
        int32_t delta = current_sample - (int16_t)lpf_state;
        if (delta < 0) delta = -delta;
        
        // If amplitude drops suddenly by more than threshold, use stronger filtering
        if (delta > 1000) {
            // Strong smoothing for sudden drops (likely PCM sample ending)
            lpf_state = (current_sample + lpf_state * 7) >> 3;  // 12.5% new, 87.5% old
        } else {
            // Normal low-pass filter
            lpf_state = (current_sample + lpf_state * 3) >> 2;  // 25% new, 75% old
        }
        current_sample = (int16_t)lpf_state;
        
        // Crossfade first FADE_SAMPLES from previous frame's last sample
        if (i < FADE_SAMPLES) {
            int32_t alpha = (i * 256) / FADE_SAMPLES;
            last_sample = (int16_t)(((prev_frame_last * (256 - alpha)) + (current_sample * alpha)) >> 8);
        } else {
            last_sample = current_sample;
        }
        
        // Stereo (mono duplicated)
        mixed_buffer[i * 2] = last_sample;
        mixed_buffer[i * 2 + 1] = last_sample;
    }
    
    // Pad with last sample value
    for (int i = available; i < TARGET_SAMPLES_NTSC; i++) {
        mixed_buffer[i * 2] = last_sample;
        mixed_buffer[i * 2 + 1] = last_sample;
    }
    
    // STARTUP MUTE: Output pure silence for first N frames to let hardware settle
    if (startup_frame_counter < STARTUP_FADE_FRAMES) {
        // Complete silence - don't even use mixed data
        memset(mixed_buffer, 0, TARGET_SAMPLES_NTSC * 2 * sizeof(int16_t));
        startup_frame_counter++;
    }
    
    // Save last sample for next frame's crossfade
    last_frame_sample = last_sample;
    
    // DEBUG: Track buffer headroom
    audio_frame_count++;
    if (audio_running && (audio_frame_count % 300) == 0) {
        int32_t headroom = get_buffer_headroom();
        printf("Audio: headroom=%ld samples, ym=%d sn=%d\n", 
               headroom, saved_ym_samples, saved_sn_samples);
    }
    
    // Always send fixed sample count for consistent timing
    i2s_dma_write_count(&i2s_config, mixed_buffer, TARGET_SAMPLES_NTSC);
}

void audio_set_volume(int volume) {
    if (volume < 0) volume = 0;
    if (volume > 128) volume = 128;
    master_volume = volume;
}

int audio_get_volume(void) {
    return master_volume;
}

void audio_set_enabled(bool enabled) {
    audio_enabled = enabled;
}

bool audio_is_enabled(void) {
    return audio_enabled;
}

void audio_debug_buffer_values(void) {
    printf("Audio: ym=%d sn=%d\n", ym2612_index, sn76489_index);
}

i2s_config_t* audio_get_i2s_config(void) {
    return &i2s_config;
}
