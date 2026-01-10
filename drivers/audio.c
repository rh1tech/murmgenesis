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
// State - Triple-buffered DMA for gapless, click-free playback
//=============================================================================

// TRIPLE BUFFERING:
// - Buffer 0, 1, 2 in a ring
// - DMA ping-pongs using control channel that reads next buffer address
// - CPU always writes to the buffer that's 2 steps ahead
// - This ensures we NEVER write to a buffer DMA might be reading

#define DMA_BUFFER_SIZE 873
static uint32_t dma_buffer_0[DMA_BUFFER_SIZE];
static uint32_t dma_buffer_1[DMA_BUFFER_SIZE];
static uint32_t dma_buffer_2[DMA_BUFFER_SIZE];  // Third buffer for safety
static uint32_t *dma_buffers[3] = {NULL, NULL, NULL};

// Ring buffer indices
static volatile int cpu_write_idx = 0;    // Buffer CPU is writing to
static volatile int dma_play_idx = 0;     // Buffer DMA is currently playing

static int dma_channel_data = -1;   // DMA channel for audio data
static PIO audio_pio;
static uint audio_sm;
static uint32_t dma_transfer_count;

static volatile bool audio_running = false;

//=============================================================================
// I2S Implementation
//=============================================================================

i2s_config_t i2s_get_default_config(void) {
    // Use 873 samples per frame for 61fps audio timing
    // This matches TARGET_SAMPLES_NTSC for consistent DMA transfers
    i2s_config_t config = {
        .sample_freq = AUDIO_SAMPLE_RATE,
        .channel_count = 2,
        .data_pin = I2S_DATA_PIN,
        .clock_pin_base = I2S_CLOCK_PIN_BASE,
        .pio = pio0,
        .sm = 0,
        .dma_channel = 0,
        .dma_trans_count = 873,
        .dma_buf = NULL,
        .volume = 0,
    };
    return config;
}

// DMA IRQ handler - called when audio buffer finishes playing
static void audio_dma_irq_handler(void) {
    // Clear the interrupt first (we use DMA_IRQ_1 so clear ints1)
    dma_hw->ints1 = (1u << dma_channel_data);
    
    // Don't do anything if audio isn't running yet
    if (!audio_running) return;
    
    // Advance to next buffer
    dma_play_idx = (dma_play_idx + 1) % 3;
    
    // Make sure buffer pointer is valid
    if (dma_buffers[dma_play_idx] == NULL) return;
    
    // Start playing the next buffer
    dma_channel_set_read_addr(dma_channel_data, dma_buffers[dma_play_idx], false);
    dma_channel_set_trans_count(dma_channel_data, dma_transfer_count, true);  // Start!
}

