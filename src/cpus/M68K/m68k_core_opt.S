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
    .extern m68k_fetch_opcode           /* C helper function for opcode fetch */
    .extern m68k_check_interrupts       /* C helper function for interrupt check */
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
    
    /* Check interrupts (critical for VBlank/HBlank handling) */
    bl      m68k_check_interrupts
    
    /* Check if stopped */
    ldr     r0, [r5, #M68K_STOPPED]
    cbnz    r0, .Lstopped
    
    /* Load jump table pointer (dereference the exported pointer) */
    ldr     r7, =m68k_instruction_table
    ldr     r7, [r7]                @ r7 = actual jump table pointer
    
    /* Load cycle table pointer (dereference the exported pointer) */
    ldr     r8, =m68k_cycles_table
    ldr     r8, [r8]                @ r8 = actual cycles table pointer
    
    /* Load ROM_DATA pointer for inline fetch */
    ldr     r9, =ROM_DATA           @ r9 = pointer to ROM_DATA variable
    
    /* Load current cycles into r4 (kept in register for loop) */
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lmain_loop:
    /* Check cycles (r4 = current cycles, r6 = target) */
    cmp     r4, r6
    bhs     .Lexit_store
    
    /*
     * Inline opcode fetch - optimized for ROM (most common case)
     * PC < 0x800000 = ROM, else fall back to C helper
     */
    ldr     r0, [r5, #M68K_PC]      @ r0 = PC
    
    /* Check if PC is in ROM (< 0x800000) - use movw for efficiency */
    movw    r1, #0
    movt    r1, #0x80               @ r1 = 0x800000
    cmp     r0, r1
    bhs     .Lslow_fetch            @ PC >= 0x800000, use C helper
    
    /* Fast ROM fetch inline */
    ldr     r1, [r9]                @ r1 = ROM_DATA pointer
    ldrh    r10, [r1, r0]           @ r10 = opcode from ROM (kept for cycle lookup)
    add     r0, r0, #2              @ PC += 2
    str     r0, [r5, #M68K_PC]      @ Store updated PC
    strh    r10, [r5, #M68K_IR]     @ Store IR
    b       .Lfetch_done
    
.Lslow_fetch:
    /* Fall back to C helper for RAM/IO access */
    str     r4, [r5, #M68K_CYCLES]  @ Save cycles before call (may be modified)
    bl      m68k_fetch_opcode       @ returns opcode in r0, also sets REG_IR
    mov     r10, r0                 @ r10 = opcode
    ldr     r4, [r5, #M68K_CYCLES]  @ Reload cycles (may have changed)
    
.Lfetch_done:
    /* Look up handler in jump table (r10 = opcode) */
    lsl     r1, r10, #2             @ r1 = opcode * 4 (table offset)
    ldr     r2, [r7, r1]            @ r2 = handler function pointer
    
    /* Save cycles before handler call (handlers may modify via USE_CYCLES) */
    str     r4, [r5, #M68K_CYCLES]
    
    /* Call instruction handler */
    blx     r2
    
    /* Reload cycles (handler may have added extra via USE_CYCLES) */
    ldr     r4, [r5, #M68K_CYCLES]
    
    /* Add base cycles for this instruction (r10 still has opcode) */
    ldrb    r1, [r8, r10]           @ r1 = cycle count
    add     r4, r4, r1              @ r4 += cycles
    
    /* Loop back */
    b       .Lmain_loop

.Lexit_store:
    /* Store final cycles value */
    str     r4, [r5, #M68K_CYCLES]
    b       .Lexit
    
.Lstopped:
    /* CPU is stopped, advance to target cycles */
    str     r6, [r5, #M68K_CYCLES]
    
.Lexit:
    pop     {r4-r11, pc}            @ Restore and return
    
    .size m68k_run_fast, . - m68k_run_fast

    .end
