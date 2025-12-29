/*
 * murmgenesis - Audio driver for RP2350
 * Uses pico_audio_i2s for I2S output
 * Based on murmdoom approach
 */
#ifndef AUDIO_H
#define AUDIO_H

#include <stdint.h>
#include <stdbool.h>

// Forward declarations to avoid pulling in pico_audio headers
struct audio_buffer_pool;
struct audio_buffer;

// Audio sample rate - Genesis NTSC runs at ~53211 Hz
// (53693175 Hz master clock / 896040 cycles per frame * 888 samples per frame)
// Using 53267 Hz to match original implementation
#define AUDIO_SAMPLE_RATE 53267

// Audio buffer size - samples per buffer
// Should be enough to cover one frame at 60 FPS (~888 samples)
#define AUDIO_BUFFER_SAMPLES 1024

// Initialize audio system
bool audio_init(void);

// Shutdown audio system
void audio_shutdown(void);

// Check if audio is initialized
bool audio_is_initialized(void);

// Update audio - call this after sound chips have run
// Mixes YM2612 and SN76489 output and sends to I2S
void audio_update(void);

// Get producer pool for direct buffer access
struct audio_buffer_pool *audio_get_producer_pool(void);

// Fill an I2S buffer directly from sound chip buffers
void audio_fill_buffer(struct audio_buffer *buffer);

// Set master volume (0-128)
void audio_set_volume(int volume);

// Get current master volume
int audio_get_volume(void);

// Enable/disable audio
void audio_set_enabled(bool enabled);

// Check if audio is enabled
bool audio_is_enabled(void);

#endif // AUDIO_H
