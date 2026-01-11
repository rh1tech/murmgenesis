/*
 * murmgenesis - Sega Genesis/Megadrive Emulator for RP2350
 * Based on Gwenesis emulator
 */
#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "pico/sync.h"
#include "hardware/vreg.h"
#include "hardware/clocks.h"
#include "hardware/structs/qmi.h"
#include "hardware/watchdog.h"
#include "hardware/sync.h"  // For memory barriers
#include "hardware/dma.h"   // For DMA reset at startup
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>

#include "board_config.h"
#include "HDMI.h"
#include "psram_init.h"
#include "psram_allocator.h"
#include "ff.h"

// Gwenesis includes
#include "bus/gwenesis_bus.h"
#include "io/gwenesis_io.h"
#include "vdp/gwenesis_vdp.h"

// Enable M68K opcode profiling (must be defined before m68k.h)
#define M68K_OPCODE_PROFILING 1
#include "cpus/M68K/m68k.h"

#include "sound/z80inst.h"
#include "sound/ym2612.h"
#include "sound/gwenesis_sn76489.h"

// Audio driver (simple DMA-based I2S)
#include "audio.h"

// Gamepad driver
#include "nespad/nespad.h"

// USB HID (gamepad support) - build with USB_HID_ENABLED=1 ./build.sh
#ifdef USB_HID_ENABLED
#include "usbhid/usbhid.h"
#endif

// ROM selector
#include "rom_selector.h"

//=============================================================================
// Profiling
//=============================================================================

// Simple logging
#define LOG(fmt, ...) printf(fmt, ##__VA_ARGS__)

#define ENABLE_PROFILING 1
#define DISABLE_FRAME_LIMITING 0

// Use assembly-optimized M68K loop (set to 0 to use original C loop for debugging)
#define USE_M68K_FAST_LOOP 1

// Adaptive frame skipping (video-only): when the emulation workload exceeds the
// target frame budget, we temporarily skip some renders to keep audio/emulation
// stable. Safety bounds prevent long streaks of unrendered frames and parity
// fairness avoids sampling only even/odd frames (important for sprite blinking).
#define ENABLE_ADAPTIVE_FRAMESKIP 1
#define FRAMESKIP_MAX_CONSECUTIVE 4
#define FRAMESKIP_MAX_BACKLOG_FRAMES 8
#define FRAMESKIP_RENDER_COST_DEFAULT_US 4000u
// Strong blink protection: never skip the opposite-parity (even/odd) frame after
// rendering. This keeps 60Hz alternating effects (invincibility blinking) visible
// even when we fall back to ~30Hz rendering.
#define FRAMESKIP_STRONG_BLINK_PROTECTION 1

// Aggressiveness tuning (higher = skip earlier / recover faster)
// - Threshold divisor: lower means more aggressive skipping.
// - Paydown factor: >1.0 makes each skipped render reduce backlog more.
#define FRAMESKIP_SKIP_THRESHOLD_DIVISOR 4u   // was effectively 2u
#define FRAMESKIP_SKIP_PAYDOWN_NUM 3u
#define FRAMESKIP_SKIP_PAYDOWN_DEN 2u

#if USE_M68K_FAST_LOOP
// Assembly-optimized M68K execution loop
extern void m68k_run_fast(unsigned int cycles);
#endif

// Emulation speed control (in percentage: 100 = normal, 50 = half speed, 150 = 1.5x speed)
#define EMULATION_SPEED_PERCENT 100

#if ENABLE_PROFILING
typedef struct {
    uint64_t m68k_time;
    uint64_t z80_time;
    uint64_t vdp_time;
    uint64_t sound_time;
    uint64_t audio_wait_time;
    uint64_t frame_time;
    uint64_t idle_time;
    uint32_t frame_count;
    uint64_t min_frame_time;
    uint64_t max_frame_time;
    uint32_t slow_frames;  // Frames that took > 17ms
    uint32_t fast_frames;  // Frames that took < 16ms
} profile_stats_t;

static profile_stats_t profile_stats = {0};
static uint64_t profile_frame_start = 0;
static uint64_t profile_section_start = 0;

#define PROFILE_START() profile_section_start = time_us_64()
#define PROFILE_END(stat) profile_stats.stat += (time_us_64() - profile_section_start)
#define PROFILE_FRAME_START() profile_frame_start = time_us_64()
#define PROFILE_FRAME_END() do { \
  uint64_t frame_duration = time_us_64() - profile_frame_start; \
  profile_stats.frame_time += frame_duration; \
  if (profile_stats.frame_count == 0 || frame_duration < profile_stats.min_frame_time) \
    profile_stats.min_frame_time = frame_duration; \
  if (frame_duration > profile_stats.max_frame_time) \
    profile_stats.max_frame_time = frame_duration; \
  if (frame_duration > 17000) profile_stats.slow_frames++; \
  if (frame_duration < 16000) profile_stats.fast_frames++; \
  profile_stats.frame_count++; \
} while(0)

