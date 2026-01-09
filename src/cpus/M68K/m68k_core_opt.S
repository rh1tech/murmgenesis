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
    .extern m68k_profile_opcode         /* C helper function for opcode profiling */
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
    blo     .Lnot_done              @ Continue if we haven't reached target
    pop     {r4-r11, pc}            @ Early exit - already done
.Lnot_done:
    
    /* Store end cycles */
    str     r0, [r5, #M68K_CYCLE_END]
    mov     r6, r0                  @ r6 = target cycles
    
    /* Check interrupts (critical for VBlank/HBlank handling) */
    bl      m68k_check_interrupts
    
    /* Check if stopped */
    ldr     r0, [r5, #M68K_STOPPED]
    cmp     r0, #0
    beq     .Lnot_stopped
    /* CPU is stopped, advance to target cycles and exit */
    str     r6, [r5, #M68K_CYCLES]
    pop     {r4-r11, pc}
.Lnot_stopped:
    
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
    bl      m68k_fetch_opcode       @ returns opcode in r0, also sets REG_IR, and profiles
    mov     r10, r0                 @ r10 = opcode
    ldr     r4, [r5, #M68K_CYCLES]  @ Reload cycles (may have changed)
    
.Lfetch_done:
    /* ================================================================
     * INLINE DISPATCH FOR HOT OPCODES
     * ================================================================ */
    
    /* Check for NOP (0x4E71) - 6% of instructions */
    movw    r0, #0x4E71
    cmp     r10, r0
    beq     .Lhandle_nop
    
    /* Check for MOVEQ (0x7000-0x7EFF, bit 8 must be 0) */
    /* Format: 0111 Rrr0 dddddddd where Rrr=Dn, d=data */
    and     r0, r10, #0xF100        @ Mask to get 7x0x pattern
    movw    r1, #0x7000
    cmp     r0, r1
    beq     .Lhandle_moveq
    
    /* Check for BEQ.B (0x6701-0x67FE) */
    lsr     r0, r10, #8             @ Get high byte
    cmp     r0, #0x67               @ Is it BEQ?
    beq     .Lcheck_bcc_displacement
    
    /* Check for BRA.B (0x6001-0x60FE) */
    cmp     r0, #0x60               @ Is it BRA?
    bne     .Lno_inline             @ Not a handled Bcc, use table
    
.Lcheck_bcc_displacement:
    and     r1, r10, #0xFF          @ Get displacement
    cmp     r1, #0                  @ 0xXX00 = .W (needs extension word)
    beq     .Lno_inline
    cmp     r1, #0xFF               @ 0xXXFF = .L (needs extension)
    beq     .Lno_inline
    
    /* Dispatch to correct Bcc handler based on high byte (still in r0) */
    cmp     r0, #0x67
    beq     .Lhandle_beq_b
    b       .Lhandle_bra_b          @ Must be BRA

.Lno_inline:
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
    /* Store final cycles value and exit */
    str     r4, [r5, #M68K_CYCLES]
    pop     {r4-r11, pc}            @ Restore and return

/* ======================================================================
 * INLINE INSTRUCTION HANDLERS
 * These handle the hottest opcodes without function call overhead
 * ====================================================================== */

/*
 * NOP handler (opcode 0x4E71)
 * Simply add cycles and continue - 6% of all instructions
 * Cycles: 4 * MUL(7) = 28
 */
.Lhandle_nop:
    add     r4, r4, #28             @ NOP takes 4 cycles * 7
    b       .Lmain_loop

/*
 * BEQ.B handler (opcodes 0x6701-0x67FE, 8-bit displacement)
 * Branch if Z flag is set (NOT_Z_FLAG == 0)
 */
.Lhandle_beq_b:
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    bne     .Lbeq_not_taken         @ Z is clear, don't branch
    
    /* Z is set - take the branch */
    sxtb    r0, r10                 @ Sign-extend 8-bit displacement
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0              @ PC += displacement
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70             @ Branch taken = 10 * 7 cycles
    b       .Lmain_loop
    
.Lbeq_not_taken:
    add     r4, r4, #56             @ Branch not taken = 8 * 7 cycles
    b       .Lmain_loop

/*
 * BRA.B handler (opcodes 0x6001-0x60FE, 8-bit displacement)
 * Unconditional branch - always taken
 */
.Lhandle_bra_b:
    sxtb    r0, r10                 @ Sign-extend 8-bit displacement
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0              @ PC += displacement
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70             @ BRA.B = 10 * 7 cycles
    b       .Lmain_loop

/*
 * MOVEQ handler (opcodes 0x7000-0x7EFF where bit 8 = 0)
 * Move quick - sign-extend 8-bit immediate to Dn
 * Sets N, Z; clears V, C
 * 4 cycles
 */
.Lhandle_moveq:
    /* Extract register number (bits 9-11) */
    lsr     r0, r10, #9             @ r0 = (opcode >> 9)
    and     r0, r0, #7              @ r0 = register number
    lsl     r0, r0, #2              @ r0 = register offset
    
    /* Sign-extend 8-bit data to 32-bit */
    sxtb    r1, r10                 @ r1 = sign-extended data
    
    /* Store to Dn */
    add     r2, r5, #M68K_DAR
    str     r1, [r2, r0]            @ Dn = data
    
    /* Set flags: N = bit 31, Z = (data == 0), V = 0, C = 0 */
    lsr     r0, r1, #24             @ N flag = high byte (bit 31 in bit 7)
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]  @ NOT_Z = value (0 if zero)
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ MOVEQ = 4 * 7 cycles
    b       .Lmain_loop

    .size m68k_run_fast, . - m68k_run_fast

    .end
