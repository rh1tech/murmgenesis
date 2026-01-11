/*
 * VDP Graphics - ARM Thumb-2 Assembly (Cortex-M33)
 * 
 * Optimized pattern drawing functions for Genesis VDP emulation.
 * These are the hottest code paths - called for every 8-pixel tile.
 *
 * Target: RP2350 Cortex-M33 @ 378-504 MHz
 */

    .syntax unified
    .cpu cortex-m33
    .thumb
    .section .time_critical.vdp_gfx_opt,"ax",%progbits

/* Pixel attribute constants */
.equ PIXATTR_HIPRI,        0x80
.equ PIXATTR_SPRITE,       0x40
.equ PIXATTR_SPRITE_HIPRI, 0xC0

/* Pixel extraction macros - pattern is packed as 4 bytes with nibbles */
/* Pattern format: byte3[7:4][3:0] byte2[7:4][3:0] byte1[7:4][3:0] byte0[7:4][3:0] */
/* PIX0 = bits[7:4] of byte0,   PIX1 = bits[3:0] of byte0 */
/* PIX2 = bits[7:4] of byte1,   PIX3 = bits[3:0] of byte1 */
/* PIX4 = bits[7:4] of byte2,   PIX5 = bits[3:0] of byte2 */
/* PIX6 = bits[7:4] of byte3,   PIX7 = bits[3:0] of byte3 */

/*
 * void draw_pattern_nofliph_planeB_asm(uint8_t* scr, uint32_t p, uint8_t attrs, uint8_t back)
 *
 * Draw 8 pixels for plane B (no horizontal flip)
 * Always writes all 8 pixels (background or pattern)
 *
 * Args:
 *   r0 = scr (destination buffer pointer)
 *   r1 = p (32-bit packed pattern data)
 *   r2 = attrs (palette + priority attributes)
 *   r3 = back (background color index)
 */
    .global draw_pattern_nofliph_planeB_asm
    .type draw_pattern_nofliph_planeB_asm, %function
    .thumb_func
    .align 2