static void print_profiling_stats(void) {
    if (profile_stats.frame_count == 0) return;
    
    uint64_t total = profile_stats.frame_time;
    uint64_t tracked = profile_stats.m68k_time + profile_stats.z80_time + 
                       profile_stats.vdp_time + profile_stats.sound_time + 
                       profile_stats.audio_wait_time + profile_stats.idle_time;
    uint64_t other = (total > tracked) ? (total - tracked) : 0;
    
    LOG("\n=== Profiling Stats (avg per frame over %u frames) ===\n", profile_stats.frame_count);
    LOG("M68K execution:  %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.m68k_time / profile_stats.frame_count),
        (int)((profile_stats.m68k_time * 100) / total));
    LOG("Z80 execution:   %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.z80_time / profile_stats.frame_count),
        (int)((profile_stats.z80_time * 100) / total));
    LOG("VDP rendering:   %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.vdp_time / profile_stats.frame_count),
        (int)((profile_stats.vdp_time * 100) / total));
    LOG("Sound chips:     %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.sound_time / profile_stats.frame_count),
        (int)((profile_stats.sound_time * 100) / total));
    LOG("Audio wait:      %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.audio_wait_time / profile_stats.frame_count),
        (int)((profile_stats.audio_wait_time * 100) / total));
    LOG("Other/overhead:  %6lu us (%3d%%)\n", 
        (unsigned long)(other / profile_stats.frame_count),
        (int)((other * 100) / total));
    LOG("Total frame:     %6lu us (min=%lu, max=%lu)\n", 
        (unsigned long)(total / profile_stats.frame_count),
        (unsigned long)profile_stats.min_frame_time,
        (unsigned long)profile_stats.max_frame_time);
    LOG("Frame rate:      %6.2f fps (target=60.00)\n", 1000000.0 / (total / (float)profile_stats.frame_count));
    LOG("Slow frames: %u (>17ms), Fast: %u (<16ms)\n",
        profile_stats.slow_frames, profile_stats.fast_frames);
    LOG("================================================\n\n");
    
    // Reset stats
    memset(&profile_stats, 0, sizeof(profile_stats));
}
#else
#define PROFILE_START() do {} while(0)
#define PROFILE_END(stat) do {} while(0)
#define PROFILE_FRAME_START() do {} while(0)
#define PROFILE_FRAME_END() do {} while(0)
#define print_profiling_stats() do {} while(0)
#endif

// Screen buffer - 320x240 8-bit indexed (static, not in PSRAM)
#define SCREEN_WIDTH 320
#define SCREEN_HEIGHT 240
static uint8_t SCREEN[SCREEN_HEIGHT][SCREEN_WIDTH];

// Semaphore for render core sync
static semaphore_t render_start_semaphore;

// Sound processing synchronization
static volatile int sound_lines_per_frame = LINES_PER_FRAME_NTSC;
static volatile int sound_screen_height = 224;
static volatile bool frame_ready = false;  // Core 0 signals frame done
static volatile bool audio_done = false;   // Core 1 signals audio submitted

// Saved sample counts for Core 1 (avoids race condition when reading indices)
volatile int saved_ym_samples = 0;
volatile int saved_sn_samples = 0;
volatile int16_t last_frame_sample = 0;  // Last sample for crossfade

// Read buffer pointers for Core 1 (points to completed frame's audio)
int16_t *audio_read_sn76489 = NULL;
int16_t *audio_read_ym2612 = NULL;

// ROM buffer in PSRAM
static uint8_t *rom_buffer = NULL;
// Remove duplicate MAX_ROM_SIZE - it's defined in gwenesis_bus.h

// Gwenesis external variables
extern unsigned char* ROM_DATA;
extern unsigned char M68K_RAM[];
extern unsigned char ZRAM[];
extern unsigned char gwenesis_vdp_regs[];
extern unsigned int gwenesis_vdp_status;
extern int hint_pending;
extern int screen_width;
extern int screen_height;

// Audio buffers - DOUBLE BUFFERED to prevent race conditions
// Core 0 writes to one buffer, Core 1 reads from the other
// Use __not_in_flash to ensure they stay in RAM
#define AUDIO_BUFFER_SIZE 4096
static int16_t __not_in_flash("audio") gwenesis_sn76489_buffer_mem[2][AUDIO_BUFFER_SIZE];
static int16_t __not_in_flash("audio") gwenesis_ym2612_buffer_mem[2][AUDIO_BUFFER_SIZE];

// Current write buffer index (0 or 1) - Core 0 writes here
static volatile int audio_write_buffer = 0;
// Current read buffer index (0 or 1) - Core 1 reads here
static volatile int audio_read_buffer = 0;

// Exported pointers for external access (points to current write buffer)
int16_t *gwenesis_sn76489_buffer = gwenesis_sn76489_buffer_mem[0];
int16_t *gwenesis_ym2612_buffer = gwenesis_ym2612_buffer_mem[0];

volatile int sn76489_index;
volatile int sn76489_clock;

volatile int ym2612_index;
volatile int ym2612_clock;

// Audio enabled flags
bool audio_enabled = true;
bool sn76489_enabled = true;

// Timing
int system_clock;
unsigned int lines_per_frame = LINES_PER_FRAME_NTSC;
int scan_line;
unsigned int frame_counter = 0;

// FatFS
static FATFS fs;

// Flash timing configuration for overclocking
#define FLASH_MAX_FREQ_MHZ 88

static void __no_inline_not_in_flash_func(set_flash_timings)(int cpu_mhz) {
    const int clock_hz = cpu_mhz * 1000000;
    const int max_flash_freq = FLASH_MAX_FREQ_MHZ * 1000000;
    
    int divisor = (clock_hz + max_flash_freq - (max_flash_freq >> 4) - 1) / max_flash_freq;
    if (divisor == 1 && clock_hz >= 166000000) {
        divisor = 2;
    }
    
    int rxdelay = divisor;
    if (clock_hz / divisor > 100000000 && clock_hz >= 166000000) {
        rxdelay += 1;
    }
    
    qmi_hw->m[0].timing = 0x60007000 |
                        rxdelay << QMI_M0_TIMING_RXDELAY_LSB |
                        divisor << QMI_M0_TIMING_CLKDIV_LSB;
}

