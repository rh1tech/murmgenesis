/*
 * M68K Memory Access Optimizations - ARM Thumb-2 Assembly (Cortex-M33)
 * 
 * Optimized memory read/write functions for 68000 emulation
 * Handles ROM (< 0x800000), RAM (>= 0xFF0000), and I/O regions
 */

    .syntax unified
    .cpu cortex-m33
    .thumb
    .section .time_critical.m68k,"ax",%progbits

    .extern m68k_read_memory_8
    .extern m68k_read_memory_16
    .extern m68k_read_memory_32
    .extern m68k_write_memory_8
    .extern m68k_write_memory_16
    .extern m68k_write_memory_32
    .extern ROM_DATA
    .extern M68K_RAM

/*
 * Fast 16-bit ROM fetch (most common operation)
 * uint32_t m68k_read_rom16_fast(uint32_t address);
 * 
 * Optimized for aligned ROM reads which are extremely common
 */
    .global m68k_read_rom16_fast
    .type m68k_read_rom16_fast, %function
    .align 4

m68k_read_rom16_fast:
    /* r0 = address */
    ldr     r1, =ROM_DATA
    ldr     r1, [r1]                /* r1 = ROM_DATA pointer */
    ldrh    r0, [r1, r0]            /* Load 16-bit value */
    /* Already in correct byte order - ROM is stored big-endian on RP2350 */
    bx      lr
    
    .size m68k_read_rom16_fast, . - m68k_read_rom16_fast


/*
 * Fast 32-bit ROM fetch  
 * uint32_t m68k_read_rom32_fast(uint32_t address);
 */
    .global m68k_read_rom32_fast
    .type m68k_read_rom32_fast, %function
    .align 4

m68k_read_rom32_fast:
    /* r0 = address */
    ldr     r1, =ROM_DATA
    ldr     r1, [r1]                /* r1 = ROM_DATA pointer */
    ldr     r2, [r1, r0]            /* Load 32-bit value */
    /* Swap 16-bit halves: (value << 16) | (value >> 16) */
    lsr     r0, r2, #16             /* r0 = high half */
    lsl     r2, r2, #16             /* r2 = low half << 16 */
    orr     r0, r2, r0              /* combine */
    bx      lr
    
    .size m68k_read_rom32_fast, . - m68k_read_rom32_fast


/*
 * Fast RAM read 16-bit
 * uint32_t m68k_read_ram16_fast(uint32_t address);
 */
    .global m68k_read_ram16_fast
    .type m68k_read_ram16_fast, %function
    .align 4

m68k_read_ram16_fast:
    /* r0 = address (full 68K address) */
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF             /* Mask for RAM offset */
    and     r0, r0, r2              /* r0 = address & 0xFFFF */
    ldrh    r0, [r1, r0]            /* Load 16-bit value */
    bx      lr
    
    .size m68k_read_ram16_fast, . - m68k_read_ram16_fast


/*
 * Fast RAM write 16-bit
 * void m68k_write_ram16_fast(uint32_t address, uint32_t value);
 */
    .global m68k_write_ram16_fast
    .type m68k_write_ram16_fast, %function
    .align 4

m68k_write_ram16_fast:
    /* r0 = address, r1 = value */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF             /* Mask for RAM offset */
    and     r0, r0, r3              /* r0 = address & 0xFFFF */
    strh    r1, [r2, r0]            /* Store 16-bit value */
    bx      lr
    
    .size m68k_write_ram16_fast, . - m68k_write_ram16_fast


/*
 * Fast RAM write 8-bit
 * void m68k_write_ram8_fast(uint32_t address, uint32_t value);
 */
    .global m68k_write_ram8_fast
    .type m68k_write_ram8_fast, %function
    .align 4

m68k_write_ram8_fast:
    /* r0 = address, r1 = value */
    /* 68K uses byte swapping: address ^ 1 */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF             /* Mask for RAM offset */
    and     r0, r0, r3              /* r0 = address & 0xFFFF */
    eor     r0, r0, #1              /* XOR with 1 for byte swap */
    strb    r1, [r2, r0]            /* Store 8-bit value */
    bx      lr
    
    .size m68k_write_ram8_fast, . - m68k_write_ram8_fast


    .end
