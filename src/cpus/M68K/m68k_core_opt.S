/*
 * M68K Core Optimizations - ARM Thumb-2 Assembly (Cortex-M33)
 * 
 * Optimized main execution loop for 68000 emulation
 * Keeps registers in ARM registers for faster access
 * 
 * NOTE: The m68ki_cpu_core struct is over 5KB due to memory_map[256],
 * so we use a base pointer offset to the 'cycles' field area.
 */

    .syntax unified
    .cpu cortex-m33
    .thumb
    .section .time_critical.m68k_core,"ax",%progbits

    /* External symbols */
    .extern m68k
    .extern m68k_instruction_table      /* pointer to jump table (exported from m68kcpu.c) */
    .extern m68k_cycles_table           /* pointer to cycles table (exported from m68kcpu.c) */
    .extern ROM_DATA
    .extern M68K_RAM

/*
 * Structure offsets for m68ki_cpu_core
 * Must match the C struct exactly!
 * 
 * Layout:
 *   memory_map[256]:  256 * 20 = 5120 bytes  (offset 0)
 *   poll (cpu_idle_t): 3 * 4 = 12 bytes      (offset 5120)
 *   cycles:            4 bytes               (offset 5132)
 *   ...
 *
 * We point r5 to (m68k + 5132) so that 'cycles' is at offset 0
 */
    .equ M68K_BASE_OFFSET,  5132    /* We offset base pointer to here */
    
    /* Offsets relative to M68K_BASE_OFFSET (cycles field) */
    .equ M68K_CYCLES,       0       /* offset of 'cycles' */
    .equ M68K_CYCLE_END,    4       /* offset of 'cycle_end' */
    .equ M68K_DAR,          8       /* offset of 'dar[16]' array (64 bytes) */
    .equ M68K_PC,           72      /* offset of 'pc' */
    .equ M68K_SP,           76      /* offset of 'sp[5]' array (20 bytes) */
    .equ M68K_IR,           96      /* offset of 'ir' */
    .equ M68K_T1_FLAG,      100     /* offset of 't1_flag' */
    .equ M68K_S_FLAG,       104     /* offset of 's_flag' */
    .equ M68K_X_FLAG,       108     /* offset of 'x_flag' */
    .equ M68K_N_FLAG,       112     /* offset of 'n_flag' */
    .equ M68K_NOT_Z_FLAG,   116     /* offset of 'not_z_flag' */
    .equ M68K_V_FLAG,       120     /* offset of 'v_flag' */
    .equ M68K_C_FLAG,       124     /* offset of 'c_flag' */
    .equ M68K_INT_MASK,     128     /* offset of 'int_mask' */
    .equ M68K_INT_LEVEL,    132     /* offset of 'int_level' */
    .equ M68K_STOPPED,      136     /* offset of 'stopped' */
    .equ M68K_PREF_ADDR,    140     /* offset of 'pref_addr' */
    .equ M68K_PREF_DATA,    144     /* offset of 'pref_data' */


/*
 * void m68k_run_fast(unsigned int cycles)
 * 
 * Optimized main execution loop
 * Uses base pointer offset to access struct fields efficiently
 * 
 * Register allocation:
 *   r5 = &m68k + M68K_BASE_OFFSET (base pointer to cycles field area)
 *   r6 = target cycles
 *   r7 = instruction jump table pointer (dereferenced from m68k_instruction_table)
 *   r8 = cycles table pointer (dereferenced from m68k_cycles_table)
 *   r9 = ROM_DATA pointer (cached)
 */
    .global m68k_run_fast
    .type m68k_run_fast, %function
    .align 4

