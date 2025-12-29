/*
 * murmgenesis - Audio driver for RP2350
 * Uses pico_audio_i2s for I2S output
 * Based on murmdoom approach
 * 
 * Simple direct mixing - no ring buffer to avoid HDMI conflicts
 */

#include "audio.h"
#include "board_config.h"

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"
#include "hardware/gpio.h"
#include "hardware/dma.h"
#include "hardware/irq.h"

// Redefine 'none' to avoid conflict with pico_audio enum
#define none pico_audio_enum_none
#include "pico/audio_i2s.h"
#undef none

// Genesis sound chip headers
#include "sound/ym2612.h"
#include "sound/gwenesis_sn76489.h"

//=============================================================================
// Configuration
//=============================================================================

// I2S configuration - use PIO 0 to avoid conflicts with HDMI on PIO 1
#ifndef PICO_AUDIO_I2S_PIO
#define PICO_AUDIO_I2S_PIO 0
#endif

#ifndef PICO_AUDIO_I2S_DMA_IRQ
#define PICO_AUDIO_I2S_DMA_IRQ 1
#endif

#ifndef PICO_AUDIO_I2S_DMA_CHANNEL
#define PICO_AUDIO_I2S_DMA_CHANNEL 6
#endif

#ifndef PICO_AUDIO_I2S_STATE_MACHINE
#define PICO_AUDIO_I2S_STATE_MACHINE 0
#endif

// Increase I2S drive strength for cleaner signal
#define INCREASE_I2S_DRIVE_STRENGTH 1

//=============================================================================
// State
//=============================================================================

static bool audio_initialized = false;
static bool audio_enabled = true;
static int master_volume = 64;  // 0-128 (half volume to prevent clipping)

static struct audio_buffer_pool *producer_pool = NULL;

// Audio format: 16-bit stereo
static struct audio_format audio_format = {
    .format = AUDIO_BUFFER_FORMAT_PCM_S16,
    .sample_freq = AUDIO_SAMPLE_RATE,
    .channel_count = 2,
};

static struct audio_buffer_format producer_format = {
    .format = &audio_format,
    .sample_stride = 4  // 2 bytes per sample * 2 channels
};

//=============================================================================
// Helper functions
//=============================================================================

static inline int16_t clamp_s16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

//=============================================================================
// Audio mixing - direct from sound chip buffers
//=============================================================================

static void mix_audio_buffer(audio_buffer_t *buffer) {
    int16_t *samples = (int16_t *)buffer->buffer->bytes;
    int sample_count = buffer->max_sample_count;
    
    // Clear buffer first
    memset(samples, 0, sample_count * 4);  // 4 bytes per stereo sample
    
    if (!audio_enabled) {
        buffer->sample_count = sample_count;
        give_audio_buffer(producer_pool, buffer);
        return;
    }
    
    // Determine how many samples we actually have
    int ym_samples = ym2612_index;
    int sn_samples = sn76489_index;
    int available_samples = (ym_samples > sn_samples) ? ym_samples : sn_samples;
    
    // Limit to buffer size
    if (available_samples > sample_count) {
        available_samples = sample_count;
    }
    
    // If no samples available, output silence
    if (available_samples == 0) {
        buffer->sample_count = sample_count;
        give_audio_buffer(producer_pool, buffer);
        return;
    }
    
    // Mix both sound chips
    for (int i = 0; i < available_samples; i++) {
        int32_t mixed = 0;
        
        if (i < ym_samples) {
            mixed += gwenesis_ym2612_buffer[i];
        }
        if (i < sn_samples) {
            mixed += gwenesis_sn76489_buffer[i];
        }
        
        // Apply volume and clamp
        mixed = (mixed * master_volume) >> 7;
        int16_t sample = clamp_s16(mixed);
        
        // Stereo output (duplicate mono to both channels)
        samples[i * 2] = sample;
        samples[i * 2 + 1] = sample;
    }
    
    buffer->sample_count = available_samples;
    give_audio_buffer(producer_pool, buffer);
}

//=============================================================================
// Public API
//=============================================================================

bool audio_init(void) {
    if (audio_initialized) {
        return true;
    }
    
    printf("Audio: Initializing I2S audio...\n");
    printf("Audio: Sample rate: %d Hz\n", AUDIO_SAMPLE_RATE);
    printf("Audio: I2S pins - DATA: %d, CLK_BASE: %d\n", 
           PICO_AUDIO_I2S_DATA_PIN, PICO_AUDIO_I2S_CLOCK_PIN_BASE);
    printf("Audio: PIO: %d, SM: %d, DMA: %d, IRQ: %d\n",
           PICO_AUDIO_I2S_PIO, PICO_AUDIO_I2S_STATE_MACHINE,
           PICO_AUDIO_I2S_DMA_CHANNEL, PICO_AUDIO_I2S_DMA_IRQ);
    
    // Create producer pool with 4 buffers for smooth audio
    producer_pool = audio_new_producer_pool(&producer_format, 4, AUDIO_BUFFER_SAMPLES);
    if (producer_pool == NULL) {
        printf("Audio: Failed to allocate producer pool!\n");
        return false;
    }
    
    // Configure I2S
    struct audio_i2s_config config = {
        .data_pin = PICO_AUDIO_I2S_DATA_PIN,
        .clock_pin_base = PICO_AUDIO_I2S_CLOCK_PIN_BASE,
        .dma_channel = PICO_AUDIO_I2S_DMA_CHANNEL,
        .pio_sm = PICO_AUDIO_I2S_STATE_MACHINE,
    };
    
    printf("Connecting PIO I2S audio\n");
    
    // Initialize I2S
    const struct audio_format *output_format = audio_i2s_setup(&audio_format, &config);
    if (!output_format) {
        printf("Audio: Failed to initialize I2S!\n");
        return false;
    }
    
#if INCREASE_I2S_DRIVE_STRENGTH
    // Increase drive strength for cleaner I2S signal
    gpio_set_drive_strength(PICO_AUDIO_I2S_DATA_PIN, GPIO_DRIVE_STRENGTH_12MA);
    gpio_set_drive_strength(PICO_AUDIO_I2S_CLOCK_PIN_BASE, GPIO_DRIVE_STRENGTH_12MA);
    gpio_set_drive_strength(PICO_AUDIO_I2S_CLOCK_PIN_BASE + 1, GPIO_DRIVE_STRENGTH_12MA);
#endif
    
    // Connect producer pool to I2S output
    bool ok = audio_i2s_connect_extra(producer_pool, false, 0, 0, NULL);
    if (!ok) {
        printf("Audio: Failed to connect audio pipeline!\n");
        return false;
    }
    
    // Enable I2S output
    audio_i2s_set_enabled(true);
    
    audio_initialized = true;
    printf("Audio: Initialization complete\n");
    
    return true;
}

void audio_shutdown(void) {
    if (!audio_initialized) {
        return;
    }
    
    audio_i2s_set_enabled(false);
    audio_initialized = false;
}

bool audio_is_initialized(void) {
    return audio_initialized;
}

void audio_update(void) {
    if (!audio_initialized) {
        return;
    }
    
    // Process all available audio buffers
    audio_buffer_t *buffer;
    while ((buffer = take_audio_buffer(producer_pool, false)) != NULL) {
        mix_audio_buffer(buffer);
    }
}

struct audio_buffer_pool *audio_get_producer_pool(void) {
    return producer_pool;
}

void audio_fill_buffer(audio_buffer_t *buffer) {
    mix_audio_buffer(buffer);
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
