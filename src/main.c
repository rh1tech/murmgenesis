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

//=============================================================================
// Profiling
//=============================================================================

// Simple logging
#define LOG(fmt, ...) printf(fmt, ##__VA_ARGS__)

#define ENABLE_PROFILING 0
#define DISABLE_FRAME_LIMITING 0  // Re-enable frame limiter for normal gameplay

#if ENABLE_PROFILING
typedef struct {
    uint64_t m68k_time;
    uint64_t vdp_time;
    uint64_t frame_time;
    uint64_t idle_time;
    uint32_t frame_count;
} profile_stats_t;

static profile_stats_t profile_stats = {0};
static uint64_t profile_frame_start = 0;
static uint64_t profile_section_start = 0;

#define PROFILE_START() profile_section_start = time_us_64()
#define PROFILE_END(stat) profile_stats.stat += (time_us_64() - profile_section_start)
#define PROFILE_FRAME_START() profile_frame_start = time_us_64()
#define PROFILE_FRAME_END() profile_stats.frame_time += (time_us_64() - profile_frame_start); profile_stats.frame_count++

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
    LOG("Total frame:     %6lu us\n", (unsigned long)(total / profile_stats.frame_count));
    LOG("Frame rate:      %6.2f fps\n", 1000000.0 / (total / (float)profile_stats.frame_count));
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
static volatile bool sound_frame_ready = false;
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

int sn76489_index;
int sn76489_clock;

int ym2612_index;
int ym2612_clock;

// Audio enabled flags
bool audio_enabled = false;
bool sn76489_enabled = false;

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
    
    // Core 1 loop - runs Z80 + sound chips (complete sound subsystem)
    while (1) {
        // Check if Core 0 has completed a frame
        if (sound_frame_ready) {
            int lpf = sound_lines_per_frame;
            
            // Reset sound chip indices for this frame
            sn76489_clock = 0;
            sn76489_index = 0;
            ym2612_clock = 0;
            ym2612_index = 0;
            
            // Run Z80 + sound chips for entire frame
            // Z80 is the sound coprocessor that controls the sound chips
            for (int line = 0; line < lpf; line++) {
                int line_clock = (line + 1) * VDP_CYCLES_PER_LINE;
                
                // Run Z80 for this scanline
                z80_run(line_clock);
                
                // Run sound chips
                gwenesis_SN76489_run(line_clock);
                ym2612_run(line_clock);
                
                // Handle Z80 IRQ at vblank
                if (line == sound_screen_height) {
                    z80_irq_line(1);
                }
                if (line == sound_screen_height + 1) {
                    z80_irq_line(0);
                }
            }
            
            // Mix and output audio
            audio_update();
            
            sound_frame_ready = false;
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
        
        PROFILE_FRAME_START();
        
        system_clock = 0;
        scan_line = 0;
        
        while (scan_line < lines_per_frame) {
            // Run M68K for one line
            PROFILE_START();
            m68k_run(system_clock + VDP_CYCLES_PER_LINE);
            PROFILE_END(m68k_time);
            
            // Z80 runs on Core 1 with sound chips
            
            // Render line (24 fps: render frames 0,3,5,8,10... - 2 out of every 5 frames)
            uint32_t frame_mod = frame_counter % 5;
            if ((frame_mod == 0 || frame_mod == 3) && scan_line < screen_height) {
                PROFILE_START();
                gwenesis_vdp_render_line(scan_line);
                PROFILE_END(vdp_time);
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
                // Z80 IRQ handled on Core 1
            }
            
            // Sound chips run on Core 1 - no sound processing here
            
            system_clock += VDP_CYCLES_PER_LINE;
        }
        
        frame_counter++;
        m68k.cycles -= system_clock;
        
        // Signal Core 1 to process Z80 + sound for this frame
        sound_screen_height = screen_height;
        sound_lines_per_frame = lines_per_frame;
        sound_frame_ready = true;
        
#if !DISABLE_FRAME_LIMITING
        // Frame timing to reduce memory bus contention
        // Use WFI (Wait For Interrupt) to sleep but remain responsive to audio DMA
        static uint64_t last_frame = 0;
        uint64_t target_time = last_frame + 16666;
        
        // Sleep in small chunks to remain responsive
        while (time_us_64() < target_time) {
            uint64_t remaining = target_time - time_us_64();
            if (remaining > 100) {
                // Sleep for small intervals, allowing interrupts
                __wfi();  // Wait for interrupt - very low power, wakes on any interrupt
            } else {
                // Final microseconds - busy wait for precision
                tight_loop_contents();
            }
        }
        last_frame = target_time;
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
    
    LOG("Starting emulation...\n");
    
    // Run emulation
    emulation_loop();
    
    return 0;
}

// Gwenesis button state is defined in gwenesis_io.c
extern unsigned char button_state[];

void gwenesis_io_get_buttons(void) {
    // No input handling yet - buttons all released  
    button_state[0] = 0xFF;
    button_state[1] = 0xFF;
}
