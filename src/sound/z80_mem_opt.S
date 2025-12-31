/*
 * ARM Assembly-optimized Z80 memory access functions for RP2350
 * Optimizes the critical RdZ80() and WrZ80() hot paths
 */

.syntax unified
.cpu cortex-m33
.thumb

.section .time_critical.z80_mem_opt, "ax"

/* External symbols */
.extern Z80_RAM
.extern YM2612Read
.extern YM2612Write
.extern gwenesis_SN76489_Write
.extern zbank_mem_r8
.extern zbank_mem_w8
.extern zbankreg_mem_w8
.extern zclk
.extern current_timeslice
.extern cpu

/* Constants */
.equ Z80_FREQ_DIVISOR, 15
.equ Z80_ICOUNT_OFFSET, 84  /* Offset of ICount in Z80 structure */

/*
 * byte RdZ80(register word Addr)
 * 
 * Optimized Z80 memory read function
 * Input: r0 = Address (word/uint16_t)
 * Output: r0 = Value (byte/uint8_t)
 * 
 * Memory map:
 *   0x0000-0x3FFF: Z80 RAM (8KB, mirrored every 2KB)
 *   0x4000-0x5FFF: YM2612 chip
 *   0x6000-0x7FFF: Bank register / SN76489
 *   0x8000-0xFFFF: Banked M68K memory
 */
.global RdZ80
.type RdZ80, %function
.thumb_func
RdZ80:
    push    {r4, lr}
    
    /* Fast path: Check if address < 0x4000 (Z80 RAM) */
    ldr     r1, =0x4000
    cmp     r0, r1
    bhs     .LRdZ80_NotRam
    
    /* Z80 RAM access: Addr & 0x1FFF */
    ldr     r1, =Z80_RAM
    ldr     r1, [r1]            /* Load Z80_RAM pointer */
    movw    r2, #0x1FFF         /* Load mask into register */
    and     r0, r0, r2          /* Mask to 8KB with mirroring */
    ldrb    r0, [r1, r0]        /* Load byte from Z80_RAM[Addr & 0x1FFF] */
    pop     {r4, pc}

