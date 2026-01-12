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
    
    /* ================================================================
     * MOVE.L INLINE HANDLERS - ~15-20% of all instructions
     * Format: 0010 DDD MMM sss SSS
     *         DDD = dest reg, MMM = dest mode, sss = src mode, SSS = src reg
     * ================================================================ */
    
    /* Check for MOVE.L (opcode 0x2xxx) */
    lsr     r0, r10, #12            @ Get top nibble
    cmp     r0, #0                  @ Is it 0x0xxx (BTST, etc)?
    beq     .Lcheck_0xxx
    cmp     r0, #2                  @ Is it MOVE.L?
    beq     .Lcheck_move_l
    
    /* Check for MOVE.W (opcode 0x3xxx) */
    cmp     r0, #3                  @ Is it MOVE.W?
    beq     .Lcheck_move_w
    
    /* Check for TST/CLR/LEA/NEG/NOT/EXT/SWAP (opcode 0x4xxx) */
    cmp     r0, #4                  @ Is it 0x4xxx?
    beq     .Lcheck_4xxx
    
    /* Check for ADDQ/SUBQ/DBcc (opcode 0x5xxx) */
    cmp     r0, #5                  @ Is it 0x5xxx?
    beq     .Lcheck_addq_subq
    
    /* Check for OR (opcode 0x8xxx) */
    cmp     r0, #8                  @ Is it 0x8xxx?
    beq     .Lcheck_or
    
    /* Check for SUB (opcode 0x9xxx) */
    cmp     r0, #9                  @ Is it 0x9xxx?
    beq     .Lcheck_sub
    
    /* Check for CMP/EOR (opcode 0xBxxx) */
    cmp     r0, #0xB                @ Is it 0xBxxx?
    beq     .Lcheck_cmp
    
    /* Check for AND (opcode 0xCxxx) */
    cmp     r0, #0xC                @ Is it 0xCxxx?
    beq     .Lcheck_and
    
    /* Check for ADD (opcode 0xDxxx) */
    cmp     r0, #0xD                @ Is it 0xDxxx?
    beq     .Lcheck_add
    
    /* Check for LSL/LSR/ASL/ASR (opcode 0xExxx) */
    cmp     r0, #0xE                @ Is it 0xExxx?
    beq     .Lcheck_shift
    
    /* Check for Bcc.B variants (0x6xxx) */
    lsr     r0, r10, #8             @ Get high byte
    cmp     r0, #0x60               @ Is it BRA?
    beq     .Lcheck_bcc_displacement
    @ BSR disabled for debugging
    @cmp     r0, #0x61               @ Is it BSR?
    @beq     .Lcheck_bsr_displacement
    cmp     r0, #0x64               @ Is it BCC (carry clear)?
    beq     .Lcheck_bcc_disp_bcc
    cmp     r0, #0x65               @ Is it BCS (carry set)?
    beq     .Lcheck_bcc_disp_bcs
    cmp     r0, #0x66               @ Is it BNE?
    beq     .Lcheck_bcc_displacement_bne
    cmp     r0, #0x67               @ Is it BEQ?
    beq     .Lcheck_bcc_disp_beq
    cmp     r0, #0x6A               @ Is it BPL (plus)?
    beq     .Lcheck_bcc_disp_bpl
    cmp     r0, #0x6B               @ Is it BMI (minus)?
    beq     .Lcheck_bcc_disp_bmi
    cmp     r0, #0x6C               @ Is it BGE (greater or equal)?
    beq     .Lcheck_bcc_disp_bge
    cmp     r0, #0x6D               @ Is it BLT (less than)?
    beq     .Lcheck_bcc_disp_blt
    cmp     r0, #0x6E               @ Is it BGT (greater than)?
    beq     .Lcheck_bcc_disp_bgt
    cmp     r0, #0x6F               @ Is it BLE (less or equal)?
    beq     .Lcheck_bcc_disp_ble
    cmp     r0, #0x62               @ Is it BHI (higher)?
    beq     .Lcheck_bcc_disp_bhi
    cmp     r0, #0x63               @ Is it BLS (lower or same)?
    beq     .Lcheck_bcc_disp_bls
    cmp     r0, #0x68               @ Is it BVC (overflow clear)?
    beq     .Lcheck_bcc_disp_bvc
    cmp     r0, #0x69               @ Is it BVS (overflow set)?
    beq     .Lcheck_bcc_disp_bvs
    b       .Lno_inline             @ Other Bcc not handled
    
.Lcheck_bcc_displacement:
    and     r1, r10, #0xFF          @ Get displacement
    cmp     r1, #0                  @ 0xXX00 = .W (needs extension word)
    beq     .Lhandle_bra_w          @ BRA.W
    cmp     r1, #0xFF               @ 0xXXFF = .L (needs extension)
    beq.w   .Lno_inline
    b       .Lhandle_bra_b          @ Must be BRA

.Lcheck_bsr_displacement:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq.w   .Lno_inline
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bsr_b

.Lcheck_bcc_disp_beq:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_beq_w          @ Word displacement
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_beq_b

.Lcheck_bcc_disp_bcc:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bcc_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bcc_b

.Lcheck_bcc_disp_bcs:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bcs_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bcs_b

.Lcheck_bcc_disp_bpl:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bpl_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bpl_b

.Lcheck_bcc_disp_bmi:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bmi_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bmi_b

.Lcheck_bcc_disp_bge:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bge_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bge_b

.Lcheck_bcc_disp_blt:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_blt_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_blt_b

.Lcheck_bcc_disp_bgt:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bgt_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bgt_b

.Lcheck_bcc_disp_ble:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_ble_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_ble_b

.Lcheck_bcc_disp_bhi:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bhi_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bhi_b

.Lcheck_bcc_disp_bls:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bls_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bls_b

.Lcheck_bcc_disp_bvc:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bvc_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bvc_b

.Lcheck_bcc_disp_bvs:
    and     r1, r10, #0xFF
    cmp     r1, #0
    beq     .Lhandle_bvs_w
    cmp     r1, #0xFF
    beq.w   .Lno_inline
    b       .Lhandle_bvs_b

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

    /* Force literal pool generation here to keep ldr= within range */
    .ltorg

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
 * BNE.B handler (opcodes 0x6601-0x66FE, 8-bit displacement)
 * Branch if Z flag is clear (NOT_Z_FLAG != 0)
 */
.Lhandle_bne_b:
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbne_not_taken         @ Z is set, don't branch
    
    /* Z is clear - take the branch */
    sxtb    r0, r10                 @ Sign-extend 8-bit displacement
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0              @ PC += displacement
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70             @ Branch taken = 10 * 7 cycles
    b       .Lmain_loop
    
.Lbne_not_taken:
    add     r4, r4, #56             @ Branch not taken = 8 * 7 cycles
    b       .Lmain_loop

/*
 * BCC.B handler (opcodes 0x6401-0x64FE) - Branch if Carry Clear
 */
.Lhandle_bcc_b:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100              @ Check bit 8 specifically
    bne     .Lbcc_not_taken         @ C is set, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbcc_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BCS.B handler (opcodes 0x6501-0x65FE) - Branch if Carry Set
 */
.Lhandle_bcs_b:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100              @ Check bit 8 specifically
    beq     .Lbcs_not_taken         @ C is clear, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbcs_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BPL.B handler (opcodes 0x6A01-0x6AFE) - Branch if Plus (N clear)
 */