draw_pattern_nofliph_planeB_asm:
    push    {r4-r7, lr}
    
    /* If pattern is zero, fill with background */
    cmp     r1, #0
    bne     .Lpb_nf_draw
    
    /* Fast path: fill 8 bytes with background */
    orr     r3, r3, r3, lsl #8      /* r3 = back | back<<8 */
    orr     r3, r3, r3, lsl #16     /* r3 = back x 4 */
    str     r3, [r0, #0]            /* scr[0-3] = back */
    str     r3, [r0, #4]            /* scr[4-7] = back */
    pop     {r4-r7, pc}

.Lpb_nf_draw:
    /* Extract and write pixels 0-7 */
    /* PIX0 = (p >> 4) & 0xF */
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4              /* attrs | pix */
    moveq   r4, r3                  /* background */
    strb    r4, [r0, #0]
    
    /* PIX1 = p & 0xF */
    and     r4, r1, #0xF
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #1]
    
    /* PIX2 = (p >> 12) & 0xF */
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #2]
    
    /* PIX3 = (p >> 8) & 0xF */
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #3]
    
    /* PIX4 = (p >> 20) & 0xF */
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #4]
    
    /* PIX5 = (p >> 16) & 0xF */
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #5]
    
    /* PIX6 = (p >> 28) & 0xF */
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #6]
    
    /* PIX7 = (p >> 24) & 0xF */
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #7]
    
    pop     {r4-r7, pc}
    .size draw_pattern_nofliph_planeB_asm, .-draw_pattern_nofliph_planeB_asm


/*
 * void draw_pattern_fliph_planeB_asm(uint8_t* scr, uint32_t p, uint8_t attrs, uint8_t back)
 *
 * Draw 8 pixels for plane B (with horizontal flip)
 */
    .global draw_pattern_fliph_planeB_asm
    .type draw_pattern_fliph_planeB_asm, %function
    .thumb_func
    .align 2
draw_pattern_fliph_planeB_asm:
    push    {r4-r7, lr}
    
    cmp     r1, #0
    bne     .Lpb_fh_draw
    
    /* Fast path: fill with background */
    orr     r3, r3, r3, lsl #8
    orr     r3, r3, r3, lsl #16
    str     r3, [r0, #0]
    str     r3, [r0, #4]
    pop     {r4-r7, pc}

.Lpb_fh_draw:
    /* Flipped: PIX7->scr[0], PIX6->scr[1], ... PIX0->scr[7] */
    
    /* PIX7 = (p >> 24) & 0xF -> scr[0] */
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #0]
    
    /* PIX6 = (p >> 28) & 0xF -> scr[1] */
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #1]
    
    /* PIX5 = (p >> 16) & 0xF -> scr[2] */
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #2]
    
    /* PIX4 = (p >> 20) & 0xF -> scr[3] */
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #3]
    
    /* PIX3 = (p >> 8) & 0xF -> scr[4] */
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #4]
    
    /* PIX2 = (p >> 12) & 0xF -> scr[5] */
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #5]
    
    /* PIX1 = p & 0xF -> scr[6] */
    and     r4, r1, #0xF
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #6]
    
    /* PIX0 = (p >> 4) & 0xF -> scr[7] */
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    ite     ne
    orrne   r4, r2, r4
    moveq   r4, r3
    strb    r4, [r0, #7]
    
    pop     {r4-r7, pc}
    .size draw_pattern_fliph_planeB_asm, .-draw_pattern_fliph_planeB_asm


/*
 * void draw_pattern_nofliph_planeA_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw plane A over plane B (respects priority)
 * Only writes non-transparent pixels, respecting HIPRI flag
 */
    .global draw_pattern_nofliph_planeA_asm
    .type draw_pattern_nofliph_planeA_asm, %function
    .thumb_func
    .align 2
draw_pattern_nofliph_planeA_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lpa_nf_done            /* All transparent, nothing to draw */
    
    /* Check if high priority */
    tst     r2, #PIXATTR_HIPRI
    bne     .Lpa_nf_hipri
    
    /* Low priority path - only draw over low priority pixels */
.Lpa_nf_lopri:
    /* PIX0 */
    ubfx    r4, r1, #4, #4
    cbz     r4, .Lpa_nf_lo_p1
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lpa_nf_lo_p1:
    and     r4, r1, #0xF
    cbz     r4, .Lpa_nf_lo_p2
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lpa_nf_lo_p2:
    ubfx    r4, r1, #12, #4
    cbz     r4, .Lpa_nf_lo_p3
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lpa_nf_lo_p3:
    ubfx    r4, r1, #8, #4
    cbz     r4, .Lpa_nf_lo_p4
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lpa_nf_lo_p4:
    ubfx    r4, r1, #20, #4
    cbz     r4, .Lpa_nf_lo_p5
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lpa_nf_lo_p5:
    ubfx    r4, r1, #16, #4
    cbz     r4, .Lpa_nf_lo_p6
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lpa_nf_lo_p6:
    ubfx    r4, r1, #28, #4
    cbz     r4, .Lpa_nf_lo_p7
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_lo_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lpa_nf_lo_p7:
    ubfx    r4, r1, #24, #4
    cbz     r4, .Lpa_nf_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_nf_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    pop     {r4-r6, pc}

    /* High priority path - always draw non-transparent */
.Lpa_nf_hipri:
    ubfx    r4, r1, #4, #4
    cbz     r4, .Lpa_nf_hi_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lpa_nf_hi_p1:
    and     r4, r1, #0xF
    cbz     r4, .Lpa_nf_hi_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lpa_nf_hi_p2:
    ubfx    r4, r1, #12, #4
    cbz     r4, .Lpa_nf_hi_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lpa_nf_hi_p3:
    ubfx    r4, r1, #8, #4
    cbz     r4, .Lpa_nf_hi_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lpa_nf_hi_p4:
    ubfx    r4, r1, #20, #4
    cbz     r4, .Lpa_nf_hi_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lpa_nf_hi_p5:
    ubfx    r4, r1, #16, #4
    cbz     r4, .Lpa_nf_hi_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lpa_nf_hi_p6:
    ubfx    r4, r1, #28, #4
    cbz     r4, .Lpa_nf_hi_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lpa_nf_hi_p7:
    ubfx    r4, r1, #24, #4
    cbz     r4, .Lpa_nf_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lpa_nf_done:
    pop     {r4-r6, pc}
    .size draw_pattern_nofliph_planeA_asm, .-draw_pattern_nofliph_planeA_asm


/*
 * void draw_pattern_fliph_planeA_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw plane A over plane B with horizontal flip
 */
    .global draw_pattern_fliph_planeA_asm
    .type draw_pattern_fliph_planeA_asm, %function
    .thumb_func
    .align 2
draw_pattern_fliph_planeA_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lpa_fh_done
    
    tst     r2, #PIXATTR_HIPRI
    bne     .Lpa_fh_hipri
    
    /* Low priority flipped */
.Lpa_fh_lopri:
    /* PIX7 -> scr[0] */
    ubfx    r4, r1, #24, #4
    cbz     r4, .Lpa_fh_lo_p1
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lpa_fh_lo_p1:
    ubfx    r4, r1, #28, #4
    cbz     r4, .Lpa_fh_lo_p2
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lpa_fh_lo_p2:
    ubfx    r4, r1, #16, #4
    cbz     r4, .Lpa_fh_lo_p3
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lpa_fh_lo_p3:
    ubfx    r4, r1, #20, #4
    cbz     r4, .Lpa_fh_lo_p4
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lpa_fh_lo_p4:
    ubfx    r4, r1, #8, #4
    cbz     r4, .Lpa_fh_lo_p5
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lpa_fh_lo_p5:
    ubfx    r4, r1, #12, #4
    cbz     r4, .Lpa_fh_lo_p6
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lpa_fh_lo_p6:
    and     r4, r1, #0xF
    cbz     r4, .Lpa_fh_lo_p7
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_lo_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lpa_fh_lo_p7:
    ubfx    r4, r1, #4, #4
    cbz     r4, .Lpa_fh_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_HIPRI
    bne     .Lpa_fh_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    pop     {r4-r6, pc}

    /* High priority flipped */
.Lpa_fh_hipri:
    ubfx    r4, r1, #24, #4
    cbz     r4, .Lpa_fh_hi_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lpa_fh_hi_p1:
    ubfx    r4, r1, #28, #4
    cbz     r4, .Lpa_fh_hi_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lpa_fh_hi_p2:
    ubfx    r4, r1, #16, #4
    cbz     r4, .Lpa_fh_hi_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lpa_fh_hi_p3:
    ubfx    r4, r1, #20, #4
    cbz     r4, .Lpa_fh_hi_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lpa_fh_hi_p4:
    ubfx    r4, r1, #8, #4
    cbz     r4, .Lpa_fh_hi_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lpa_fh_hi_p5:
    ubfx    r4, r1, #12, #4
    cbz     r4, .Lpa_fh_hi_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lpa_fh_hi_p6:
    and     r4, r1, #0xF
    cbz     r4, .Lpa_fh_hi_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lpa_fh_hi_p7:
    ubfx    r4, r1, #4, #4
    cbz     r4, .Lpa_fh_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lpa_fh_done:
    pop     {r4-r6, pc}
    .size draw_pattern_fliph_planeA_asm, .-draw_pattern_fliph_planeA_asm

.end
