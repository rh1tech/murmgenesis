/*
 * M68K Hot Instruction Handlers - ARM Thumb-2 Assembly (Cortex-M33)
 * 
 * Optimized handlers for frequently-executed 68000 instructions
 * These replace the C versions in m68kops.h for better performance
 */

    .syntax unified
    .cpu cortex-m33
    .thumb
    .section .time_critical.m68k_ops,"ax",%progbits

    .extern m68k

/*
 * Structure offsets for m68ki_cpu_core (relative to base at cycles field)
 * Base offset = 5132 from start of struct
 */
    .equ M68K_BASE_OFFSET,  5132
    .equ M68K_CYCLES,       0
    .equ M68K_CYCLE_END,    4
    .equ M68K_DAR,          8       /* dar[16] = 64 bytes (D0-D7, A0-A7) */
    .equ M68K_PC,           72
    .equ M68K_SP,           76      /* sp[5] = 20 bytes */
    .equ M68K_IR,           96
    .equ M68K_T1_FLAG,      100
    .equ M68K_S_FLAG,       104
    .equ M68K_X_FLAG,       108
    .equ M68K_N_FLAG,       112
    .equ M68K_NOT_Z_FLAG,   116     /* Note: Z flag is inverted (not_z) */
    .equ M68K_V_FLAG,       120
    .equ M68K_C_FLAG,       124
    .equ M68K_INT_MASK,     128
    .equ M68K_INT_LEVEL,    132
    .equ M68K_STOPPED,      136

/*
 * Cycle costs (pre-multiplied by MUL=7)
 */
    .equ CYC_BCC_NOTAKE_B,  -14     /* -2 * 7 */

/*
 * Helper macro to get base pointer to m68k struct
 */
    .macro GET_M68K_BASE reg
    ldr     \reg, =m68k
    movw    r12, #M68K_BASE_OFFSET
    add     \reg, \reg, r12
    .endm

/* ========================================================================== */
/* ========================= BRANCH INSTRUCTIONS ============================ */
/* ========================================================================== */

/*
 * BNE.B - Branch if Not Equal (8-bit displacement)
 * Opcode: 0110 0110 dddd dddd (66xx)
 * 
 * This is one of the most frequently executed instructions in loops
 */
    .global m68k_op_bne_8_asm
    .type m68k_op_bne_8_asm, %function
    .align 4