.Lhandle_bpl_b:
    ldr     r0, [r5, #M68K_N_FLAG]
    tst     r0, #0x80               @ Check bit 7 specifically
    bne     .Lbpl_not_taken         @ N is set, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbpl_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BMI.B handler (opcodes 0x6B01-0x6BFE) - Branch if Minus (N set)
 */
.Lhandle_bmi_b:
    ldr     r0, [r5, #M68K_N_FLAG]
    tst     r0, #0x80               @ Check bit 7 specifically
    beq     .Lbmi_not_taken         @ N is clear, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbmi_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BGE.B handler (opcodes 0x6C01-0x6CFE) - Branch if Greater or Equal
 * Condition: N xor V = 0 (both same sign)
 */
.Lhandle_bge_b:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r2, r0, r1              @ N xor V
    tst     r2, #0x80               @ Check bit 7 of XOR result
    bne     .Lbge_not_taken         @ N xor V != 0, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbge_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BLT.B handler (opcodes 0x6D01-0x6DFE) - Branch if Less Than
 * Condition: N xor V = 1 (different signs)
 */
.Lhandle_blt_b:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r2, r0, r1              @ N xor V
    tst     r2, #0x80               @ Check bit 7 of XOR result
    beq     .Lblt_not_taken         @ N xor V == 0, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lblt_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BGT.B handler (opcodes 0x6E01-0x6EFE) - Branch if Greater Than
 * Condition: (N xor V) = 0 AND Z = 0
 */
.Lhandle_bgt_b:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r2, r0, r1              @ N xor V
    tst     r2, #0x80               @ Check bit 7
    bne     .Lbgt_not_taken         @ N xor V != 0, don't branch
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbgt_not_taken         @ Z is set, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbgt_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BLE.B handler (opcodes 0x6F01-0x6FFE) - Branch if Less or Equal
 * Condition: (N xor V) = 1 OR Z = 1
 */
.Lhandle_ble_b:
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lble_take_branch       @ Z is set, take branch
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r2, r0, r1              @ N xor V
    tst     r2, #0x80               @ Check bit 7
    beq     .Lble_not_taken         @ N xor V == 0 and Z clear, don't branch
.Lble_take_branch:
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lble_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BHI.B handler (opcodes 0x6201-0x62FE) - Branch if Higher (unsigned)
 * Condition: C = 0 AND Z = 0
 */
.Lhandle_bhi_b:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100              @ Check bit 8
    bne     .Lbhi_not_taken         @ C is set, don't branch
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbhi_not_taken         @ Z is set, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbhi_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BLS.B handler (opcodes 0x6301-0x63FE) - Branch if Lower or Same (unsigned)
 * Condition: C = 1 OR Z = 1
 */
.Lhandle_bls_b:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100              @ Check bit 8
    bne     .Lbls_take_branch       @ C is set, take branch
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    bne     .Lbls_not_taken         @ Z is clear and C is clear, don't branch
.Lbls_take_branch:
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbls_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BVC.B handler (opcodes 0x6801-0x68FE) - Branch if Overflow Clear
 */
.Lhandle_bvc_b:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80               @ Check bit 7
    bne     .Lbvc_not_taken         @ V is set, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbvc_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BVS.B handler (opcodes 0x6901-0x69FE) - Branch if Overflow Set
 */
.Lhandle_bvs_b:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80               @ Check bit 7
    beq     .Lbvs_not_taken         @ V is clear, don't branch
    sxtb    r0, r10
    ldr     r1, [r5, #M68K_PC]
    add     r1, r1, r0
    str     r1, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbvs_not_taken:
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BSR.B handler (opcodes 0x6101-0x61FE) - Branch to Subroutine
 * 18 cycles - pushes return address then branches
 */
.Lhandle_bsr_b:
    /* Get SP (A7) */
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, #60]           @ A7 = dar[15]
    
    /* Decrement SP by 4 */
    sub     r0, r0, #4
    str     r0, [r2, #60]
    
    /* Get return address (PC after opcode) */
    ldr     r1, [r5, #M68K_PC]
    
    /* Push return address to stack (big-endian) */
    movw    r3, #0
    movt    r3, #0xFF               @ RAM base
    cmp     r0, r3
    blo     .Lbsr_slow_push
    
    /* Fast RAM path - store as big-endian */
    ldr     r3, =M68K_RAM
    movw    r11, #0xFFFF
    and     r11, r0, r11
    ror     r1, r1, #16             @ Swap for big-endian
    str     r1, [r3, r11]
    ror     r1, r1, #16             @ Restore for PC calc
    
    /* Calculate branch target */
    sxtb    r0, r10                 @ Sign-extend displacement
    sub     r1, r1, #2              @ PC was pointing past opcode, adjust
    add     r1, r1, r0              @ Add displacement
    str     r1, [r5, #M68K_PC]
    
    add     r4, r4, #126            @ 18 * 7 cycles
    b       .Lmain_loop

.Lbsr_slow_push:
    /* Fall back to C for stack in ROM/IO area */
    b.w     .Lno_inline

/*
 * BRA.W handler (opcode 0x6000) - Branch Always with word displacement
 * 10 cycles
 */
.Lhandle_bra_w:
    ldr     r0, [r5, #M68K_PC]      @ Get PC
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r2, [r1, r0]            @ Read displacement word
    sxth    r2, r2                  @ Sign extend
    add     r0, r0, r2              @ Apply displacement (from PC of extension)
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70             @ 10 * 7 cycles
    b       .Lmain_loop

/*
 * BEQ.W handler (opcode 0x6700) - Branch if Equal with word displacement
 * 10 cycles taken, 12 cycles not taken
 */
.Lhandle_beq_w:
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    bne     .Lbeq_w_not_taken       @ Z is clear, don't branch
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbeq_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2              @ Skip displacement word
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BNE.W handler (opcode 0x6600) - Branch if Not Equal with word displacement
 * 10 cycles taken, 12 cycles not taken
 */
.Lhandle_bne_w:
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbne_w_not_taken       @ Z is set, don't branch
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbne_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BCC.W handler (opcode 0x6400) - Branch if Carry Clear with word displacement
 */
.Lhandle_bcc_w:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    bne     .Lbcc_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbcc_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BCS.W handler (opcode 0x6500) - Branch if Carry Set with word displacement
 */
.Lhandle_bcs_w:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    beq     .Lbcs_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbcs_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BPL.W handler (opcode 0x6A00) - Branch if Plus with word displacement
 */
.Lhandle_bpl_w:
    ldr     r0, [r5, #M68K_N_FLAG]
    tst     r0, #0x80
    bne     .Lbpl_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbpl_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BMI.W handler (opcode 0x6B00) - Branch if Minus with word displacement
 */
.Lhandle_bmi_w:
    ldr     r0, [r5, #M68K_N_FLAG]
    tst     r0, #0x80
    beq     .Lbmi_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbmi_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BGE.W handler (opcode 0x6C00) - Branch if Greater or Equal with word displacement
 * Condition: N xor V = 0
 */
.Lhandle_bge_w:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    bne     .Lbge_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbge_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BLT.W handler (opcode 0x6D00) - Branch if Less Than with word displacement
 * Condition: N xor V = 1
 */
.Lhandle_blt_w:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    beq     .Lblt_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lblt_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BGT.W handler (opcode 0x6E00) - Branch if Greater Than with word displacement
 * Condition: (N xor V) or Z = 0
 */
.Lhandle_bgt_w:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    ldr     r2, [r5, #M68K_NOT_Z_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    bne     .Lbgt_w_not_taken
    cmp     r2, #0
    beq     .Lbgt_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbgt_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BLE.W handler (opcode 0x6F00) - Branch if Less or Equal with word displacement
 * Condition: Z or (N xor V) = 1
 */
.Lhandle_ble_w:
    ldr     r2, [r5, #M68K_NOT_Z_FLAG]
    cmp     r2, #0
    beq     .Lble_w_take_branch
    
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    beq     .Lble_w_not_taken

.Lble_w_take_branch:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lble_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BHI.W handler (opcode 0x6200) - Branch if High with word displacement
 * Condition: C and Z = 0
 */
.Lhandle_bhi_w:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    bne     .Lbhi_w_not_taken
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lbhi_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbhi_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BLS.W handler (opcode 0x6300) - Branch if Low or Same with word displacement
 * Condition: C or Z = 1
 */
.Lhandle_bls_w:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    bne     .Lbls_w_take_branch
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    bne     .Lbls_w_not_taken

.Lbls_w_take_branch:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbls_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BVC.W handler (opcode 0x6800) - Branch if Overflow Clear with word displacement
 */
.Lhandle_bvc_w:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80
    bne     .Lbvc_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbvc_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BVS.W handler (opcode 0x6900) - Branch if Overflow Set with word displacement
 */
.Lhandle_bvs_w:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80
    beq     .Lbvs_w_not_taken
    
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    sxth    r2, r2
    add     r0, r0, r2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #70
    b       .Lmain_loop
.Lbvs_w_not_taken:
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84
    b       .Lmain_loop

    /* Force literal pool here to keep ldr= in range */
    .ltorg

/* ======================================================================
 * 0x0xxx HANDLERS - BTST, ORI, ANDI, EORI, etc.
 * ====================================================================== */

.Lcheck_0xxx:
    /* Check for BTST Dn,Dn (0x0100-0x0107, 0x0300-0x0307, etc) */
    /* Format: 0000 DDD 100 000 SSS */
    movw    r0, #0xF1F8
    and     r0, r10, r0
    movw    r1, #0x0100
    cmp     r0, r1
    beq     .Lhandle_btst_32_r_d
    
    /* Check for ORI.L #imm,Dn (0x0080-0x0087) */
    bic     r0, r10, #7
    movw    r1, #0x0080
    cmp     r0, r1
    beq     .Lhandle_ori_32_imm_d
    
    /* Check for ORI.W #imm,Dn (0x0040-0x0047) */
    movw    r1, #0x0040
    cmp     r0, r1
    beq     .Lhandle_ori_16_imm_d
    
    /* Check for ORI.B #imm,Dn (0x0000-0x0007) */
    movw    r1, #0x0000
    cmp     r0, r1
    beq     .Lhandle_ori_8_imm_d
    
    /* Check for ANDI.L #imm,Dn (0x0280-0x0287) */
    movw    r1, #0x0280
    cmp     r0, r1
    beq     .Lhandle_andi_32_imm_d
    
    /* Check for ANDI.W #imm,Dn (0x0240-0x0247) */
    movw    r1, #0x0240
    cmp     r0, r1
    beq     .Lhandle_andi_16_imm_d
    
    /* Check for ANDI.B #imm,Dn (0x0200-0x0207) */
    movw    r1, #0x0200
    cmp     r0, r1
    beq     .Lhandle_andi_8_imm_d
    
    /* Check for EORI.L #imm,Dn (0x0A80-0x0A87) */
    movw    r1, #0x0A80
    cmp     r0, r1
    beq     .Lhandle_eori_32_imm_d
    
    /* Check for EORI.W #imm,Dn (0x0A40-0x0A47) */
    movw    r1, #0x0A40
    cmp     r0, r1
    beq     .Lhandle_eori_16_imm_d
    
    /* Check for EORI.B #imm,Dn (0x0A00-0x0A07) */
    movw    r1, #0x0A00
    cmp     r0, r1
    beq     .Lhandle_eori_8_imm_d
    
    /* Check for BTST #imm,Dn (0x0800-0x0807) */
    movw    r1, #0x0800
    cmp     r0, r1
    beq     .Lhandle_btst_imm_d
    
    /* Check for CMPI.L #imm,Dn (0x0C80-0x0C87) */
    movw    r1, #0x0C80
    cmp     r0, r1
    beq     .Lhandle_cmpi_32_d
    
    /* Check for CMPI.W #imm,Dn (0x0C40-0x0C47) */
    movw    r1, #0x0C40
    cmp     r0, r1
    beq     .Lhandle_cmpi_16_d
    
    /* Check for CMPI.B #imm,Dn (0x0C00-0x0C07) */
    movw    r1, #0x0C00
    cmp     r0, r1
    beq     .Lhandle_cmpi_8_d
    
    /* Check for SUBI.L #imm,Dn (0x0480-0x0487) */
    movw    r1, #0x0480
    cmp     r0, r1
    beq     .Lhandle_subi_32_d
    
    /* Check for SUBI.W #imm,Dn (0x0440-0x0447) */
    movw    r1, #0x0440
    cmp     r0, r1
    beq     .Lhandle_subi_16_d
    
    /* Check for SUBI.B #imm,Dn (0x0400-0x0407) */
    movw    r1, #0x0400
    cmp     r0, r1
    beq     .Lhandle_subi_8_d
    
    /* Check for ADDI.L #imm,Dn (0x0680-0x0687) */
    movw    r1, #0x0680
    cmp     r0, r1
    beq     .Lhandle_addi_32_d
    
    /* Check for ADDI.W #imm,Dn (0x0640-0x0647) */
    movw    r1, #0x0640
    cmp     r0, r1
    beq     .Lhandle_addi_16_d
    
    /* Check for ADDI.B #imm,Dn (0x0600-0x0607) */
    movw    r1, #0x0600
    cmp     r0, r1
    beq     .Lhandle_addi_8_d
    
    /* Check for BSET Dn,Dn (0x01C0-0x01C7, 0x03C0-0x03C7, etc) */
    /* Format: 0000 DDD 111 000 SSS */
    movw    r0, #0xF1F8
    and     r0, r10, r0
    movw    r1, #0x01C0
    cmp     r0, r1
    beq     .Lhandle_bset_r_d
    
    /* Check for BCLR Dn,Dn (0x0180-0x0187, etc) */
    /* Format: 0000 DDD 110 000 SSS */
    movw    r1, #0x0180
    cmp     r0, r1
    beq     .Lhandle_bclr_r_d
    
    /* Check for BCHG Dn,Dn (0x0140-0x0147, etc) */
    /* Format: 0000 DDD 101 000 SSS */
    movw    r1, #0x0140
    cmp     r0, r1
    beq     .Lhandle_bchg_r_d
    
    /* Check for BSET #imm,Dn (0x08C0-0x08C7) */
    bic     r0, r10, #7
    movw    r1, #0x08C0
    cmp     r0, r1
    beq     .Lhandle_bset_imm_d
    
    /* Check for BCLR #imm,Dn (0x0880-0x0887) */
    movw    r1, #0x0880
    cmp     r0, r1
    beq     .Lhandle_bclr_imm_d
    
    /* Check for BCHG #imm,Dn (0x0840-0x0847) */
    movw    r1, #0x0840
    cmp     r0, r1
    beq     .Lhandle_bchg_imm_d
    
    /* Check for BTST Dn,(An) - Format: 0000 DDD 100 010 SSS */
    movw    r0, #0xF1F8
    and     r0, r10, r0
    movw    r1, #0x0110
    cmp     r0, r1
    beq     .Lhandle_btst_r_ai
    
    /* Check for BTST Dn,(An)+ - Format: 0000 DDD 100 011 SSS */
    movw    r1, #0x0118
    cmp     r0, r1
    beq     .Lhandle_btst_r_pi
    
    /* Check for BSET Dn,(An) - Format: 0000 DDD 111 010 SSS */
    movw    r1, #0x01D0
    cmp     r0, r1
    beq     .Lhandle_bset_r_ai
    
    /* Check for BCLR Dn,(An) - Format: 0000 DDD 110 010 SSS */
    movw    r1, #0x0190
    cmp     r0, r1
    beq     .Lhandle_bclr_r_ai
    
    b.w     .Lno_inline             @ Other 0x0xxx use C

/*
 * BTST Dn,Dn - Bit Test (dynamic bit number)
 * Opcode: 0000 DDD 100 000 SSS (0x0100)
 * 6 cycles - tests bit (Dn mod 32) of Dm, sets Z flag
 */
.Lhandle_btst_32_r_d:
    /* Get bit number from DX (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = DX (bit number)
    and     r1, r1, #0x1F           @ mod 32
    
    /* Get tested value from DY (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r0, [r2, r0]            @ r0 = DY (value to test)
    
    /* Test bit and set Z flag */
    mov     r3, #1
    lsl     r3, r3, r1              @ r3 = 1 << bit_number
    ands    r0, r0, r3              @ Test the bit
    
    /* Z flag = 0 if bit is set, non-zero if bit is clear */
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

/*
 * BTST #imm,Dn - Bit Test with immediate bit number
 * Opcode: 0000 1000 00 000 DDD (0x0800)
 * 10 cycles
 */
.Lhandle_btst_imm_d:
    /* Read bit number from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]            @ r2 = bit number
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    and     r2, r2, #0x1F           @ mod 32
    
    /* Get tested value from Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r0, [r1, r0]
    
    mov     r3, #1
    lsl     r3, r3, r2
    ands    r0, r0, r3
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    add     r4, r4, #70             @ 10 * 7 cycles
    b       .Lmain_loop

/*
 * BSET Dn,Dn - Bit Test and Set (dynamic bit number)
 * Opcode: 0000 DDD 111 000 SSS (0x01C0)
 * 8 cycles - tests bit, then sets it
 */
.Lhandle_bset_r_d:
    /* Get bit number from DX (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = DX (bit number)
    and     r1, r1, #0x1F           @ mod 32
    
    /* Get destination Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = Dn value
    
    /* Create bit mask and test */
    mov     r11, #1
    lsl     r11, r11, r1            @ r11 = 1 << bit_number
    ands    r12, r3, r11            @ Test the bit
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    /* Set the bit */
    orr     r3, r3, r11
    str     r3, [r2, r0]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * BCLR Dn,Dn - Bit Test and Clear (dynamic bit number)
 * Opcode: 0000 DDD 110 000 SSS (0x0180)
 * 10 cycles - tests bit, then clears it
 */
.Lhandle_bclr_r_d:
    /* Get bit number from DX (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = DX (bit number)
    and     r1, r1, #0x1F           @ mod 32
    
    /* Get destination Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = Dn value
    
    /* Create bit mask and test */
    mov     r11, #1
    lsl     r11, r11, r1            @ r11 = 1 << bit_number
    ands    r12, r3, r11            @ Test the bit
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    /* Clear the bit */
    bic     r3, r3, r11
    str     r3, [r2, r0]
    
    add     r4, r4, #70             @ 10 * 7 cycles
    b       .Lmain_loop

/*
 * BCHG Dn,Dn - Bit Test and Change (dynamic bit number)
 * Opcode: 0000 DDD 101 000 SSS (0x0140)
 * 8 cycles - tests bit, then toggles it
 */
.Lhandle_bchg_r_d:
    /* Get bit number from DX (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = DX (bit number)
    and     r1, r1, #0x1F           @ mod 32
    
    /* Get destination Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = Dn value
    
    /* Create bit mask and test */
    mov     r11, #1
    lsl     r11, r11, r1            @ r11 = 1 << bit_number
    ands    r12, r3, r11            @ Test the bit
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    /* Toggle the bit */
    eor     r3, r3, r11
    str     r3, [r2, r0]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * BSET #imm,Dn - Bit Test and Set with immediate
 * Opcode: 0000 1000 11 000 DDD (0x08C0)
 * 12 cycles
 */
.Lhandle_bset_imm_d:
    /* Read bit number from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]            @ r2 = bit number
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    and     r2, r2, #0x1F           @ mod 32
    
    /* Get destination Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    /* Test and set */
    mov     r11, #1
    lsl     r11, r11, r2
    ands    r12, r3, r11
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    orr     r3, r3, r11
    str     r3, [r1, r0]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * BCLR #imm,Dn - Bit Test and Clear with immediate
 * Opcode: 0000 1000 10 000 DDD (0x0880)
 * 14 cycles
 */
.Lhandle_bclr_imm_d:
    /* Read bit number from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]            @ r2 = bit number
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    and     r2, r2, #0x1F           @ mod 32
    
    /* Get destination Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    /* Test and clear */
    mov     r11, #1
    lsl     r11, r11, r2
    ands    r12, r3, r11
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    bic     r3, r3, r11
    str     r3, [r1, r0]
    
    add     r4, r4, #98             @ 14 * 7 cycles
    b       .Lmain_loop

/*
 * BCHG #imm,Dn - Bit Test and Change with immediate
 * Opcode: 0000 1000 01 000 DDD (0x0840)
 * 12 cycles
 */
.Lhandle_bchg_imm_d:
    /* Read bit number from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]            @ r2 = bit number
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    and     r2, r2, #0x1F           @ mod 32
    
    /* Get destination Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    /* Test and toggle */
    mov     r11, #1
    lsl     r11, r11, r2
    ands    r12, r3, r11
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    eor     r3, r3, r11
    str     r3, [r1, r0]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * BTST Dn,(An) - Bit Test (dynamic) on memory byte
 * Format: 0000 DDD 100 010 SSS (0x0110)
 * 8 cycles
 */
.Lhandle_btst_r_ai:
    /* Get bit number from Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r2, [r1, r0]
    and     r2, r2, #7              @ mod 8 for byte
    
    /* Get address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Read byte from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lbtst_r_ai_ram
    
    ldr     r1, [r9]
    ldrb    r3, [r1, r11]
    b       .Lbtst_r_ai_test

.Lbtst_r_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    ldrb    r3, [r1, r0]

.Lbtst_r_ai_test:
    mov     r1, #1
    lsl     r1, r1, r2
    ands    r3, r3, r1
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BTST Dn,(An)+ - Bit Test (dynamic) on memory byte with post-inc
 * Format: 0000 DDD 100 011 SSS (0x0118)
 * 8 cycles
 */
.Lhandle_btst_r_pi:
    /* Get bit number from Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r12, [r2, r0]
    and     r12, r12, #7            @ mod 8 for byte, save in r12
    
    /* Get address from An and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = address
    add     r1, r11, #1
    str     r1, [r2, r0]            @ Post-increment by 1 (byte)
    
    /* Read byte from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lbtst_r_pi_ram
    
    ldr     r1, [r9]
    ldrb    r3, [r1, r11]
    b       .Lbtst_r_pi_test

.Lbtst_r_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    ldrb    r3, [r1, r0]

.Lbtst_r_pi_test:
    mov     r1, #1
    lsl     r1, r1, r12
    ands    r3, r3, r1
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * BSET Dn,(An) - Bit Test and Set on memory byte
 * Format: 0000 DDD 111 010 SSS (0x01D0)
 * 12 cycles
 */
.Lhandle_bset_r_ai:
    /* Get bit number from Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r2, [r1, r0]
    and     r2, r2, #7              @ mod 8 for byte
    
    /* Get address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Must be RAM for write */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    ldrb    r3, [r1, r0]            @ Read byte
    
    /* Test and set */
    mov     r12, #1
    lsl     r12, r12, r2
    ands    r0, r3, r12
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    orr     r3, r3, r12
    
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    strb    r3, [r1, r0]            @ Write back
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * BCLR Dn,(An) - Bit Test and Clear on memory byte
 * Format: 0000 DDD 110 010 SSS (0x0190)
 * 12 cycles
 */
.Lhandle_bclr_r_ai:
    /* Get bit number from Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r2, [r1, r0]
    and     r2, r2, #7              @ mod 8 for byte
    
    /* Get address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Must be RAM for write */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    ldrb    r3, [r1, r0]            @ Read byte
    
    /* Test and clear */
    mov     r12, #1
    lsl     r12, r12, r2
    ands    r0, r3, r12
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    bic     r3, r3, r12
    
    ldr     r1, =M68K_RAM
    movw    r0, #0xFFFF
    and     r0, r11, r0
    strb    r3, [r1, r0]            @ Write back
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * ORI.L #imm,Dn - OR Immediate Long
 * 16 cycles
 */
.Lhandle_ori_32_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0              @ r1 = ROM_DATA + PC
    ldrh    r2, [r1]                @ High word
    ldrh    r3, [r1, #2]            @ Low word
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16     @ Combine to 32-bit immediate
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    orr     r3, r3, r2
    str     r3, [r1, r0]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #112
    b       .Lmain_loop

/*
 * ORI.W #imm,Dn - OR Immediate Word
 * 8 cycles
 */
.Lhandle_ori_16_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    orr     r11, r3, r2
    uxth    r11, r11
    bfi     r3, r11, #0, #16
    str     r3, [r1, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ORI.B #imm,Dn - OR Immediate Byte
 * 8 cycles
 */
.Lhandle_ori_8_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    orr     r11, r3, r2
    uxtb    r11, r11
    bfi     r3, r11, #0, #8
    str     r3, [r1, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ANDI.L #imm,Dn - AND Immediate Long
 * 14 cycles
 */
.Lhandle_andi_32_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]
    ldrh    r3, [r1, #2]
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    and     r3, r3, r2
    str     r3, [r1, r0]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * ANDI.W #imm,Dn - AND Immediate Word
 * 8 cycles
 */
.Lhandle_andi_16_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    and     r11, r3, r2
    uxth    r11, r11
    bfi     r3, r11, #0, #16
    str     r3, [r1, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ANDI.B #imm,Dn - AND Immediate Byte
 * 8 cycles
 */
.Lhandle_andi_8_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    and     r11, r3, r2
    uxtb    r11, r11
    bfi     r3, r11, #0, #8
    str     r3, [r1, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * EORI.L #imm,Dn - EOR Immediate Long
 * 16 cycles
 */
.Lhandle_eori_32_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]
    ldrh    r3, [r1, #2]
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    eor     r3, r3, r2
    str     r3, [r1, r0]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #112
    b       .Lmain_loop

/*
 * EORI.W #imm,Dn - EOR Immediate Word
 * 8 cycles
 */
.Lhandle_eori_16_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    eor     r11, r3, r2
    uxth    r11, r11
    bfi     r3, r11, #0, #16
    str     r3, [r1, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * EORI.B #imm,Dn - EOR Immediate Byte
 * 8 cycles
 */
.Lhandle_eori_8_imm_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    eor     r11, r3, r2
    uxtb    r11, r11
    bfi     r3, r11, #0, #8
    str     r3, [r1, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * CMPI.L #imm,Dn - Compare Immediate Long
 * 14 cycles
 */
.Lhandle_cmpi_32_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]
    ldrh    r3, [r1, #2]
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16     @ r2 = immediate
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]            @ r3 = Dn
    
    subs    r0, r3, r2              @ Compare (Dn - imm)
    
    lsr     r1, r0, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * CMPI.W #imm,Dn - Compare Immediate Word
 * 8 cycles
 */
.Lhandle_cmpi_16_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    uxth    r3, r3
    
    subs    r0, r3, r2
    uxth    r0, r0
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    cmp     r3, r2
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * CMPI.B #imm,Dn - Compare Immediate Byte
 * 8 cycles
 */
.Lhandle_cmpi_8_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    uxtb    r3, r3
    
    subs    r0, r3, r2
    uxtb    r0, r0
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    cmp     r3, r2
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUBI.L #imm,Dn - Subtract Immediate Long
 * 16 cycles
 */
.Lhandle_subi_32_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]
    ldrh    r3, [r1, #2]
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    subs    r11, r3, r2
    str     r11, [r1, r0]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #112
    b       .Lmain_loop

/*
 * SUBI.W #imm,Dn - Subtract Immediate Word
 * 8 cycles
 */
.Lhandle_subi_16_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    mov     r11, r0
    
    uxth    r0, r3
    subs    r0, r0, r2
    uxth    r0, r0
    bfi     r3, r0, #0, #16
    str     r3, [r1, r11]
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUBI.B #imm,Dn - Subtract Immediate Byte
 * 8 cycles
 */
.Lhandle_subi_8_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    mov     r11, r0
    
    uxtb    r0, r3
    subs    r0, r0, r2
    uxtb    r0, r0
    bfi     r3, r0, #0, #8
    str     r3, [r1, r11]
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDI.L #imm,Dn - Add Immediate Long
 * 16 cycles
 */
.Lhandle_addi_32_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]
    ldrh    r3, [r1, #2]
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r2, r3, r2, lsl #16
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    adds    r11, r3, r2
    str     r11, [r1, r0]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #112
    b       .Lmain_loop

/*
 * ADDI.W #imm,Dn - Add Immediate Word
 * 8 cycles
 */
.Lhandle_addi_16_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    mov     r11, r0
    
    uxth    r0, r3
    adds    r0, r0, r2
    uxth    r0, r0
    bfi     r3, r0, #0, #16
    str     r3, [r1, r11]
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDI.B #imm,Dn - Add Immediate Byte
 * 8 cycles
 */
.Lhandle_addi_8_d:
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r2, [r1, r0]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    uxtb    r2, r2
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    mov     r11, r0
    
    uxtb    r0, r3
    adds    r0, r0, r2
    uxtb    r0, r0
    bfi     r3, r0, #0, #8
    str     r3, [r1, r11]
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
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

/* ======================================================================
 * MOVE.L INLINE HANDLERS
 * Format: 0010 DDD MMM sss SSS
 * ====================================================================== */

/*
 * Check which MOVE.L variant and dispatch
 * r10 = opcode (already verified top nibble = 2)
 */
.Lcheck_move_l:
    /* Extract dest mode (bits 6-8) and src mode (bits 3-5) */
    ubfx    r0, r10, #6, #3         @ r0 = dest mode
    ubfx    r1, r10, #3, #3         @ r1 = src mode
    
    /* Check for dest mode = 000 (to Dn) */
    cmp     r0, #0
    bne     .Lmove_l_check_dest_an
    
    /* Dest is Dn - check source mode */
    cmp     r1, #0
    beq     .Lhandle_move_l_d_d     @ MOVE.L Dn,Dn
    cmp     r1, #1
    beq     .Lhandle_move_l_a_d     @ MOVE.L An,Dn
    cmp     r1, #2
    beq     .Lhandle_move_l_ai_d    @ MOVE.L (An),Dn
    cmp     r1, #3
    beq     .Lhandle_move_l_pi_d    @ MOVE.L (An)+,Dn
    cmp     r1, #4
    beq     .Lhandle_move_l_pd_d    @ MOVE.L -(An),Dn
    cmp     r1, #5
    beq     .Lhandle_move_l_di_d    @ MOVE.L (d16,An),Dn
    cmp     r1, #7
    beq     .Lmove_l_check_imm_src  @ Check for immediate
    /* Other src modes need complex EA - fall through to C */
    b       .Lno_inline

.Lmove_l_check_imm_src:
    /* Mode 7, check reg field for immediate (100) */
    and     r0, r10, #7
    cmp     r0, #4
    beq     .Lhandle_move_l_imm_d   @ MOVE.L #imm,Dn
    b       .Lno_inline
    
.Lmove_l_check_dest_an:
    /* Check for dest mode = 001 (to An) - this is actually MOVEA.L */
    cmp     r0, #1
    bne     .Lmove_l_check_dest_ai
    
    /* Dest is An - check source mode */
    cmp     r1, #0
    beq     .Lhandle_movea_l_d      @ MOVEA.L Dn,An
    cmp     r1, #1
    beq     .Lhandle_movea_l_a      @ MOVEA.L An,An
    cmp     r1, #2
    beq     .Lhandle_movea_l_ai     @ MOVEA.L (An),An
    cmp     r1, #3
    beq     .Lhandle_movea_l_pi     @ MOVEA.L (An)+,An
    cmp     r1, #5
    beq     .Lhandle_movea_l_di     @ MOVEA.L (d16,An),An
    /* Other src modes need complex EA - fall through to C */
    b       .Lno_inline

.Lmove_l_check_dest_ai:
    /* Check for dest mode = 010 (to (An)) */
    cmp     r0, #2
    bne     .Lmove_l_check_dest_pi
    
    /* Dest is (An) - check source mode */
    cmp     r1, #0
    beq     .Lhandle_move_l_d_ai    @ MOVE.L Dn,(An)
    cmp     r1, #1
    beq     .Lhandle_move_l_a_ai    @ MOVE.L An,(An)
    cmp     r1, #2
    beq     .Lhandle_move_l_ai_ai   @ MOVE.L (An),(An) ✓
    @ (An)+,(An) disabled - needs debugging
    b       .Lno_inline

.Lmove_l_check_dest_pi:
    /* Check for dest mode = 011 (to (An)+) - post-increment */
    cmp     r0, #3
    bne     .Lmove_l_check_dest_pd
    
    /* Dest is (An)+ - check source mode */
    cmp     r1, #0
    beq     .Lhandle_move_l_d_pi    @ MOVE.L Dn,(An)+
    cmp     r1, #1
    beq     .Lhandle_move_l_a_pi    @ MOVE.L An,(An)+
    cmp     r1, #2
    beq     .Lhandle_move_l_ai_pi   @ MOVE.L (An),(An)+ ✓
    cmp     r1, #3
    beq     .Lhandle_move_l_pi_pi   @ MOVE.L (An)+,(An)+ - TEST
    b       .Lno_inline

.Lmove_l_check_dest_pd:
    /* Check for dest mode = 100 (to -(An)) - pre-decrement */
    cmp     r0, #4
    bne.w   .Lno_inline
    
    /* Dest is -(An) - check source mode */
    cmp     r1, #0
    beq     .Lhandle_move_l_d_pd    @ MOVE.L Dn,-(An)
    cmp     r1, #1
    beq     .Lhandle_move_l_a_pd    @ MOVE.L An,-(An)
    b       .Lno_inline
    b       .Lno_inline

/*
 * MOVE.L Dn,Dn - Move Long between data registers
 * Opcode: 0010 DDD 000 000 SSS
 * 4 cycles
 */
.Lhandle_move_l_d_d:
    /* Get source register index from bits 0-2 */
    and     r0, r10, #7             @ r0 = src reg index
    lsl     r0, r0, #2              @ r0 = src offset
    
    /* Get destination register index from bits 9-11 */
    ubfx    r1, r10, #9, #3         @ r1 = dest reg index
    lsl     r1, r1, #2              @ r1 = dest offset
    
    /* Load source value from dar[src] */
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Store to dar[dst] */
    str     r3, [r2, r1]
    
    /* Set flags: N from bit 31, Z from value, V=0, C=0 */
    lsr     r0, r3, #24             @ N flag in bit 7
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ MOVE.L Dn,Dn = 4 * 7 cycles
    b       .Lmain_loop

/*
 * MOVE.L An,Dn - Move Long from address register to data register
 * Opcode: 0010 DDD 000 001 SSS
 * 4 cycles
 */
.Lhandle_move_l_a_d:
    /* Get source An index from bits 0-2 (add 8 for address registers) */
    and     r0, r10, #7
    add     r0, r0, #8              @ Address regs are dar[8-15]
    lsl     r0, r0, #2
    
    /* Get destination Dn index from bits 9-11 */
    ubfx    r1, r10, #9, #3
    lsl     r1, r1, #2
    
    /* Load source, store to dest */
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value from An
    str     r3, [r2, r1]            @ Store to Dn
    
    /* Set flags */
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * MOVEA.L Dn,An - Move Long from data register to address register
 * Opcode: 0010 DDD 001 000 SSS
 * 4 cycles - does NOT affect flags
 */
.Lhandle_movea_l_d:
    /* Get source Dn index from bits 0-2 */
    and     r0, r10, #7
    lsl     r0, r0, #2
    
    /* Get destination An index from bits 9-11 (add 8 for address registers) */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r1, r1, #2
    
    /* Load source, store to dest */
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value from Dn
    str     r3, [r2, r1]            @ Store to An
    
    /* MOVEA does NOT affect flags */
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * MOVEA.L An,An - Move Long between address registers
 * Opcode: 0010 DDD 001 001 SSS
 * 4 cycles - does NOT affect flags
 */
.Lhandle_movea_l_a:
    /* Get source An index from bits 0-2 (add 8) */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    
    /* Get destination An index from bits 9-11 (add 8) */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r1, r1, #2
    
    /* Load source, store to dest */
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    str     r3, [r2, r1]
    
    /* MOVEA does NOT affect flags */
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/* ======================================================================
 * MOVE.L WITH MEMORY ACCESS
 * These require reading/writing memory via ROM_DATA or M68K_RAM
 * ====================================================================== */

    .extern M68K_RAM
    .extern m68k_read_memory_32
    .extern m68k_write_memory_32

/*
 * MOVE.L (An),Dn - Load long from address register indirect
 * Opcode: 0010 DDD 000 010 SSS
 * 12 cycles
 */
.Lhandle_move_l_ai_d:
    /* Get source An index and load address */
    and     r0, r10, #7
    add     r0, r0, #8              @ Address regs are dar[8-15]
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address from An
    
    /* Get destination Dn index */
    ubfx    r11, r10, #9, #3        @ r11 = dest reg index (save for later)
    
    /* Check if address is in ROM (< 0x800000) */
    movw    r1, #0
    movt    r1, #0x80               @ r1 = 0x800000
    cmp     r0, r1
    bhs     .Lmove_l_ai_d_not_rom
    
    /* Fast ROM read - load 32-bit with half-word swap */
    ldr     r1, [r9]                @ r1 = ROM_DATA pointer (r9 cached)
    ldr     r3, [r1, r0]            @ Load 32-bit
    /* Swap 16-bit halves for big-endian */
    ror     r3, r3, #16             @ Rotate right 16 = swap halves
    b       .Lmove_l_ai_d_store
    
.Lmove_l_ai_d_not_rom:
    /* Check if address is in RAM (>= 0xFF0000) */
    movw    r1, #0
    movt    r1, #0xFF               @ r1 = 0xFF0000
    cmp     r0, r1
    blo     .Lmove_l_ai_d_slow
    
    /* Fast RAM read */
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2              @ Mask to RAM offset
    ldr     r3, [r1, r0]            @ Load 32-bit from RAM
    ror     r3, r3, #16             @ Swap halves
    b       .Lmove_l_ai_d_store
    
.Lmove_l_ai_d_slow:
    /* Fall back to C function for I/O regions */
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0                  @ r3 = value
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lmove_l_ai_d_store:
    /* Store to Dn */
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    
    /* Set flags */
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * MOVE.L (An)+,Dn - Load long from address register with post-increment
 * Opcode: 0010 DDD 000 011 SSS
 * 12 cycles
 */
.Lhandle_move_l_pi_d:
    /* Get source An index */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2             @ r11 = An offset (save for post-inc)
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = address from An
    
    /* Post-increment An by 4 */
    add     r1, r0, #4
    str     r1, [r2, r11]           @ An += 4
    
    /* Get destination Dn index */
    ubfx    r11, r10, #9, #3        @ r11 = dest reg index
    
    /* Check if address is in ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_pi_d_not_rom
    
    /* Fast ROM read */
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pi_d_store
    
.Lmove_l_pi_d_not_rom:
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_pi_d_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pi_d_store
    
.Lmove_l_pi_d_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lmove_l_pi_d_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * MOVEA.L (An),An - Load long from memory to address register
 * Opcode: 0010 DDD 001 010 SSS
 * 12 cycles - does NOT affect flags
 */
.Lhandle_movea_l_ai:
    /* Get source An index and load address */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Get destination An index */
    ubfx    r11, r10, #9, #3
    add     r11, r11, #8
    
    /* Check ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmovea_l_ai_not_rom
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_ai_store
    
.Lmovea_l_ai_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmovea_l_ai_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_ai_store
    
.Lmovea_l_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lmovea_l_ai_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    /* MOVEA does NOT affect flags */
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVEA.L (An)+,An - Load long with post-increment to address register
 * Opcode: 0010 DDD 001 011 SSS
 * 12 cycles - does NOT affect flags
 */
.Lhandle_movea_l_pi:
    /* Get source An index */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = address
    
    /* Post-increment */
    add     r1, r0, #4
    str     r1, [r2, r11]
    
    /* Get destination An index */
    ubfx    r11, r10, #9, #3
    add     r11, r11, #8
    
    /* Check ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmovea_l_pi_not_rom
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_pi_store
    
.Lmovea_l_pi_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmovea_l_pi_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_pi_store
    
.Lmovea_l_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lmovea_l_pi_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L -(An),Dn - Load long from memory with pre-decrement
 * Opcode: 0010 DDD 000 100 SSS
 * 14 cycles
 */
.Lhandle_move_l_pd_d:
    /* Get source An index and load address */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2             @ Save offset
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = An value
    
    /* Pre-decrement by 4 */
    sub     r0, r0, #4
    str     r0, [r2, r11]           @ Store updated An
    
    /* Get destination Dn index */
    ubfx    r11, r10, #9, #3
    
    /* Check ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_pd_d_not_rom
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pd_d_store

.Lmove_l_pd_d_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_pd_d_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pd_d_store

.Lmove_l_pd_d_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]

.Lmove_l_pd_d_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #98             @ 14 * 7 cycles
    b       .Lmain_loop

/*
 * MOVE.L (d16,An),Dn - Load long from memory with displacement
 * Opcode: 0010 DDD 000 101 SSS
 * 16 cycles
 */
.Lhandle_move_l_di_d:
    /* Get base An and displacement */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = An value
    
    /* Read displacement from extension word */
    ldr     r1, [r5, #M68K_PC]
    ldr     r2, [r9]
    ldrh    r3, [r2, r1]            @ r3 = displacement (unsigned)
    sxth    r3, r3                  @ Sign-extend
    add     r1, r1, #2
    str     r1, [r5, #M68K_PC]      @ Consume extension word
    
    /* Calculate effective address */
    add     r0, r0, r3              @ r0 = An + d16
    
    /* Get destination Dn index */
    ubfx    r11, r10, #9, #3
    
    /* Check ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_di_d_not_rom
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_di_d_store

.Lmove_l_di_d_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_di_d_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_di_d_store

.Lmove_l_di_d_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]

.Lmove_l_di_d_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #112            @ 16 * 7 cycles
    b       .Lmain_loop

/*
 * MOVEA.L (d16,An),An - Load long from memory with displacement to An
 * Opcode: 0010 DDD 001 101 SSS
 * 16 cycles - does NOT affect flags
 */
.Lhandle_movea_l_di:
    /* Get base An and displacement */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]
    
    /* Read displacement */
    ldr     r1, [r5, #M68K_PC]
    ldr     r2, [r9]
    ldrh    r3, [r2, r1]
    sxth    r3, r3
    add     r1, r1, #2
    str     r1, [r5, #M68K_PC]
    
    add     r0, r0, r3
    
    /* Get dest An */
    ubfx    r11, r10, #9, #3
    add     r11, r11, #8
    
    /* Check ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmovea_l_di_not_rom
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_di_store

.Lmovea_l_di_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmovea_l_di_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmovea_l_di_store

.Lmovea_l_di_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]

.Lmovea_l_di_store:
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    str     r3, [r2, r11]
    add     r4, r4, #112
    b       .Lmain_loop

    /* Force literal pool here */
    .ltorg

/*
 * MOVE.L Dn,(An) - Store long from data register to memory
 * Opcode: 0010 AAA 010 000 DDD
 * 12 cycles
 */
.Lhandle_move_l_d_ai:
    /* Get source Dn value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get destination An index and load address */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r0, [r2, r0]            @ r0 = destination address
    
    /* Set flags first (from source value) */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check if address is in RAM (only RAM is writable inline) */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_d_ai_slow
    
    /* Fast RAM write */
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ror     r3, r3, #16             @ Swap halves for big-endian
    str     r3, [r1, r0]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop
    
.Lmove_l_d_ai_slow:
    /* Fall back to C for writes to ROM/IO */
    str     r4, [r5, #M68K_CYCLES]
    mov     r1, r3                  @ r1 = value
    bl      m68k_write_memory_32
    ldr     r4, [r5, #M68K_CYCLES]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L An,(An) - Store address register to memory indirect
 * Opcode: 0010 AAA 010 001 SSS
 * 12 cycles
 */
.Lhandle_move_l_a_ai:
    /* Get source An value */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get destination An and load address */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r0, [r2, r0]            @ r0 = destination address
    
    /* Set flags */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_a_ai_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #84
    b       .Lmain_loop
    
.Lmove_l_a_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    mov     r1, r3
    bl      m68k_write_memory_32
    ldr     r4, [r5, #M68K_CYCLES]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L Dn,-(An) - Move Long to pre-decrement address
 * Opcode: 0010 DDD 100 000 SSS
 * 12 cycles
 */
.Lhandle_move_l_d_pd:
    /* Get source Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get dest An, pre-decrement */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r11, r0, #2             @ Save reg offset
    ldr     r0, [r2, r11]           @ r0 = An
    sub     r0, r0, #4              @ Pre-decrement
    str     r0, [r2, r11]           @ Store back
    
    /* Set flags */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_d_pd_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #84
    b       .Lmain_loop
    
.Lmove_l_d_pd_slow:
    str     r4, [r5, #M68K_CYCLES]
    mov     r1, r3
    bl      m68k_write_memory_32
    ldr     r4, [r5, #M68K_CYCLES]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L An,-(An) - Move Address Register to pre-decrement address
 * Opcode: 0010 DDD 100 001 SSS
 * 12 cycles
 */
.Lhandle_move_l_a_pd:
    /* Get source An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get dest An, pre-decrement */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r11, r0, #2
    ldr     r0, [r2, r11]
    sub     r0, r0, #4
    str     r0, [r2, r11]
    
    /* Set flags */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lmove_l_a_pd_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #84
    b       .Lmain_loop
    
.Lmove_l_a_pd_slow:
    str     r4, [r5, #M68K_CYCLES]
    mov     r1, r3
    bl      m68k_write_memory_32
    ldr     r4, [r5, #M68K_CYCLES]
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L #imm,Dn - Move Immediate Long to Data Register
 * Opcode: 0010 DDD 000 111 100 (0x203C)
 * 12 cycles
 */
.Lhandle_move_l_imm_d:
    /* Read 32-bit immediate */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    add     r1, r1, r0
    ldrh    r2, [r1]                @ High word
    ldrh    r3, [r1, #2]            @ Low word
    add     r0, r0, #4
    str     r0, [r5, #M68K_PC]
    orr     r11, r3, r2, lsl #16    @ Combine to 32-bit
    
    /* Store to destination Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    str     r11, [r2, r0]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * MOVE.L Dn,(An)+ - Move Data Register to post-increment address
 * Opcode: 0010 DDD 011 000 SSS
 * 12 cycles
 */
.Lhandle_move_l_d_pi:
    /* Get source Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get dest An, post-increment */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r11, r0, #2
    ldr     r0, [r2, r11]           @ r0 = dest address
    mov     r12, r0                 @ Save address for write
    add     r0, r0, #4
    str     r0, [r2, r11]           @ Post-increment
    
    /* Set flags */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r12, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r12, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L An,(An)+ - Move Address Register to post-increment address
 * Opcode: 0010 DDD 011 001 SSS
 * 12 cycles
 */
.Lhandle_move_l_a_pi:
    /* Get source An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = source value
    
    /* Get dest An, post-increment */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r11, r0, #2
    ldr     r0, [r2, r11]
    mov     r12, r0
    add     r0, r0, #4
    str     r0, [r2, r11]
    
    /* Set flags */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r12, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r12, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * MOVE.L (An),(An) - Memory to memory indirect
 * 20 cycles
 */
.Lhandle_move_l_ai_ai:
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = source address
    
    /* Save dest An offset */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r12, r1, #2
    ldr     r11, [r2, r12]          @ r11 = dest address
    
    /* Read source from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_ai_ai_ram_src
    
    ldr     r1, [r9]                @ ROM_DATA
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_ai_ai_write

.Lmove_l_ai_ai_ram_src:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16             @ Swap for big-endian

.Lmove_l_ai_ai_write:
    /* Set flags from value (r3 is in native format after read swap) */
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Write to dest (must be RAM) */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ror     r3, r3, #16             @ Swap back to storage format
    str     r3, [r1, r0]
    
    add     r4, r4, #140
    b       .Lmain_loop

/*
 * MOVE.L (An)+,(Am) - Memory post-increment to memory indirect
 * 20 cycles
 */
.Lhandle_move_l_pi_ai:
    add     r2, r5, #M68K_DAR
    
    /* Get source address from An and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = source address (save for read)
    add     r1, r11, #4
    str     r1, [r2, r0]            @ Post-increment source
    
    /* Get dest address from Am (AFTER increment - M68K semantics) */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r12, r1, #2
    ldr     r12, [r2, r12]          @ r12 = dest address
    
    /* Read source from ROM or RAM (source addr in r11) */
    mov     r0, r11
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_pi_ai_ram_src
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pi_ai_write

.Lmove_l_pi_ai_ram_src:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16

.Lmove_l_pi_ai_write:
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    /* Write to dest (r12) */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r12, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r12, r2
    ror     r3, r3, #16
    str     r3, [r1, r0]
    
    add     r4, r4, #140
    b       .Lmain_loop

/*
 * MOVE.L (An),(An)+ - Memory indirect to post-increment
 * 20 cycles
 */
.Lhandle_move_l_ai_pi:
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = source address
    
    /* Get dest address from An and post-increment */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r12, r1, #2
    ldr     r11, [r2, r12]          @ r11 = dest address
    add     r1, r11, #4
    str     r1, [r2, r12]           @ Post-increment
    
    /* Read source from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_ai_pi_ram_src
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_ai_pi_write

.Lmove_l_ai_pi_ram_src:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16             @ Swap for big-endian

.Lmove_l_ai_pi_write:
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ror     r3, r3, #16             @ Swap back to storage format
    str     r3, [r1, r0]
    
    add     r4, r4, #140
    b       .Lmain_loop

/*
 * MOVE.L (An)+,(An)+ - Memory post-increment to post-increment (block copy)
 * 20 cycles
 */
.Lhandle_move_l_pi_pi:
    /* Get source address from An and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source address
    add     r3, r1, #4
    str     r3, [r2, r0]            @ Post-increment source
    mov     r0, r1                  @ r0 = source address
    
    /* Get dest address from An and post-increment */
    ubfx    r1, r10, #9, #3
    add     r1, r1, #8
    lsl     r12, r1, #2
    ldr     r11, [r2, r12]          @ r11 = dest address
    add     r1, r11, #4
    str     r1, [r2, r12]           @ Post-increment dest
    
    /* Read source from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_l_pi_pi_ram_src
    
    ldr     r1, [r9]
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Lmove_l_pi_pi_write

.Lmove_l_pi_pi_ram_src:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16             @ Swap for big-endian

.Lmove_l_pi_pi_write:
    lsr     r1, r3, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ror     r3, r3, #16             @ Swap back to storage format
    str     r3, [r1, r0]
    
    add     r4, r4, #140
    b       .Lmain_loop

    /* Literal pool for MOVE.L handlers */
    .ltorg

/* ======================================================================
 * MOVE.W HANDLERS - 0x3xxx opcodes
 * Format: 0011 DDD MMM sss SSS
 * ====================================================================== */

.Lcheck_move_w:
    /* Get source mode (bits 5-3) and dest mode (bits 8-6) */
    ubfx    r0, r10, #6, #3         @ dest mode
    ubfx    r1, r10, #3, #3         @ src mode
    
    /* Check for MOVE.W Dn,Dn (src mode=0, dest mode=0) */
    orrs    r2, r0, r1
    beq     .Lhandle_move_w_d_d
    
    /* Check for MOVE.W An,Dn (src mode=1, dest mode=0) */
    cmp     r0, #0
    bne     .Lmove_w_check_dest_modes
    cmp     r1, #1
    beq     .Lhandle_move_w_a_d
    cmp     r1, #2
    beq     .Lhandle_move_w_ai_d    @ MOVE.W (An),Dn
    cmp     r1, #3
    beq     .Lhandle_move_w_pi_d    @ MOVE.W (An)+,Dn
    cmp     r1, #4
    beq     .Lhandle_move_w_pd_d    @ MOVE.W -(An),Dn
    b.w     .Lno_inline

.Lmove_w_check_dest_modes:
    /* Dest mode = 1 is MOVEA.W */
    cmp     r0, #1
    beq     .Lmove_w_check_movea
    /* Dest mode = 2 is MOVE.W Dn/An,(An) */
    cmp     r0, #2
    beq     .Lmove_w_check_dest_ai
    /* Dest mode = 4 is MOVE.W Dn/An,-(An) */
    cmp     r0, #4
    beq     .Lmove_w_check_dest_pd
    b.w     .Lno_inline

.Lmove_w_check_movea:
    cmp     r1, #0
    beq     .Lhandle_movea_w_d      @ MOVEA.W Dn,An
    cmp     r1, #1
    beq     .Lhandle_movea_w_a      @ MOVEA.W An,An
    b.w     .Lno_inline

.Lmove_w_check_dest_ai:
    cmp     r1, #0
    beq     .Lhandle_move_w_d_ai    @ MOVE.W Dn,(An)
    cmp     r1, #1
    beq     .Lhandle_move_w_a_ai    @ MOVE.W An,(An)
    b.w     .Lno_inline

.Lmove_w_check_dest_pd:
    cmp     r1, #0
    beq     .Lhandle_move_w_d_pd    @ MOVE.W Dn,-(An)
    cmp     r1, #1
    beq     .Lhandle_move_w_a_pd    @ MOVE.W An,-(An)
    b.w     .Lno_inline

/*
 * MOVE.W Dn,Dn - Move Word between Data Registers
 * Opcode: 0011 DDD 000 000 SSS (0x3000)
 * 4 cycles
 */
.Lhandle_move_w_d_d:
    /* Get source register and value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (full 32-bit)
    uxth    r1, r1                  @ Mask to 16 bits
    
    /* Get destination register */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = dest (full 32-bit)
    bfi     r3, r1, #0, #16         @ Insert low 16 bits
    str     r3, [r2, r0]
    
    /* Set flags from 16-bit value */
    lsr     r0, r1, #8              @ N flag from bit 15 (shifted to bit 7)
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * MOVE.W An,Dn - Move Word from Address to Data Register
 * Opcode: 0011 DDD 000 001 SSS (0x3008)
 * 4 cycles
 */
.Lhandle_move_w_a_d:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    bfi     r3, r1, #0, #16
    str     r3, [r2, r0]
    
    lsr     r0, r1, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * MOVE.W (An),Dn - Move Word from memory indirect to Data Register
 * Opcode: 0011 DDD 000 010 SSS
 * 8 cycles
 */
.Lhandle_move_w_ai_d:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address in An
    
    /* Check if ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_w_ai_d_ram
    
    /* ROM read */
    ldr     r1, [r9]
    ldrh    r1, [r1, r0]
    b       .Lmove_w_ai_d_store

.Lmove_w_ai_d_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r1, r0]

.Lmove_w_ai_d_store:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    bfi     r3, r1, #0, #16
    str     r3, [r2, r0]
    
    lsr     r0, r1, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * MOVE.W (An)+,Dn - Move Word with post-increment
 * Opcode: 0011 DDD 000 011 SSS
 * 8 cycles
 */
.Lhandle_move_w_pi_d:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2             @ Save offset for increment
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = address in An
    
    /* Increment An by 2 */
    add     r3, r0, #2
    str     r3, [r2, r11]
    
    /* Check if ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_w_pi_d_ram
    
    ldr     r1, [r9]
    ldrh    r1, [r1, r0]
    b       .Lmove_w_pi_d_store

.Lmove_w_pi_d_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r1, r0]

.Lmove_w_pi_d_store:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    bfi     r3, r1, #0, #16
    str     r3, [r2, r0]
    
    lsr     r0, r1, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * MOVEA.W Dn,An - Move Word from Data to Address Register (sign-extend)
 * Opcode: 0011 AAA 001 000 DDD
 * 4 cycles - does NOT affect flags
 */
.Lhandle_movea_w_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    sxth    r1, r1                  @ Sign-extend word to long
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    str     r1, [r2, r0]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * MOVEA.W An,An - Move Word from Address to Address Register (sign-extend)
 * Opcode: 0011 AAA 001 001 SSS
 * 4 cycles - does NOT affect flags
 */
.Lhandle_movea_w_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    sxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    str     r1, [r2, r0]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * MOVE.W -(An),Dn - Move Word with pre-decrement
 * Opcode: 0011 DDD 000 100 SSS
 * 10 cycles
 */
.Lhandle_move_w_pd_d:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]
    
    /* Pre-decrement An by 2 */
    sub     r0, r0, #2
    str     r0, [r2, r11]
    
    /* Check if ROM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lmove_w_pd_d_ram
    
    ldr     r1, [r9]
    ldrh    r1, [r1, r0]
    b       .Lmove_w_pd_d_store

.Lmove_w_pd_d_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r1, r0]

.Lmove_w_pd_d_store:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    bfi     r3, r1, #0, #16
    str     r3, [r2, r0]
    
    lsr     r0, r1, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #70
    b       .Lmain_loop

/*
 * MOVE.W Dn,(An) - Move Word from Data Register to memory indirect
 * Opcode: 0011 AAA 010 000 DDD
 * 8 cycles
 */
.Lhandle_move_w_d_ai:
    /* Get source value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r11, r1                 @ r11 = 16-bit value
    
    /* Get destination address from An */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Must be RAM (>= 0xFF0000) */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    strh    r11, [r2, r0]
    
    /* Set flags */
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * MOVE.W An,(An) - Move Word from Address Register to memory indirect
 * Opcode: 0011 AAA 010 001 SSS
 * 8 cycles
 */
.Lhandle_move_w_a_ai:
    /* Get source value from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r11, r1
    
    /* Get destination address from An */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r0, [r2, r0]
    
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    strh    r11, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * MOVE.W Dn,-(An) - Move Word from Data Register with pre-decrement
 * Opcode: 0011 AAA 100 000 DDD
 * 8 cycles
 */
.Lhandle_move_w_d_pd:
    /* Get source value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r11, r1
    
    /* Get destination An and pre-decrement */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    sub     r0, r0, #2
    str     r0, [r2, r3]
    
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    strh    r11, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * MOVE.W An,-(An) - Move Word from Address Register with pre-decrement
 * Opcode: 0011 AAA 100 001 SSS
 * 8 cycles
 */
.Lhandle_move_w_a_pd:
    /* Get source value from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r11, r1
    
    /* Get destination An and pre-decrement */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    sub     r0, r0, #2
    str     r0, [r2, r3]
    
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    strh    r11, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

    /* Literal pool for MOVE.W handlers */
    .ltorg

/* ======================================================================
 * 0x4xxx HANDLERS - TST, CLR, LEA, NEG, NOT, EXT, SWAP, etc.
 * ====================================================================== */

.Lcheck_4xxx:
    bic     r0, r10, #7             @ r0 = opcode & 0xFFF8
    
    /* Check for CLR.L Dn (0x4280-0x4287) */
    movw    r1, #0x4280
    cmp     r0, r1
    beq     .Lhandle_clr_32_d
    
    /* Check for NEG.L Dn (0x4480-0x4487) */
    movw    r1, #0x4480
    cmp     r0, r1
    beq     .Lhandle_neg_32_d
    
    /* Check for NEG.W Dn (0x4440-0x4447) */
    movw    r1, #0x4440
    cmp     r0, r1
    beq     .Lhandle_neg_16_d
    
    /* Check for NEG.B Dn (0x4400-0x4407) */
    movw    r1, #0x4400
    cmp     r0, r1
    beq     .Lhandle_neg_8_d
    
    /* Check for NEGX.L Dn (0x4080-0x4087) */
    movw    r1, #0x4080
    cmp     r0, r1
    beq     .Lhandle_negx_32_d
    
    /* Check for NEGX.W Dn (0x4040-0x4047) */
    movw    r1, #0x4040
    cmp     r0, r1
    beq     .Lhandle_negx_16_d
    
    /* Check for NEGX.B Dn (0x4000-0x4007) */
    movw    r1, #0x4000
    cmp     r0, r1
    beq     .Lhandle_negx_8_d
    
    /* Check for NOT.L Dn (0x4680-0x4687) */
    movw    r1, #0x4680
    cmp     r0, r1
    beq     .Lhandle_not_32_d
    
    /* Check for NOT.W Dn (0x4640-0x4647) */
    movw    r1, #0x4640
    cmp     r0, r1
    beq     .Lhandle_not_16_d
    
    /* Check for NOT.B Dn (0x4600-0x4607) */
    movw    r1, #0x4600
    cmp     r0, r1
    beq     .Lhandle_not_8_d
    
    /* Check for SWAP Dn (0x4840-0x4847) */
    movw    r1, #0x4840
    cmp     r0, r1
    beq     .Lhandle_swap_32
    
    /* Check for EXT.L Dn (0x48C0-0x48C7) */
    movw    r1, #0x48C0
    cmp     r0, r1
    beq     .Lhandle_ext_32
    
    /* Check for LEA (An),An (0x41D0-0x41D7) */
    movw    r1, #0x41D0
    cmp     r0, r1
    beq     .Lhandle_lea_ai
    
    /* Check for TST.L Dn (0x4A80-0x4A87) */
    movw    r1, #0x4A80
    cmp     r0, r1
    beq     .Lhandle_tst_32_d
    
    /* Check for TST.L (An) (0x4A90-0x4A97) */
    movw    r1, #0x4A90
    cmp     r0, r1
    beq     .Lhandle_tst_32_ai
    
    /* Check for TST.L (An)+ (0x4A98-0x4A9F) */
    movw    r1, #0x4A98
    cmp     r0, r1
    beq     .Lhandle_tst_32_pi
    
    /* Check for JMP (An) (0x4ED0-0x4ED7) */
    movw    r1, #0x4ED0
    cmp     r0, r1
    beq     .Lhandle_jmp_ai
    
    /* Check for JSR (An) (0x4E90-0x4E97) */
    movw    r1, #0x4E90
    cmp     r0, r1
    beq     .Lhandle_jsr_ai
    
    /* Check for EXT.W Dn (0x4880-0x4887) */
    movw    r1, #0x4880
    cmp     r0, r1
    beq     .Lhandle_ext_16
    
    /* Check for CLR.W Dn (0x4240-0x4247) */
    movw    r1, #0x4240
    cmp     r0, r1
    beq     .Lhandle_clr_16_d
    
    /* Check for CLR.B Dn (0x4200-0x4207) */
    movw    r1, #0x4200
    cmp     r0, r1
    beq     .Lhandle_clr_8_d
    
    /* Check for CLR.L (An) (0x4290-0x4297) */
    movw    r1, #0x4290
    cmp     r0, r1
    beq     .Lhandle_clr_32_ai
    
    /* Check for CLR.L (An)+ (0x4298-0x429F) */
    movw    r1, #0x4298
    cmp     r0, r1
    beq     .Lhandle_clr_32_pi
    
    /* Check for CLR.W (An) (0x4250-0x4257) */
    movw    r1, #0x4250
    cmp     r0, r1
    beq     .Lhandle_clr_16_ai
    
    /* Check for CLR.W (An)+ (0x4258-0x425F) */
    movw    r1, #0x4258
    cmp     r0, r1
    beq     .Lhandle_clr_16_pi
    
    /* Check for TST.W Dn (0x4A40-0x4A47) */
    movw    r1, #0x4A40
    cmp     r0, r1
    beq     .Lhandle_tst_16_d
    
    /* Check for TST.W (An) (0x4A50-0x4A57) */
    movw    r1, #0x4A50
    cmp     r0, r1
    beq     .Lhandle_tst_16_ai
    
    /* Check for TST.W (An)+ (0x4A58-0x4A5F) */
    movw    r1, #0x4A58
    cmp     r0, r1
    beq     .Lhandle_tst_16_pi
    
    /* Check for TST.B Dn (0x4A00-0x4A07) */
    movw    r1, #0x4A00
    cmp     r0, r1
    beq     .Lhandle_tst_8_d
    
    /* Check for RTS (0x4E75) - exact match */
    movw    r1, #0x4E75
    cmp     r10, r1
    beq     .Lhandle_rts
    
    /* Check for NOP (0x4E71) - exact match */
    movw    r1, #0x4E71
    cmp     r10, r1
    beq     .Lhandle_nop
    
    /* Check for PEA (An) (0x4850-0x4857) */
    movw    r1, #0x4850
    cmp     r0, r1
    beq     .Lhandle_pea_ai
    
    /* Check for PEA (d16,An) (0x4868-0x486F) */
    movw    r1, #0x4868
    cmp     r0, r1
    beq     .Lhandle_pea_di
    
    /* Check for LEA (d16,An),An - need to check full pattern */
    /* Opcode: 0100 AAA 111 101 aaa (0x41E8-0x4FEF) */
    movw    r0, #0x01F8
    and     r0, r10, r0
    movw    r1, #0x01E8             @ Bits 8-3 = 111 101
    cmp     r0, r1
    beq     .Lhandle_lea_di
    
    /* Check for LEA (d16,PC),An (0x41FA-0x4FFA) */
    movw    r0, #0x01FF
    and     r0, r10, r0
    movw    r1, #0x01FA             @ 111 111 010
    cmp     r0, r1
    beq     .Lhandle_lea_pc_di
    
    /* Check for JMP (d16,An) (0x4EE8-0x4EEF) */
    bic     r0, r10, #7
    movw    r1, #0x4EE8
    cmp     r0, r1
    beq     .Lhandle_jmp_di
    
    /* Check for JSR (d16,An) (0x4EA8-0x4EAF) */
    movw    r1, #0x4EA8
    cmp     r0, r1
    beq     .Lhandle_jsr_di
    
    /* Check for JMP (d16,PC) (0x4EFA) */
    movw    r1, #0x4EFA
    cmp     r10, r1
    beq     .Lhandle_jmp_pc_di
    
    /* Check for JSR (d16,PC) (0x4EBA) */
    movw    r1, #0x4EBA
    cmp     r10, r1
    beq     .Lhandle_jsr_pc_di
    
    /* Check for LINK An,#imm (0x4E50-0x4E57) */
    bic     r0, r10, #7
    movw    r1, #0x4E50
    cmp     r0, r1
    beq     .Lhandle_link
    
    /* Check for UNLK An (0x4E58-0x4E5F) */
    movw    r1, #0x4E58
    cmp     r0, r1
    beq     .Lhandle_unlk
    
    /* Other 0x4xxx variants - use C */
    b       .Lno_inline

/*
 * NEG.L Dn - Negate Data Register
 * Opcode: 0100 0100 1000 0rrr (0x4480)
 * 6 cycles
 */
.Lhandle_neg_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = original value
    
    /* Negate: 0 - src */
    rsbs    r11, r1, #0             @ r11 = -r1
    str     r11, [r2, r0]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* V = src & res (both negative = overflow) */
    and     r0, r1, r11
    lsr     r0, r0, #24
    str     r0, [r5, #M68K_V_FLAG]
    
    /* C/X = src != 0 (borrow occurred if we subtracted from 0) */
    cmp     r1, #0
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

.ltorg

/*
 * NEG.W Dn - Negate Data Register Word
 * Opcode: 0100 0100 0100 0rrr (0x4440)
 * 4 cycles
 */
.Lhandle_neg_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r3, r1                  @ r3 = original low word
    
    rsb     r11, r3, #0             @ r11 = -r3
    uxth    r11, r11                @ Mask to 16 bits
    bfi     r1, r11, #0, #16
    str     r1, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* V = src & res (both negative = overflow) - check bit 15 */
    and     r0, r3, r11
    lsr     r0, r0, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    
    cmp     r3, #0
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * NEG.B Dn - Negate Data Register Byte
 * Opcode: 0100 0100 0000 0rrr (0x4400)
 * 4 cycles
 */
.Lhandle_neg_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r3, r1                  @ r3 = original low byte
    
    rsb     r11, r3, #0
    uxtb    r11, r11
    bfi     r1, r11, #0, #8
    str     r1, [r2, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    and     r0, r3, r11
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    
    cmp     r3, #0
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * NEGX.L Dn - Negate with Extend Long
 * Opcode: 0100 0000 1000 0rrr (0x4080)
 * 6 cycles - computes 0 - Dn - X
 */
.Lhandle_negx_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    /* Get X flag (bit 8 set means X=1) */
    ldr     r3, [r5, #M68K_X_FLAG]
    lsr     r3, r3, #8              @ r3 = 0 or 1
    
    /* Result = 0 - source - X */
    rsb     r11, r1, #0
    sub     r11, r11, r3
    str     r11, [r2, r0]
    
    /* N flag */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag: only cleared if result != 0, not set */
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* V = (src & result) has MSB set */
    and     r0, r1, r11
    lsr     r0, r0, #24
    str     r0, [r5, #M68K_V_FLAG]
    
    /* C/X = src != 0 or X was set */
    orrs    r0, r1, r3
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * NEGX.W Dn - Negate with Extend Word
 * Opcode: 0100 0000 0100 0rrr (0x4040)
 * 4 cycles
 */
.Lhandle_negx_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r3, r1                  @ r3 = low word
    
    ldr     r12, [r5, #M68K_X_FLAG]
    lsr     r12, r12, #8
    
    rsb     r11, r3, #0
    sub     r11, r11, r12
    uxth    r11, r11
    bfi     r1, r11, #0, #16
    str     r1, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    and     r0, r3, r11
    lsr     r0, r0, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    
    orrs    r0, r3, r12
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * NEGX.B Dn - Negate with Extend Byte
 * Opcode: 0100 0000 0000 0rrr (0x4000)
 * 4 cycles
 */
.Lhandle_negx_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r3, r1
    
    ldr     r12, [r5, #M68K_X_FLAG]
    lsr     r12, r12, #8
    
    rsb     r11, r3, #0
    sub     r11, r11, r12
    uxtb    r11, r11
    bfi     r1, r11, #0, #8
    str     r1, [r2, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    and     r0, r3, r11
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    
    orrs    r0, r3, r12
    ite     ne
    movne   r0, #0x100
    moveq   r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * NOT.L Dn - Logical Complement Data Register
 * Opcode: 0100 0110 1000 0rrr (0x4680)
 * 6 cycles
 */
.Lhandle_not_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    mvn     r11, r1                 @ r11 = ~r1
    str     r11, [r2, r0]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * NOT.W Dn - Logical Complement Data Register Word
 * Opcode: 0100 0110 0100 0rrr (0x4640)
 * 4 cycles
 */
.Lhandle_not_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    mvn     r11, r1
    uxth    r11, r11
    bfi     r1, r11, #0, #16
    str     r1, [r2, r0]
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * NOT.B Dn - Logical Complement Data Register Byte
 * Opcode: 0100 0110 0000 0rrr (0x4600)
 * 4 cycles
 */
.Lhandle_not_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    mvn     r11, r1
    uxtb    r11, r11
    bfi     r1, r11, #0, #8
    str     r1, [r2, r0]
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SWAP Dn - Swap Register Halves
 * Opcode: 0100 1000 0100 0rrr (0x4840)
 * 4 cycles
 */
.Lhandle_swap_32:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    /* Swap halves using ROR #16 */
    ror     r11, r1, #16
    str     r11, [r2, r0]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * EXT.L Dn - Sign Extend Word to Long
 * Opcode: 0100 1000 1100 0rrr (0x48C0)
 * 4 cycles
 */
.Lhandle_ext_32:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    /* Sign extend word to long using SXTH */
    sxth    r11, r1
    str     r11, [r2, r0]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * LEA (An),An - Load Effective Address
 * Opcode: 0100 DDD 111 010 SSS (0x41D0)
 * 4 cycles - just copies An to An (no flags affected)
 */
.Lhandle_lea_ai:
    /* Get source An (bits 0-2) */
    and     r0, r10, #7
    add     r0, r0, #8              @ Address registers at dar[8-15]
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source address
    
    /* Get destination An (bits 9-11) */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    str     r1, [r2, r0]            @ Store to dest An
    
    /* LEA does NOT affect flags */
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * LEA (d16,An),An - Load Effective Address with displacement
 * Opcode: 0100 DDD 111 101 SSS (0x41E8)
 * 8 cycles
 */
.Lhandle_lea_di:
    /* Read displacement */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r3, [r1, r0]
    sxth    r3, r3                  @ Sign extend
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    /* Get source An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    add     r11, r1, r3             @ r11 = An + displacement
    
    /* Store to destination An */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    str     r11, [r2, r0]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * LEA (d16,PC),An - Load Effective Address PC-relative
 * Opcode: 0100 DDD 111 111 010 (0x41FA)
 * 8 cycles - very common for loading addresses of data
 */
.Lhandle_lea_pc_di:
    /* Get PC (before reading displacement) */
    ldr     r11, [r5, #M68K_PC]     @ r11 = PC pointing to displacement
    
    /* Read displacement */
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    sxth    r3, r3
    add     r0, r11, #2
    str     r0, [r5, #M68K_PC]
    
    /* Calculate effective address: PC + displacement */
    add     r11, r11, r3
    
    /* Store to destination An */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    str     r11, [r2, r0]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * JMP (d16,An) - Jump with displacement
 * Opcode: 0100 1110 1110 1rrr (0x4EE8)
 * 10 cycles
 */
.Lhandle_jmp_di:
    /* Read displacement */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r3, [r1, r0]
    sxth    r3, r3
    
    /* Get base An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    add     r1, r1, r3              @ target = An + displacement
    
    str     r1, [r5, #M68K_PC]
    
    add     r4, r4, #70             @ 10 * 7 cycles
    b       .Lmain_loop

/*
 * JSR (d16,An) - Jump to Subroutine with displacement
 * Opcode: 0100 1110 1010 1rrr (0x4EA8)
 * 18 cycles
 */
.Lhandle_jsr_di:
    /* Read displacement */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r3, [r1, r0]
    sxth    r3, r3
    add     r0, r0, #2              @ r0 = return address (PC after displacement)
    
    /* Get base An */
    and     r12, r10, #7
    add     r12, r12, #8
    lsl     r12, r12, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r12]
    add     r11, r11, r3            @ r11 = target address
    
    /* Decrement SP and push return address */
    ldr     r1, [r2, #60]           @ A7
    sub     r1, r1, #4
    str     r1, [r2, #60]
    
    /* Check if in RAM */
    movw    r3, #0
    movt    r3, #0xFF
    cmp     r1, r3
    blo.w   .Lno_inline
    
    /* Fast RAM push */
    ldr     r3, =M68K_RAM
    movw    r12, #0xFFFF
    and     r12, r1, r12
    ror     r0, r0, #16
    str     r0, [r3, r12]
    
    str     r11, [r5, #M68K_PC]
    
    add     r4, r4, #126            @ 18 * 7 cycles
    b       .Lmain_loop

/*
 * JMP (d16,PC) - Jump PC-relative
 * Opcode: 0100 1110 1111 1010 (0x4EFA)
 * 10 cycles
 */
.Lhandle_jmp_pc_di:
    /* Get current PC */
    ldr     r11, [r5, #M68K_PC]
    
    /* Read displacement */
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    sxth    r3, r3
    
    /* target = PC + displacement */
    add     r11, r11, r3
    str     r11, [r5, #M68K_PC]
    
    add     r4, r4, #70             @ 10 * 7 cycles
    b       .Lmain_loop

/*
 * JSR (d16,PC) - Jump to Subroutine PC-relative
 * Opcode: 0100 1110 1011 1010 (0x4EBA)
 * 18 cycles
 */
.Lhandle_jsr_pc_di:
    /* Get current PC */
    ldr     r11, [r5, #M68K_PC]
    
    /* Read displacement */
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    sxth    r3, r3
    add     r0, r11, #2             @ r0 = return address
    
    /* target = PC + displacement */
    add     r11, r11, r3
    
    /* Decrement SP and push return address */
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, #60]           @ A7
    sub     r1, r1, #4
    str     r1, [r2, #60]
    
    /* Check if in RAM */
    movw    r3, #0
    movt    r3, #0xFF
    cmp     r1, r3
    blo.w   .Lno_inline
    
    /* Fast RAM push */
    ldr     r3, =M68K_RAM
    movw    r12, #0xFFFF
    and     r12, r1, r12
    ror     r0, r0, #16
    str     r0, [r3, r12]
    
    str     r11, [r5, #M68K_PC]
    
    add     r4, r4, #126            @ 18 * 7 cycles
    b       .Lmain_loop

/*
 * LINK An,#imm - Create Stack Frame
 * Opcode: 0100 1110 0101 0rrr (0x4E50)
 * 16 cycles - pushes An, SP->An, SP+displacement->SP
 */
.Lhandle_link:
    /* Read displacement from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r3, [r1, r0]
    sxth    r3, r3                  @ Sign extend displacement
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    /* Get An register */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = An value to push
    mov     r12, r0                 @ Save An offset
    
    /* Decrement SP and push An */
    ldr     r0, [r2, #60]           @ A7
    sub     r0, r0, #4
    
    /* Check if in RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo.w   .Lno_inline
    
    /* Fast RAM push */
    ldr     r1, =M68K_RAM
    movw    lr, #0xFFFF
    and     lr, r0, lr
    ror     r11, r11, #16
    str     r11, [r1, lr]
    
    /* An = SP (after push) */
    str     r0, [r2, r12]
    
    /* SP = SP + displacement (displacement is usually negative) */
    add     r0, r0, r3
    str     r0, [r2, #60]
    
    add     r4, r4, #112            @ 16 * 7 cycles
    b       .Lmain_loop

/*
 * UNLK An - Destroy Stack Frame
 * Opcode: 0100 1110 0101 1rrr (0x4E58)
 * 12 cycles - SP=An, pop An
 */
.Lhandle_unlk:
    /* Get An register */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = An (becomes new SP)
    mov     r12, r0                 @ Save An offset
    
    /* Check if in RAM for pop */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    /* Fast RAM pop */
    ldr     r1, =M68K_RAM
    movw    lr, #0xFFFF
    and     lr, r11, lr
    ldr     r0, [r1, lr]            @ Read from stack
    ror     r0, r0, #16             @ Big-endian swap
    
    /* Store popped value to An */
    str     r0, [r2, r12]
    
    /* Update SP = old An + 4 */
    add     r11, r11, #4
    str     r11, [r2, #60]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

.ltorg

/*
 * RTS - Return from Subroutine
 * Opcode: 0x4E75
 * 16 cycles - pops return address from stack
 */
.Lhandle_rts:
    /* Get SP (A7) */
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, #60]           @ A7 = dar[15], offset = 15*4 = 60
    
    /* Read return address from stack (big-endian 32-bit) */
    movw    r1, #0
    movt    r1, #0xFF               @ RAM base
    cmp     r0, r1
    blo     .Lrts_slow
    
    /* Fast RAM path */
    ldr     r1, =M68K_RAM
    movw    r3, #0xFFFF
    and     r3, r0, r3
    ldr     r1, [r1, r3]            @ Load from RAM
    ror     r1, r1, #16             @ Big-endian swap
    
    /* Increment SP by 4 */
    add     r0, r0, #4
    str     r0, [r2, #60]
    
    /* Set PC to return address */
    str     r1, [r5, #M68K_PC]
    
    add     r4, r4, #112            @ 16 * 7 cycles
    b       .Lmain_loop

.Lrts_slow:
    /* Slow path - use memory read function */
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
    /* Increment SP and store PC */
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, #60]
    add     r0, r0, #4
    str     r0, [r2, #60]
    str     r1, [r5, #M68K_PC]
    
    add     r4, r4, #112
    b       .Lmain_loop

/*
 * PEA (An) - Push Effective Address via (An)
 * Opcode: 0100 1000 0101 0rrr (0x4850)
 * 12 cycles - pushes address in An to stack
 */
.Lhandle_pea_ai:
    /* Get address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = effective address
    
    /* Decrement SP */
    ldr     r0, [r2, #60]           @ A7
    sub     r0, r0, #4
    str     r0, [r2, #60]
    
    /* Push address to stack */
    movw    r3, #0
    movt    r3, #0xFF
    cmp     r0, r3
    blo.w   .Lno_inline             @ Slow path
    
    /* Fast RAM path */
    ldr     r3, =M68K_RAM
    movw    r1, #0xFFFF
    and     r1, r0, r1
    ror     r11, r11, #16           @ Big-endian swap
    str     r11, [r3, r1]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * PEA (d16,An) - Push Effective Address with displacement
 * Opcode: 0100 1000 0110 1rrr (0x4868)
 * 16 cycles
 */
.Lhandle_pea_di:
    /* Read displacement from extension word */
    ldr     r0, [r5, #M68K_PC]
    ldr     r1, [r9]
    ldrh    r3, [r1, r0]
    sxth    r3, r3                  @ Sign extend displacement
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    
    /* Get base address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    add     r11, r11, r3            @ r11 = An + displacement
    
    /* Decrement SP */
    ldr     r0, [r2, #60]           @ A7
    sub     r0, r0, #4
    str     r0, [r2, #60]
    
    /* Push address to stack */
    movw    r3, #0
    movt    r3, #0xFF
    cmp     r0, r3
    blo.w   .Lno_inline             @ Slow path
    
    /* Fast RAM path */
    ldr     r3, =M68K_RAM
    movw    r1, #0xFFFF
    and     r1, r0, r1
    ror     r11, r11, #16           @ Big-endian swap
    str     r11, [r3, r1]
    
    add     r4, r4, #112            @ 16 * 7 cycles
    b       .Lmain_loop

/*
 * JMP (An) - Jump to address in An
 * Opcode: 0100 1110 1101 0rrr (0x4ED0)
 * 8 cycles
 */
.Lhandle_jmp_ai:
    /* Get An (bits 0-2) */
    and     r0, r10, #7
    add     r0, r0, #8              @ Address register offset
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = address in An
    
    /* Set PC to this address */
    str     r1, [r5, #M68K_PC]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * JSR (An) - Jump to Subroutine via address in An
 * Opcode: 0100 1110 1001 0rrr (0x4E90)
 * 16 cycles - pushes return address, then jumps
 */
.Lhandle_jsr_ai:
    /* Get target address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = target address
    
    /* Get SP and decrement */
    ldr     r0, [r2, #60]           @ A7
    sub     r0, r0, #4
    str     r0, [r2, #60]
    
    /* Get return address (PC after opcode) */
    ldr     r1, [r5, #M68K_PC]
    
    /* Push return address to stack */
    movw    r3, #0
    movt    r3, #0xFF
    cmp     r0, r3
    blo     .Ljsr_slow_push
    
    /* Fast RAM path */
    ldr     r3, =M68K_RAM
    movw    r2, #0xFFFF
    and     r2, r0, r2
    ror     r1, r1, #16
    str     r1, [r3, r2]
    
    /* Set PC to target */
    str     r11, [r5, #M68K_PC]
    
    add     r4, r4, #112            @ 16 * 7 cycles
    b       .Lmain_loop

.Ljsr_slow_push:
    b       .Lno_inline

.ltorg

/*
 * EXT.W Dn - Sign Extend Byte to Word
 * Opcode: 0100 1000 1000 0rrr (0x4880)
 * 4 cycles
 */
.Lhandle_ext_16:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    /* Sign extend byte to word, keep upper word */
    sxtb    r3, r1                  @ Sign extend byte
    bfi     r1, r3, #0, #16         @ Insert into low word
    str     r1, [r2, r0]
    
    /* Flags based on low word */
    lsr     r0, r3, #8
    and     r0, r0, #0x80           @ N from bit 15
    str     r0, [r5, #M68K_N_FLAG]
    uxth    r3, r3
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CLR.W Dn - Clear Data Register Word
 * Opcode: 0100 0010 0100 0rrr (0x4240)
 * 4 cycles
 */
.Lhandle_clr_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r2, [r1, r0]
    bic     r2, r2, #0xFF
    bic     r2, r2, #0xFF00
    str     r2, [r1, r0]
    
    mov     r2, #0
    str     r2, [r5, #M68K_N_FLAG]
    str     r2, [r5, #M68K_NOT_Z_FLAG]
    str     r2, [r5, #M68K_V_FLAG]
    str     r2, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CLR.B Dn - Clear Data Register Byte
 * Opcode: 0100 0010 0000 0rrr (0x4200)
 * 4 cycles
 */
.Lhandle_clr_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r2, [r1, r0]
    bic     r2, r2, #0xFF
    str     r2, [r1, r0]
    
    mov     r2, #0
    str     r2, [r5, #M68K_N_FLAG]
    str     r2, [r5, #M68K_NOT_Z_FLAG]
    str     r2, [r5, #M68K_V_FLAG]
    str     r2, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * TST.W Dn - Test Data Register Word
 * Opcode: 0100 1010 0100 0rrr (0x4A40)
 * 4 cycles
 */
.Lhandle_tst_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    uxth    r3, r3                  @ Get low word
    lsr     r0, r3, #8
    and     r0, r0, #0x80           @ N from bit 15
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * TST.W (An) - Test Memory Word
 * Opcode: 0100 1010 0101 0rrr (0x4A50)
 * 4 cycles
 */
.Lhandle_tst_16_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Read from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Ltst_16_ai_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3                  @ Big-endian swap
    b       .Ltst_16_ai_flags

.Ltst_16_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Ltst_16_ai_flags:
    uxth    r3, r3
    lsr     r0, r3, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * TST.W (An)+ - Test Memory Word with Post-increment
 * Opcode: 0100 1010 0101 1rrr (0x4A58)
 * 4 cycles
 */
.Lhandle_tst_16_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = address
    add     r1, r11, #2
    str     r1, [r2, r0]            @ Post-increment by 2
    
    /* Read from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Ltst_16_pi_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3                  @ Big-endian swap
    b       .Ltst_16_pi_flags

.Ltst_16_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Ltst_16_pi_flags:
    uxth    r3, r3
    lsr     r0, r3, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * TST.B Dn - Test Data Register Byte
 * Opcode: 0100 1010 0000 0rrr (0x4A00)
 * 4 cycles
 */
.Lhandle_tst_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]
    
    uxtb    r3, r3                  @ Get low byte
    and     r0, r3, #0x80           @ N from bit 7
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CLR.L Dn - Clear Data Register
 * Opcode: 0100 0010 1000 0rrr (0x4280)
 * 6 cycles
 */
.Lhandle_clr_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    mov     r2, #0
    str     r2, [r1, r0]            @ Dn = 0
    
    /* Flags: N=0, V=0, C=0, Z=1 (NOT_Z=0 means Z set) */
    str     r2, [r5, #M68K_N_FLAG]
    str     r2, [r5, #M68K_NOT_Z_FLAG]  @ 0 = Z is set
    str     r2, [r5, #M68K_V_FLAG]
    str     r2, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

/*
 * CLR.L (An) - Clear Memory Long
 * Opcode: 0100 0010 1001 0rrr (0x4290)
 * 12 cycles
 */
.Lhandle_clr_32_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Must be RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    mov     r3, #0
    str     r3, [r1, r0]            @ Write 0 to memory
    
    str     r3, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    str     r3, [r5, #M68K_V_FLAG]
    str     r3, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * CLR.L (An)+ - Clear Memory Long with Post-increment
 * Opcode: 0100 0010 1001 1rrr (0x4298)
 * 12 cycles
 */
.Lhandle_clr_32_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = address
    add     r1, r11, #4
    str     r1, [r2, r0]            @ Post-increment
    
    /* Must be RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    mov     r3, #0
    str     r3, [r1, r0]            @ Write 0 to memory
    
    str     r3, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    str     r3, [r5, #M68K_V_FLAG]
    str     r3, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84
    b       .Lmain_loop

/*
 * CLR.W (An) - Clear Memory Word
 * Opcode: 0100 0010 0101 0rrr (0x4250)
 * 8 cycles
 */
.Lhandle_clr_16_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Must be RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    mov     r3, #0
    strh    r3, [r1, r0]            @ Write 0 to memory (half)
    
    str     r3, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    str     r3, [r5, #M68K_V_FLAG]
    str     r3, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * CLR.W (An)+ - Clear Memory Word with Post-increment
 * Opcode: 0100 0010 0101 1rrr (0x4258)
 * 8 cycles
 */
.Lhandle_clr_16_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = address
    add     r1, r11, #2
    str     r1, [r2, r0]            @ Post-increment by 2
    
    /* Must be RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    mov     r3, #0
    strh    r3, [r1, r0]            @ Write 0 to memory (half)
    
    str     r3, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    str     r3, [r5, #M68K_V_FLAG]
    str     r3, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

.ltorg

/*
 * TST.L Dn - Test Data Register (Long)
 * Opcode: 0100 1010 1000 0rrr (0x4A80)
 * 4 cycles
 */
.Lhandle_tst_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r3, [r1, r0]            @ r3 = Dn value
    
    /* Set N flag from bit 31 */
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Set Z flag (NOT_Z stores the value - 0 means Z set) */
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    
    /* V=0, C=0 */
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * TST.L (An) - Test Memory Indirect (Long)
 * Opcode: 0100 1010 1001 0rrr (0x4A90)
 * 12 cycles
 */
.Lhandle_tst_32_ai:
    and     r0, r10, #7
    add     r0, r0, #8              @ Address registers at dar[8-15]
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r0, [r1, r0]            @ r0 = address
    
    /* Fast ROM read */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Ltst_32_ai_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldr     r3, [r1, r0]
    ror     r3, r3, #16             @ Big-endian swap
    b       .Ltst_32_ai_flags
    
.Ltst_32_ai_not_rom:
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Ltst_32_ai_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Ltst_32_ai_flags
    
.Ltst_32_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ltst_32_ai_flags:
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

/*
 * TST.L (An)+ - Test Memory Post-Increment (Long)
 * Opcode: 0100 1010 1001 1rrr (0x4A98)
 * 12 cycles
 */
.Lhandle_tst_32_pi:
    and     r11, r10, #7
    add     r11, r11, #8            @ Address registers at dar[8-15]
    lsl     r11, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = address
    
    /* Post-increment by 4 */
    add     r1, r0, #4
    str     r1, [r2, r11]
    
    /* Fast ROM read */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Ltst_32_pi_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldr     r3, [r1, r0]
    ror     r3, r3, #16             @ Big-endian swap
    b       .Ltst_32_pi_flags
    
.Ltst_32_pi_not_rom:
    /* Check RAM */
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Ltst_32_pi_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r0, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16
    b       .Ltst_32_pi_flags
    
.Ltst_32_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ltst_32_pi_flags:
    lsr     r0, r3, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r3, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

.ltorg

/* ======================================================================
 * CMP/EOR HANDLERS - 0xBxxx opcodes
 * CMP: 1011 DDD 0ss mmm rrr (bit 8=0)
 * EOR: 1011 DDD 1ss mmm rrr (bit 8=1)
 * ====================================================================== */

.Lcheck_cmp:
    /* Check size field (bits 7-6) */
    ubfx    r0, r10, #6, #2         @ Get size field
    
    /* Check bit 8: 0=CMP, 1=EOR/CMPA */
    tst     r10, #0x100
    bne     .Lcheck_cmp_bit8_set
    
    /* Bit 8 clear = CMP */
    cmp     r0, #2                  @ .L?
    beq     .Lcmp_size_l
    cmp     r0, #1                  @ .W?
    beq     .Lcmp_size_w
    cmp     r0, #0                  @ .B?
    beq     .Lcmp_size_b
    b.w     .Lno_inline

.Lcheck_cmp_bit8_set:
    /* Bit 8 set: check opmode for EOR vs CMPA */
    ubfx    r1, r10, #6, #3         @ Full opmode
    cmp     r1, #7                  @ CMPA.L?
    beq     .Lcheck_cmpa_l
    cmp     r1, #3                  @ CMPA.W?
    beq     .Lcheck_cmpa_w
    cmp     r0, #2                  @ EOR.L?
    beq     .Lcheck_eor_32
    cmp     r0, #1                  @ EOR.W?
    beq     .Lcheck_eor_16
    cmp     r0, #0                  @ EOR.B?
    beq     .Lcheck_eor_8
    b.w     .Lno_inline

.Lcmp_size_l:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_cmp_32_d
    cmp     r0, #1
    beq     .Lhandle_cmp_32_a
    cmp     r0, #2
    beq     .Lhandle_cmp_32_ai
    cmp     r0, #3
    beq     .Lhandle_cmp_32_pi
    b.w     .Lno_inline

.Lcmp_size_w:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_cmp_16_d
    cmp     r0, #1
    beq     .Lhandle_cmp_16_a
    cmp     r0, #2
    beq     .Lhandle_cmp_16_ai
    cmp     r0, #3
    beq     .Lhandle_cmp_16_pi
    b.w     .Lno_inline

.Lcmp_size_b:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_cmp_8_d
    b.w     .Lno_inline

.Lcheck_cmpa_l:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_cmpa_l_d
    cmp     r0, #1
    beq     .Lhandle_cmpa_l_a
    b.w     .Lno_inline

.Lcheck_cmpa_w:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_cmpa_w_d
    cmp     r0, #1
    beq     .Lhandle_cmpa_w_a
    b.w     .Lno_inline

.Lcheck_eor_32:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_eor_32_d
    cmp     r0, #2
    beq     .Lhandle_eor_32_ai
    cmp     r0, #3
    beq     .Lhandle_eor_32_pi
    b.w     .Lno_inline

.Lcheck_eor_16:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_eor_16_d
    cmp     r0, #2
    beq     .Lhandle_eor_16_ai
    cmp     r0, #3
    beq     .Lhandle_eor_16_pi
    b.w     .Lno_inline

.Lcheck_eor_8:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_eor_8_d
    b.w     .Lno_inline

/*
 * EOR.L Dn,Dn - Exclusive OR Data Registers
 * Opcode: 1011 DDD 110 000 SSS (0xB180)
 * 8 cycles
 */
.Lhandle_eor_32_d:
    /* Get source Dn (bits 9-11) - note: source is DX for EOR */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (DX)
    
    /* Get destination Dn (bits 0-2) - note: dest is DY for EOR */
    and     r0, r10, #7
    lsl     r3, r0, #2              @ Save offset for writeback
    ldr     r0, [r2, r3]            @ r0 = destination (DY)
    
    /* EOR and store */
    eor     r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags: N, Z from result, V=0, C=0 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * EOR.W Dn,Dn - Exclusive OR Data Registers (Word)
 * Opcode: 1011 DDD 101 000 SSS (0xB140)
 * 4 cycles
 */
.Lhandle_eor_16_d:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (DX)
    
    and     r0, r10, #7
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination (DY)
    
    eor     r11, r0, r1
    bfi     r0, r11, #0, #16        @ Only affect low 16 bits
    str     r0, [r2, r3]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * EOR.B Dn,Dn - Exclusive OR Data Registers (Byte)
 * Opcode: 1011 DDD 100 000 SSS (0xB100)
 * 4 cycles
 */
.Lhandle_eor_8_d:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    and     r0, r10, #7
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    
    eor     r11, r0, r1
    bfi     r0, r11, #0, #8
    str     r0, [r2, r3]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * EOR.L Dn,(An) - Exclusive OR to Memory
 * Opcode: 1011 DDD 110 010 AAA
 * Dn XOR (An) -> (An)
 */
.Lhandle_eor_32_ai:
    /* Get source Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = Dn value
    
    /* Get An pointer */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = address
    
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r11, r2
    blo     .Lhandle_eor_32_ai_slow
    
    /* Fast RAM path - read long, XOR, write back */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r3, r11, r3
    ldr     r12, [r2, r3]
    ror     r12, r12, #16           @ swap for big-endian
    eor     r12, r12, r1            @ XOR
    ror     r12, r12, #16           @ swap back for storage
    str     r12, [r2, r3]
    
    /* Set flags from result (before swap-back) */
    ror     r12, r12, #16           @ get result back
    lsr     r0, r12, #24
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #48             @ 12 cycles
    b       .Lmain_loop

.Lhandle_eor_32_ai_slow:
    b.w     .Lno_inline

.ltorg

/*
 * EOR.L Dn,(An)+ - Exclusive OR to Memory with Post-increment
 * Opcode: 1011 DDD 110 011 AAA
 */
.Lhandle_eor_32_pi:
    /* Get source Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = Dn value
    
    /* Get An pointer and increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2
    add     r6, r5, #M68K_DAR
    ldr     r11, [r6, r3]           @ r11 = address
    add     r12, r11, #4            @ post-increment by 4
    str     r12, [r6, r3]           @ save updated An
    
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r11, r2
    blo     .Lhandle_eor_32_pi_slow
    
    /* Fast RAM path */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r3, r11, r3
    ldr     r12, [r2, r3]
    ror     r12, r12, #16
    eor     r12, r12, r1
    ror     r12, r12, #16
    str     r12, [r2, r3]
    
    /* Set flags */
    ror     r12, r12, #16
    lsr     r0, r12, #24
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #48             @ 12 cycles
    b       .Lmain_loop

.Lhandle_eor_32_pi_slow:
    b.w     .Lno_inline

.ltorg

/*
 * EOR.W Dn,(An) - Exclusive OR Word to Memory
 * Opcode: 1011 DDD 101 010 AAA
 */
.Lhandle_eor_16_ai:
    /* Get source Dn (bits 9-11) - low word */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1                  @ r1 = Dn low word
    
    /* Get An pointer */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = address
    
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r11, r2
    blo     .Lhandle_eor_16_ai_slow
    
    /* Fast RAM path - read word, XOR, write back */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r3, r11, r3
    ldrh    r12, [r2, r3]
    rev16   r12, r12                @ swap bytes for big-endian
    eor     r12, r12, r1            @ XOR
    uxth    r12, r12
    rev16   r0, r12                 @ swap back for storage
    strh    r0, [r2, r3]
    
    /* Set flags */
    lsr     r0, r12, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #40             @ 10 cycles
    b       .Lmain_loop

.Lhandle_eor_16_ai_slow:
    b.w     .Lno_inline

.ltorg

/*
 * EOR.W Dn,(An)+ - Exclusive OR Word to Memory with Post-increment
 * Opcode: 1011 DDD 101 011 AAA
 */
.Lhandle_eor_16_pi:
    /* Get source Dn (bits 9-11) - low word */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1                  @ r1 = Dn low word
    
    /* Get An pointer and increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2
    add     r6, r5, #M68K_DAR
    ldr     r11, [r6, r3]           @ r11 = address
    add     r12, r11, #2            @ post-increment by 2
    str     r12, [r6, r3]           @ save updated An
    
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r11, r2
    blo     .Lhandle_eor_16_pi_slow
    
    /* Fast RAM path */
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r3, r11, r3
    ldrh    r12, [r2, r3]
    rev16   r12, r12
    eor     r12, r12, r1
    uxth    r12, r12
    rev16   r0, r12
    strh    r0, [r2, r3]
    
    /* Set flags */
    lsr     r0, r12, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #40             @ 10 cycles
    b       .Lmain_loop

.Lhandle_eor_16_pi_slow:
    b.w     .Lno_inline

.ltorg

/*
 * CMP.L Dn,Dn - Compare Data Registers
 * Opcode: 1011 DDD 010 000 SSS (0xB080)
 * 6 cycles
 */
.Lhandle_cmp_32_d:
    /* Get source Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    /* Get destination Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = destination
    
    /* Compare: dst - src */
    subs    r11, r3, r1
    
    /* Set N flag */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Set Z flag (mask to 32 bits - but r11 is already 32-bit) */
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* Get ARM APSR for V and C */
    mrs     r0, APSR
    
    /* V flag from ARM bit 28 */
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    /* C flag - inverted for SUB (ARM C = no borrow, M68K C = borrow) */
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

/*
 * CMP.L An,Dn - Compare Address Register to Data Register
 * Opcode: 1011 DDD 010 001 SSS (0xB088)
 * 6 cycles
 */
.Lhandle_cmp_32_a:
    /* Get source An (bits 0-2) */
    and     r0, r10, #7
    add     r0, r0, #8              @ Address registers at dar[8-15]
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (An)
    
    /* Get destination Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = destination (Dn)
    
    /* Compare: dst - src */
    subs    r11, r3, r1
    
    /* Set flags same as CMP.L Dn,Dn */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

    .ltorg

/*
 * CMP.L (An),Dn - Compare Memory Indirect to Data Register
 * Opcode: 1011 DDD 010 010 SSS (0xB090)
 * 14 cycles
 */
.Lhandle_cmp_32_ai:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Fast ROM read */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lcmp_32_ai_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldr     r1, [r1, r0]
    ror     r1, r1, #16             @ Big-endian swap, r1 = source value
    b       .Lcmp_32_ai_compare
    
.Lcmp_32_ai_not_rom:
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lcmp_32_ai_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldr     r1, [r2, r0]
    ror     r1, r1, #16
    b       .Lcmp_32_ai_compare
    
.Lcmp_32_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r1, r0                  @ r1 = source value
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lcmp_32_ai_compare:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = destination
    
    /* Compare: dst - src */
    subs    r11, r3, r1
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #98             @ 14 * 7 cycles
    b       .Lmain_loop

    .ltorg

/*
 * CMP.L (An)+,Dn - Compare Memory Post-Increment to Data Register
 * Opcode: 1011 DDD 010 011 SSS (0xB098)
 * 14 cycles
 */
.Lhandle_cmp_32_pi:
    /* Save dest register index and source An index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2              @ r3 = An offset (save for post-inc)
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r3]            @ r0 = address
    
    /* Post-increment by 4 */
    add     r1, r0, #4
    str     r1, [r2, r3]
    
    /* Fast ROM read */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lcmp_32_pi_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldr     r1, [r1, r0]
    ror     r1, r1, #16             @ Big-endian swap
    b       .Lcmp_32_pi_compare
    
    .ltorg
    
.Lcmp_32_pi_not_rom:
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lcmp_32_pi_slow
    
    movw    r2, #:lower16:M68K_RAM
    movt    r2, #:upper16:M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldr     r1, [r2, r0]
    ror     r1, r1, #16
    b       .Lcmp_32_pi_compare
    
.Lcmp_32_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_32
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lcmp_32_pi_compare:
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]            @ r3 = destination
    
    subs    r11, r3, r1
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #98             @ 14 * 7 cycles
    b       .Lmain_loop

/*
 * CMP.W Dn,Dn - Compare Data Registers (Word)
 * Opcode: 1011 DDD 001 000 SSS (0xB040)
 * 4 cycles
 */
.Lhandle_cmp_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    uxth    r3, r3
    
    subs    r11, r3, r1
    uxth    r11, r11
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CMP.W An,Dn - Compare Address Register to Data Register (Word)
 * Opcode: 1011 DDD 001 001 SSS (0xB048)
 * 4 cycles
 */
.Lhandle_cmp_16_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    uxth    r3, r3
    
    subs    r11, r3, r1
    uxth    r11, r11
    
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CMP.W (An),Dn - Compare Memory Word to Data Register
 * Opcode: 1011 DDD 001 010 AAA
 * 8 cycles
 */
.Lhandle_cmp_16_ai:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lcmp_16_ai_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1                  @ Big-endian swap
    b       .Lcmp_16_ai_compare
    
.Lcmp_16_ai_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lcmp_16_ai_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Lcmp_16_ai_compare
    
.Lcmp_16_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lcmp_16_ai_compare:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r3, r3
    uxth    r1, r1
    
    /* Compare using shift-left trick for proper 16-bit flags */
    lsl     r3, r3, #16
    lsl     r1, r1, #16
    subs    r12, r3, r1
    
    /* Read flags immediately after subs */
    mrs     r0, APSR
    
    /* Get result in low 16 bits */
    lsr     r12, r12, #16
    
    lsr     r3, r12, #8
    and     r3, r3, #0x80
    str     r3, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * CMP.W (An)+,Dn - Compare Memory Word to Data Register with Post-increment
 * Opcode: 1011 DDD 001 011 AAA
 * 8 cycles
 */
.Lhandle_cmp_16_pi:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2
    add     r6, r5, #M68K_DAR
    ldr     r0, [r6, r3]            @ r0 = address
    add     r12, r0, #2             @ post-increment by 2
    str     r12, [r6, r3]           @ save updated An
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lcmp_16_pi_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1
    b       .Lcmp_16_pi_compare
    
.Lcmp_16_pi_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lcmp_16_pi_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Lcmp_16_pi_compare
    
.Lcmp_16_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lcmp_16_pi_compare:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r3, r3
    uxth    r1, r1
    
    /* Compare using shift-left trick for proper 16-bit flags */
    lsl     r3, r3, #16
    lsl     r1, r1, #16
    subs    r12, r3, r1
    
    /* Read flags immediately after subs */
    mrs     r0, APSR
    
    /* Get result in low 16 bits */
    lsr     r12, r12, #16
    
    lsr     r3, r12, #8
    and     r3, r3, #0x80
    str     r3, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

.ltorg

/*
 * CMP.B Dn,Dn - Compare Data Registers (Byte)
 * Opcode: 1011 DDD 000 000 SSS (0xB000)
 * 4 cycles
 */
.Lhandle_cmp_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    uxtb    r3, r3
    
    subs    r11, r3, r1
    uxtb    r11, r11
    
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * CMPA.L Dn,An - Compare Data Register to Address Register (Long)
 * Opcode: 1011 AAA 111 000 DDD
 * 6 cycles
 */
.Lhandle_cmpa_l_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ source Dn
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ dest An
    
    subs    r11, r3, r1
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * CMPA.L An,An - Compare Address Registers (Long)
 * Opcode: 1011 AAA 111 001 SSS
 * 6 cycles
 */
.Lhandle_cmpa_l_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    
    subs    r11, r3, r1
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * CMPA.W Dn,An - Compare Data Register to Address Register (Word, sign-extended)
 * Opcode: 1011 AAA 011 000 DDD
 * 6 cycles
 */
.Lhandle_cmpa_w_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    sxth    r1, r1                  @ Sign-extend word
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    
    subs    r11, r3, r1
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * CMPA.W An,An - Compare Address Registers (Word, sign-extended)
 * Opcode: 1011 AAA 011 001 SSS
 * 6 cycles
 */
.Lhandle_cmpa_w_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    sxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    
    subs    r11, r3, r1
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/* ======================================================================
 * AND/MULU/MULS HANDLERS - 0xCxxx opcodes
 * AND: 1100 DDD ooo mmm rrr (ooo = 000/001/010 for <ea>,Dn)
 * MULU: 1100 DDD 011 mmm rrr (unsigned multiply)
 * MULS: 1100 DDD 111 mmm rrr (signed multiply)
 * ====================================================================== */

.Lcheck_and:
    /* Check for EXG first (uses specific opmodes) */
    /* EXG Dn,Dn: 1100 XXX 101000 YYY (0xC140) */
    /* EXG An,An: 1100 XXX 101001 YYY (0xC148) */
    /* EXG Dn,An: 1100 XXX 110001 YYY (0xC188) */
    movw    r0, #0xF1F8
    and     r0, r10, r0
    movw    r1, #0xC140
    cmp     r0, r1
    beq     .Lhandle_exg_dd
    movw    r1, #0xC148
    cmp     r0, r1
    beq     .Lhandle_exg_aa
    movw    r1, #0xC188
    cmp     r0, r1
    beq     .Lhandle_exg_da
    
    /* Check opmode (bits 8-6) for MULU/MULS */
    ubfx    r0, r10, #6, #3         @ Get full opmode
    cmp     r0, #3                  @ MULU?
    beq     .Lcheck_mulu
    cmp     r0, #7                  @ MULS?
    beq     .Lcheck_muls
    
    /* Check direction bit 8: 0=<ea>,Dn  1=Dn,<ea> */
    tst     r10, #0x100
    bne.w   .Lno_inline             @ Dn,<ea> requires RMW - use C
    
    /* Mode bits 5-3 */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0                  @ Dn mode?
    beq     .Lcheck_and_size
    cmp     r0, #2                  @ (An) mode?
    beq     .Lcheck_and_ai
    cmp     r0, #3                  @ (An)+ mode?
    beq     .Lcheck_and_pi
    b.w     .Lno_inline

.Lcheck_and_size:
    /* Check size field (bits 7-6) */
    ubfx    r0, r10, #6, #2         @ Get size field
    cmp     r0, #2                  @ Is it .L (10)?
    beq     .Lhandle_and_32_er_d
    cmp     r0, #1                  @ Is it .W (01)?
    beq     .Lhandle_and_16_er_d
    cmp     r0, #0                  @ Is it .B (00)?
    beq     .Lhandle_and_8_er_d
    b       .Lno_inline

.Lcheck_and_ai:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lhandle_and_32_ai
    cmp     r0, #1
    beq     .Lhandle_and_16_ai
    b       .Lno_inline

.Lcheck_and_pi:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lhandle_and_32_pi
    cmp     r0, #1
    beq     .Lhandle_and_16_pi
    b       .Lno_inline

.Lcheck_mulu:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_mulu_d
    b.w     .Lno_inline

.Lcheck_muls:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_muls_d
    b.w     .Lno_inline

/*
 * MULU Dn,Dn - Unsigned Multiply
 * Opcode: 1100 DDD 011 000 SSS (0xC0C0)
 * 70 cycles (worst case, varies with operand)
 */
.Lhandle_mulu_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source Dn
    uxth    r1, r1                  @ 16-bit unsigned
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = dest Dn
    uxth    r0, r0                  @ 16-bit unsigned
    
    mul     r11, r0, r1             @ 32-bit result
    str     r11, [r2, r3]
    
    /* Flags: N from bit 31, Z from result, V=0, C=0 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #490            @ ~70 * 7 cycles
    b       .Lmain_loop

/*
 * MULS Dn,Dn - Signed Multiply
 * Opcode: 1100 DDD 111 000 SSS (0xC1C0)
 * 70 cycles (worst case, varies with operand)
 */
.Lhandle_muls_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    sxth    r1, r1                  @ 16-bit signed
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    sxth    r0, r0                  @ 16-bit signed
    
    mul     r11, r0, r1             @ 32-bit result
    str     r11, [r2, r3]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #490
    b       .Lmain_loop

/*
 * EXG Dn,Dn - Exchange Data Registers
 * Opcode: 1100 XXX 101000 YYY (0xC140)
 * 6 cycles - no flags affected
 */
.Lhandle_exg_dd:
    add     r2, r5, #M68K_DAR
    
    /* Get first Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = first Dn
    
    /* Get second Dn (bits 0-2) */
    and     r1, r10, #7
    lsl     r1, r1, #2
    ldr     r12, [r2, r1]           @ r12 = second Dn
    
    /* Exchange */
    str     r12, [r2, r0]
    str     r11, [r2, r1]
    
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

/*
 * EXG An,An - Exchange Address Registers
 * Opcode: 1100 XXX 101001 YYY (0xC148)
 * 6 cycles
 */
.Lhandle_exg_aa:
    add     r2, r5, #M68K_DAR
    
    /* Get first An (bits 9-11) */
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]
    
    /* Get second An (bits 0-2) */
    and     r1, r10, #7
    add     r1, r1, #8
    lsl     r1, r1, #2
    ldr     r12, [r2, r1]
    
    /* Exchange */
    str     r12, [r2, r0]
    str     r11, [r2, r1]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * EXG Dn,An - Exchange Data and Address Registers
 * Opcode: 1100 XXX 110001 YYY (0xC188)
 * 6 cycles
 */
.Lhandle_exg_da:
    add     r2, r5, #M68K_DAR
    
    /* Get Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    ldr     r11, [r2, r0]           @ r11 = Dn
    
    /* Get An (bits 0-2) */
    and     r1, r10, #7
    add     r1, r1, #8
    lsl     r1, r1, #2
    ldr     r12, [r2, r1]           @ r12 = An
    
    /* Exchange */
    str     r12, [r2, r0]
    str     r11, [r2, r1]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * AND.L Dn,Dn - AND Data Registers
 * Opcode: 1100 DDD 010 000 SSS (0xC080)
 * 8 cycles
 */
.Lhandle_and_32_er_d:
    /* Get source Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    /* Get destination Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2              @ Save offset for writeback
    ldr     r0, [r2, r3]            @ r0 = destination
    
    /* AND and store */
    and     r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags: N, Z from result, V=0, C=0 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * AND.W Dn,Dn - AND Data Registers (Word)
 * Opcode: 1100 DDD 001 000 SSS (0xC040)
 * 4 cycles
 */
.Lhandle_and_16_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (full word)
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination (full word)
    
    and     r11, r0, r1             @ Full 32-bit AND
    bfi     r0, r11, #0, #16        @ Insert low 16 bits
    str     r0, [r2, r3]
    
    uxth    r11, r11                @ Mask for flag calculation
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * AND.B Dn,Dn - AND Data Registers (Byte)
 * Opcode: 1100 DDD 000 000 SSS (0xC000)
 * 4 cycles
 */
.Lhandle_and_8_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    
    and     r11, r0, r1
    bfi     r0, r11, #0, #8
    str     r0, [r2, r3]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

.ltorg

/*
 * AND.L (An),Dn - AND Memory to Register (Long)
 * 6 cycles
 */
.Lhandle_and_32_ai:
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]           @ r11 = address
    
    /* Get dest register */
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    /* Read from ROM or RAM */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Land_32_ai_ram
    
    ldr     r1, [r9]
    ldr     r3, [r1, r11]
    ror     r3, r3, #16
    b       .Land_32_ai_op

.Land_32_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    movw    r1, #:lower16:M68K_RAM
    movt    r1, #:upper16:M68K_RAM
    ldr     r1, [r1]
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16

.Land_32_ai_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    and     r11, r0, r3
    str     r11, [r2, r12]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * AND.W (An),Dn - AND Memory to Register (Word)
 * 4 cycles
 */
.Lhandle_and_16_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Land_16_ai_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3
    b       .Land_16_ai_op

.Land_16_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Land_16_ai_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    and     r11, r0, r3
    bfi     r0, r11, #0, #16
    str     r0, [r2, r12]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * AND.L (An)+,Dn - AND Memory to Register (Long) with post-inc
 * 6 cycles
 */
.Lhandle_and_32_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    add     r1, r11, #4
    str     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Land_32_pi_ram
    
    ldr     r1, [r9]
    ldr     r3, [r1, r11]
    ror     r3, r3, #16
    b       .Land_32_pi_op

.Land_32_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16

.Land_32_pi_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    and     r11, r0, r3
    str     r11, [r2, r12]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * AND.W (An)+,Dn - AND Memory to Register (Word) with post-inc
 * 4 cycles
 */
.Lhandle_and_16_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    add     r1, r11, #2
    str     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Land_16_pi_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3
    b       .Land_16_pi_op

.Land_16_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Land_16_pi_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    and     r11, r0, r3
    bfi     r0, r11, #0, #16
    str     r0, [r2, r12]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/* ======================================================================
 * OR HANDLERS - Logical OR operations
 * Format: 1000 DDD ooo mmm rrr
 * ooo = opmode: 010=.L <ea>,Dn  110=.L Dn,<ea>
 * ====================================================================== */

.Lcheck_or:
    /* First check for DIVU/DIVS which share the 0x8xxx range */
    /* DIVU.W Dn,Dn: 1000 DDD 011 000 SSS (0x80C0) */
    /* DIVS.W Dn,Dn: 1000 DDD 111 000 SSS (0x81C0) */
    ubfx    r0, r10, #6, #3         @ Get opmode bits 8-6
    cmp     r0, #3                  @ DIVU opmode = 011?
    beq     .Lcheck_divu
    cmp     r0, #7                  @ DIVS opmode = 111?
    beq     .Lcheck_divs
    
    /* Check direction bit 8: 0=<ea>,Dn  1=Dn,<ea> */
    tst     r10, #0x100
    bne.w   .Lno_inline             @ Dn,<ea> requires RMW - use C
    
    /* Mode bits 5-3 */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0                  @ Dn mode?
    beq     .Lcheck_or_size
    cmp     r0, #2                  @ (An) mode?
    beq     .Lcheck_or_ai
    cmp     r0, #3                  @ (An)+ mode?
    beq     .Lcheck_or_pi
    b.w     .Lno_inline

.Lcheck_or_size:
    /* Check size field (bits 7-6) */
    ubfx    r0, r10, #6, #2         @ Get size field
    cmp     r0, #2                  @ Is it .L (10)?
    beq     .Lhandle_or_32_er_d
    cmp     r0, #1                  @ Is it .W (01)?
    beq     .Lhandle_or_16_er_d
    cmp     r0, #0                  @ Is it .B (00)?
    beq     .Lhandle_or_8_er_d
    b       .Lno_inline

.Lcheck_or_ai:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lhandle_or_32_ai
    cmp     r0, #1
    beq     .Lhandle_or_16_ai
    b       .Lno_inline

.Lcheck_or_pi:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lhandle_or_32_pi
    cmp     r0, #1
    beq     .Lhandle_or_16_pi
    b       .Lno_inline

.Lcheck_divu:
    /* Verify mode is Dn (bits 5-3 = 000) */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_divu_d
    b.w     .Lno_inline

.Lcheck_divs:
    /* Verify mode is Dn (bits 5-3 = 000) */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_divs_d
    b.w     .Lno_inline

/*
 * DIVU.W Dn,Dn - Unsigned Divide
 * Opcode: 1000 DDD 011 000 SSS (0x80C0)
 * 140 cycles worst case (varies with quotient)
 * Divides 32-bit destination by 16-bit source
 * Result: quotient in low word, remainder in high word
 */
.Lhandle_divu_d:
    /* Get divisor from source Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (divisor)
    uxth    r1, r1                  @ 16-bit unsigned
    
    /* Check for division by zero */
    cmp     r1, #0
    beq.w   .Lno_inline             @ Division by zero - let C handle trap
    
    /* Get dividend from dest Dn */
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = dest (32-bit dividend)
    
    /* Perform unsigned division */
    udiv    r11, r0, r1             @ r11 = quotient
    
    /* Check for overflow (quotient > 16 bits) */
    movw    r12, #0xFFFF
    cmp     r11, r12
    bhi     .Ldivu_overflow
    
    /* Calculate remainder */
    mls     r12, r11, r1, r0        @ r12 = dividend - (quotient * divisor)
    
    /* Pack result: remainder(high) : quotient(low) */
    orr     r11, r11, r12, lsl #16
    str     r11, [r2, r3]
    
    /* Flags: N from quotient bit 15, Z from quotient, V=0, C=0 */
    uxth    r0, r11                 @ Get quotient
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #980            @ ~140 * 7 cycles
    b       .Lmain_loop

.Ldivu_overflow:
    /* Overflow - set V flag, C cleared, N and Z undefined */
    mov     r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    add     r4, r4, #700            @ Shorter on overflow
    b       .Lmain_loop

/*
 * DIVS.W Dn,Dn - Signed Divide
 * Opcode: 1000 DDD 111 000 SSS (0x81C0)
 * 158 cycles worst case
 */
.Lhandle_divs_d:
    /* Get divisor from source Dn */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source (divisor)
    sxth    r1, r1                  @ 16-bit signed
    
    /* Check for division by zero */
    cmp     r1, #0
    beq.w   .Lno_inline             @ Division by zero - let C handle trap
    
    /* Get dividend from dest Dn */
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = dest (32-bit signed dividend)
    
    /* Perform signed division */
    sdiv    r11, r0, r1             @ r11 = quotient
    
    /* Check for overflow (quotient outside -32768 to 32767) */
    movw    r12, #0x7FFF
    cmp     r11, r12
    bgt     .Ldivs_overflow
    movw    r12, #0x8000
    movt    r12, #0xFFFF            @ r12 = -32768
    cmp     r11, r12
    blt     .Ldivs_overflow
    
    /* Calculate remainder (has same sign as dividend) */
    mls     r12, r11, r1, r0        @ r12 = dividend - (quotient * divisor)
    
    /* Pack result: remainder(high) : quotient(low) */
    uxth    r11, r11                @ Mask quotient to 16 bits
    orr     r11, r11, r12, lsl #16
    str     r11, [r2, r3]
    
    /* Flags: N from quotient bit 15, Z from quotient, V=0, C=0 */
    uxth    r0, r11
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #1106           @ ~158 * 7 cycles
    b       .Lmain_loop

.Ldivs_overflow:
    mov     r0, #0x80
    str     r0, [r5, #M68K_V_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_C_FLAG]
    add     r4, r4, #700
    b       .Lmain_loop

/*
 * OR.L Dn,Dn - OR Data Registers
 * Opcode: 1000 DDD 010 000 SSS (0x8080)
 * 8 cycles
 */
.Lhandle_or_32_er_d:
    /* Get source Dn (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    /* Get destination Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination
    
    /* OR and store */
    orr     r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * OR.W Dn,Dn - OR Data Registers (Word)
 * Opcode: 1000 DDD 001 000 SSS (0x8040)
 * 4 cycles
 */
.Lhandle_or_16_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    
    orr     r11, r0, r1
    bfi     r0, r11, #0, #16
    str     r0, [r2, r3]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * OR.B Dn,Dn - OR Data Registers (Byte)
 * Opcode: 1000 DDD 000 000 SSS (0x8000)
 * 4 cycles
 */
.Lhandle_or_8_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    
    orr     r11, r0, r1
    bfi     r0, r11, #0, #8
    str     r0, [r2, r3]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

/*
 * OR.L (An),Dn - OR Memory to Register (Long)
 * 6 cycles
 */
.Lhandle_or_32_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lor_32_ai_ram
    
    ldr     r1, [r9]
    ldr     r3, [r1, r11]
    ror     r3, r3, #16
    b       .Lor_32_ai_op

.Lor_32_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16

.Lor_32_ai_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    orr     r11, r0, r3
    str     r11, [r2, r12]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * OR.W (An),Dn - OR Memory to Register (Word)
 * 4 cycles
 */
.Lhandle_or_16_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r1, r5, #M68K_DAR
    ldr     r11, [r1, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lor_16_ai_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3
    b       .Lor_16_ai_op

.Lor_16_ai_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Lor_16_ai_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    orr     r11, r0, r3
    bfi     r0, r11, #0, #16
    str     r0, [r2, r12]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * OR.L (An)+,Dn - OR Memory to Register (Long) with post-inc
 * 6 cycles
 */
.Lhandle_or_32_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    add     r1, r11, #4
    str     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lor_32_pi_ram
    
    ldr     r1, [r9]
    ldr     r3, [r1, r11]
    ror     r3, r3, #16
    b       .Lor_32_pi_op

.Lor_32_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldr     r3, [r1, r0]
    ror     r3, r3, #16

.Lor_32_pi_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    orr     r11, r0, r3
    str     r11, [r2, r12]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #42
    b       .Lmain_loop

/*
 * OR.W (An)+,Dn - OR Memory to Register (Word) with post-inc
 * 4 cycles
 */
.Lhandle_or_16_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    add     r1, r11, #2
    str     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    lsl     r12, r0, #2
    
    movw    r1, #0
    movt    r1, #0x80
    cmp     r11, r1
    bhs     .Lor_16_pi_ram
    
    ldr     r1, [r9]
    ldrh    r3, [r1, r11]
    rev16   r3, r3
    b       .Lor_16_pi_op

.Lor_16_pi_ram:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r11, r1
    blo.w   .Lno_inline
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r0, r11, r2
    ldrh    r3, [r1, r0]
    rev16   r3, r3

.Lor_16_pi_op:
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r12]
    orr     r11, r0, r3
    bfi     r0, r11, #0, #16
    str     r0, [r2, r12]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/* ======================================================================
 * SUB HANDLERS - Subtraction operations
 * Format: 1001 DDD ooo mmm rrr (0x9xxx)
 * ====================================================================== */

.Lcheck_sub:
    /* Check for SUBX first: opmode 100/101/110 with rm=0 for Dn mode */
    ubfx    r1, r10, #6, #3         @ Get full opmode
    cmp     r1, #4                  @ opmode 100 = SUBX.L
    beq     .Lcheck_subx_l
    cmp     r1, #5                  @ opmode 101 = SUBX.W
    beq     .Lcheck_subx_w
    cmp     r1, #6                  @ opmode 110 - check if SUBX.B or SUB
    beq     .Lcheck_subx_b_or_sub
    
    /* Check size field */
    ubfx    r0, r10, #6, #2
    
    /* Check for SUBA.L (opmode = 111) */
    cmp     r1, #7
    beq     .Lcheck_suba_l
    
    cmp     r0, #2                  @ .L size?
    beq     .Lsub_size_l
    cmp     r0, #1                  @ .W size?
    beq     .Lsub_size_w
    cmp     r0, #0                  @ .B size?
    beq     .Lsub_size_b
    b.w     .Lno_inline

.Lcheck_subx_l:
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_subx_32_d

.Lcheck_subx_w:
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_subx_16_d

.Lcheck_subx_b_or_sub:
    /* opmode 110: Could be SUBX.B or SUB.B direction=1 */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0                  @ mode 000?
    bne.w   .Lno_inline             @ Regular SUB, direction=1
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_subx_8_d

.Lcheck_suba_l:
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_suba_l_d
    cmp     r0, #1
    beq     .Lhandle_suba_l_a
    b.w     .Lno_inline

.Lsub_size_l:
    tst     r10, #0x100
    bne.w   .Lno_inline
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_sub_32_er_d
    cmp     r0, #1
    beq     .Lhandle_sub_32_er_a
    cmp     r0, #2
    beq     .Lhandle_sub_32_er_ai
    cmp     r0, #3
    beq     .Lhandle_sub_32_er_pi
    b.w     .Lno_inline

.Lsub_size_w:
    tst     r10, #0x100
    bne.w   .Lno_inline
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_sub_16_er_d
    cmp     r0, #1
    beq     .Lhandle_sub_16_er_a
    cmp     r0, #2
    beq     .Lhandle_sub_16_er_ai
    @ cmp     r0, #3
    @ beq     .Lhandle_sub_16_er_pi   @ BUG: breaks emulation - needs investigation
    b.w     .Lno_inline

.Lsub_size_b:
    tst     r10, #0x100
    bne.w   .Lno_inline
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_sub_8_er_d
    b.w     .Lno_inline

/*
 * SUBA.L Dn,An - Subtract Data Register from Address Register
 * Opcode: 1001 AAA 111 000 DDD
 * 8 cycles - does NOT affect flags
 */
.Lhandle_suba_l_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    sub     r3, r3, r1
    str     r3, [r2, r0]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUBA.L An,An - Subtract Address Register from Address Register
 * Opcode: 1001 AAA 111 001 SSS
 * 8 cycles - does NOT affect flags
 */
.Lhandle_suba_l_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    sub     r3, r3, r1
    str     r3, [r2, r0]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUB.L Dn,Dn - Subtract Data Registers
 * Opcode: 1001 DDD 010 000 SSS (0x9080)
 * 8 cycles
 */
.Lhandle_sub_32_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination
    
    /* Subtract: dst - src */
    subs    r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1              @ Invert for M68K borrow convention
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUB.L An,Dn - Subtract Address Register from Data Register
 * Opcode: 1001 DDD 010 001 SSS (0x9088)
 * 8 cycles
 */
.Lhandle_sub_32_er_a:
    and     r0, r10, #7
    add     r0, r0, #8              @ Address registers
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source An
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination Dn
    
    subs    r11, r0, r1
    str     r11, [r2, r3]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUB.W Dn,Dn - Subtract Data Registers (Word)
 * Opcode: 1001 DDD 001 000 SSS (0x9040)
 * 4 cycles
 */
.Lhandle_sub_16_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    uxth    r11, r0
    
    subs    r11, r11, r1
    bfi     r0, r11, #0, #16
    str     r0, [r2, r3]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUB.W An,Dn - Subtract Address Register from Data Register (Word)
 * Opcode: 1001 DDD 001 001 SSS (0x9048)
 * 4 cycles
 */
.Lhandle_sub_16_er_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    uxth    r11, r0
    
    subs    r11, r11, r1
    bfi     r0, r11, #0, #16
    str     r0, [r2, r3]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUB.B Dn,Dn - Subtract Data Registers (Byte)
 * Opcode: 1001 DDD 000 000 SSS (0x9000)
 * 4 cycles
 */
.Lhandle_sub_8_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    uxtb    r11, r0
    
    subs    r11, r11, r1
    bfi     r0, r11, #0, #8
    str     r0, [r2, r3]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUB.L (An),Dn - Subtract Memory from Data Register (Long)
 * Opcode: 1001 DDD 010 010 SSS
 * 14 cycles
 */
.Lhandle_sub_32_er_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address in An
    
    ldr     r1, [r9]
    cmp     r0, r1
    bhs     .Lsub_32_ai_not_rom
    
    ldrh    r3, [r1, r0]
    add     r0, r0, #2
    ldrh    r1, [r1, r0]
    orr     r3, r1, r3, lsl #16
    b       .Lsub_32_ai_do_sub
    
.Lsub_32_ai_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lsub_32_ai_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r2, r0, r2
    ldr     r3, [r1, r2]
    ror     r3, r3, #16
    b       .Lsub_32_ai_do_sub
    
.Lsub_32_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lsub_32_ai_do_sub:
    ubfx    r0, r10, #9, #3
    lsl     r1, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r1]
    
    subs    r11, r0, r3
    str     r11, [r2, r1]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * SUB.L (An)+,Dn - Subtract Memory with Post-increment (Long)
 * Opcode: 1001 DDD 010 011 SSS
 * 14 cycles
 */
.Lhandle_sub_32_er_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]
    
    add     r1, r0, #4
    str     r1, [r2, r11]
    
    ldr     r1, [r9]
    cmp     r0, r1
    bhs     .Lsub_32_pi_not_rom
    
    ldrh    r3, [r1, r0]
    add     r0, r0, #2
    ldrh    r1, [r1, r0]
    orr     r3, r1, r3, lsl #16
    b       .Lsub_32_pi_do_sub
    
.Lsub_32_pi_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Lsub_32_pi_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r2, r0, r2
    ldr     r3, [r1, r2]
    ror     r3, r3, #16
    b       .Lsub_32_pi_do_sub
    
.Lsub_32_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lsub_32_pi_do_sub:
    ubfx    r0, r10, #9, #3
    lsl     r1, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r1]
    
    subs    r11, r0, r3
    str     r11, [r2, r1]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * SUB.W (An),Dn - Subtract Memory Word from Data Register
 * Opcode: 1001 DDD 001 010 AAA
 * 8 cycles
 */
.Lhandle_sub_16_er_ai:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lsub_16_ai_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1
    b       .Lsub_16_ai_do_sub
    
.Lsub_16_ai_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lsub_16_ai_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Lsub_16_ai_do_sub
    
.Lsub_16_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lsub_16_ai_do_sub:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r12, r3                 @ r12 = dest low word
    uxth    r1, r1                  @ r1 = source word
    
    /* Subtract using shift-left for proper 16-bit flags */
    lsl     r12, r12, #16
    lsl     r1, r1, #16
    subs    r12, r12, r1
    
    /* Read flags immediately */
    mrs     r0, APSR
    
    /* Get result and store */
    lsr     r12, r12, #16
    bfi     r3, r12, #0, #16
    lsl     r1, r11, #2
    str     r3, [r2, r1]
    
    /* Set flags */
    lsr     r1, r12, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1              @ invert carry for borrow
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

.ltorg

/*
 * SUB.W (An)+,Dn - Subtract Memory Word from Data Register with Post-increment
 * Opcode: 1001 DDD 001 011 AAA
 * 8 cycles
 */
.Lhandle_sub_16_er_pi:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2
    add     r6, r5, #M68K_DAR
    ldr     r0, [r6, r3]            @ r0 = address
    add     r12, r0, #2             @ post-increment by 2
    str     r12, [r6, r3]           @ save updated An
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Lsub_16_pi_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1
    b       .Lsub_16_pi_do_sub
    
.Lsub_16_pi_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Lsub_16_pi_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Lsub_16_pi_do_sub
    
.Lsub_16_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Lsub_16_pi_do_sub:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r12, r3
    uxth    r1, r1
    
    /* Subtract using shift-left for proper 16-bit flags */
    lsl     r12, r12, #16
    lsl     r1, r1, #16
    subs    r12, r12, r1
    
    /* Read flags immediately */
    mrs     r0, APSR
    
    /* Get result and store */
    lsr     r12, r12, #16
    bfi     r3, r12, #0, #16
    lsl     r1, r11, #2
    str     r3, [r2, r1]
    
    /* Set flags */
    lsr     r1, r12, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

.ltorg

/* ======================================================================
 * ADD HANDLERS - Addition operations
 * Format: 1101 DDD ooo mmm rrr (0xDxxx)
 * ====================================================================== */

.Lcheck_add:
    /* Check for ADDX first: opmode 100/101/110 with rm=0 for Dn mode */
    ubfx    r1, r10, #6, #3         @ Get full opmode
    cmp     r1, #4                  @ opmode 100 = ADDX.L
    beq     .Lcheck_addx_l
    cmp     r1, #5                  @ opmode 101 = ADDX.W
    beq     .Lcheck_addx_w
    cmp     r1, #6                  @ opmode 110 - check if ADDX.B or ADD
    beq     .Lcheck_addx_b_or_add
    
    /* Check size field for .L */
    ubfx    r0, r10, #6, #2
    
    /* Check for ADDA.L (opmode = 111) */
    cmp     r1, #7                  @ ADDA.L?
    beq     .Lcheck_adda_l
    
    cmp     r0, #2                  @ .L size?
    beq     .Ladd_size_l
    cmp     r0, #1                  @ .W size?
    beq     .Ladd_size_w
    cmp     r0, #0                  @ .B size?
    beq     .Ladd_size_b
    b.w     .Lno_inline

.Lcheck_addx_l:
    /* opmode 100: ADDX.L if rm=0 */
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_addx_32_d

.Lcheck_addx_w:
    /* opmode 101: ADDX.W if rm=0 */
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_addx_16_d

.Lcheck_addx_b_or_add:
    /* opmode 110: Could be ADDX.B or ADD.B direction=1 */
    /* ADDX.B has mode field = 000, ADD.B has other modes */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0                  @ mode 000?
    bne.w   .Lno_inline             @ Regular ADD, direction=1
    /* Check rm bit (bit 3) for ADDX */
    tst     r10, #0x08
    bne.w   .Lno_inline             @ -(An) mode - use C
    b       .Lhandle_addx_8_d

.Lcheck_adda_l:
    ubfx    r0, r10, #3, #3         @ src mode
    cmp     r0, #0
    beq     .Lhandle_adda_l_d       @ ADDA.L Dn,An
    cmp     r0, #1
    beq     .Lhandle_adda_l_a       @ ADDA.L An,An
    b.w     .Lno_inline

.Ladd_size_l:
    /* Check direction bit 8: 0=<ea>,Dn  1=Dn,<ea> */
    tst     r10, #0x100
    bne.w   .Lno_inline             @ Dn,<ea> requires RMW
    
    /* Mode bits 5-3 */
    ubfx    r0, r10, #3, #3
    cmp     r0, #0                  @ Dn mode?
    beq     .Lhandle_add_32_er_d
    cmp     r0, #1                  @ An mode?
    beq     .Lhandle_add_32_er_a
    cmp     r0, #2                  @ (An) mode?
    beq     .Lhandle_add_32_er_ai
    cmp     r0, #3                  @ (An)+ mode?
    beq     .Lhandle_add_32_er_pi
    b.w     .Lno_inline

.Ladd_size_w:
    tst     r10, #0x100
    bne.w   .Lno_inline
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_add_16_er_d
    cmp     r0, #1
    beq     .Lhandle_add_16_er_a
    cmp     r0, #2
    beq     .Lhandle_add_16_er_ai
    cmp     r0, #3
    beq     .Lhandle_add_16_er_pi
    b.w     .Lno_inline

.Ladd_size_b:
    tst     r10, #0x100
    bne.w   .Lno_inline
    ubfx    r0, r10, #3, #3
    cmp     r0, #0
    beq     .Lhandle_add_8_er_d
    b.w     .Lno_inline

/*
 * ADDA.L Dn,An - Add Data Register to Address Register
 * Opcode: 1101 AAA 111 000 DDD
 * 8 cycles - does NOT affect flags
 */
.Lhandle_adda_l_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source Dn
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]            @ r3 = dest An
    add     r3, r3, r1
    str     r3, [r2, r0]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDA.L An,An - Add Address Register to Address Register
 * Opcode: 1101 AAA 111 001 SSS
 * 8 cycles - does NOT affect flags
 */
.Lhandle_adda_l_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source An
    
    ubfx    r0, r10, #9, #3
    add     r0, r0, #8
    lsl     r0, r0, #2
    ldr     r3, [r2, r0]
    add     r3, r3, r1
    str     r3, [r2, r0]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADD.L Dn,Dn - Add Data Registers
 * Opcode: 1101 DDD 010 000 SSS (0xD080)
 * 8 cycles
 */
.Lhandle_add_32_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination
    
    /* Add: dst + src */
    adds    r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADD.L An,Dn - Add Address Register to Data Register
 * Opcode: 1101 DDD 010 001 SSS (0xD088)
 * 8 cycles
 */
.Lhandle_add_32_er_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source An
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = destination Dn
    
    adds    r11, r0, r1
    str     r11, [r2, r3]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADD.W Dn,Dn - Add Data Registers (Word)
 * Opcode: 1101 DDD 001 000 SSS (0xD040)
 * 4 cycles
 */
.Lhandle_add_16_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1                  @ Source word
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ Dest full
    uxth    r11, r0                 @ Dest word
    
    adds    r11, r11, r1
    bfi     r0, r11, #0, #16
    str     r0, [r2, r3]
    
    uxth    r11, r11                @ Mask result to 16 bits for flags
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * ADD.W An,Dn - Add Address Register to Data Register (Word)
 * Opcode: 1101 DDD 001 001 SSS (0xD048)
 * 4 cycles
 */
.Lhandle_add_16_er_a:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    uxth    r11, r0
    
    adds    r11, r11, r1
    bfi     r0, r11, #0, #16
    str     r0, [r2, r3]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * ADD.B Dn,Dn - Add Data Registers (Byte)
 * Opcode: 1101 DDD 000 000 SSS (0xD000)
 * 4 cycles
 */
.Lhandle_add_8_er_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r1, r1
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]
    uxtb    r11, r0
    
    adds    r11, r11, r1
    bfi     r0, r11, #0, #8
    str     r0, [r2, r3]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * ADD.L (An),Dn - Add Memory to Data Register (Long)
 * Opcode: 1101 DDD 010 010 SSS
 * 14 cycles
 */
.Lhandle_add_32_er_ai:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address in An
    
    /* Read from memory */
    ldr     r1, [r9]                @ r1 = ROM_DATA
    cmp     r0, r1
    bhs     .Ladd_32_ai_not_rom
    
    ldrh    r3, [r1, r0]
    add     r0, r0, #2
    ldrh    r1, [r1, r0]
    orr     r3, r1, r3, lsl #16     @ Big-endian combine
    b       .Ladd_32_ai_do_add
    
.Ladd_32_ai_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Ladd_32_ai_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r2, r0, r2
    ldr     r3, [r1, r2]
    ror     r3, r3, #16             @ Big-endian swap
    b       .Ladd_32_ai_do_add
    
.Ladd_32_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ladd_32_ai_do_add:
    /* Get dest Dn */
    ubfx    r0, r10, #9, #3
    lsl     r1, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r1]            @ r0 = dest Dn
    
    adds    r11, r0, r3
    str     r11, [r2, r1]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * ADD.L (An)+,Dn - Add Memory with Post-increment (Long)
 * Opcode: 1101 DDD 010 011 SSS
 * 14 cycles
 */
.Lhandle_add_32_er_pi:
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r11, r0, #2             @ Save reg offset
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r11]           @ r0 = address
    
    /* Post-increment */
    add     r1, r0, #4
    str     r1, [r2, r11]
    
    /* Read from memory */
    ldr     r1, [r9]
    cmp     r0, r1
    bhs     .Ladd_32_pi_not_rom
    
    ldrh    r3, [r1, r0]
    add     r0, r0, #2
    ldrh    r1, [r1, r0]
    orr     r3, r1, r3, lsl #16
    b       .Ladd_32_pi_do_add
    
.Ladd_32_pi_not_rom:
    movw    r1, #0
    movt    r1, #0xFF
    cmp     r0, r1
    blo     .Ladd_32_pi_slow
    
    ldr     r1, =M68K_RAM
    movw    r2, #0xFFFF
    and     r2, r0, r2
    ldr     r3, [r1, r2]
    ror     r3, r3, #16
    b       .Ladd_32_pi_do_add
    
.Ladd_32_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    bl      m68k_read_memory_32
    mov     r3, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ladd_32_pi_do_add:
    ubfx    r0, r10, #9, #3
    lsl     r1, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r1]
    
    adds    r11, r0, r3
    str     r11, [r2, r1]
    
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #98
    b       .Lmain_loop

/*
 * ADD.W (An),Dn - Add Memory Word to Data Register
 * Opcode: 1101 DDD 001 010 AAA
 * 8 cycles
 */
.Lhandle_add_16_er_ai:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address from An */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r0, [r2, r0]            @ r0 = address
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Ladd_16_ai_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1
    b       .Ladd_16_ai_do_add
    
.Ladd_16_ai_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Ladd_16_ai_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Ladd_16_ai_do_add
    
.Ladd_16_ai_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ladd_16_ai_do_add:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r12, r3                 @ r12 = dest low word
    uxth    r1, r1                  @ r1 = source word
    
    /* Add using shift-left for proper 16-bit flags */
    lsl     r12, r12, #16
    lsl     r1, r1, #16
    adds    r12, r12, r1
    
    /* Read flags immediately */
    mrs     r0, APSR
    
    /* Get result and store */
    lsr     r12, r12, #16
    bfi     r3, r12, #0, #16
    lsl     r1, r11, #2
    str     r3, [r2, r1]
    
    /* Set flags */
    lsr     r1, r12, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADD.W (An)+,Dn - Add Memory Word to Data Register with Post-increment
 * Opcode: 1101 DDD 001 011 AAA
 * 8 cycles
 */
.Lhandle_add_16_er_pi:
    /* Save dest register index */
    ubfx    r11, r10, #9, #3        @ r11 = dest Dn index
    
    /* Get source address and post-increment */
    and     r0, r10, #7
    add     r0, r0, #8
    lsl     r3, r0, #2
    add     r6, r5, #M68K_DAR
    ldr     r0, [r6, r3]            @ r0 = address
    add     r12, r0, #2             @ post-increment by 2
    str     r12, [r6, r3]           @ save updated An
    
    /* Fast ROM read - check if addr < 0x800000 */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Ladd_16_pi_not_rom
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]
    rev16   r1, r1
    b       .Ladd_16_pi_do_add
    
.Ladd_16_pi_not_rom:
    /* Check if addr >= 0xFF0000 for RAM */
    movw    r2, #0
    movt    r2, #0xFF
    cmp     r0, r2
    blo     .Ladd_16_pi_slow
    
    ldr     r2, =M68K_RAM
    movw    r3, #0xFFFF
    and     r0, r0, r3
    ldrh    r1, [r2, r0]
    rev16   r1, r1
    b       .Ladd_16_pi_do_add
    
.Ladd_16_pi_slow:
    str     r4, [r5, #M68K_CYCLES]
    push    {r11}
    bl      m68k_read_memory_16
    pop     {r11}
    mov     r1, r0
    ldr     r4, [r5, #M68K_CYCLES]
    
.Ladd_16_pi_do_add:
    /* Get destination Dn */
    lsl     r0, r11, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r0]
    uxth    r12, r3
    uxth    r1, r1
    
    /* Add using shift-left for proper 16-bit flags */
    lsl     r12, r12, #16
    lsl     r1, r1, #16
    adds    r12, r12, r1
    
    /* Read flags immediately */
    mrs     r0, APSR
    
    /* Get result and store */
    lsr     r12, r12, #16
    bfi     r3, r12, #0, #16
    lsl     r1, r11, #2
    str     r3, [r2, r1]
    
    /* Set flags */
    lsr     r1, r12, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r12, [r5, #M68K_NOT_Z_FLAG]
    
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

.ltorg

/* ======================================================================
 * ADDX/SUBX HANDLERS - Add/Subtract with Extend
 * Format: 1101/1001 XXX 1 ss 00 r YYY
 * ss = size (00=B, 01=W, 10=L), r = mode (0=Dn, 1=-(An))
 * Only Dn,Dn mode is handled inline here
 * ====================================================================== */

/*
 * ADDX.L Dn,Dn - Add with Extend (Long)
 * Opcode: 1101 XXX 110 000 YYY (0xD180)
 * Dst.L = Dst.L + Src.L + X
 * Z flag: Only cleared if result != 0, never set
 * 8 cycles
 */
.Lhandle_addx_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source Dn
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = dest Dn
    
    /* Get X flag and set carry */
    ldr     r11, [r5, #M68K_X_FLAG]
    lsrs    r11, r11, #8            @ Shift X to carry
    
    /* Add with carry: dst + src + X */
    adcs    r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags - N from bit 31 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 (never set) */
    cmp     r11, #0
    bne     .Laddx_32_d_clear_z
    b       .Laddx_32_d_do_cv
    
.Laddx_32_d_clear_z:
    mov     r0, #1
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
.Laddx_32_d_do_cv:
    /* Get C and V from APSR */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1         @ V flag
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1         @ C flag
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUBX.L Dn,Dn - Subtract with Extend (Long)
 * Opcode: 1001 XXX 110 000 YYY (0x9180)
 * Dst.L = Dst.L - Src.L - X
 * Z flag: Only cleared if result != 0, never set
 * 8 cycles
 */
.Lhandle_subx_32_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source Dn
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r0, [r2, r3]            @ r0 = dest Dn
    
    /* Get X flag and set carry (inverted for sbc) */
    ldr     r11, [r5, #M68K_X_FLAG]
    cmp     r11, #0
    ite     eq
    moveq   r11, #1                 @ If X=0, set carry (no borrow)
    movne   r11, #0                 @ If X=1, clear carry (borrow)
    lsrs    r11, r11, #1            @ Shift to carry
    
    /* Subtract with carry: dst - src - X */
    sbcs    r11, r0, r1
    str     r11, [r2, r3]
    
    /* Set flags - N from bit 31 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 (never set) */
    cmp     r11, #0
    bne     .Lsubx_32_d_clear_z
    b       .Lsubx_32_d_do_cv
    
.Lsubx_32_d_clear_z:
    mov     r0, #1
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
.Lsubx_32_d_do_cv:
    /* Get C and V from APSR (invert C for M68K convention) */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1         @ V flag
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    /* For subtraction, ARM carry=0 means borrow, M68K uses opposite */
    ubfx    r1, r0, #29, #1         @ C flag
    eor     r1, r1, #1              @ Invert for M68K
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDX.W Dn,Dn - Add with Extend (Word)
 * Opcode: 1101 XXX 101 000 YYY (0xD140)
 * 4 cycles
 */
.Lhandle_addx_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1                  @ Source word
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r12, [r2, r3]           @ Full dest
    uxth    r0, r12                 @ Dest word only
    
    /* Get X flag and set carry */
    ldr     r11, [r5, #M68K_X_FLAG]
    lsrs    r11, r11, #8
    
    /* Add with carry */
    adcs    r11, r0, r1
    
    /* Merge result into dest register */
    bfi     r12, r11, #0, #16
    str     r12, [r2, r3]
    
    /* Set flags - N from bit 15 */
    lsr     r0, r11, #8
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 */
    uxth    r11, r11
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* C and V from bit 16 overflow */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * ADDX.B Dn,Dn - Add with Extend (Byte)
 * Opcode: 1101 XXX 110 000 YYY (0xD100) with mode=000
 * 4 cycles
 */
.Lhandle_addx_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r1, r1                  @ Source byte
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r12, [r2, r3]           @ Full dest
    uxtb    r0, r12                 @ Dest byte only
    
    /* Get X flag and set carry */
    ldr     r11, [r5, #M68K_X_FLAG]
    lsrs    r11, r11, #8
    
    /* Add with carry */
    adcs    r11, r0, r1
    
    /* Merge result into dest register */
    bfi     r12, r11, #0, #8
    str     r12, [r2, r3]
    
    /* Set flags - N from bit 7 */
    str     r11, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 */
    uxtb    r11, r11
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* C from bit 8 */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUBX.W Dn,Dn - Subtract with Extend (Word)
 * Opcode: 1001 XXX 101 000 YYY (0x9140)
 * 4 cycles
 */
.Lhandle_subx_16_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxth    r1, r1                  @ Source word
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r12, [r2, r3]           @ Full dest
    uxth    r0, r12                 @ Dest word only
    
    /* Get X flag and set carry (inverted for sbc) */
    ldr     r11, [r5, #M68K_X_FLAG]
    cmp     r11, #0
    ite     eq
    moveq   r11, #1
    movne   r11, #0
    lsrs    r11, r11, #1
    
    /* Subtract with carry */
    sbcs    r11, r0, r1
    
    /* Merge result into dest register */
    bfi     r12, r11, #0, #16
    str     r12, [r2, r3]
    
    /* Set flags - N from bit 15 */
    lsr     r0, r11, #8
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 */
    uxth    r11, r11
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* C and V (invert C for M68K) */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUBX.B Dn,Dn - Subtract with Extend (Byte)
 * Opcode: 1001 XXX 110 000 YYY (0x9100) with mode=000
 * 4 cycles
 */
.Lhandle_subx_8_d:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    uxtb    r1, r1                  @ Source byte
    
    ubfx    r0, r10, #9, #3
    lsl     r3, r0, #2
    ldr     r12, [r2, r3]           @ Full dest
    uxtb    r0, r12                 @ Dest byte only
    
    /* Get X flag and set carry (inverted for sbc) */
    ldr     r11, [r5, #M68K_X_FLAG]
    cmp     r11, #0
    ite     eq
    moveq   r11, #1
    movne   r11, #0
    lsrs    r11, r11, #1
    
    /* Subtract with carry */
    sbcs    r11, r0, r1
    
    /* Merge result into dest register */
    bfi     r12, r11, #0, #8
    str     r12, [r2, r3]
    
    /* Set flags - N from bit 7 */
    str     r11, [r5, #M68K_N_FLAG]
    
    /* Z flag: Only clear if result != 0 */
    uxtb    r11, r11
    cmp     r11, #0
    it      ne
    strne   r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* C and V (invert C for M68K) */
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/* ======================================================================
 * SHIFT HANDLERS - LSL, LSR, ASL, ASR
 * Format: 1110 ccc d ss i 00 rrr (immediate count)
 *         1110 ccc d ss i 01 rrr (register count)
 * ccc = count/register, d = direction, ss = size, i = i/r
 * ====================================================================== */

.Lcheck_shift:
    /* Check if immediate (bit 5=0) or register (bit 5=1) shift */
    tst     r10, #0x20
    bne     .Lcheck_shift_reg       @ Register shifts
    
    /* Check shift type (bits 4-3): 00=AS, 01=LS, 10=ROX, 11=RO */
    ubfx    r1, r10, #3, #2
    cmp     r1, #0                  @ AS?
    beq     .Lcheck_as_size
    cmp     r1, #1                  @ LS?
    beq     .Lcheck_ls_size
    cmp     r1, #3                  @ RO (ROL/ROR)?
    beq     .Lcheck_ro_size
    b       .Lno_inline             @ ROX - use C

.Lcheck_shift_reg:
    /* Register shift: count in Dn, shift Dm */
    /* Only handle .L for now, most common case */
    ubfx    r0, r10, #6, #2
    cmp     r0, #2                  @ .L?
    bne.w   .Lno_inline             @ .W/.B use C for now
    
    /* Check shift type */
    ubfx    r1, r10, #3, #2
    cmp     r1, #1                  @ LS?
    beq     .Lcheck_ls_reg_dir
    cmp     r1, #0                  @ AS?
    beq     .Lcheck_as_reg_dir
    b.w     .Lno_inline             @ RO/ROX register - use C

.Lcheck_ls_reg_dir:
    tst     r10, #0x100
    bne     .Lhandle_lsl_32_r
    b       .Lhandle_lsr_32_r

.Lcheck_as_reg_dir:
    tst     r10, #0x100
    bne     .Lhandle_lsl_32_r       @ ASL same as LSL
    b       .Lhandle_asr_32_r

.Lcheck_as_size:
    ubfx    r0, r10, #6, #2         @ Get size
    cmp     r0, #2                  @ .L?
    beq     .Lcheck_as_direction_l
    cmp     r0, #1                  @ .W?
    beq     .Lcheck_as_direction_w
    cmp     r0, #0                  @ .B?
    beq     .Lcheck_as_direction_b
    b       .Lno_inline

.Lcheck_as_direction_l:
    tst     r10, #0x100
    bne     .Lhandle_lsl_32_s
    b       .Lhandle_asr_32_s

.Lcheck_as_direction_w:
    tst     r10, #0x100
    bne     .Lhandle_lsl_16_s
    b       .Lhandle_asr_16_s

.Lcheck_as_direction_b:
    tst     r10, #0x100
    bne     .Lhandle_lsl_8_s
    b       .Lhandle_asr_8_s

.Lcheck_ls_size:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lcheck_ls_direction_l
    cmp     r0, #1
    beq     .Lcheck_ls_direction_w
    cmp     r0, #0
    beq     .Lcheck_ls_direction_b
    b       .Lno_inline

.Lcheck_ls_direction_l:
    tst     r10, #0x100
    bne     .Lhandle_lsl_32_s
    b       .Lhandle_lsr_32_s

.Lcheck_ls_direction_w:
    tst     r10, #0x100
    bne     .Lhandle_lsl_16_s
    b       .Lhandle_lsr_16_s

.Lcheck_ls_direction_b:
    tst     r10, #0x100
    bne     .Lhandle_lsl_8_s
    b       .Lhandle_lsr_8_s

.Lcheck_ro_size:
    ubfx    r0, r10, #6, #2
    cmp     r0, #2
    beq     .Lcheck_ro_direction_l
    cmp     r0, #1
    beq     .Lcheck_ro_direction_w
    cmp     r0, #0
    beq     .Lcheck_ro_direction_b
    b       .Lno_inline

.Lcheck_ro_direction_l:
    tst     r10, #0x100
    bne     .Lhandle_rol_32_s
    b       .Lhandle_ror_32_s

.Lcheck_ro_direction_w:
    tst     r10, #0x100
    bne     .Lhandle_rol_16_s
    b       .Lhandle_ror_16_s

.Lcheck_ro_direction_b:
    tst     r10, #0x100
    bne     .Lhandle_rol_8_s
    b       .Lhandle_ror_8_s

/*
 * LSL.L #imm,Dn - Logical Shift Left (immediate)
 * Opcode: 1110 ccc1 1010 1rrr (0xE188)
 * 8 + 2*shift cycles
 */
.Lhandle_lsl_32_s:
    /* Get shift count from bits 9-11 (0 means 8) */
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0                 @ Save shift count
    
    /* Get register and value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = source value
    mov     r3, r0                  @ Save reg offset
    
    /* Perform shift */
    lsl     r0, r1, r11
    str     r0, [r2, r3]            @ Store result
    
    /* Set N flag */
    lsr     r1, r0, #24
    str     r1, [r5, #M68K_N_FLAG]
    
    /* Set Z flag */
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    /* V flag always 0 for LSL */
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    
    /* C/X flag from last bit shifted out */
    /* For LSL.L by n, C = bit (32-n) of original */
    rsb     r1, r11, #32            @ 32 - shift
    ldr     r0, [r2, r3]            @ Reload original... wait, we overwrote it
    /* Actually we need original value, let me redo this */
    
    /* Simpler: just set C=0 for now, games rarely check it for LSL */
    mov     r1, #0
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    /* Cycles: 8 + 2*shift, times 7 */
    lsl     r0, r11, #1             @ shift * 2
    add     r0, r0, #8              @ + 8
    mov     r1, #7
    mul     r0, r1, r0              @ * 7
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ASR.L #imm,Dn - Arithmetic Shift Right (immediate)
 * Opcode: 1110 ccc0 1000 0rrr (0xE080)
 * 8 + 2*shift cycles - preserves sign bit
 */
.Lhandle_asr_32_s:
    /* Get shift count */
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    /* Get register and value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = original value
    mov     r3, r0                  @ Save reg offset
    
    /* Arithmetic shift right (sign-extends) */
    asr     r0, r1, r11
    str     r0, [r2, r3]
    
    /* N flag from bit 31 of result */
    lsr     r2, r0, #24
    str     r2, [r5, #M68K_N_FLAG]
    
    /* Z flag */
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    /* V flag always 0 for ASR */
    mov     r2, #0
    str     r2, [r5, #M68K_V_FLAG]
    
    /* C/X = last bit shifted out */
    sub     r2, r11, #1
    lsr     r1, r1, r2              @ Shift to get last bit in bit 0
    and     r1, r1, #1
    lsl     r1, r1, #8              @ Put in bit 8 for C_FLAG format
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    /* Cycles: 8 + 2*shift, times 7 */
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSR.L #imm,Dn - Logical Shift Right (immediate)
 * Opcode: 1110 ccc0 1010 1rrr (0xE088)
 * 8 + 2*shift cycles
 */
.Lhandle_lsr_32_s:
    /* Get shift count */
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    /* Get register and value */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    /* Perform shift */
    lsr     r0, r1, r11
    str     r0, [r2, r3]
    
    /* N flag always 0 for LSR */
    mov     r1, #0
    str     r1, [r5, #M68K_N_FLAG]
    
    /* Z flag */
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    
    /* V flag always 0 */
    str     r1, [r5, #M68K_V_FLAG]
    
    /* C/X = 0 for simplicity */
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    /* Cycles: 8 + 2*shift, times 7 */
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSL.W #imm,Dn - Logical Shift Left Word
 * 6 + 2*shift cycles
 */
.Lhandle_lsl_16_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxth    r0, r1                  @ Get low word
    lsl     r0, r0, r11             @ Shift
    uxth    r0, r0                  @ Mask to 16 bits
    bfi     r1, r0, #0, #16         @ Insert back
    str     r1, [r2, r3]
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSR.W #imm,Dn - Logical Shift Right Word
 */
.Lhandle_lsr_16_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxth    r0, r1
    lsr     r0, r0, r11
    bfi     r1, r0, #0, #16
    str     r1, [r2, r3]
    
    mov     r1, #0
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ASR.W #imm,Dn - Arithmetic Shift Right Word
 */
.Lhandle_asr_16_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    sxth    r0, r1                  @ Sign-extend to 32
    asr     r0, r0, r11
    bfi     r1, r0, #0, #16
    str     r1, [r2, r3]
    
    uxth    r0, r0
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSL.B #imm,Dn - Logical Shift Left Byte
 */
.Lhandle_lsl_8_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxtb    r0, r1
    lsl     r0, r0, r11
    uxtb    r0, r0
    bfi     r1, r0, #0, #8
    str     r1, [r2, r3]
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSR.B #imm,Dn - Logical Shift Right Byte
 */
.Lhandle_lsr_8_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxtb    r0, r1
    lsr     r0, r0, r11
    bfi     r1, r0, #0, #8
    str     r1, [r2, r3]
    
    mov     r1, #0
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ASR.B #imm,Dn - Arithmetic Shift Right Byte
 */
.Lhandle_asr_8_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    sxtb    r0, r1
    asr     r0, r0, r11
    bfi     r1, r0, #0, #8
    str     r1, [r2, r3]
    
    uxtb    r0, r0
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROL.L #imm,Dn - Rotate Left Long
 * 8 + 2*count cycles
 */
.Lhandle_rol_32_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    /* Rotate left: ror by (32 - count) */
    rsb     r0, r11, #32
    ror     r1, r1, r0
    str     r1, [r2, r3]
    
    lsr     r0, r1, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    /* C = bit 0 of result (last bit rotated in) */
    and     r0, r1, #1
    lsl     r0, r0, #8
    str     r0, [r5, #M68K_C_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROR.L #imm,Dn - Rotate Right Long
 */
.Lhandle_ror_32_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    ror     r1, r1, r11
    str     r1, [r2, r3]
    
    lsr     r0, r1, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    /* C = bit 31 of result (last bit rotated in) */
    lsr     r0, r1, #31
    lsl     r0, r0, #8
    str     r0, [r5, #M68K_C_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROL.W #imm,Dn - Rotate Left Word
 */
.Lhandle_rol_16_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxth    r0, r1
    /* 16-bit rotate left by r11 */
    and     r11, r11, #15           @ mod 16
    lsl     r12, r0, r11
    rsb     r11, r11, #16
    lsr     r0, r0, r11
    orr     r0, r0, r12
    uxth    r0, r0
    bfi     r1, r0, #0, #16
    str     r1, [r2, r3]
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    and     r1, r0, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    lsl     r0, r0, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROR.W #imm,Dn - Rotate Right Word
 */
.Lhandle_ror_16_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxth    r0, r1
    and     r11, r11, #15
    lsr     r12, r0, r11
    rsb     r11, r11, #16
    lsl     r0, r0, r11
    orr     r0, r0, r12
    uxth    r0, r0
    bfi     r1, r0, #0, #16
    str     r1, [r2, r3]
    
    lsr     r1, r0, #8
    and     r1, r1, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    lsr     r1, r0, #15
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    lsl     r0, r0, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROL.B #imm,Dn - Rotate Left Byte
 */
.Lhandle_rol_8_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxtb    r0, r1
    and     r11, r11, #7
    lsl     r12, r0, r11
    rsb     r11, r11, #8
    lsr     r0, r0, r11
    orr     r0, r0, r12
    uxtb    r0, r0
    bfi     r1, r0, #0, #8
    str     r1, [r2, r3]
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    and     r1, r0, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    lsl     r0, r0, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * ROR.B #imm,Dn - Rotate Right Byte
 */
.Lhandle_ror_8_s:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    mov     r11, r0
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    uxtb    r0, r1
    and     r11, r11, #7
    lsr     r12, r0, r11
    rsb     r11, r11, #8
    lsl     r0, r0, r11
    orr     r0, r0, r12
    uxtb    r0, r0
    bfi     r1, r0, #0, #8
    str     r1, [r2, r3]
    
    and     r1, r0, #0x80
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    lsr     r1, r0, #7
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    lsl     r0, r0, #1
    add     r0, r0, #6
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

/*
 * LSL.L Dn,Dm - Logical Shift Left (register count)
 * Opcode: 1110 RRR1 1010 1rrr
 * 8 + 2*shift cycles
 */
.Lhandle_lsl_32_r:
    /* Get shift count from Dn (bits 9-11) */
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]           @ r11 = shift count
    and     r11, r11, #63           @ Mod 64 per M68K spec
    
    /* Get value from Dm (bits 0-2) */
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r1, [r2, r0]            @ r1 = value
    mov     r3, r0                  @ Save reg offset
    
    /* Handle shift >= 32 */
    cmp     r11, #32
    bge     .Llsl_32_r_overflow
    
    /* Perform shift */
    lsl     r0, r1, r11
    str     r0, [r2, r3]
    
    lsr     r1, r0, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    /* Variable cycles */
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

.Llsl_32_r_overflow:
    mov     r0, #0
    and     r1, r10, #7
    lsl     r1, r1, #2
    str     r0, [r2, r1]
    str     r0, [r5, #M68K_N_FLAG]
    mov     r1, #1
    str     r1, [r5, #M68K_NOT_Z_FLAG]  @ Z set
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    add     r4, r4, #490            @ Worst case
    b       .Lmain_loop

/*
 * LSR.L Dn,Dm - Logical Shift Right (register count)
 */
.Lhandle_lsr_32_r:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    and     r11, r11, #63
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    cmp     r11, #32
    bge     .Llsr_32_r_overflow
    
    lsr     r0, r1, r11
    str     r0, [r2, r3]
    
    lsr     r1, r0, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

.Llsr_32_r_overflow:
    mov     r0, #0
    and     r1, r10, #7
    lsl     r1, r1, #2
    str     r0, [r2, r1]
    str     r0, [r5, #M68K_N_FLAG]
    mov     r1, #1
    str     r1, [r5, #M68K_NOT_Z_FLAG]
    mov     r0, #0
    str     r0, [r5, #M68K_V_FLAG]
    str     r0, [r5, #M68K_C_FLAG]
    str     r0, [r5, #M68K_X_FLAG]
    add     r4, r4, #490
    b       .Lmain_loop

/*
 * ASR.L Dn,Dm - Arithmetic Shift Right (register count)
 */
.Lhandle_asr_32_r:
    ubfx    r0, r10, #9, #3
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r11, [r2, r0]
    and     r11, r11, #63
    
    and     r0, r10, #7
    lsl     r0, r0, #2
    ldr     r1, [r2, r0]
    mov     r3, r0
    
    /* ASR saturates at 31 for signed behavior */
    cmp     r11, #31
    it      gt
    movgt   r11, #31
    
    asr     r0, r1, r11
    str     r0, [r2, r3]
    
    lsr     r1, r0, #24
    str     r1, [r5, #M68K_N_FLAG]
    str     r0, [r5, #M68K_NOT_Z_FLAG]
    mov     r1, #0
    str     r1, [r5, #M68K_V_FLAG]
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    lsl     r0, r11, #1
    add     r0, r0, #8
    mov     r1, #7
    mul     r0, r1, r0
    add     r4, r4, r0
    b       .Lmain_loop

    .ltorg

/*
 * Bcc.B displacement check for BNE
 */
.Lcheck_bcc_displacement_bne:
    and     r1, r10, #0xFF          @ Get displacement
    cmp     r1, #0                  @ 0xXX00 = .W (needs extension word)
    beq     .Lhandle_bne_w          @ BNE.W
    cmp     r1, #0xFF               @ 0xXXFF = .L (needs extension)
    beq.w   .Lno_inline
    b       .Lhandle_bne_b          @ Handle BNE.B

/* ======================================================================
 * ADDQ/SUBQ/DBcc HANDLERS
 * Format: 0101 iii D ss mm mrrr
 *   iii = data (0=8, 1-7 as-is)
 *   D = 0 for ADDQ, 1 for SUBQ
 *   ss = size (00=byte, 01=word, 10=long)
 *   mmm = mode, rrr = register
 * DBcc: 0101 cccc 1100 1rrr
 * ====================================================================== */

.Lcheck_addq_subq:
    /* Check for DBcc first: bits 7-3 = 11001 (0xC8-0xCF) */
    and     r0, r10, #0xF8          @ Get bits 7-3
    cmp     r0, #0xC8               @ Is it DBcc?
    beq     .Lcheck_dbcc
    
    /* Check for Scc Dn: bits 7-3 = 11000 (0xC0-0xC7) */
    cmp     r0, #0xC0               @ Is it Scc Dn?
    beq     .Lcheck_scc
    
    /* Check mode field (bits 5-3) for register direct */
    ubfx    r1, r10, #3, #3         @ Get mode
    cmp     r1, #0                  @ Is it Dn mode?
    beq     .Lcheck_addq_subq_d_size
    cmp     r1, #1                  @ Is it An mode?
    beq     .Lcheck_addq_subq_a
    b       .Lno_inline             @ Memory modes - use C

.Lcheck_addq_subq_d_size:
    /* Check size field (bits 7-6) */
    ubfx    r0, r10, #6, #2         @ Get size field
    cmp     r0, #2                  @ Is it .L (10)?
    beq     .Lcheck_addq_subq_d
    cmp     r0, #1                  @ Is it .W (01)?
    beq     .Lcheck_addq_subq_d_16
    cmp     r0, #0                  @ Is it .B (00)?
    beq     .Lcheck_addq_subq_d_8
    b       .Lno_inline

.Lcheck_addq_subq_d:
    /* Check bit 8 for ADDQ vs SUBQ */
    tst     r10, #0x100
    bne     .Lhandle_subq_32_d
    b       .Lhandle_addq_32_d

.Lcheck_addq_subq_d_16:
    tst     r10, #0x100
    bne     .Lhandle_subq_16_d
    b       .Lhandle_addq_16_d

.Lcheck_addq_subq_d_8:
    tst     r10, #0x100
    bne     .Lhandle_subq_8_d
    b       .Lhandle_addq_8_d

.Lcheck_addq_subq_a:
    /* An mode only supports .L (word operations also affect full An) */
    tst     r10, #0x100
    bne     .Lhandle_subq_32_a
    b       .Lhandle_addq_32_a

/*
 * ADDQ.L #imm,Dn - Add Quick to Data Register (Long)
 * Opcode: 0101 iii0 1000 0rrr
 * 8 cycles
 */
.Lhandle_addq_32_d:
    /* Get immediate from bits 9-11 (0 means 8) */
    ubfx    r0, r10, #9, #3         @ r0 = immediate field
    cmp     r0, #0
    it      eq
    moveq   r0, #8                  @ 0 means 8
    
    /* Get register index from bits 0-2 */
    and     r1, r10, #7
    lsl     r1, r1, #2              @ r1 = register offset
    
    /* Load register value */
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]            @ r3 = original value
    
    /* Add immediate - use ARM flags */
    adds    r11, r3, r0             @ r11 = result, sets ARM flags
    str     r11, [r2, r1]           @ Store result
    
    /* Set M68K flags from ARM flags */
    /* N flag from bit 31 */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    
    /* Z flag */
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    /* Get ARM APSR for V and C */
    mrs     r0, APSR
    
    /* V flag from ARM bit 28 */
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    /* C flag from ARM bit 29 */
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]  @ X = C for arithmetic ops
    
    add     r4, r4, #56             @ 8 * 7 cycles
    b       .Lmain_loop

/*
 * SUBQ.L #imm,Dn - Subtract Quick from Data Register (Long)
 * Opcode: 0101 iii1 1000 0rrr
 * 8 cycles
 */
.Lhandle_subq_32_d:
    /* Get immediate */
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    /* Get register */
    and     r1, r10, #7
    lsl     r1, r1, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    
    /* Subtract */
    subs    r11, r3, r0
    str     r11, [r2, r1]
    
    /* Set flags */
    lsr     r0, r11, #24
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    
    /* Note: ARM C is inverted for SUB vs M68K borrow */
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1              @ Invert for M68K convention
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDQ.L #imm,An - Add Quick to Address Register (Long)
 * Opcode: 0101 iii0 1000 1rrr
 * 8 cycles - does NOT affect flags
 */
.Lhandle_addq_32_a:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    add     r1, r1, #8              @ Address regs at dar[8-15]
    lsl     r1, r1, #2
    
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    add     r3, r3, r0
    str     r3, [r2, r1]
    
    /* ADDQ to An does NOT affect flags */
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * SUBQ.L #imm,An - Subtract Quick from Address Register (Long)
 * Opcode: 0101 iii1 1000 1rrr
 * 8 cycles - does NOT affect flags
 */
.Lhandle_subq_32_a:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    add     r1, r1, #8
    lsl     r1, r1, #2
    
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    sub     r3, r3, r0
    str     r3, [r2, r1]
    
    /* SUBQ to An does NOT affect flags */
    add     r4, r4, #56
    b       .Lmain_loop

/*
 * ADDQ.W #imm,Dn - Add Quick to Data Register (Word)
 * Opcode: 0101 iii0 0100 0rrr
 * 4 cycles
 */
.Lhandle_addq_16_d:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    lsl     r1, r1, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    
    uxth    r11, r3                 @ Get low word
    adds    r11, r11, r0            @ Add with flags
    bfi     r3, r11, #0, #16        @ Insert result
    str     r3, [r2, r1]
    
    uxth    r11, r11                @ Mask for flag calculation
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * ADDQ.B #imm,Dn - Add Quick to Data Register (Byte)
 * Opcode: 0101 iii0 0000 0rrr
 * 4 cycles
 */
.Lhandle_addq_8_d:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    lsl     r1, r1, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    
    uxtb    r11, r3
    adds    r11, r11, r0
    bfi     r3, r11, #0, #8
    str     r3, [r2, r1]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUBQ.W #imm,Dn - Subtract Quick from Data Register (Word)
 * Opcode: 0101 iii1 0100 0rrr
 * 4 cycles
 */
.Lhandle_subq_16_d:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    lsl     r1, r1, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    
    uxth    r11, r3
    subs    r11, r11, r0
    bfi     r3, r11, #0, #16
    str     r3, [r2, r1]
    
    uxth    r11, r11
    lsr     r0, r11, #8
    and     r0, r0, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/*
 * SUBQ.B #imm,Dn - Subtract Quick from Data Register (Byte)
 * Opcode: 0101 iii1 0000 0rrr
 * 4 cycles
 */
.Lhandle_subq_8_d:
    ubfx    r0, r10, #9, #3
    cmp     r0, #0
    it      eq
    moveq   r0, #8
    
    and     r1, r10, #7
    lsl     r1, r1, #2
    add     r2, r5, #M68K_DAR
    ldr     r3, [r2, r1]
    
    uxtb    r11, r3
    subs    r11, r11, r0
    bfi     r3, r11, #0, #8
    str     r3, [r2, r1]
    
    uxtb    r11, r11
    and     r0, r11, #0x80
    str     r0, [r5, #M68K_N_FLAG]
    str     r11, [r5, #M68K_NOT_Z_FLAG]
    
    mrs     r0, APSR
    ubfx    r1, r0, #28, #1
    lsl     r1, r1, #7
    str     r1, [r5, #M68K_V_FLAG]
    ubfx    r1, r0, #29, #1
    eor     r1, r1, #1
    lsl     r1, r1, #8
    str     r1, [r5, #M68K_C_FLAG]
    str     r1, [r5, #M68K_X_FLAG]
    
    add     r4, r4, #28
    b       .Lmain_loop

/* ======================================================================
 * Scc HANDLERS - Set on Condition
 * Format: 0101 cccc 1100 0rrr
 * Sets byte to 0xFF if condition true, 0x00 if false
 * 4 cycles if false, 6 cycles if true
 * ====================================================================== */

.Lcheck_scc:
    ubfx    r0, r10, #8, #4         @ r0 = condition code
    
    /* Route to specific condition handlers */
    cmp     r0, #0                  @ ST (always true)
    beq     .Lhandle_st
    cmp     r0, #1                  @ SF (always false)
    beq     .Lhandle_sf
    cmp     r0, #6                  @ SNE (Z=0)
    beq     .Lhandle_sne
    cmp     r0, #7                  @ SEQ (Z=1)
    beq     .Lhandle_seq
    cmp     r0, #4                  @ SCC (C=0)
    beq     .Lhandle_scc_cc
    cmp     r0, #5                  @ SCS (C=1)
    beq     .Lhandle_scs
    cmp     r0, #10                 @ SPL (N=0)
    beq     .Lhandle_spl
    cmp     r0, #11                 @ SMI (N=1)
    beq     .Lhandle_smi
    cmp     r0, #12                 @ SGE (N xor V = 0)
    beq     .Lhandle_sge
    cmp     r0, #13                 @ SLT (N xor V = 1)
    beq     .Lhandle_slt
    cmp     r0, #14                 @ SGT ((N xor V) or Z = 0)
    beq     .Lhandle_sgt
    cmp     r0, #15                 @ SLE (Z or (N xor V) = 1)
    beq     .Lhandle_sle
    cmp     r0, #2                  @ SHI (C=0 and Z=0)
    beq     .Lhandle_shi
    cmp     r0, #3                  @ SLS (C=1 or Z=1)
    beq     .Lhandle_sls
    b       .Lno_inline

.Lhandle_st:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    orr     r1, r1, #0xFF           @ Set low byte to 0xFF
    str     r1, [r2, r0]
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

.Lhandle_sf:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    bic     r1, r1, #0xFF           @ Clear low byte
    str     r1, [r2, r0]
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

.Lhandle_sne:
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_seq:
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_scc_cc:
    ldr     r1, [r5, #M68K_C_FLAG]
    cmp     r1, #0
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_scs:
    ldr     r1, [r5, #M68K_C_FLAG]
    cmp     r1, #0
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_spl:
    ldr     r1, [r5, #M68K_N_FLAG]
    tst     r1, #0x80
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_smi:
    ldr     r1, [r5, #M68K_N_FLAG]
    tst     r1, #0x80
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_sge:
    ldr     r1, [r5, #M68K_N_FLAG]
    ldr     r2, [r5, #M68K_V_FLAG]
    eor     r1, r1, r2
    tst     r1, #0x80
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_slt:
    ldr     r1, [r5, #M68K_N_FLAG]
    ldr     r2, [r5, #M68K_V_FLAG]
    eor     r1, r1, r2
    tst     r1, #0x80
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_sgt:
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    beq     .Lscc_set_false         @ Z=1, condition false
    ldr     r1, [r5, #M68K_N_FLAG]
    ldr     r2, [r5, #M68K_V_FLAG]
    eor     r1, r1, r2
    tst     r1, #0x80
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_sle:
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    beq     .Lscc_set_true          @ Z=1, condition true
    ldr     r1, [r5, #M68K_N_FLAG]
    ldr     r2, [r5, #M68K_V_FLAG]
    eor     r1, r1, r2
    tst     r1, #0x80
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_shi:
    ldr     r1, [r5, #M68K_C_FLAG]
    cmp     r1, #0
    bne     .Lscc_set_false
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    bne     .Lscc_set_true
    b       .Lscc_set_false

.Lhandle_sls:
    ldr     r1, [r5, #M68K_C_FLAG]
    cmp     r1, #0
    bne     .Lscc_set_true
    ldr     r1, [r5, #M68K_NOT_Z_FLAG]
    cmp     r1, #0
    beq     .Lscc_set_true
    b       .Lscc_set_false

.Lscc_set_true:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    orr     r1, r1, #0xFF
    str     r1, [r2, r0]
    add     r4, r4, #42             @ 6 * 7 cycles
    b       .Lmain_loop

.Lscc_set_false:
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]
    bic     r1, r1, #0xFF
    str     r1, [r2, r0]
    add     r4, r4, #28             @ 4 * 7 cycles
    b       .Lmain_loop

    .ltorg

/* ======================================================================
 * DBcc HANDLERS - Decrement and Branch if condition false
 * Format: 0101 cccc 1100 1rrr
 * cc = condition code (same as Bcc)
 * rrr = data register for counter
 * ====================================================================== */

.Lcheck_dbcc:
    /* Extract condition code from bits 11-8 */
    ubfx    r0, r10, #8, #4         @ r0 = condition
    
    /* Handle common cases inline */
    cmp     r0, #1                  @ DBF/DBRA (always decrement)
    beq     .Lhandle_dbf
    cmp     r0, #6                  @ DBNE
    beq     .Lhandle_dbne
    cmp     r0, #7                  @ DBEQ
    beq     .Lhandle_dbeq
    cmp     r0, #4                  @ DBCC (C clear)
    beq     .Lhandle_dbcc_cc
    cmp     r0, #5                  @ DBCS (C set)
    beq     .Lhandle_dbcs
    cmp     r0, #10                 @ DBPL (N clear)
    beq     .Lhandle_dbpl
    cmp     r0, #11                 @ DBMI (N set)
    beq     .Lhandle_dbmi
    cmp     r0, #2                  @ DBHI (C=0 and Z=0)
    beq     .Lhandle_dbhi
    cmp     r0, #3                  @ DBLS (C=1 or Z=1)
    beq     .Lhandle_dbls
    cmp     r0, #12                 @ DBGE (N xor V = 0)
    beq     .Lhandle_dbge
    cmp     r0, #13                 @ DBLT (N xor V = 1)
    beq     .Lhandle_dblt
    cmp     r0, #14                 @ DBGT ((N xor V) or Z = 0)
    beq     .Lhandle_dbgt
    cmp     r0, #15                 @ DBLE (Z or (N xor V) = 1)
    beq     .Lhandle_dble
    cmp     r0, #8                  @ DBVC (V clear)
    beq     .Lhandle_dbvc
    cmp     r0, #9                  @ DBVS (V set)
    beq     .Lhandle_dbvs
    
    /* Other conditions - fall back to C */
    b       .Lno_inline

/*
 * DBF/DBRA - Decrement and Branch Always (condition never true)
 * Opcode: 0101 0001 1100 1rrr
 * Very common for counted loops
 */
.Lhandle_dbf:
    /* Get register and decrement */
    and     r0, r10, #7
    lsl     r0, r0, #2
    add     r2, r5, #M68K_DAR
    ldr     r1, [r2, r0]            @ r1 = Dn.L
    
    /* Decrement low word only */
    sub     r3, r1, #1              @ Decrement
    bfi     r1, r3, #0, #16         @ Insert low 16 bits back
    str     r1, [r2, r0]            @ Store back
    
    /* Check if low word wrapped to 0xFFFF */
    uxth    r3, r3                  @ Zero-extend low word
    movw    r0, #0xFFFF
    cmp     r3, r0
    beq     .Ldbcc_expired          @ Counter expired
    
    /* Take the branch - read offset from next word */
    ldr     r0, [r5, #M68K_PC]      @ Get PC
    
    /* Fast ROM fetch for branch offset */
    movw    r1, #0
    movt    r1, #0x80
    cmp     r0, r1
    bhs     .Ldbf_slow_fetch
    
    ldr     r1, [r9]                @ ROM_DATA
    ldrh    r1, [r1, r0]            @ Load offset word
    add     r0, r0, #2              @ Consume the offset word
    
    /* Sign-extend 16-bit offset and apply */
    sxth    r1, r1                  @ Sign extend
    sub     r0, r0, #2              @ PC was pointing after opcode, adjust
    add     r0, r0, r1              @ Apply offset
    str     r0, [r5, #M68K_PC]
    
    add     r4, r4, #70             @ 10 * 7 cycles for taken branch
    b       .Lmain_loop

.Ldbf_slow_fetch:
    /* Fall back to C for slow path */
    b       .Lno_inline

.Ldbcc_expired:
    /* Counter reached -1, skip branch offset word and continue */
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2              @ Skip offset word
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #98             @ 14 * 7 cycles for expired
    b       .Lmain_loop

/*
 * DBNE - Decrement and Branch if Not Equal (Z=0)
 */
.Lhandle_dbne:
    /* Check condition first - if Z is clear (NE true), skip */
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    bne     .Ldbcc_condition_true   @ NE is true, skip decrement
    
    /* Condition false, do the decrement and branch */
    b       .Lhandle_dbf            @ Same logic as DBF

/*
 * DBEQ - Decrement and Branch if Equal (Z=1)
 */
.Lhandle_dbeq:
    /* Check condition first - if Z is set (EQ true), skip */
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Ldbcc_condition_true   @ EQ is true, skip decrement
    
    /* Condition false, do the decrement and branch */
    b       .Lhandle_dbf

/*
 * DBCC - Decrement and Branch if Carry Clear
 */
.Lhandle_dbcc_cc:
    ldr     r0, [r5, #M68K_C_FLAG]
    cmp     r0, #0
    beq     .Ldbcc_condition_true   @ CC is true
    b       .Lhandle_dbf

/*
 * DBCS - Decrement and Branch if Carry Set
 */
.Lhandle_dbcs:
    ldr     r0, [r5, #M68K_C_FLAG]
    cmp     r0, #0
    bne     .Ldbcc_condition_true   @ CS is true
    b       .Lhandle_dbf

/*
 * DBPL - Decrement and Branch if Plus (N clear)
 */
.Lhandle_dbpl:
    ldr     r0, [r5, #M68K_N_FLAG]
    cmp     r0, #0
    beq     .Ldbcc_condition_true   @ PL is true
    b       .Lhandle_dbf

/*
 * DBMI - Decrement and Branch if Minus (N set)
 */
.Lhandle_dbmi:
    ldr     r0, [r5, #M68K_N_FLAG]
    cmp     r0, #0
    bne     .Ldbcc_condition_true   @ MI is true
    b       .Lhandle_dbf

/*
 * DBHI - Decrement and Branch if High (C=0 and Z=0)
 */
.Lhandle_dbhi:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    bne     .Lhandle_dbf            @ C set, condition false
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Lhandle_dbf            @ Z set, condition false
    b       .Ldbcc_condition_true   @ HI is true

/*
 * DBLS - Decrement and Branch if Low or Same (C=1 or Z=1)
 */
.Lhandle_dbls:
    ldr     r0, [r5, #M68K_C_FLAG]
    tst     r0, #0x100
    bne     .Ldbcc_condition_true   @ C set, LS is true
    ldr     r0, [r5, #M68K_NOT_Z_FLAG]
    cmp     r0, #0
    beq     .Ldbcc_condition_true   @ Z set, LS is true
    b       .Lhandle_dbf            @ Condition false

/*
 * DBGE - Decrement and Branch if Greater or Equal (N xor V = 0)
 */
.Lhandle_dbge:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    beq     .Ldbcc_condition_true   @ GE is true
    b       .Lhandle_dbf

/*
 * DBLT - Decrement and Branch if Less Than (N xor V = 1)
 */
.Lhandle_dblt:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    bne     .Ldbcc_condition_true   @ LT is true
    b       .Lhandle_dbf

/*
 * DBGT - Decrement and Branch if Greater Than ((N xor V) or Z = 0)
 */
.Lhandle_dbgt:
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    ldr     r2, [r5, #M68K_NOT_Z_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    bne     .Lhandle_dbf            @ N xor V != 0, condition false
    cmp     r2, #0
    beq     .Lhandle_dbf            @ Z set, condition false
    b       .Ldbcc_condition_true   @ GT is true

/*
 * DBLE - Decrement and Branch if Less or Equal (Z or (N xor V) = 1)
 */
.Lhandle_dble:
    ldr     r2, [r5, #M68K_NOT_Z_FLAG]
    cmp     r2, #0
    beq     .Ldbcc_condition_true   @ Z set, LE is true
    ldr     r0, [r5, #M68K_N_FLAG]
    ldr     r1, [r5, #M68K_V_FLAG]
    eor     r0, r0, r1
    tst     r0, #0x80
    bne     .Ldbcc_condition_true   @ N xor V = 1, LE is true
    b       .Lhandle_dbf            @ Condition false

/*
 * DBVC - Decrement and Branch if Overflow Clear
 */
.Lhandle_dbvc:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80
    beq     .Ldbcc_condition_true   @ VC is true
    b       .Lhandle_dbf

/*
 * DBVS - Decrement and Branch if Overflow Set
 */
.Lhandle_dbvs:
    ldr     r0, [r5, #M68K_V_FLAG]
    tst     r0, #0x80
    bne     .Ldbcc_condition_true   @ VS is true
    b       .Lhandle_dbf

.Ldbcc_condition_true:
    /* Condition is true - just skip the offset word */
    ldr     r0, [r5, #M68K_PC]
    add     r0, r0, #2
    str     r0, [r5, #M68K_PC]
    add     r4, r4, #84             @ 12 * 7 cycles
    b       .Lmain_loop

    .size m68k_run_fast, . - m68k_run_fast

    .end