m68k_run_fast:
    push    {r4-r11, lr}            @ Save callee-saved registers
    
    /* r0 = target cycles */
    
    /* r5 = &m68k + offset (base pointer to cycles area) */
    ldr     r5, =m68k
    movw    r1, #M68K_BASE_OFFSET
    add     r5, r5, r1              @ r5 = &m68k.cycles (effectively)
    
    /* Check if already past target */
    ldr     r1, [r5, #M68K_CYCLES]
    cmp     r1, r0
    bhs     .Lexit                  @ Already done
    
    /* Store end cycles */
    str     r0, [r5, #M68K_CYCLE_END]
    mov     r6, r0                  @ r6 = target cycles
    
    /* Check if stopped */
    ldr     r0, [r5, #M68K_STOPPED]
    cbnz    r0, .Lstopped
    
    /* Load jump table pointer (dereference the exported pointer) */
    ldr     r7, =m68k_instruction_table
    ldr     r7, [r7]                @ r7 = actual jump table pointer
    
    /* Load cycle table pointer (dereference the exported pointer) */
    ldr     r8, =m68k_cycles_table
    ldr     r8, [r8]                @ r8 = actual cycles table pointer
    
    /* Cache ROM_DATA pointer */
    ldr     r9, =ROM_DATA
    ldr     r9, [r9]                @ r9 = ROM_DATA pointer
    
.Lmain_loop:
    /* Check cycles */
    ldr     r4, [r5, #M68K_CYCLES]
    cmp     r4, r6
    bhs     .Lexit
    
    /*
     * Inline instruction fetch
     * Most instructions come from ROM (< 0x800000)
     */
    ldr     r0, [r5, #M68K_PC]      @ r0 = PC
    
    /* Fast path: ROM access (PC < 0x800000) */
    cmp     r0, #0x800000
    bhs     .Lfetch_slow
    
    /* ROM fetch - fast path using cached r9 */
    ldrh    r1, [r9, r0]            @ r1 = 16-bit opcode from ROM
    add     r0, r0, #2              @ PC += 2
    str     r0, [r5, #M68K_PC]      @ store updated PC
    str     r1, [r5, #M68K_IR]      @ Store opcode to IR
    
    /* Look up handler in jump table */
    lsl     r0, r1, #2              @ r0 = opcode * 4 (table offset)
    ldr     r2, [r7, r0]            @ r2 = handler function pointer
    
    /* Call instruction handler */
    blx     r2
    
    /* Add cycles for this instruction */
    ldr     r0, [r5, #M68K_IR]      @ reload IR (handler may have changed it)
    ldrb    r1, [r8, r0]            @ r1 = cycle count (unsigned char table, no shift needed)
    ldr     r2, [r5, #M68K_CYCLES]
    add     r2, r2, r1
    str     r2, [r5, #M68K_CYCLES]
    
    /* Loop back */
    b       .Lmain_loop
    
.Lfetch_slow:
    /* Slow path: RAM access (PC >= 0xFF0000) or other memory */
    /* Fall back to reading from M68K_RAM */
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r3, r0, r2              @ r3 = PC & 0xFFFF
    ldrh    r1, [r1, r3]            @ r1 = 16-bit opcode from RAM
    add     r0, r0, #2              @ PC += 2
    str     r0, [r5, #M68K_PC]      @ store updated PC
    str     r1, [r5, #M68K_IR]      @ Store opcode to IR
    
    /* Look up handler in jump table */
    lsl     r0, r1, #2              @ r0 = opcode * 4 (table offset)
    ldr     r2, [r7, r0]            @ r2 = handler function pointer
    
    /* Call instruction handler */
    blx     r2
    
    /* Add cycles for this instruction */
    ldr     r0, [r5, #M68K_IR]      @ reload IR
    ldrb    r1, [r8, r0]            @ r1 = cycle count (unsigned char table)
    ldr     r2, [r5, #M68K_CYCLES]
    add     r2, r2, r1
    str     r2, [r5, #M68K_CYCLES]
    
    /* Loop back */
    b       .Lmain_loop
    
.Lstopped:
    /* CPU is stopped, advance to target cycles */
    str     r6, [r5, #M68K_CYCLES]
    
.Lexit:
    pop     {r4-r11, pc}            @ Restore and return
    
    .size m68k_run_fast, . - m68k_run_fast

    .end