// Load ROM from SD card
static bool load_rom(const char *filename) {
    FIL file;
    UINT bytes_read;
    
    LOG("Opening ROM: %s\n", filename);
    
    FRESULT res = f_open(&file, filename, FA_READ);
    if (res != FR_OK) {
        LOG("Failed to open ROM file: %d\n", res);
        return false;
    }
    
    FSIZE_t file_size = f_size(&file);
    LOG("ROM size: %lu bytes\n", (unsigned long)file_size);
    
    if (file_size > MAX_ROM_SIZE) {
        LOG("ROM too large!\n");
        f_close(&file);
        return false;
    }
    
    // Allocate ROM buffer in PSRAM (size based on actual file, rounded up to 64KB)
    size_t alloc_size = (file_size + 0xFFFF) & ~0xFFFF;  // Round up to 64KB boundary
    if (rom_buffer == NULL) {
        rom_buffer = (uint8_t *)psram_malloc(alloc_size);
        if (rom_buffer == NULL) {
            LOG("Failed to allocate ROM buffer (%lu bytes)!\n", (unsigned long)alloc_size);
            f_close(&file);
            return false;
        }
        LOG("Allocated %lu bytes for ROM\n", (unsigned long)alloc_size);
    }
    
    // Read ROM into buffer
    res = f_read(&file, rom_buffer, file_size, &bytes_read);
    f_close(&file);
    
    if (res != FR_OK || bytes_read != file_size) {
        LOG("Failed to read ROM: %d\n", res);
        return false;
    }
    
    LOG("ROM loaded: %lu bytes\n", (unsigned long)bytes_read);
    
    // Byte-swap ROM (Genesis ROMs are big-endian)
    for (size_t i = 0; i < bytes_read; i += 2) {
        uint8_t tmp = rom_buffer[i];
        rom_buffer[i] = rom_buffer[i + 1];
        rom_buffer[i + 1] = tmp;
    }
    
    // Set ROM_DATA to point to our PSRAM buffer
    ROM_DATA = rom_buffer;
    
    return true;
}

// Initialize Genesis emulator
static void genesis_init(void) {
    // Print M68K struct offsets for assembly optimization
    printf("M68K struct offsets:\n");
    printf("  cycles:      %zu\n", offsetof(m68ki_cpu_core, cycles));
    printf("  cycle_end:   %zu\n", offsetof(m68ki_cpu_core, cycle_end));
    printf("  dar:         %zu\n", offsetof(m68ki_cpu_core, dar));
    printf("  pc:          %zu\n", offsetof(m68ki_cpu_core, pc));
    printf("  ir:          %zu\n", offsetof(m68ki_cpu_core, ir));
    printf("  stopped:     %zu\n", offsetof(m68ki_cpu_core, stopped));
    printf("  sizeof:      %zu\n", sizeof(m68ki_cpu_core));
    
    // Clear RAM
    memset(M68K_RAM, 0, MAX_RAM_SIZE);
    memset(ZRAM, 0, MAX_Z80_RAM_SIZE);
    
    // Initialize Z80
    z80_set_memory(ZRAM);
    z80_start();
    z80_pulse_reset();
    
    // Initialize M68K
    m68k_init();
    m68k_pulse_reset();
    
    // Initialize YM2612
    YM2612Init();
    YM2612ResetChip();  // MUST call reset to clear all registers after init
    YM2612Config(9);
    
    // Initialize PSG
    gwenesis_SN76489_Init(3579545, 888 * 60, AUDIO_FREQ_DIVISOR);
    gwenesis_SN76489_Reset();
    
    // Initialize VDP
    gwenesis_vdp_reset();
    gwenesis_vdp_set_buffer((uint8_t *)SCREEN);
    
    // Clear screen buffer to avoid garbage (Genesis NTSC is 224 lines, buffer is 240)
    memset(SCREEN, 0, sizeof(SCREEN));
    
    LOG("Genesis initialized\n");
}

// Set up Genesis palette for HDMI
static void setup_genesis_palette(void) {
    // Genesis uses 9-bit color (3 bits per channel)
    // Initialize all palette entries to black
    // The actual palette will be updated from CRAM during emulation by VDP
    for (int i = 0; i < 256; i++) {
        graphics_set_palette(i, 0x000000);
    }
}

// Sound processing on Core 1 (I2S output only)
// With GWENESIS_AUDIO_ACCURATE=1, sound chips are run during M68K/Z80 emulation
// Core 1 just submits the already-generated samples to I2S DMA
static void __scratch_x("sound") sound_core(void) {
    // Allow core 0 to pause this core during flash operations
    multicore_lockout_victim_init();
    
    // Initialize audio on Core 1
    audio_init();
    
    // CRITICAL: Warmup period - wait for I2S/DMA to stabilize
    // Don't call audio_submit() - just wait
    LOG("Audio: Warmup delay...\n");
    sleep_ms(500);
    LOG("Audio: Warmup complete\n");
    
    // Signal that we're ready
    sem_release(&render_start_semaphore);
    
    // Core 1 loop - synchronized with Core 0 emulation
    while (1) {
        // Wait for Core 0 to complete a frame
        while (!frame_ready) {
            tight_loop_contents();
        }
        frame_ready = false;
        
        // Memory barrier to ensure we see all writes from Core 0
        __dmb();
        
        // Submit samples to I2S - samples were already generated during emulation
        // This blocks until previous frame's DMA is done
        audio_submit();
        
        // Signal Core 0 that audio is done
        audio_done = true;
    }
}