m68k_op_bne_8_asm:
    GET_M68K_BASE r0
    
    /* Check Z flag (not_z_flag) - if non-zero, condition is true */
    ldr     r1, [r0, #M68K_NOT_Z_FLAG]
    cbz     r1, .Lbne_8_not_taken
    
    /* Branch taken: PC += sign_extend(displacement) */
    ldrh    r2, [r0, #M68K_IR]      /* Get IR */
    sxtb    r2, r2                  /* Sign extend 8-bit displacement */
    ldr     r3, [r0, #M68K_PC]      /* Get PC */
    add     r3, r3, r2              /* PC += displacement */
    str     r3, [r0, #M68K_PC]      /* Store new PC */
    bx      lr

.Lbne_8_not_taken:
    /* Branch not taken: add penalty cycles */
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14             /* CYC_BCC_NOTAKE_B = -14 (actually subtracts) */
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_bne_8_asm, . - m68k_op_bne_8_asm


/*
 * BEQ.B - Branch if Equal (8-bit displacement)
 * Opcode: 0110 0111 dddd dddd (67xx)
 */
    .global m68k_op_beq_8_asm
    .type m68k_op_beq_8_asm, %function
    .align 4

m68k_op_beq_8_asm:
    GET_M68K_BASE r0
    
    /* Check Z flag (not_z_flag) - if zero, condition is true (EQ) */
    ldr     r1, [r0, #M68K_NOT_Z_FLAG]
    cbnz    r1, .Lbeq_8_not_taken
    
    /* Branch taken: PC += sign_extend(displacement) */
    ldrh    r2, [r0, #M68K_IR]      /* Get IR */
    sxtb    r2, r2                  /* Sign extend 8-bit displacement */
    ldr     r3, [r0, #M68K_PC]      /* Get PC */
    add     r3, r3, r2              /* PC += displacement */
    str     r3, [r0, #M68K_PC]      /* Store new PC */
    bx      lr

.Lbeq_8_not_taken:
    /* Branch not taken: add penalty cycles */
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14             /* CYC_BCC_NOTAKE_B */
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_beq_8_asm, . - m68k_op_beq_8_asm


/*
 * BPL.B - Branch if Plus (N flag clear)
 * Opcode: 0110 1010 dddd dddd (6Axx)
 */
    .global m68k_op_bpl_8_asm
    .type m68k_op_bpl_8_asm, %function
    .align 4

m68k_op_bpl_8_asm:
    GET_M68K_BASE r0
    
    /* Check N flag - if bit 7 is clear, condition is true */
    ldr     r1, [r0, #M68K_N_FLAG]
    tst     r1, #0x80
    bne     .Lbpl_8_not_taken
    
    /* Branch taken */
    ldrh    r2, [r0, #M68K_IR]
    sxtb    r2, r2
    ldr     r3, [r0, #M68K_PC]
    add     r3, r3, r2
    str     r3, [r0, #M68K_PC]
    bx      lr

.Lbpl_8_not_taken:
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_bpl_8_asm, . - m68k_op_bpl_8_asm


/*
 * BMI.B - Branch if Minus (N flag set)
 * Opcode: 0110 1011 dddd dddd (6Bxx)
 */
    .global m68k_op_bmi_8_asm
    .type m68k_op_bmi_8_asm, %function
    .align 4

m68k_op_bmi_8_asm:
    GET_M68K_BASE r0
    
    /* Check N flag - if bit 7 is set, condition is true */
    ldr     r1, [r0, #M68K_N_FLAG]
    tst     r1, #0x80
    beq     .Lbmi_8_not_taken
    
    /* Branch taken */
    ldrh    r2, [r0, #M68K_IR]
    sxtb    r2, r2
    ldr     r3, [r0, #M68K_PC]
    add     r3, r3, r2
    str     r3, [r0, #M68K_PC]
    bx      lr

.Lbmi_8_not_taken:
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_bmi_8_asm, . - m68k_op_bmi_8_asm


/*
 * BCC.B - Branch if Carry Clear
 * Opcode: 0110 0100 dddd dddd (64xx)
 */
    .global m68k_op_bcc_8_asm
    .type m68k_op_bcc_8_asm, %function
    .align 4

m68k_op_bcc_8_asm:
    GET_M68K_BASE r0
    
    /* Check C flag - if bit 8 is clear, condition is true */
    ldr     r1, [r0, #M68K_C_FLAG]
    tst     r1, #0x100
    bne     .Lbcc_8_not_taken
    
    /* Branch taken */
    ldrh    r2, [r0, #M68K_IR]
    sxtb    r2, r2
    ldr     r3, [r0, #M68K_PC]
    add     r3, r3, r2
    str     r3, [r0, #M68K_PC]
    bx      lr

.Lbcc_8_not_taken:
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_bcc_8_asm, . - m68k_op_bcc_8_asm


/*
 * BCS.B - Branch if Carry Set
 * Opcode: 0110 0101 dddd dddd (65xx)
 */
    .global m68k_op_bcs_8_asm
    .type m68k_op_bcs_8_asm, %function
    .align 4

m68k_op_bcs_8_asm:
    GET_M68K_BASE r0
    
    /* Check C flag - if bit 8 is set, condition is true */
    ldr     r1, [r0, #M68K_C_FLAG]
    tst     r1, #0x100
    beq     .Lbcs_8_not_taken
    
    /* Branch taken */
    ldrh    r2, [r0, #M68K_IR]
    sxtb    r2, r2
    ldr     r3, [r0, #M68K_PC]
    add     r3, r3, r2
    str     r3, [r0, #M68K_PC]
    bx      lr

.Lbcs_8_not_taken:
    ldr     r1, [r0, #M68K_CYCLES]
    sub     r1, r1, #14
    str     r1, [r0, #M68K_CYCLES]
    bx      lr

    .size m68k_op_bcs_8_asm, . - m68k_op_bcs_8_asm


/*
 * BRA.B - Branch Always (8-bit displacement)
 * Opcode: 0110 0000 dddd dddd (60xx) where dd != 00 and dd != FF
 */
    .global m68k_op_bra_8_asm
    .type m68k_op_bra_8_asm, %function
    .align 4

m68k_op_bra_8_asm:
    GET_M68K_BASE r0
    
    /* Always taken: PC += sign_extend(displacement) */
    ldrh    r2, [r0, #M68K_IR]
    sxtb    r2, r2
    ldr     r3, [r0, #M68K_PC]
    add     r3, r3, r2
    str     r3, [r0, #M68K_PC]
    bx      lr

    .size m68k_op_bra_8_asm, . - m68k_op_bra_8_asm


/* ========================================================================== */
/* ========================= MOVE INSTRUCTIONS ============================== */
/* ========================================================================== */

/*
 * MOVE.L Dn,Dn - Move Long between data registers
 * Opcode: 0010 xxx0 0000 0yyy (2000-2E00 range with mode 0)
 * 
 * This is very common for register-to-register operations
 */
    .global m68k_op_move_32_d_d_asm
    .type m68k_op_move_32_d_d_asm, %function
    .align 4

m68k_op_move_32_d_d_asm:
    GET_M68K_BASE r0
    
    /* Get source register index from IR bits 0-2 */
    ldrh    r1, [r0, #M68K_IR]
    and     r2, r1, #7              /* r2 = source reg index */
    
    /* Get destination register index from IR bits 9-11 */
    lsr     r3, r1, #9
    and     r3, r3, #7              /* r3 = dest reg index */
    
    /* Load source value from dar[src] */
    add     r2, r0, r2, lsl #2      /* r2 = &dar[src] */
    ldr     r1, [r2, #M68K_DAR]     /* r1 = source value */
    
    /* Store to dar[dst] */
    add     r3, r0, r3, lsl #2      /* r3 = &dar[dst] */
    str     r1, [r3, #M68K_DAR]
    
    /* Set flags: N, Z based on result; clear V, C */
    /* N flag = bit 31 of result */
    lsr     r2, r1, #24             /* Get high byte for N flag */
    str     r2, [r0, #M68K_N_FLAG]
    
    /* Z flag = result (non-zero means NE) */
    str     r1, [r0, #M68K_NOT_Z_FLAG]
    
    /* Clear V and C */
    mov     r2, #0
    str     r2, [r0, #M68K_V_FLAG]
    str     r2, [r0, #M68K_C_FLAG]
    
    bx      lr

    .size m68k_op_move_32_d_d_asm, . - m68k_op_move_32_d_d_asm


/*
 * MOVE.W Dn,Dn - Move Word between data registers
 */
    .global m68k_op_move_16_d_d_asm
    .type m68k_op_move_16_d_d_asm, %function
    .align 4

m68k_op_move_16_d_d_asm:
    GET_M68K_BASE r0
    
    /* Get source register index from IR bits 0-2 */
    ldrh    r1, [r0, #M68K_IR]
    and     r2, r1, #7              /* r2 = source reg index */
    
    /* Get destination register index from IR bits 9-11 */
    lsr     r3, r1, #9
    and     r3, r3, #7              /* r3 = dest reg index */
    
    /* Load source value from dar[src] (only low 16 bits) */
    add     r2, r0, r2, lsl #2
    ldr     r1, [r2, #M68K_DAR]
    uxth    r1, r1                  /* Mask to 16 bits */
    
    /* Load dest, preserve high 16 bits, replace low 16 */
    add     r3, r0, r3, lsl #2
    ldr     r12, [r3, #M68K_DAR]
    /* Clear low 16 bits using movt (set high 16 bits and shift) */
    lsr     r12, r12, #16           /* Shift right by 16 */
    lsl     r12, r12, #16           /* Shift left by 16 (clears low 16) */
    orr     r12, r12, r1
    str     r12, [r3, #M68K_DAR]
    
    /* Set flags for 16-bit result */
    lsr     r2, r1, #8              /* N flag from bit 15 -> bit 7 */
    str     r2, [r0, #M68K_N_FLAG]
    str     r1, [r0, #M68K_NOT_Z_FLAG]
    mov     r2, #0
    str     r2, [r0, #M68K_V_FLAG]
    str     r2, [r0, #M68K_C_FLAG]
    
    bx      lr

    .size m68k_op_move_16_d_d_asm, . - m68k_op_move_16_d_d_asm


/* ========================================================================== */
/* =========================== NOP INSTRUCTION ============================== */
/* ========================================================================== */

/*
 * NOP - No Operation
 * Opcode: 0100 1110 0111 0001 (4E71)
 */
    .global m68k_op_nop_asm
    .type m68k_op_nop_asm, %function
    .align 4

m68k_op_nop_asm:
    /* Do nothing - just return */
    bx      lr

    .size m68k_op_nop_asm, . - m68k_op_nop_asm


/* ========================================================================== */
/* ========================= ADDQ/SUBQ INSTRUCTIONS ========================= */
/* ========================================================================== */

/*
 * ADDQ.L #imm,Dn - Add Quick to Data Register (Long)
 * Opcode: 0101 iii0 1000 0yyy
 * Where iii = immediate (1-8, 0 means 8), yyy = register
 */
    .global m68k_op_addq_32_d_asm
    .type m68k_op_addq_32_d_asm, %function
    .align 4

m68k_op_addq_32_d_asm:
    GET_M68K_BASE r0
    
    /* Get register index from IR bits 0-2 */
    ldrh    r1, [r0, #M68K_IR]
    and     r2, r1, #7              /* r2 = register index */
    
    /* Get immediate from IR bits 9-11 (0 = 8) */
    lsr     r3, r1, #9
    and     r3, r3, #7
    cmp     r3, #0
    it      eq
    moveq   r3, #8                  /* 0 means 8 */
    
    /* Load register value */
    add     r2, r0, r2, lsl #2
    ldr     r1, [r2, #M68K_DAR]     /* r1 = original value */
    
    /* Add immediate */
    adds    r12, r1, r3             /* r12 = result, flags set */
    str     r12, [r2, #M68K_DAR]    /* Store result */
    
    /* Set M68K flags from ARM flags */
    /* N flag */
    lsr     r1, r12, #24
    str     r1, [r0, #M68K_N_FLAG]
    
    /* Z flag */
    str     r12, [r0, #M68K_NOT_Z_FLAG]
    
    /* V flag - overflow for addition */
    /* ARM V flag is in APSR bit 28 */
    mrs     r1, APSR
    ubfx    r3, r1, #28, #1         /* Extract V bit */
    lsl     r3, r3, #7              /* Shift to bit 7 */
    str     r3, [r0, #M68K_V_FLAG]
    
    /* C flag - carry from bit 31 */
    ubfx    r3, r1, #29, #1         /* Extract C bit */
    lsl     r3, r3, #8              /* Shift to bit 8 */
    str     r3, [r0, #M68K_C_FLAG]
    
    /* X flag = C flag for arithmetic */
    str     r3, [r0, #M68K_X_FLAG]
    
    bx      lr

    .size m68k_op_addq_32_d_asm, . - m68k_op_addq_32_d_asm


/*
 * SUBQ.L #imm,Dn - Subtract Quick from Data Register (Long)
 * Opcode: 0101 iii1 1000 0yyy
 */
    .global m68k_op_subq_32_d_asm
    .type m68k_op_subq_32_d_asm, %function
    .align 4

m68k_op_subq_32_d_asm:
    GET_M68K_BASE r0
    
    /* Get register index from IR bits 0-2 */
    ldrh    r1, [r0, #M68K_IR]
    and     r2, r1, #7
    
    /* Get immediate from IR bits 9-11 (0 = 8) */
    lsr     r3, r1, #9
    and     r3, r3, #7
    cmp     r3, #0
    it      eq
    moveq   r3, #8
    
    /* Load register value */
    add     r2, r0, r2, lsl #2
    ldr     r1, [r2, #M68K_DAR]
    
    /* Subtract immediate */
    subs    r12, r1, r3             /* r12 = result */
    str     r12, [r2, #M68K_DAR]
    
    /* Set M68K flags */
    lsr     r1, r12, #24
    str     r1, [r0, #M68K_N_FLAG]
    str     r12, [r0, #M68K_NOT_Z_FLAG]
    
    /* V and C flags from ARM */
    mrs     r1, APSR
    ubfx    r3, r1, #28, #1
    lsl     r3, r3, #7
    str     r3, [r0, #M68K_V_FLAG]
    
    /* Note: ARM C flag is inverted for subtraction vs M68K */
    ubfx    r3, r1, #29, #1
    eor     r3, r3, #1              /* Invert for M68K borrow convention */
    lsl     r3, r3, #8
    str     r3, [r0, #M68K_C_FLAG]
    str     r3, [r0, #M68K_X_FLAG]
    
    bx      lr

    .size m68k_op_subq_32_d_asm, . - m68k_op_subq_32_d_asm


    .end