void i2s_init(i2s_config_t *config) {
    printf("Audio: Initializing I2S with triple-buffered DMA...\n");
    printf("Audio: Sample rate: %lu Hz, Buffer: %lu samples\n", 
           config->sample_freq, config->dma_trans_count);
    
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
    
    // Initialize triple buffers with silence
    memset(dma_buffer_0, 0, sizeof(dma_buffer_0));
    memset(dma_buffer_1, 0, sizeof(dma_buffer_1));
    memset(dma_buffer_2, 0, sizeof(dma_buffer_2));
    dma_buffers[0] = dma_buffer_0;
    dma_buffers[1] = dma_buffer_1;
    dma_buffers[2] = dma_buffer_2;
    config->dma_buf = (uint16_t *)dma_buffers[0];
    
    // Use fixed DMA channel 10 for audio data
    dma_channel_abort(10);
    while (dma_channel_is_busy(10)) {
        tight_loop_contents();
    }
    
    dma_channel_unclaim(10);
    dma_channel_claim(10);
    dma_channel_data = 10;
    config->dma_channel = dma_channel_data;
    printf("Audio: Using DMA channel %d\n", dma_channel_data);
    
    // Configure DATA channel - transfers audio samples to PIO
    dma_channel_config cfg_data = dma_channel_get_default_config(dma_channel_data);
    channel_config_set_read_increment(&cfg_data, true);
    channel_config_set_write_increment(&cfg_data, false);
    channel_config_set_transfer_data_size(&cfg_data, DMA_SIZE_32);
    channel_config_set_dreq(&cfg_data, pio_get_dreq(audio_pio, audio_sm, true));
    // No chaining - we use IRQ to set up next buffer
    
    dma_channel_configure(
        dma_channel_data,
        &cfg_data,
        &audio_pio->txf[audio_sm],
        dma_buffers[0],
        config->dma_trans_count,
        false  // Don't start yet
    );
    
    // Set up IRQ handler for DMA completion
    // Use DMA_IRQ_1 to avoid conflict with HDMI which may use DMA_IRQ_0
    dma_channel_set_irq1_enabled(dma_channel_data, true);
    irq_set_exclusive_handler(DMA_IRQ_1, audio_dma_irq_handler);
    irq_set_enabled(DMA_IRQ_1, true);
    
    // Enable PIO state machine
    pio_sm_set_enabled(audio_pio, audio_sm, true);
    
    // Initialize state
    cpu_write_idx = 2;  // CPU starts writing to buffer 2 (0 and 1 are for DMA)
    dma_play_idx = 0;   // DMA starts with buffer 0
    audio_running = false;
    
    printf("Audio: I2S ready (triple-buffered DMA)\n");
}

void i2s_dma_write_count(i2s_config_t *config, const int16_t *samples, uint32_t sample_count) {
    // TRIPLE BUFFERING with IRQ:
    // - DMA plays buffer N, IRQ fires and starts buffer N+1
    // - CPU fills buffer N+2 (always 2 ahead of DMA)
    // - This gives us a full buffer of margin - no race conditions
    
    if (sample_count > dma_transfer_count) sample_count = dma_transfer_count;
    if (sample_count == 0) sample_count = 1;
    
    // Get the buffer we're writing to (always 2 ahead of DMA)
    uint32_t *buf = dma_buffers[cpu_write_idx];
    
    // Fill the buffer
    if (config->volume == 0) {
        memcpy(buf, samples, sample_count * sizeof(uint32_t));
    } else {
        int16_t *buf16 = (int16_t *)buf;
        for (uint32_t i = 0; i < sample_count * 2; i++) {
            buf16[i] = samples[i] >> config->volume;
        }
    }
    
    // Memory barrier to ensure writes are visible
    __dmb();
    
    if (!audio_running) {
        // FIRST FRAME: Initialize all buffers and start DMA
        // Copy first frame to all 3 buffers
        memcpy(dma_buffers[0], buf, sample_count * sizeof(uint32_t));
        memcpy(dma_buffers[1], buf, sample_count * sizeof(uint32_t));
        
        // Start DMA with buffer 0
        dma_channel_set_read_addr(dma_channel_data, dma_buffers[0], false);
        dma_channel_set_trans_count(dma_channel_data, sample_count, true);  // Start!
        
        audio_running = true;
        dma_play_idx = 0;
        cpu_write_idx = 2;  // Next write goes to buffer 2
        return;
    }
    
    // NORMAL OPERATION: Triple buffering means we NEVER wait!
    // IRQ handler chains the buffers automatically
    // Just advance CPU write index to next buffer
    cpu_write_idx = (cpu_write_idx + 1) % 3;
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
    cpu_write_idx = 2;
    dma_play_idx = 0;
    lpf_state = 0;
    dma_buffers[0] = NULL;
    dma_buffers[1] = NULL;
    dma_buffers[2] = NULL;
    dma_channel_data = -1;
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
#define TARGET_SAMPLES_NTSC 873
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
        
        // Simple single-pole low-pass filter to smooth transitions
        lpf_state = (current_sample + lpf_state * 3) >> 2;  // 25% new, 75% old
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
