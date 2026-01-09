/*
 * murmgenesis - Simple I2S Audio Driver
 * 
 * Architecture (matching pico-megadrive):
 * - Single DMA buffer
 * - Wait for DMA completion, copy new samples, start DMA
 * - Called once per frame from emulation loop
 * 
 * The key insight: DMA playback time = frame time (888 samples @ 53267 Hz = 16.67ms)
 * So blocking on DMA naturally provides 60Hz timing.
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
// State - Double buffer with chained DMA for seamless playback
//=============================================================================

static uint32_t *dma_buffer[2] = {NULL, NULL};  // Double DMA buffers
static int dma_channel = -1;
static int dma_ctrl_channel = -1;  // Control channel for chaining
static PIO audio_pio;
static uint audio_sm;
static uint32_t dma_transfer_count;
static volatile int current_buffer = 0;  // Which buffer is being filled
static volatile bool first_transfer = true;

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
    printf("Audio: Initializing I2S...\n");
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
    
    // Configure main DMA channel
    dma_channel = dma_claim_unused_channel(true);
    config->dma_channel = dma_channel;
    printf("Audio: Using DMA channel %d\n", dma_channel);
    
    dma_channel_config dma_cfg = dma_channel_get_default_config(dma_channel);
    channel_config_set_read_increment(&dma_cfg, true);
    channel_config_set_write_increment(&dma_cfg, false);
    channel_config_set_transfer_data_size(&dma_cfg, DMA_SIZE_32);
    channel_config_set_dreq(&dma_cfg, pio_get_dreq(audio_pio, audio_sm, true));
    
    dma_channel_configure(
        dma_channel,
        &dma_cfg,
        &audio_pio->txf[audio_sm],
        dma_buffer[0],
        config->dma_trans_count,
        false  // Don't start yet
    );
    
    // Enable PIO state machine
    pio_sm_set_enabled(audio_pio, audio_sm, true);
    
    current_buffer = 0;
    first_transfer = true;
    printf("Audio: I2S ready (double-buffered)\n");
}

void i2s_dma_write(i2s_config_t *config, const int16_t *samples) {
    // Double buffer strategy:
    // - Fill the "next" buffer while current one is playing
    // - Wait for current DMA to finish, then immediately start next
    // - This eliminates gaps between buffers
    
    int fill_buffer = current_buffer;
    uint32_t *buf = dma_buffer[fill_buffer];
    
    // Copy samples to the buffer we'll use next
    if (config->volume == 0) {
        memcpy(buf, samples, dma_transfer_count * sizeof(uint32_t));
    } else {
        int16_t *buf16 = (int16_t *)buf;
        for (uint32_t i = 0; i < dma_transfer_count * 2; i++) {
            buf16[i] = samples[i] >> config->volume;
        }
    }
    
    // Wait for any ongoing DMA to complete
    if (!first_transfer) {
        dma_channel_wait_for_finish_blocking(dma_channel);
    }
    first_transfer = false;
    
    // Immediately start the next transfer (no gap!)
    dma_channel_set_read_addr(dma_channel, buf, false);
    dma_channel_set_trans_count(dma_channel, dma_transfer_count, true);
    
    // Swap buffers for next call
    current_buffer = 1 - current_buffer;
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

void audio_submit(void) {
    if (!audio_initialized) return;
    
    if (!audio_enabled) {
        memset(mixed_buffer, 0, sizeof(mixed_buffer));
        i2s_dma_write(&i2s_config, mixed_buffer);
        return;
    }
    
    int ym_samples = ym2612_index;
    int sn_samples = sn76489_index;
    int available = (ym_samples > sn_samples) ? ym_samples : sn_samples;
    if (available > AUDIO_BUFFER_SAMPLES) available = AUDIO_BUFFER_SAMPLES;
    
    // Mix sound chips
    for (int i = 0; i < available; i++) {
        int32_t mixed = 0;
        if (i < ym_samples) mixed += gwenesis_ym2612_buffer[i];
        if (i < sn_samples) mixed += gwenesis_sn76489_buffer[i];
        
        mixed = (mixed * master_volume) >> 7;
        int16_t sample = clamp_s16(mixed);
        
        // Stereo (mono duplicated)
        mixed_buffer[i * 2] = sample;
        mixed_buffer[i * 2 + 1] = sample;
    }
    
    // Fill rest with silence
    for (int i = available; i < AUDIO_BUFFER_SAMPLES; i++) {
        mixed_buffer[i * 2] = 0;
        mixed_buffer[i * 2 + 1] = 0;
    }
    
    i2s_dma_write(&i2s_config, mixed_buffer);
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
