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
    
    /* Check for DBF Dn (0x51C8-0x51CF) - 9% of instructions combined */
    movw    r0, #0x51C8
    sub     r1, r10, r0             @ r1 = opcode - 0x51C8
    cmp     r1, #8                  @ Check if in range 0-7 (D0-D7)
    blo     .Lhandle_dbf            @ Unsigned less than = in range
    
    /* Check for BNE.B (0x6601-0x66FE) - ~1% of instructions */
    lsr     r0, r10, #8             @ Get high byte
    cmp     r0, #0x66               @ Is it BNE?
    bne     .Lno_inline             @ No, use table
    and     r0, r10, #0xFF          @ Get displacement
    cmp     r0, #0                  @ 0x6600 = BNE.W (needs extension word)
    beq     .Lno_inline
    cmp     r0, #0xFF               @ 0x66FF = BNE.L (needs extension)
    beq     .Lno_inline
    b       .Lhandle_bne_b          @ Handle BNE.B inline

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
 */
.Lhandle_nop:
    add     r4, r4, #4              @ NOP takes 4 cycles
    b       .Lmain_loop

/*
 * DBF Dn,label handler (opcodes 0x51C8-0x51CF)
 * Decrement Dn.W, branch if Dn.W != -1
 * This is ~9% of all instructions (loop counters)
 * 
 * Entry: r10 = opcode (0x51C8-0x51CF)
 * PC points to the 16-bit displacement word
 * 
 * Cycle timing:
 *   Base: 10 cycles (from table)
 *   Not expired (branch taken): -2 cycles adjustment
 *   Expired (fall through): +2 cycles adjustment
 */
.Lhandle_dbf:
    /* First check if PC is in ROM - if not, use table handler */
    /* This avoids modifying state before we know we can handle it */
    ldr     r0, [r5, #M68K_PC]      @ r0 = PC (points to displacement)
    movw    r1, #0
    movt    r1, #0x80               @ r1 = 0x800000
    cmp     r0, r1
    bhs     .Lno_inline             @ PC not in ROM, use table handler (no state modified)
    
    /* PC is in ROM - we can handle this inline */
    and     r1, r10, #7             @ r1 = register number (0-7)
    lsl     r1, r1, #2              @ r1 = register offset (0, 4, 8, ...)
    add     r2, r5, #M68K_DAR       @ r2 = base of D/A registers
    ldr     r3, [r2, r1]            @ r3 = current Dn value (full 32-bit)
    
    /* Decrement lower 16 bits only, preserve upper 16 bits */
    uxth    r11, r3                 @ r11 = Dn.W (lower 16 bits, zero-extended)
    sub     r11, r11, #1            @ r11 = Dn.W - 1
    bfi     r3, r11, #0, #16        @ Insert lower 16 bits back into r3
    str     r3, [r2, r1]            @ Store updated Dn
    
    /* Check if result is -1 (0xFFFF in lower 16 bits) */
    movw    r1, #0xFFFF
    uxth    r11, r11                @ Mask to 16 bits
    cmp     r11, r1
    beq     .Ldbf_expired           @ Counter expired, don't branch
    
    /* Counter not expired - fetch displacement and branch */
    /* r0 still has PC from earlier check */
    ldr     r1, [r9]                @ r1 = ROM_DATA pointer
    ldrh    r2, [r1, r0]            @ r2 = displacement word (already byte-swapped during ROM load)
    sxth    r2, r2                  @ Sign extend to 32-bit
    
    /* New PC = (PC pointing at disp) + displacement */
    add     r0, r0, r2              @ r0 = PC + displacement
    str     r0, [r5, #M68K_PC]      @ Store new PC
    
    /* DBF branch taken: base 10 + adjustment -2 = 8 cycles */
    add     r4, r4, #8
    b       .Lmain_loop
    
.Ldbf_expired:
    /* Counter reached -1 (0xFFFF), skip displacement word */
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2              @ Skip displacement word
    str     r0, [r5, #M68K_PC]
    /* DBF expired: base 10 + adjustment +2 = 12 cycles */
    add     r4, r4, #12
    b       .Lmain_loop

/*
 * BNE.B handler (opcodes 0x6601-0x66FE, 8-bit displacement)
 * Branch if Z flag is clear (NOT_Z_FLAG != 0)
 * 
 * r10 = opcode (0x66XX where XX is signed displacement)
 */
.Lhandle_bne_b:
    /* Check Z flag (NOT_Z_FLAG: 0 = Z set, non-zero = Z clear) */
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbne_not_taken         @ Z is set, don't branch
    
    /* Z is clear - take the branch */
    sxtb    r0, r10                 @ Sign-extend 8-bit displacement
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0              @ PC += displacement
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #10             @ Branch taken = 10 cycles
    b       .Lmain_loop
    
.Lbne_not_taken:
    add     r4, r4, #8              @ Branch not taken = 8 cycles
    b       .Lmain_loop

    .size m68k_run_fast, . - m68k_run_fast

    .end
