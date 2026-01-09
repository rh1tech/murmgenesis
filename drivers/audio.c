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

// Genesis sound chip headers
#include "sound/ym2612.h"
#include "sound/gwenesis_sn76489.h"

//=============================================================================
// State - Chained DMA for gapless playback
//=============================================================================

static uint32_t *dma_buffer[2] = {NULL, NULL};  // Double DMA buffers
static int dma_channel_a = -1;  // DMA channel A (plays buffer 0)
static int dma_channel_b = -1;  // DMA channel B (plays buffer 1)
static PIO audio_pio;
static uint audio_sm;
static uint32_t dma_transfer_count;

static volatile int next_write_buffer = 0;  // Next buffer to write to
static volatile bool audio_running = false;

//=============================================================================
// I2S Implementation
//=============================================================================

i2s_config_t i2s_get_default_config(void) {
    i2s_config_t config = {
        .sample_freq = AUDIO_SAMPLE_RATE,
        .channel_count = 2,
        .data_pin = I2S_DATA_PIN,
        .clock_pin_base = I2S_CLOCK_PIN_BASE,
        .pio = pio0,
        .sm = 0,
        .dma_channel = 0,
        .dma_trans_count = AUDIO_BUFFER_SAMPLES,
        .dma_buf = NULL,
        .volume = 0,
    };
    return config;
}

void i2s_init(i2s_config_t *config) {
    printf("Audio: Initializing I2S with chained DMA...\n");
    printf("Audio: Sample rate: %lu Hz, Buffer: %lu samples\n", 
           config->sample_freq, config->dma_trans_count);
    
    audio_pio = config->pio;
    dma_transfer_count = config->dma_trans_count;
    
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
    
    // Set clock divider for sample rate
    uint32_t sys_clk = clock_get_hz(clk_sys);
    uint32_t divider = sys_clk * 4 / config->sample_freq;
    pio_sm_set_clkdiv_int_frac(audio_pio, audio_sm, divider >> 8u, divider & 0xffu);
    printf("Audio: Clock divider: %lu.%lu (sys=%lu MHz)\n", 
           divider >> 8u, divider & 0xffu, sys_clk / 1000000);
    
    // Allocate double DMA buffers
    dma_buffer[0] = malloc(config->dma_trans_count * sizeof(uint32_t));
    dma_buffer[1] = malloc(config->dma_trans_count * sizeof(uint32_t));
    if (!dma_buffer[0] || !dma_buffer[1]) {
        printf("Audio: Buffer allocation failed!\n");
        return;
    }
    memset(dma_buffer[0], 0, config->dma_trans_count * sizeof(uint32_t));
    memset(dma_buffer[1], 0, config->dma_trans_count * sizeof(uint32_t));
    config->dma_buf = (uint16_t *)dma_buffer[0];
    
    // Claim two DMA channels
    dma_channel_a = dma_claim_unused_channel(true);
    dma_channel_b = dma_claim_unused_channel(true);
    config->dma_channel = dma_channel_a;
    printf("Audio: Using DMA channels %d and %d (chained)\n", dma_channel_a, dma_channel_b);
    
    // Configure DMA channel A -> plays buffer 0, chains to B
    dma_channel_config cfg_a = dma_channel_get_default_config(dma_channel_a);
    channel_config_set_read_increment(&cfg_a, true);
    channel_config_set_write_increment(&cfg_a, false);
    channel_config_set_transfer_data_size(&cfg_a, DMA_SIZE_32);
    channel_config_set_dreq(&cfg_a, pio_get_dreq(audio_pio, audio_sm, true));
    channel_config_set_chain_to(&cfg_a, dma_channel_b);  // Chain to B when done
    
    dma_channel_configure(
        dma_channel_a,
        &cfg_a,
        &audio_pio->txf[audio_sm],
        dma_buffer[0],
        config->dma_trans_count,
        false  // Don't start yet
    );
    
    // Configure DMA channel B -> plays buffer 1, chains to A
    dma_channel_config cfg_b = dma_channel_get_default_config(dma_channel_b);
    channel_config_set_read_increment(&cfg_b, true);
    channel_config_set_write_increment(&cfg_b, false);
    channel_config_set_transfer_data_size(&cfg_b, DMA_SIZE_32);
    channel_config_set_dreq(&cfg_b, pio_get_dreq(audio_pio, audio_sm, true));
    channel_config_set_chain_to(&cfg_b, dma_channel_a);  // Chain to A when done
    
    dma_channel_configure(
        dma_channel_b,
        &cfg_b,
        &audio_pio->txf[audio_sm],
        dma_buffer[1],
        config->dma_trans_count,
        false  // Don't start yet
    );
    
    // Enable PIO state machine
    pio_sm_set_enabled(audio_pio, audio_sm, true);
    
    // Initialize state - we'll poll DMA busy status instead of using IRQs
    next_write_buffer = 0;
    audio_running = false;
    
    printf("Audio: I2S ready (chained DMA)\n");
}