// Main emulation loop
static void __time_critical_func(emulation_loop)(void) {
    // Initialize screen dimensions
    screen_width = 320;
    screen_height = 224;
    int last_screen_width = 0;
    int last_screen_height = 0;
    
    gwenesis_vdp_set_buffer((uint8_t *)SCREEN);
    gwenesis_vdp_render_config();
    
    // Frame timing state (used for both pacing and adaptive frame-skip)
    uint64_t first_frame_time = 0;
    uint32_t frame_num = 0;
    uint32_t consecutive_skipped_frames = 0;
    uint32_t frame_budget_us = 16666;
    uint64_t frame_work_start_us = 0;
    uint32_t frame_work_us = 0;
    uint32_t audio_wait_us_local = 0;

    // Adaptive frameskip state
    uint32_t backlog_us = 0;                 // accumulated "time behind" (work - budget)
    uint32_t render_cost_ema_us = 0;         // EMA of render cost when we do render
    int last_rendered_parity = -1;           // 0/1 or -1 unknown
    uint32_t same_parity_render_count = 0;   // count of repeated parity renders (can cause blink invisibility)

    while (1) {
        int hint_counter = gwenesis_vdp_regs[10];
        
        bool is_pal = REG1_PAL;
        // Target frame budget for adaptive frame skipping
        frame_budget_us = 1000000u / (is_pal ? GWENESIS_REFRESH_RATE_PAL : GWENESIS_REFRESH_RATE_NTSC);
        screen_width = REG12_MODE_H40 ? 320 : 256;
        screen_height = is_pal ? 240 : 224;
        lines_per_frame = is_pal ? LINES_PER_FRAME_PAL : LINES_PER_FRAME_NTSC;
        
        // Only update graphics config when screen dimensions change
        bool force_render = false;
        if (screen_width != last_screen_width || screen_height != last_screen_height) {
            graphics_set_res(screen_width, screen_height);
            graphics_set_shift(screen_width != 320 ? 32 : 0, screen_height != 240 ? 8 : 0);
            gwenesis_vdp_render_config();
            last_screen_width = screen_width;
            last_screen_height = screen_height;
            force_render = true;
        }

        // Decide whether to render this frame (video-only). Emulation + audio run every frame.
        // If we're consistently too slow, build backlog_us and skip some renders.
        bool render_this_frame = true;
#if ENABLE_ADAPTIVE_FRAMESKIP
        // If we have backlog, prefer skipping render (saves render_cost_ema_us).
        uint32_t estimated_render_cost_us = render_cost_ema_us ? render_cost_ema_us : FRAMESKIP_RENDER_COST_DEFAULT_US;
    if (backlog_us >= (estimated_render_cost_us / FRAMESKIP_SKIP_THRESHOLD_DIVISOR) && estimated_render_cost_us) {
            render_this_frame = false;
        }
        // Safety: always render at least once every (FRAMESKIP_MAX_CONSECUTIVE + 1) frames.
        if (consecutive_skipped_frames >= FRAMESKIP_MAX_CONSECUTIVE) {
            render_this_frame = true;
        }

        // Parity fairness / blink protection:
        // Many games blink by toggling sprite visibility every frame. If we only ever render
        // one parity (even/odd), we can miss the sprite entirely. In strong mode, never skip
        // the opposite parity frame after a render (caps to ~30Hz but keeps blinking visible).
        if (!render_this_frame && last_rendered_parity >= 0) {
            int current_parity = (int)(frame_num & 1u);
#if FRAMESKIP_STRONG_BLINK_PROTECTION
            if (current_parity != last_rendered_parity) {
                render_this_frame = true;
            }
#else
            if (current_parity != last_rendered_parity && same_parity_render_count >= 1u) {
                render_this_frame = true;
            }
#endif
        }
#endif
        if (force_render) {
            render_this_frame = true;
        }

#if ENABLE_ADAPTIVE_FRAMESKIP
        // If we choose to skip, immediately reduce backlog by the estimated render cost.
        // This prevents long streaks of skips and makes the controller more stable.
        if (!render_this_frame && backlog_us) {
            uint32_t dec = render_cost_ema_us ? render_cost_ema_us : FRAMESKIP_RENDER_COST_DEFAULT_US;
            // Slightly over-pay (aggressive) to converge faster.
            uint32_t paydown = (dec * FRAMESKIP_SKIP_PAYDOWN_NUM) / FRAMESKIP_SKIP_PAYDOWN_DEN;
            backlog_us = (backlog_us > paydown) ? (backlog_us - paydown) : 0;
        }
#endif

        PROFILE_FRAME_START();
        frame_work_start_us = time_us_64();
        
        // No explicit frame limiting needed - audio DMA wait provides natural pacing
        // When running fast, Core 1 waits for DMA buffer room (~60 FPS)
        // When running slow, no waiting occurs (raw emulation speed)
        
        system_clock = 0;
        scan_line = 0;
        
        // Reset Z80 clock for new frame (now runs on Core 0)
        extern volatile int zclk;
        zclk = 0;
        
        // Reset sound chip indices for new frame
        sn76489_clock = 0;
        sn76489_index = 0;
        ym2612_clock = 0;
        ym2612_index = 0;
        
        // ==================================================================
        // PHASE 1: Run all emulation first (M68K + Z80 + sound chips)
        // This ensures sound chip state is updated at consistent timing
        // Z80 must run every scanline for proper DAC/PCM timing
        // ==================================================================
        while (scan_line < lines_per_frame) {
            // Run M68K for one line
            PROFILE_START();
#if USE_M68K_FAST_LOOP
            m68k_run_fast(system_clock + VDP_CYCLES_PER_LINE);
#else
            m68k_run(system_clock + VDP_CYCLES_PER_LINE);
#endif
            PROFILE_END(m68k_time);
            
            // Run Z80 every scanline - required for correct PCM audio timing
            PROFILE_START();
            z80_run(system_clock + VDP_CYCLES_PER_LINE);
            PROFILE_END(z80_time);
            
            // Note: Sound chips are called automatically during YM2612Write/SN76489_Write
            // with GWENESIS_AUDIO_ACCURATE=1 for cycle-accurate timing
            
            // Handle line counter interrupt
            if (scan_line == 0 || scan_line > screen_height) {
                hint_counter = gwenesis_vdp_regs[10];
            }
            
            if (--hint_counter < 0) {
                if (REG0_LINE_INTERRUPT != 0 && scan_line <= screen_height) {
                    hint_pending = 1;
                    if ((gwenesis_vdp_status & STATUS_VIRQPENDING) == 0)
                        m68k_update_irq(4);
                }
                hint_counter = gwenesis_vdp_regs[10];
            }
            
            scan_line++;
            
            // VBlank
            if (scan_line == screen_height) {
                if (REG1_VBLANK_INTERRUPT != 0) {
                    gwenesis_vdp_status |= STATUS_VIRQPENDING;
                    m68k_set_irq(6);
                }
                // Z80 IRQ for vblank (Z80 runs on Core 0)
                z80_irq_line(1);
            }
            if (scan_line == screen_height + 1) {
                z80_irq_line(0);
            }
            
            system_clock += VDP_CYCLES_PER_LINE;
        }
        
        // Generate any remaining audio samples for this frame
        // Fixed 888 samples per NTSC frame (53280 Hz / 60 fps)
        #define TARGET_SAMPLES_PER_FRAME 888
        #define AUDIO_TARGET_CLOCK (TARGET_SAMPLES_PER_FRAME * AUDIO_FREQ_DIVISOR)
        PROFILE_START();
        gwenesis_SN76489_run(AUDIO_TARGET_CLOCK);
        ym2612_run(AUDIO_TARGET_CLOCK);
        PROFILE_END(sound_time);
        
        // ==================================================================
        // PHASE 2: Render the frame AFTER emulation is complete
        // This decouples rendering from emulation timing for stable audio
        // ==================================================================
        if (render_this_frame) {
            PROFILE_START();
            uint64_t render_start_us = time_us_64();
            for (int line = 0; line < screen_height; line++) {
                gwenesis_vdp_render_line(line);
            }
            uint32_t render_us = (uint32_t)(time_us_64() - render_start_us);
            PROFILE_END(vdp_time);

#if ENABLE_ADAPTIVE_FRAMESKIP
            // EMA update (1/8 smoothing). Keep a non-zero estimate.
            if (render_cost_ema_us == 0) render_cost_ema_us = render_us ? render_us : FRAMESKIP_RENDER_COST_DEFAULT_US;
            else render_cost_ema_us = (render_cost_ema_us * 7u + (render_us ? render_us : render_cost_ema_us)) / 8u;
#endif
        }
        
        frame_counter++;
        m68k.cycles -= system_clock;

#if M68K_OPCODE_PROFILING
        m68k_check_profile_report();
#endif

        if (render_this_frame) {
            consecutive_skipped_frames = 0;

#if ENABLE_ADAPTIVE_FRAMESKIP
            int current_parity = (int)(frame_num & 1u);
            if (last_rendered_parity == current_parity) same_parity_render_count++;
            else same_parity_render_count = 0;
            last_rendered_parity = current_parity;
#endif
        } else {
            consecutive_skipped_frames++;
        }
        
        // Update sound parameters for Core 1
        sound_screen_height = screen_height;
        sound_lines_per_frame = lines_per_frame;
        
        // ==================================================================
        // PHASE 3: Signal Core 1 to submit audio
        // Must wait for previous audio to complete before reusing buffer
        // ==================================================================

        // Compute work time for this frame (emulation + optional render), excluding audio wait.
        frame_work_us = (uint32_t)(time_us_64() - frame_work_start_us);
        
        // Wait for previous audio submission to complete 
        // This prevents buffer race condition where Core 0 overwrites audio
        // while Core 1 is still reading it
        PROFILE_START();
        uint64_t audio_wait_start_us = time_us_64();
        while (!audio_done && frame_num > 0) {
            tight_loop_contents();
        }
        audio_wait_us_local = (uint32_t)(time_us_64() - audio_wait_start_us);
        PROFILE_END(audio_wait_time);
        audio_done = false;

#if ENABLE_ADAPTIVE_FRAMESKIP
        // Update backlog after the frame's work is complete.
        // If we had to wait for audio, we're not "behind" (audio pacing is active), so pay backlog down.
        {
            int32_t delta = (int32_t)frame_work_us - (int32_t)frame_budget_us;
            if (delta > 0) backlog_us += (uint32_t)delta;
            else {
                uint32_t dec = (uint32_t)(-delta);
                backlog_us = (backlog_us > dec) ? (backlog_us - dec) : 0;
            }

            if (audio_wait_us_local > 500u) {
                backlog_us = 0;
            }

            uint32_t max_backlog_us = frame_budget_us * FRAMESKIP_MAX_BACKLOG_FRAMES;
            if (backlog_us > max_backlog_us) backlog_us = max_backlog_us;
        }
#endif
        
        // Save sample counts for Core 1 BEFORE swapping buffers
        saved_ym_samples = ym2612_index;
        saved_sn_samples = sn76489_index;
        
        // Set read buffer pointers for Core 1 (current write buffer becomes read buffer)
        audio_read_sn76489 = gwenesis_sn76489_buffer;
        audio_read_ym2612 = gwenesis_ym2612_buffer;
        
        // Memory barrier to ensure all writes are visible to Core 1
        __dmb();
        
        // Swap to other buffer for next frame's writes
        audio_write_buffer = 1 - audio_write_buffer;
        gwenesis_sn76489_buffer = gwenesis_sn76489_buffer_mem[audio_write_buffer];
        gwenesis_ym2612_buffer = gwenesis_ym2612_buffer_mem[audio_write_buffer];
        
        // Signal Core 1 to process audio (from read buffer)
        // Core 1's DMA wait provides natural frame pacing when running fast
        frame_ready = true;
        
        frame_num++;
        
        PROFILE_FRAME_END();
        
#ifdef USB_HID_ENABLED
        // Poll USB HID Host for gamepad events
        usbhid_task();
#endif
        
        // Print profiling stats every 300 frames (~5 seconds at 60fps)
        if ((frame_counter % 300) == 0) {
            print_profiling_stats();
        }
    }
}

