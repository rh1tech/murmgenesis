cmake_minimum_required(VERSION 3.13)

# Set board to Pico 2 (RP2350)
set(PICO_BOARD pico2 CACHE STRING "Pico board type")

# Board configuration variant (M1, M2)
set(BOARD_VARIANT "M1" CACHE STRING "Board variant: M1 or M2")

# CPU overclock configuration (252, 378, 504 MHz)
set(CPU_SPEED "378" CACHE STRING "CPU clock in MHz: 252, 378, 504")

# PSRAM speed configuration (84, 100, 133, 166 MHz target)
set(PSRAM_SPEED "100" CACHE STRING "PSRAM max frequency in MHz: 84, 100, 133, 166")

# Z80 scheduling: run the Z80 core less often to reduce interpreter overhead.
# Higher values generally improve performance but can reduce timing fidelity for
# some PCM-heavy drivers.
set(Z80_SLICE_LINES "16" CACHE STRING "Run Z80 every N scanlines (default 16)")

# CPU voltage selection based on speed
if(CPU_SPEED GREATER_EQUAL 504)
    set(CPU_VOLTAGE "VREG_VOLTAGE_1_65")
elseif(CPU_SPEED GREATER_EQUAL 378)
    set(CPU_VOLTAGE "VREG_VOLTAGE_1_60")
else()
    set(CPU_VOLTAGE "VREG_VOLTAGE_1_50")
endif()

message(STATUS "Board: ${BOARD_VARIANT}, CPU: ${CPU_SPEED} MHz, PSRAM: ${PSRAM_SPEED} MHz, Voltage: ${CPU_VOLTAGE}")

include(pico_sdk_import.cmake)

# Import pico-extras for audio_i2s library
set(PICO_EXTRAS_PATH ${CMAKE_CURRENT_LIST_DIR}/pico-extras CACHE PATH "Path to pico-extras")
if(EXISTS ${PICO_EXTRAS_PATH}/external/pico_extras_import.cmake)
    include(${PICO_EXTRAS_PATH}/external/pico_extras_import.cmake)
endif()