.LRdZ80_NotRam:
    /* Check if address < 0x6000 (YM2612) */
    ldr     r1, =0x6000
    cmp     r0, r1
    bhs     .LRdZ80_NotYM2612
    
    /* YM2612 access - calculate cycle timing */
    /* zclk + current_timeslice - (cpu.ICount * Z80_FREQ_DIVISOR) */
    ldr     r1, =zclk
    ldr     r2, [r1]            /* r2 = zclk */
    ldr     r1, =current_timeslice
    ldr     r3, [r1]            /* r3 = current_timeslice */
    add     r2, r2, r3          /* r2 = zclk + current_timeslice */
    
    ldr     r1, =cpu
    ldr     r3, [r1, #Z80_ICOUNT_OFFSET]  /* r3 = cpu.ICount */
    mov     r1, #Z80_FREQ_DIVISOR
    mul     r3, r3, r1          /* r3 = cpu.ICount * Z80_FREQ_DIVISOR */
    sub     r0, r2, r3          /* r0 = timing parameter */
    
    bl      YM2612Read
    pop     {r4, pc}

.LRdZ80_NotYM2612:
    /* Check if address >= 0x8000 (Banked memory) */
    ldr     r1, =0x8000
    cmp     r0, r1
    bhs     .LRdZ80_Banked
    
    /* Unknown/unmapped address, return 0xFF */
    mov     r0, #0xFF
    pop     {r4, pc}

.LRdZ80_Banked:
    /* Call zbank_mem_r8(Addr) */
    bl      zbank_mem_r8
    pop     {r4, pc}

.size RdZ80, .-RdZ80


/*
 * void WrZ80(register word Addr, register byte Value)
 * 
 * Optimized Z80 memory write function
 * Input: r0 = Address (word/uint16_t)
 *        r1 = Value (byte/uint8_t)
 * Output: none
 * 
 * Memory map:
 *   0x0000-0x3FFF: Z80 RAM (8KB, mirrored every 2KB)
 *   0x4000-0x5FFF: YM2612 chip
 *   0x6000: Bank register
 *   0x7F11: SN76489 PSG
 *   0x8000-0xFFFF: Banked M68K memory
 */
.global WrZ80
.type WrZ80, %function
.thumb_func
WrZ80:
    push    {r4-r6, lr}
    mov     r4, r0              /* Save Addr in r4 */
    mov     r5, r1              /* Save Value in r5 */
    
    /* Fast path: Check if address < 0x4000 (Z80 RAM) */
    ldr     r1, =0x4000
    cmp     r0, r1
    bhs     .LWrZ80_NotRam
    
    /* Z80 RAM write: Z80_RAM[Addr & 0x1FFF] = Value */
    ldr     r1, =Z80_RAM
    ldr     r1, [r1]            /* Load Z80_RAM pointer */
    movw    r2, #0x1FFF         /* Load mask into register */
    and     r0, r0, r2          /* Mask to 8KB */
    strb    r5, [r1, r0]        /* Store byte to Z80_RAM[Addr & 0x1FFF] */
    pop     {r4-r6, pc}

.LWrZ80_NotRam:
    /* Check if address < 0x6000 (YM2612) */
    ldr     r1, =0x6000
    cmp     r0, r1
    bhs     .LWrZ80_NotYM2612
    
    /* YM2612 write - YM2612Write(Addr & 0x3, Value, timing) */
    and     r0, r4, #0x3        /* r0 = Addr & 0x3 */
    mov     r1, r5              /* r1 = Value */
    
    /* Calculate timing: zclk + current_timeslice - (cpu.ICount * Z80_FREQ_DIVISOR) */
    ldr     r2, =zclk
    ldr     r3, [r2]            /* r3 = zclk */
    ldr     r2, =current_timeslice
    ldr     r6, [r2]            /* r6 = current_timeslice */
    add     r3, r3, r6          /* r3 = zclk + current_timeslice */
    
    ldr     r2, =cpu
    ldr     r6, [r2, #Z80_ICOUNT_OFFSET]  /* r6 = cpu.ICount */
    mov     r2, #Z80_FREQ_DIVISOR
    mul     r6, r6, r2          /* r6 = cpu.ICount * Z80_FREQ_DIVISOR */
    sub     r2, r3, r6          /* r2 = timing */
    
    bl      YM2612Write
    pop     {r4-r6, pc}

.LWrZ80_NotYM2612:
    /* Check if address == 0x6000 (Bank register) */
    ldr     r1, =0x6000
    cmp     r4, r1
    bne     .LWrZ80_NotBank
    
    /* Bank register write */
    mov     r0, r5              /* r0 = Value */
    bl      zbankreg_mem_w8
    pop     {r4-r6, pc}

.LWrZ80_NotBank:
    /* Check if address == 0x7F11 (SN76489 PSG) */
    ldr     r1, =0x7F11
    cmp     r4, r1
    bne     .LWrZ80_NotPSG
    
    /* SN76489 write - gwenesis_SN76489_Write(Value, timing) */
    mov     r0, r5              /* r0 = Value */
    
    /* Calculate timing */
    ldr     r1, =zclk
    ldr     r2, [r1]            /* r2 = zclk */
    ldr     r1, =current_timeslice
    ldr     r3, [r1]            /* r3 = current_timeslice */
    add     r2, r2, r3          /* r2 = zclk + current_timeslice */
    
    ldr     r1, =cpu
    ldr     r3, [r1, #Z80_ICOUNT_OFFSET]  /* r3 = cpu.ICount */
    lsl     r3, r3, #1          /* r3 = cpu.ICount * 2 */
    sub     r1, r2, r3          /* r1 = timing */
    
    bl      gwenesis_SN76489_Write
    pop     {r4-r6, pc}

.LWrZ80_NotPSG:
    /* Check if address >= 0x8000 (Banked memory) */
    ldr     r1, =0x8000
    cmp     r4, r1
    bhs     .LWrZ80_Banked
    
    /* Unknown address, just return */
    pop     {r4-r6, pc}

.LWrZ80_Banked:
    /* Banked memory write - zbank_mem_w8(Addr, Value) */
    mov     r0, r4              /* r0 = Addr */
    mov     r1, r5              /* r1 = Value */
    bl      zbank_mem_w8
    pop     {r4-r6, pc}

.size WrZ80, .-WrZ80