int main(void) {
    // CRITICAL: Full DMA reset at the very start
    // After warm reset, DMA channels may be running with stale config
    // We can't reset ALL DMA (HDMI uses it), but abort all channels first
    for (int ch = 0; ch < 12; ch++) {
        dma_channel_abort(ch);
    }
    // Wait for all channels to stop
    while (dma_hw->ch[0].ctrl_trig & DMA_CH0_CTRL_TRIG_BUSY_BITS) tight_loop_contents();
    while (dma_hw->ch[1].ctrl_trig & DMA_CH1_CTRL_TRIG_BUSY_BITS) tight_loop_contents();
    // Clear all DMA IRQ flags
    dma_hw->ints0 = 0xFFFF;
    dma_hw->ints1 = 0xFFFF;
    
    // Invalidate XIP cache to ensure clean flash data after reset
    extern void xip_cache_clean_all(void);
    xip_cache_clean_all();
    
    // Early delay to let hardware settle
    for (volatile int i = 0; i < 1000000; i++) { }
    
    // CRITICAL: Force cold-boot behavior on warm resets
    // The reset button doesn't zero .bss like a power-on does
    // Reset all critical audio state immediately
    frame_ready = false;
    audio_done = true;
    last_frame_sample = 0;
    audio_write_buffer = 0;
    sn76489_index = 0;
    sn76489_clock = 0;
    ym2612_index = 0;
    ym2612_clock = 0;
    saved_ym_samples = 0;
    saved_sn_samples = 0;
    audio_read_sn76489 = NULL;
    audio_read_ym2612 = NULL;
    
    // Overclock support
#if CPU_CLOCK_MHZ > 252
    vreg_disable_voltage_limit();
    vreg_set_voltage(CPU_VOLTAGE);
    set_flash_timings(CPU_CLOCK_MHZ);
    sleep_ms(100);
#endif
    
    // Set system clock
    if (!set_sys_clock_khz(CPU_CLOCK_MHZ * 1000, false)) {
        set_sys_clock_khz(252 * 1000, true);
    }
    
    stdio_init_all();
    
#ifdef USB_HID_ENABLED
    // Initialize USB HID Host (for USB gamepad support)
    usbhid_init();
    LOG("USB HID Host initialized\n");
#else
    // Startup delay for USB serial console (4 seconds)
    for (int i = 0; i < 8; i++) {
        sleep_ms(500);
    }
#endif
    
    LOG("\n\n");
    LOG("========================================\n");
    LOG("   murmgenesis - Genesis for RP2350\n");
    LOG("========================================\n");
    LOG("System Clock: %lu MHz\n", clock_get_hz(clk_sys) / 1000000);
    
    // Initialize PSRAM
    LOG("Initializing PSRAM...\n");
    uint psram_pin = get_psram_pin();
    LOG("PSRAM pin: %u\n", psram_pin);
    psram_init(psram_pin);
    psram_reset();
    LOG("PSRAM initialized\n");
    
    // Mount SD card
    LOG("Mounting SD card...\n");
    FRESULT res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        LOG("Failed to mount SD card: %d\n", res);
        while (1) {
            tight_loop_contents();
        }
    }
    LOG("SD card mounted\n");
    
    // Initialize HDMI on Core 0 - DMA IRQ is timing-critical
    LOG("Initializing HDMI...\n");
    graphics_init(g_out_HDMI);
    
    // Set up screen buffer
    uint8_t *buffer = (uint8_t *)SCREEN;
    graphics_set_buffer(buffer);
    graphics_set_res(SCREEN_WIDTH, SCREEN_HEIGHT);
    graphics_set_shift(0, 0);
    
    // Don't call setup_genesis_palette() yet - we'll do it after ROM selector
    LOG("HDMI initialized\n");
    
    // Initialize semaphore for sound core sync
    sem_init(&render_start_semaphore, 0, 1);
    
    // Zero audio buffers to prevent garbage from previous session after hard reset
    memset(gwenesis_sn76489_buffer_mem, 0, sizeof(gwenesis_sn76489_buffer_mem));
    memset(gwenesis_ym2612_buffer_mem, 0, sizeof(gwenesis_ym2612_buffer_mem));
    
    // Reset buffer pointers to valid zeroed buffers
    gwenesis_sn76489_buffer = gwenesis_sn76489_buffer_mem[0];
    gwenesis_ym2612_buffer = gwenesis_ym2612_buffer_mem[0];
    audio_read_sn76489 = gwenesis_sn76489_buffer_mem[0];
    audio_read_ym2612 = gwenesis_ym2612_buffer_mem[0];
    
    // Launch Core 1 (sound generation + I2S output)
    LOG("Starting sound core...\\n");
    multicore_launch_core1(sound_core);
    
    // Wait for Core 1 to be ready
    sem_acquire_blocking(&render_start_semaphore);
    LOG("Sound core started\\n");
    
    // Initialize gamepad (needed for ROM selector)
    LOG("Initializing gamepad...\n");