void i2s_dma_write_count(i2s_config_t *config, const int16_t *samples, uint32_t sample_count) {
    // Chained DMA strategy:
    // 1. Wait for next_write_buffer's DMA channel to finish (poll)
    // 2. Fill that buffer  
    // 3. If not running, start the chain
    // 4. Advance to next buffer
    
    if (sample_count > dma_transfer_count) sample_count = dma_transfer_count;
    if (sample_count == 0) sample_count = 1;
    
    int buf_idx = next_write_buffer;
    int channel = (buf_idx == 0) ? dma_channel_a : dma_channel_b;
    
    // Wait for this buffer's DMA channel to finish (poll busy status)
    dma_channel_wait_for_finish_blocking(channel);
    
    // Fill the buffer
    uint32_t *buf = dma_buffer[buf_idx];
    
    if (config->volume == 0) {
        memcpy(buf, samples, sample_count * sizeof(uint32_t));
    } else {
        int16_t *buf16 = (int16_t *)buf;
        for (uint32_t i = 0; i < sample_count * 2; i++) {
            buf16[i] = samples[i] >> config->volume;
        }
    }
    
    // Update DMA channel with new address and count for next chain trigger
    dma_channel_set_read_addr(channel, buf, false);
    dma_channel_set_trans_count(channel, sample_count, false);
    
    // If not running yet, start the chain
    if (!audio_running) {
        audio_running = true;
        dma_channel_start(channel);
    }
    
    // Move to next buffer
    next_write_buffer = 1 - buf_idx;
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

// Mixed stereo buffer
static int16_t __attribute__((aligned(4))) mixed_buffer[AUDIO_BUFFER_SAMPLES * 2];

static inline int16_t clamp_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

bool audio_init(void) {
    if (audio_initialized) return true;
    
    i2s_config = i2s_get_default_config();
    i2s_init(&i2s_config);
    
    audio_initialized = true;
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
#define FADE_SAMPLES 16  // Samples to crossfade at frame boundary

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
    
    // Use saved counts and READ buffer pointers from Core 0
    // This is the completed frame's audio - Core 0 is now writing to a different buffer
    int ym_samples = saved_ym_samples;
    int sn_samples = saved_sn_samples;
    int16_t *ym_buffer = audio_read_ym2612;
    int16_t *sn_buffer = audio_read_sn76489;
    int available = (ym_samples > sn_samples) ? ym_samples : sn_samples;
    if (available > AUDIO_BUFFER_SAMPLES) available = AUDIO_BUFFER_SAMPLES;
    
    if (!audio_enabled || available == 0 || !ym_buffer || !sn_buffer) {
        memset(mixed_buffer, 0, TARGET_SAMPLES_NTSC * 2 * sizeof(int16_t));
        i2s_dma_write_count(&i2s_config, mixed_buffer, TARGET_SAMPLES_NTSC);
        prev_sample = 0;
        return;
    }
    
    // Mix sound chips
    int16_t last_sample = 0;
    int16_t prev_frame_last = last_frame_sample;
    
    for (int i = 0; i < available; i++) {
        int32_t mixed = 0;
        if (i < ym_samples) mixed += ym_buffer[i];
        if (i < sn_samples) mixed += sn_buffer[i];
        
        mixed = (mixed * master_volume) >> 7;
        
        // Clamp to 16-bit range
        if (mixed > 32767) mixed = 32767;
        if (mixed < -32768) mixed = -32768;
        
        int16_t current_sample = (int16_t)mixed;
        
        // Crossfade first FADE_SAMPLES from previous frame's last sample
        if (i < FADE_SAMPLES) {
            int32_t alpha = (i * 256) / FADE_SAMPLES;
            last_sample = (int16_t)(((prev_frame_last * (256 - alpha)) + (current_sample * alpha)) >> 8);
        } else {
            last_sample = current_sample;
        }
        
        prev_sample = last_sample;
        
        // Stereo (mono duplicated)
        mixed_buffer[i * 2] = last_sample;
        mixed_buffer[i * 2 + 1] = last_sample;
    }
    
    // Pad with last sample value
    for (int i = available; i < TARGET_SAMPLES_NTSC; i++) {
        mixed_buffer[i * 2] = last_sample;
        mixed_buffer[i * 2 + 1] = last_sample;
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
