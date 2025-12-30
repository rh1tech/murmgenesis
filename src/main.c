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
#include "cpus/M68K/m68k.h"
#include "sound/z80inst.h"
#include "sound/ym2612.h"
#include "sound/gwenesis_sn76489.h"

// Audio driver
#include "audio.h"

// Pico audio for buffer types
#define none pico_audio_enum_none
#include "pico/audio_i2s.h"
#undef none

// Gamepad driver
#include "nespad/nespad.h"

//=============================================================================
// Profiling
//=============================================================================

// Simple logging
#define LOG(fmt, ...) printf(fmt, ##__VA_ARGS__)

#define ENABLE_PROFILING 1
#define DISABLE_FRAME_LIMITING 0

// Use assembly-optimized M68K loop (set to 0 to use original C loop for debugging)
#define USE_M68K_FAST_LOOP 0

#if USE_M68K_FAST_LOOP
// Assembly-optimized M68K execution loop
extern void m68k_run_fast(unsigned int cycles);
#endif

// Emulation speed control (in percentage: 100 = normal, 50 = half speed, 150 = 1.5x speed)
#define EMULATION_SPEED_PERCENT 100

#if ENABLE_PROFILING
typedef struct {
    uint64_t m68k_time;
    uint64_t vdp_time;
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
    
    LOG("\n=== Profiling Stats (avg per frame over %u frames) ===\n", profile_stats.frame_count);
    LOG("M68K execution:  %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.m68k_time / profile_stats.frame_count),
        (int)((profile_stats.m68k_time * 100) / total));
    LOG("VDP rendering:   %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.vdp_time / profile_stats.frame_count),
        (int)((profile_stats.vdp_time * 100) / total));
    LOG("Idle/sync:       %6lu us (%3d%%)\n", 
        (unsigned long)(profile_stats.idle_time / profile_stats.frame_count),
        (int)((profile_stats.idle_time * 100) / total));
    LOG("Total frame:     %6lu us (min=%lu, max=%lu)\n", 
        (unsigned long)(total / profile_stats.frame_count),
        (unsigned long)profile_stats.min_frame_time,
        (unsigned long)profile_stats.max_frame_time);
    LOG("Frame rate:      %6.2f fps (target=60.00)\n", 1000000.0 / (total / (float)profile_stats.frame_count));
    LOG("Frame variance:  slow=%u (>17ms), fast=%u (<16ms)\n",
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

// Audio buffers - keep in regular SRAM (not PSRAM) to avoid contention
// Use __not_in_flash to ensure they stay in RAM
static int16_t __not_in_flash("audio") gwenesis_sn76489_buffer_mem[GWENESIS_AUDIO_BUFFER_LENGTH_NTSC * 2];
static int16_t __not_in_flash("audio") gwenesis_ym2612_buffer_mem[GWENESIS_AUDIO_BUFFER_LENGTH_NTSC * 2];

// Exported pointers for external access
int16_t *gwenesis_sn76489_buffer = gwenesis_sn76489_buffer_mem;
int16_t *gwenesis_ym2612_buffer = gwenesis_ym2612_buffer_mem;

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

// Sound processing on Core 1 (Z80 + YM2612 + SN76489 + I2S)
static void __scratch_x("sound") sound_core(void) {
    // Allow core 0 to pause this core during flash operations
    multicore_lockout_victim_init();
    
    // Initialize audio on Core 1
    audio_init();
    
    // Signal that we're ready
    sem_release(&render_start_semaphore);
    
    // Sound runs at fixed 60Hz regardless of rendering speed
    uint64_t last_sound_frame = time_us_64();
    const uint64_t sound_frame_period = 16666; // 60Hz fixed
    
    // Core 1 loop - runs Z80 + sound chips (complete sound subsystem)
    while (1) {
        uint64_t now = time_us_64();
        
        // Process sound frame at fixed 60Hz
        if (now >= last_sound_frame + sound_frame_period) {
            int lpf = sound_lines_per_frame;
            
            // Reset sound chip indices for this frame
            sn76489_clock = 0;
            sn76489_index = 0;
            ym2612_clock = 0;
            ym2612_index = 0;
            
            // Sound chips generate samples based on their internal state
            // (which was updated by Z80 writes from Core 0)
            for (int line = 0; line < lpf; line++) {
                int line_clock = (line + 1) * VDP_CYCLES_PER_LINE;
                
                // Run sound chips to generate audio samples
                gwenesis_SN76489_run(line_clock);
                ym2612_run(line_clock);
            }
            
            // Mix and output audio
            audio_update();
            
            // Debug first few frames
            static int sound_debug_count = 0;
            if (sound_debug_count < 3) {
                audio_debug_buffer_values();
                sound_debug_count++;
            }
            
            last_sound_frame += sound_frame_period;
        }
        
        // Continuously feed I2S buffers
        audio_buffer_t *buffer = take_audio_buffer(audio_get_producer_pool(), false);
        if (buffer != NULL) {
            audio_fill_buffer(buffer);
        }
        
        tight_loop_contents();
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

    while (1) {
        int hint_counter = gwenesis_vdp_regs[10];
        
        bool is_pal = REG1_PAL;
        screen_width = REG12_MODE_H40 ? 320 : 256;
        screen_height = is_pal ? 240 : 224;
        lines_per_frame = is_pal ? LINES_PER_FRAME_PAL : LINES_PER_FRAME_NTSC;
        
        // Only update graphics config when screen dimensions change
        if (screen_width != last_screen_width || screen_height != last_screen_height) {
            graphics_set_res(screen_width, screen_height);
            graphics_set_shift(screen_width != 320 ? 32 : 0, screen_height != 240 ? 8 : 0);
            gwenesis_vdp_render_config();
            last_screen_width = screen_width;
            last_screen_height = screen_height;
        }
        
        // ------------------------------------------------------------------
        // Timing + adaptive frame-skip
        //
        // Goal: keep emulation (and therefore audio/game speed) on a fixed
        // wall-clock cadence. If rendering makes us fall behind, skip rendering
        // for that frame instead of slowing emulation.
        // ------------------------------------------------------------------
        bool render_this_frame = true;

#if !DISABLE_FRAME_LIMITING
        {
            const uint64_t now = time_us_64();
            const uint64_t base_period_us = is_pal ? 20000u : 16666u; // 50Hz vs 60Hz
            const uint64_t frame_period_us = (base_period_us * 100u) / EMULATION_SPEED_PERCENT;

            if (frame_num == 0) {
                first_frame_time = now;
            }

            const uint64_t expected_start = first_frame_time + ((uint64_t)frame_num * frame_period_us);
            const int64_t lateness_us = (int64_t)now - (int64_t)expected_start;

            // Fixed frame-skip: render every 2nd frame (30 fps)
            render_this_frame = ((frame_num & 1u) == 0u);

            // If we're way behind, resync to avoid a catch-up spiral.
            if (lateness_us > (int64_t)(frame_period_us * 2)) {
                first_frame_time = now;
                frame_num = 0;
                render_this_frame = true;
                consecutive_skipped_frames = 0;
            }
        }
#endif

        PROFILE_FRAME_START();
        
        system_clock = 0;
        scan_line = 0;
        
        // Reset Z80 clock for new frame (now runs on Core 0)
        extern volatile int zclk;
        zclk = 0;
        
        // Run Z80 in larger chunks to reduce overhead (every 32 scanlines instead of every line)
        int z80_lines_per_chunk = 32;
        
        // ==================================================================
        // PHASE 1: Run all emulation first (M68K + Z80 + interrupts)
        // This ensures sound chip state is updated at consistent timing
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
            
            // Run Z80 every N scanlines to reduce function call overhead
            if ((scan_line % z80_lines_per_chunk) == (z80_lines_per_chunk - 1) || scan_line == lines_per_frame - 1) {
                int line_clock = (scan_line + 1) * VDP_CYCLES_PER_LINE;
                z80_run(line_clock);
            }
            
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
        
        // ==================================================================
        // PHASE 2: Render the frame AFTER emulation is complete
        // This decouples rendering from emulation timing for stable audio
        // ==================================================================
        if (render_this_frame) {
            PROFILE_START();
            for (int line = 0; line < screen_height; line++) {
                gwenesis_vdp_render_line(line);
            }
            PROFILE_END(vdp_time);
        }
        
        frame_counter++;
        m68k.cycles -= system_clock;

        if (render_this_frame) {
            consecutive_skipped_frames = 0;
        } else {
            consecutive_skipped_frames++;
        }
        
        // Update sound parameters (Core 1 runs independently)
        sound_screen_height = screen_height;
        sound_lines_per_frame = lines_per_frame;
        
#if !DISABLE_FRAME_LIMITING
        {
            const uint64_t base_period_us = is_pal ? 20000u : 16666u; // 50Hz vs 60Hz
            const uint64_t frame_period_us = (base_period_us * 100u) / EMULATION_SPEED_PERCENT;

            // Advance to next frame slot and wait if we're ahead.
            frame_num++;
            const uint64_t target_time = first_frame_time + ((uint64_t)frame_num * frame_period_us);

            while (time_us_64() < target_time) {
                const uint64_t remaining = target_time - time_us_64();
                if (remaining > 1000) {
                    // Sleep for most of the wait, but in small chunks.
                    sleep_us(500);
                } else {
                    tight_loop_contents();
                }
            }
        }
#endif
        
        PROFILE_FRAME_END();
        
        // Print profiling stats every 300 frames (~5 seconds at 60fps)
        if ((frame_counter % 300) == 0) {
            print_profiling_stats();
        }
    }
}

int main(void) {
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
    
    // Startup delay for USB serial console (4 seconds)
    for (int i = 0; i < 8; i++) {
        sleep_ms(500);
    }
    
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
    
    setup_genesis_palette();
    LOG("HDMI initialized\n");
    
    // Initialize semaphore for sound core sync
    sem_init(&render_start_semaphore, 0, 1);
    
    // Launch Core 1 (Z80 + sound only, no HDMI)
    LOG("Starting sound core...\n");
    multicore_launch_core1(sound_core);
    
    // Wait for Core 1 to be ready
    sem_acquire_blocking(&render_start_semaphore);
    LOG("Sound core started\n");
    
    // Load ROM
    LOG("Loading ROM...\n");
    if (!load_rom("/genesis/test.md")) {
        LOG("Failed to load ROM!\n");
        // Try alternate paths
        if (!load_rom("/GENESIS/test.md") && 
            !load_rom("/genesis/test.bin") &&
            !load_rom("/GENESIS/test.gen")) {
            LOG("Could not find test ROM!\n");
            while (1) {
                tight_loop_contents();
            }
        }
    }
    
    // Initialize emulator
    genesis_init();
    
    // Audio is initialized on Core 1 (render_core)
    
    // Initialize gamepad
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
// Bit 4: B (SNES Y)
// Bit 5: C (SNES B)
// Bit 6: A (SNES A)
// Bit 7: Start

void gwenesis_io_get_buttons(void) {
#ifdef NESPAD_GPIO_CLK
    // Read gamepad state
    nespad_read();
    
    // Map NES/SNES buttons to Genesis controller
    // Pad 1
    button_state[0] = 0xFF; // Start with all buttons released
    if (nespad_state & DPAD_UP)    button_state[0] &= ~(1 << 0);
    if (nespad_state & DPAD_DOWN)  button_state[0] &= ~(1 << 1);
    if (nespad_state & DPAD_LEFT)  button_state[0] &= ~(1 << 2);
    if (nespad_state & DPAD_RIGHT) button_state[0] &= ~(1 << 3);
    if (nespad_state & DPAD_B)     button_state[0] &= ~(1 << 4); // B = SNES Y
    if (nespad_state & DPAD_A)     button_state[0] &= ~(1 << 5); // C = SNES B  
    if (nespad_state & DPAD_Y)     button_state[0] &= ~(1 << 6); // A = SNES A
    if (nespad_state & DPAD_START) button_state[0] &= ~(1 << 7);
    
    // Pad 2
    button_state[1] = 0xFF;
    if (nespad_state2 & DPAD_UP)    button_state[1] &= ~(1 << 0);
    if (nespad_state2 & DPAD_DOWN)  button_state[1] &= ~(1 << 1);
    if (nespad_state2 & DPAD_LEFT)  button_state[1] &= ~(1 << 2);
    if (nespad_state2 & DPAD_RIGHT) button_state[1] &= ~(1 << 3);
    if (nespad_state2 & DPAD_B)     button_state[1] &= ~(1 << 4);
    if (nespad_state2 & DPAD_A)     button_state[1] &= ~(1 << 5);
    if (nespad_state2 & DPAD_Y)     button_state[1] &= ~(1 << 6);
    if (nespad_state2 & DPAD_START) button_state[1] &= ~(1 << 7);
#else
    // No gamepad - all buttons released
    button_state[0] = 0xFF;
    button_state[1] = 0xFF;
#endif
}