#ifdef NESPAD_GPIO_CLK
    if (nespad_begin(clock_get_hz(clk_sys) / 1000, NESPAD_GPIO_CLK, NESPAD_GPIO_DATA, NESPAD_GPIO_LATCH)) {
        LOG("Gamepad initialized (CLK=%d, DATA=%d, LATCH=%d)\n", 
            NESPAD_GPIO_CLK, NESPAD_GPIO_DATA, NESPAD_GPIO_LATCH);
    } else {
        LOG("Failed to initialize gamepad!\n");
    }
#else
    LOG("Gamepad not configured for this board\n");
#endif
    
    // Set up a simple palette for ROM selector (before calling it)
    LOG("Setting up ROM selector palette...\n");
    graphics_set_palette(0, 0x000000);      // Black
    graphics_set_palette(63, 0xFFFFFF);     // White (max visible index with 0x3F mask)
    graphics_set_palette(32, 0xFF0000);     // Red for title
    graphics_set_palette(16, 0x404040);     // Dark gray for scrollbar
    
    // Show ROM selector
    LOG("Showing ROM selector...\n");
    static char selected_rom[MAX_ROM_PATH];
    
    if (!rom_selector_show(selected_rom, sizeof(selected_rom), (uint8_t *)SCREEN)) {
        LOG("No ROM selected!\n");
        while (1) {
            tight_loop_contents();
        }
    }
    
    // Set up Genesis palette after ROM selection
    setup_genesis_palette();
    
    // Load selected ROM
    LOG("Loading ROM: %s\n", selected_rom);
    if (!load_rom(selected_rom)) {
        LOG("Failed to load ROM: %s\n", selected_rom);
        while (1) {
            tight_loop_contents();
        }
    }
    
    // Initialize emulator
    genesis_init();
    
    // Audio is initialized on Core 1 (render_core)
    
    LOG("Starting emulation...\n");
    
    // Run emulation
    emulation_loop();
    
    return 0;
}