project(murmgenesis C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

# Inject version.txt as a compile-time string.
file(READ "${CMAKE_CURRENT_LIST_DIR}/version.txt" MURMGENESIS_VERSION_RAW)
string(STRIP "${MURMGENESIS_VERSION_RAW}" MURMGENESIS_VERSION_RAW)
string(REGEX REPLACE "[ \t]+" "." MURMGENESIS_VERSION "${MURMGENESIS_VERSION_RAW}")

pico_sdk_init()

# Initialize pico-extras if available
if(COMMAND pico_extras_init)
    pico_extras_init()
endif()

# Add fatfs
add_subdirectory(src/fatfs)
# Add drivers
add_subdirectory(drivers/sdcard)
add_subdirectory(drivers/nespad)

# Create a library for other drivers
add_library(drivers
    drivers/HDMI.c
    drivers/hdmi_scanline.S
    drivers/psram_init.c
    drivers/psram_allocator.c
    drivers/audio.c
)

# Generate PIO header for I2S audio
pico_generate_pio_header(drivers ${CMAKE_CURRENT_LIST_DIR}/drivers/audio_i2s.pio)

target_include_directories(drivers PUBLIC drivers src ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(drivers PRIVATE
    BOARD_${BOARD_VARIANT}
    PSRAM_MAX_FREQ_MHZ=${PSRAM_SPEED}
)

target_link_libraries(drivers pico_stdlib hardware_dma hardware_pio hardware_spi)

# Gwenesis emulator sources
set(GWENESIS_SOURCES
    # Bus
    src/bus/gwenesis_bus.c
    # CPUs
    src/cpus/M68K/m68kcpu.c
    src/cpus/M68K/m68k_memory_opt.S
    src/cpus/M68K/m68k_core_opt.S
    # Assembly instruction handlers disabled (256KB jump table doesn't fit in RAM)
    # src/cpus/M68K/m68k_ops_opt.S
    src/cpus/Z80/Z80.c
    src/cpus/Z80/z80_arm.S
    # IO
    src/io/gwenesis_io.c
    # Sound
    src/sound/gwenesis_sn76489.c
    src/sound/ym2612.c
    src/sound/ym2612_opt.S
    src/sound/z80inst.c
    src/sound/z80_mem_opt.S
    # VDP
    src/vdp/gwenesis_vdp_gfx.c
    src/vdp/gwenesis_vdp_mem.c
    # Savestate
    src/savestate/gwenesis_savestate.c
)

# Apply aggressive optimizations to M68K CPU
set_source_files_properties(src/cpus/M68K/m68kcpu.c PROPERTIES
    COMPILE_FLAGS "-O3 -ffast-math -funroll-loops -finline-functions"
)

add_executable(murmgenesis
    src/main.c
    src/rom_selector.c
    ${GWENESIS_SOURCES}
)

target_include_directories(murmgenesis PRIVATE
    src
    src/bus
    src/cpus/M68K
    src/cpus/Z80
    src/io
    src/sound
    src/vdp
    src/savestate
    src/fatfs
    drivers
    drivers/sdcard
)

target_compile_definitions(murmgenesis PRIVATE
    BOARD_${BOARD_VARIANT}
    CPU_CLOCK_MHZ=${CPU_SPEED}
    CPU_VOLTAGE=${CPU_VOLTAGE}
    PSRAM_MAX_FREQ_MHZ=${PSRAM_SPEED}
    PICO_ON_DEVICE=1
    MURMGENESIS_VERSION="${MURMGENESIS_VERSION}"
    # Gwenesis configuration
    ROM_SWAP=0
    BUS_DISABLE_LOGGING=1
    VDP_GFX_DISABLE_LOGGING=1
    ENABLE_LOGGING=0
    # I2S Audio configuration - use PIO0 to avoid conflict with HDMI on PIO1
    PICO_AUDIO_I2S_PIO=0
    PICO_AUDIO_I2S_DMA_IRQ=1
    Z80_SLICE_LINES=${Z80_SLICE_LINES}
)

# Set peripheral pins based on board variant
if(BOARD_VARIANT STREQUAL "M1")
    target_compile_definitions(murmgenesis PRIVATE
        # I2S Audio
        PICO_AUDIO_I2S_DATA_PIN=26
        PICO_AUDIO_I2S_CLOCK_PIN_BASE=27
        # SD Card
        SDCARD_PIN_SPI0_CS=5
        SDCARD_PIN_SPI0_SCK=2
        SDCARD_PIN_SPI0_MOSI=3
        SDCARD_PIN_SPI0_MISO=4
        # NES/SNES Gamepad
        NESPAD_GPIO_CLK=14
        NESPAD_GPIO_LATCH=15
        NESPAD_GPIO_DATA=16
    )
elseif(BOARD_VARIANT STREQUAL "M2")
    target_compile_definitions(murmgenesis PRIVATE
        # I2S Audio
        PICO_AUDIO_I2S_DATA_PIN=9
        PICO_AUDIO_I2S_CLOCK_PIN_BASE=10
        # SD Card
        SDCARD_PIN_SPI0_CS=5
        SDCARD_PIN_SPI0_SCK=6
        SDCARD_PIN_SPI0_MOSI=7
        SDCARD_PIN_SPI0_MISO=4
    )
endif()

target_link_libraries(murmgenesis
    pico_stdlib
    pico_multicore
    hardware_spi
    hardware_dma
    hardware_pio
    hardware_pwm
    hardware_irq
    sdcard
    fatfs
    drivers
    nespad
)

# USB configuration: stdio vs HID Host (mutually exclusive)
if(USB_HID_ENABLED)
    # USB HID Host mode - disable USB stdio, use UART instead
    pico_enable_stdio_usb(murmgenesis 0)
    pico_enable_stdio_uart(murmgenesis 1)
    message(STATUS "USB HID Host enabled - using UART for stdio")
    
    # Add USB HID driver
    add_subdirectory(drivers/usbhid)
    target_link_libraries(murmgenesis usbhid)
else()
    # USB Device mode for stdio
    pico_enable_stdio_usb(murmgenesis 1)
    pico_enable_stdio_uart(murmgenesis 0)
endif()

pico_add_extra_outputs(murmgenesis)
