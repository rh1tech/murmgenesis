/*
 * murmgenesis - Audio driver for RP2350
 * Uses pico_audio_i2s for I2S output
 * Based on murmdoom approach
 * 
 * Uses a ring buffer to decouple emulation speed from audio playback.
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
// Ring Buffer for decoupling emulation from audio playback
//=============================================================================

// Ring buffer size - must be power of 2 for fast modulo
// 4096 samples = ~77ms of audio at 53267 Hz - enough to absorb frame timing variations
#define RING_BUFFER_SIZE 4096
#define RING_BUFFER_MASK (RING_BUFFER_SIZE - 1)

static int16_t ring_buffer[RING_BUFFER_SIZE];
static volatile uint32_t ring_write_pos = 0;
static volatile uint32_t ring_read_pos = 0;

// Get number of samples available to read
static inline uint32_t ring_available(void) {
    return (ring_write_pos - ring_read_pos) & RING_BUFFER_MASK;
}

// Get free space in ring buffer
static inline uint32_t ring_free(void) {
    return RING_BUFFER_SIZE - 1 - ring_available();
}

// Write a sample to ring buffer (called by emulation)
static inline void ring_write(int16_t sample) {
    ring_buffer[ring_write_pos] = sample;
    ring_write_pos = (ring_write_pos + 1) & RING_BUFFER_MASK;
}

// Read a sample from ring buffer (called by audio output)
static inline int16_t ring_read(void) {
    int16_t sample = ring_buffer[ring_read_pos];
    ring_read_pos = (ring_read_pos + 1) & RING_BUFFER_MASK;
    return sample;
}

//=============================================================================
// State
//=============================================================================

static bool audio_initialized = false;
static bool audio_enabled = true;
static int master_volume = 128;  // 0-128

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
// Audio mixing
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
    
    // Mix YM2612 samples
    if (ym_samples > 0) {
        int mix_count = (ym_samples < available_samples) ? ym_samples : available_samples;
        for (int i = 0; i < mix_count; i++) {
            // YM2612 outputs mono, duplicate to stereo
            int32_t ym_sample = gwenesis_ym2612_buffer[i];
            ym_sample = (ym_sample * master_volume) >> 7;
            
            int32_t left = samples[i * 2] + ym_sample;
            int32_t right = samples[i * 2 + 1] + ym_sample;
            
            samples[i * 2] = clamp_s16(left);
            samples[i * 2 + 1] = clamp_s16(right);
        }
    }
    
    // Mix SN76489 samples
    if (sn_samples > 0) {
        int mix_count = (sn_samples < available_samples) ? sn_samples : available_samples;
        for (int i = 0; i < mix_count; i++) {
            // SN76489 outputs mono, duplicate to stereo
            int32_t sn_sample = gwenesis_sn76489_buffer[i];
            sn_sample = (sn_sample * master_volume) >> 7;
            
            int32_t left = samples[i * 2] + sn_sample;
            int32_t right = samples[i * 2 + 1] + sn_sample;
            
            samples[i * 2] = clamp_s16(left);
            samples[i * 2 + 1] = clamp_s16(right);
        }
    }
    
    // Set actual sample count to what we have
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
    
    // Debug: print sample counts occasionally
    static int debug_counter = 0;
    if (++debug_counter >= 120) {  // Every 2 seconds at 60 FPS
        printf("Audio: YM=%d SN=%d samples\n", ym2612_index, sn76489_index);
        debug_counter = 0;
    }
    
    // Process all available audio buffers
    audio_buffer_t *buffer;
    while ((buffer = take_audio_buffer(producer_pool, false)) != NULL) {
        mix_audio_buffer(buffer);
    }
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