// Gwenesis button state is defined in gwenesis_io.c
extern unsigned char button_state[];

// Genesis button mapping (button_state bits):
// Bit 0: Up
// Bit 1: Down  
// Bit 2: Left
// Bit 3: Right
// Bit 0: UP
// Bit 1: DOWN  
// Bit 2: LEFT
// Bit 3: RIGHT
// Bit 4: B
// Bit 5: C
// Bit 6: A
// Bit 7: Start
//
// NES Controller mapping (3-button):
// - D-pad → Genesis D-pad
// - NES B → Genesis B
// - NES A → Genesis A  
// - NES A + B → Genesis A (jump - combo)
// - NES Start → Genesis Start
// - NES Select+B → Genesis C
// - NES Select+A → Genesis C
//
// SNES Controller mapping (6-button):
// - D-pad → Genesis D-pad
// - SNES B (bottom) → Genesis A (jump)
// - SNES A (right) → Genesis B (primary action)
// - SNES Y (left) → Genesis C (secondary action)
// - SNES X (top) → Genesis C (secondary alt)
// - SNES L → Genesis A (jump alt)
// - SNES R → Genesis B (primary alt)
// - Start → Genesis Start
// - Select+Start → Reset to ROM selector

void gwenesis_io_get_buttons(void) {
#ifdef NESPAD_GPIO_CLK
    // Read gamepad state
    nespad_read();
    
    // Debug: track button presses for player 1
    static uint32_t prev_nespad_state = 0;
    uint32_t pressed = nespad_state & ~prev_nespad_state;  // Newly pressed buttons
    
    if (pressed) {
        printf("P1 Raw state: 0x%08lX | Pressed: 0x%08lX | ", 
               (unsigned long)nespad_state, (unsigned long)pressed);
        if (pressed & DPAD_UP)     printf("UP ");
        if (pressed & DPAD_DOWN)   printf("DOWN ");
        if (pressed & DPAD_LEFT)   printf("LEFT ");
        if (pressed & DPAD_RIGHT)  printf("RIGHT ");
        if (pressed & DPAD_SELECT) printf("SELECT ");
        if (pressed & DPAD_START)  printf("START ");
        if (pressed & DPAD_A)      printf("A(NES-A/SNES-B) ");
        if (pressed & DPAD_B)      printf("B(NES-B/SNES-Y) ");
        if (pressed & DPAD_Y)      printf("Y(SNES-A) ");
        if (pressed & DPAD_X)      printf("X(SNES-X) ");
        if (pressed & DPAD_LT)     printf("L ");
        if (pressed & DPAD_RT)     printf("R ");
        printf("\n");
    }
    prev_nespad_state = nespad_state;
    
    // Check for SELECT+START combo to return to ROM selector
    if ((nespad_state & DPAD_SELECT) && (nespad_state & DPAD_START)) {
        // Trigger watchdog reset to restart and show ROM selector
        watchdog_reboot(0, 0, 10);
        while(1) tight_loop_contents();
    }
    
    // Detect if SNES controller (has extended buttons)
    bool is_snes_pad1 = (nespad_state & (DPAD_X | DPAD_Y | DPAD_LT | DPAD_RT));
    bool is_snes_pad2 = (nespad_state2 & (DPAD_X | DPAD_Y | DPAD_LT | DPAD_RT));
    
    // Map buttons to Genesis controller - Pad 1
    button_state[0] = 0xFF; // Start with all buttons released
    
    // D-pad mapping (same for NES/SNES)
    if (nespad_state & DPAD_UP)    button_state[0] &= ~(1 << 0);
    if (nespad_state & DPAD_DOWN)  button_state[0] &= ~(1 << 1);
    if (nespad_state & DPAD_LEFT)  button_state[0] &= ~(1 << 2);
    if (nespad_state & DPAD_RIGHT) button_state[0] &= ~(1 << 3);
    
    if (is_snes_pad1) {
        // SNES controller - 6-button mapping
        // Note: Bit names don't match physical SNES button labels!
        // DPAD_A bit = Physical SNES B button (bottom)
        // DPAD_B bit = Physical SNES Y button (left)
        // DPAD_Y bit = Physical SNES A button (right)
        // DPAD_X bit = Physical SNES X button (top)
        //
        // Mapping for intuitive gameplay:
        // SNES B (bottom) → Genesis A (jump)
        // SNES A (right) → Genesis B (primary action - shoot)
        // SNES Y (left) → Genesis C (secondary action - special)
        // SNES X (top) → Genesis C (alternate)
        // SNES L → Genesis A (alternate jump)
        // SNES R → Genesis B (alternate shoot)
        if (nespad_state & DPAD_A)  button_state[0] &= ~(1 << 6); // SNES B → Genesis A (jump)
        if (nespad_state & DPAD_Y)  button_state[0] &= ~(1 << 4); // SNES A → Genesis B (shoot)
        if (nespad_state & DPAD_B)  button_state[0] &= ~(1 << 5); // SNES Y → Genesis C (special)
        if (nespad_state & DPAD_X)  button_state[0] &= ~(1 << 5); // SNES X → Genesis C (special alt)
        if (nespad_state & DPAD_LT) button_state[0] &= ~(1 << 6); // SNES L → Genesis A (jump alt)
        if (nespad_state & DPAD_RT) button_state[0] &= ~(1 << 4); // SNES R → Genesis B (shoot alt)
    } else {
        // NES controller - button combos
        bool select_pressed = (nespad_state & DPAD_SELECT);
        bool a_pressed = (nespad_state & DPAD_A);
        bool b_pressed = (nespad_state & DPAD_B);
        
        // A+B combo = Jump (Genesis A)
        if (a_pressed && b_pressed) {
            button_state[0] &= ~(1 << 6); // A+B = Genesis A (jump)
        } else {
            if (b_pressed) {
                if (select_pressed) {
                    button_state[0] &= ~(1 << 5); // SELECT+B = Genesis C
                } else {
                    button_state[0] &= ~(1 << 4); // B = Genesis B
                }
            }
            
            if (a_pressed) {
                if (select_pressed) {
                    button_state[0] &= ~(1 << 5); // SELECT+A = Genesis C
                } else {
                    button_state[0] &= ~(1 << 6); // A = Genesis A
                }
            }
        }
    }
    
    if (nespad_state & DPAD_START) button_state[0] &= ~(1 << 7);
    
    // Map buttons to Genesis controller - Pad 2
    button_state[1] = 0xFF;
    
    // D-pad mapping (same for NES/SNES)
    if (nespad_state2 & DPAD_UP)    button_state[1] &= ~(1 << 0);
    if (nespad_state2 & DPAD_DOWN)  button_state[1] &= ~(1 << 1);
    if (nespad_state2 & DPAD_LEFT)  button_state[1] &= ~(1 << 2);
    if (nespad_state2 & DPAD_RIGHT) button_state[1] &= ~(1 << 3);
    
    if (is_snes_pad2) {
        // SNES controller - 6-button mapping (same as pad 1)
        if (nespad_state2 & DPAD_A)  button_state[1] &= ~(1 << 6); // SNES B → Genesis A (jump)
        if (nespad_state2 & DPAD_Y)  button_state[1] &= ~(1 << 4); // SNES A → Genesis B (shoot)
        if (nespad_state2 & DPAD_B)  button_state[1] &= ~(1 << 5); // SNES Y → Genesis C (special)
        if (nespad_state2 & DPAD_X)  button_state[1] &= ~(1 << 5); // SNES X → Genesis C (special alt)
        if (nespad_state2 & DPAD_LT) button_state[1] &= ~(1 << 6); // SNES L → Genesis A (jump alt)
        if (nespad_state2 & DPAD_RT) button_state[1] &= ~(1 << 4); // SNES R → Genesis B (shoot alt)
    } else {
        // NES controller - button combos
        bool select_pressed2 = (nespad_state2 & DPAD_SELECT);
        bool a_pressed2 = (nespad_state2 & DPAD_A);
        bool b_pressed2 = (nespad_state2 & DPAD_B);
        
        // A+B combo = Jump (Genesis A)
        if (a_pressed2 && b_pressed2) {
            button_state[1] &= ~(1 << 6); // A+B = Genesis A (jump)
        } else {
            if (b_pressed2) {
                if (select_pressed2) {
                    button_state[1] &= ~(1 << 5); // SELECT+B = Genesis C
                } else {
                    button_state[1] &= ~(1 << 4); // B = Genesis B
                }
            }
            
            if (a_pressed2) {
                if (select_pressed2) {
                    button_state[1] &= ~(1 << 5); // SELECT+A = Genesis C
                } else {
                    button_state[1] &= ~(1 << 6); // A = Genesis A
                }
            }
        }
    }
    
    if (nespad_state2 & DPAD_START) button_state[1] &= ~(1 << 7);
#else
    // No gamepad - all buttons released
    button_state[0] = 0xFF;
    button_state[1] = 0xFF;
#endif

#ifdef USB_HID_ENABLED
    // Also check USB gamepad (overrides/combines with NES/SNES pad)
    if (usbhid_gamepad_connected()) {
        usbhid_gamepad_state_t gp;
        usbhid_get_gamepad_state(&gp);
        
        // D-pad from USB gamepad
        if (gp.dpad & 0x01) button_state[0] &= ~(1 << 0); // Up
        if (gp.dpad & 0x02) button_state[0] &= ~(1 << 1); // Down
        if (gp.dpad & 0x04) button_state[0] &= ~(1 << 2); // Left
        if (gp.dpad & 0x08) button_state[0] &= ~(1 << 3); // Right
        
        // Buttons from USB gamepad (mapped in process_gamepad_report)
        // bit 0=A, 1=B, 2=C, 3=X, 4=Y, 5=Z, 6=Start, 7=Select/Mode
        if (gp.buttons & 0x01) button_state[0] &= ~(1 << 6); // A → Genesis A
        if (gp.buttons & 0x02) button_state[0] &= ~(1 << 4); // B → Genesis B
        if (gp.buttons & 0x04) button_state[0] &= ~(1 << 5); // C → Genesis C
        if (gp.buttons & 0x40) button_state[0] &= ~(1 << 7); // Start → Genesis Start
        
        // SELECT+START combo for USB gamepad too
        if ((gp.buttons & 0x40) && (gp.buttons & 0x80)) {
            watchdog_reboot(0, 0, 10);
            while(1) tight_loop_contents();
        }
    }
#endif
}
