/*
 * VDP Sprite Drawing - ARM Thumb-2 Assembly (Cortex-M33)
 * 
 * Optimized sprite pattern drawing functions for Genesis VDP.
 *
 * Target: RP2350 Cortex-M33 @ 378-504 MHz
 */

    .syntax unified
    .cpu cortex-m33
    .thumb
    .section .time_critical.vdp_sprite_opt,"ax",%progbits

/* Pixel attribute constants */
.equ PIXATTR_HIPRI,        0x80
.equ PIXATTR_SPRITE,       0x40
.equ PIXATTR_SPRITE_HIPRI, 0xC0

/*
 * void draw_pattern_nofliph_sprite_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw sprite pattern (no flip) - only writes if pixel not already a sprite
 */
    .global draw_pattern_nofliph_sprite_asm
    .type draw_pattern_nofliph_sprite_asm, %function
    .thumb_func
    .align 2
draw_pattern_nofliph_sprite_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lsp_nf_done
    
    /* PIX0 */
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     .Lsp_nf_p1
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lsp_nf_p1:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     .Lsp_nf_p2
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lsp_nf_p2:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     .Lsp_nf_p3
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lsp_nf_p3:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     .Lsp_nf_p4
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lsp_nf_p4:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     .Lsp_nf_p5
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lsp_nf_p5:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     .Lsp_nf_p6
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lsp_nf_p6:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     .Lsp_nf_p7
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lsp_nf_p7:
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     .Lsp_nf_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_nf_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lsp_nf_done:
    pop     {r4-r6, pc}
    .size draw_pattern_nofliph_sprite_asm, .-draw_pattern_nofliph_sprite_asm


/*
 * void draw_pattern_fliph_sprite_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw sprite pattern (with flip)
 */
    .global draw_pattern_fliph_sprite_asm
    .type draw_pattern_fliph_sprite_asm, %function
    .thumb_func
    .align 2
draw_pattern_fliph_sprite_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lsp_fh_done
    
    /* PIX7 -> scr[0] */
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     .Lsp_fh_p1
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p1
    orr     r4, r2, r4
    strb    r4, [r0, #0]
.Lsp_fh_p1:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     .Lsp_fh_p2
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p2
    orr     r4, r2, r4
    strb    r4, [r0, #1]
.Lsp_fh_p2:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     .Lsp_fh_p3
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p3
    orr     r4, r2, r4
    strb    r4, [r0, #2]
.Lsp_fh_p3:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     .Lsp_fh_p4
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p4
    orr     r4, r2, r4
    strb    r4, [r0, #3]
.Lsp_fh_p4:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     .Lsp_fh_p5
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p5
    orr     r4, r2, r4
    strb    r4, [r0, #4]
.Lsp_fh_p5:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     .Lsp_fh_p6
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p6
    orr     r4, r2, r4
    strb    r4, [r0, #5]
.Lsp_fh_p6:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     .Lsp_fh_p7
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_p7
    orr     r4, r2, r4
    strb    r4, [r0, #6]
.Lsp_fh_p7:
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     .Lsp_fh_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lsp_fh_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lsp_fh_done:
    pop     {r4-r6, pc}
    .size draw_pattern_fliph_sprite_asm, .-draw_pattern_fliph_sprite_asm


/*
 * void draw_pattern_nofliph_sprite_over_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw sprite over planes - respects priority
 */
    .global draw_pattern_nofliph_sprite_over_asm
    .type draw_pattern_nofliph_sprite_over_asm, %function
    .thumb_func
    .align 2
draw_pattern_nofliph_sprite_over_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lspo_nf_done
    
    tst     r2, #PIXATTR_HIPRI
    bne     .Lspo_nf_hipri
    
    /* Low priority - check SPRITE_HIPRI mask */
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     1f
    ldrb    r5, [r0, #0]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     1f
    orr     r4, r2, r4
    strb    r4, [r0, #0]
1:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     2f
    ldrb    r5, [r0, #1]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     2f
    orr     r4, r2, r4
    strb    r4, [r0, #1]
2:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     3f
    ldrb    r5, [r0, #2]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     3f
    orr     r4, r2, r4
    strb    r4, [r0, #2]
3:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     4f
    ldrb    r5, [r0, #3]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     4f
    orr     r4, r2, r4
    strb    r4, [r0, #3]
4:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     5f
    ldrb    r5, [r0, #4]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     5f
    orr     r4, r2, r4
    strb    r4, [r0, #4]
5:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     6f
    ldrb    r5, [r0, #5]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     6f
    orr     r4, r2, r4
    strb    r4, [r0, #5]
6:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     7f
    ldrb    r5, [r0, #6]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     7f
    orr     r4, r2, r4
    strb    r4, [r0, #6]
7:
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     .Lspo_nf_done
    ldrb    r5, [r0, #7]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     .Lspo_nf_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    b       .Lspo_nf_done

    /* High priority - only check SPRITE bit */
.Lspo_nf_hipri:
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     10f
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_SPRITE
    bne     10f
    orr     r4, r2, r4
    strb    r4, [r0, #0]
10:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     11f
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_SPRITE
    bne     11f
    orr     r4, r2, r4
    strb    r4, [r0, #1]
11:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     12f
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_SPRITE
    bne     12f
    orr     r4, r2, r4
    strb    r4, [r0, #2]
12:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     13f
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_SPRITE
    bne     13f
    orr     r4, r2, r4
    strb    r4, [r0, #3]
13:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     14f
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_SPRITE
    bne     14f
    orr     r4, r2, r4
    strb    r4, [r0, #4]
14:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     15f
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_SPRITE
    bne     15f
    orr     r4, r2, r4
    strb    r4, [r0, #5]
15:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     16f
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_SPRITE
    bne     16f
    orr     r4, r2, r4
    strb    r4, [r0, #6]
16:
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     .Lspo_nf_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lspo_nf_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lspo_nf_done:
    pop     {r4-r6, pc}
    .size draw_pattern_nofliph_sprite_over_asm, .-draw_pattern_nofliph_sprite_over_asm


/*
 * void draw_pattern_fliph_sprite_over_asm(uint8_t* scr, uint32_t p, uint8_t attrs)
 *
 * Draw sprite over planes with horizontal flip
 */
    .global draw_pattern_fliph_sprite_over_asm
    .type draw_pattern_fliph_sprite_over_asm, %function
    .thumb_func
    .align 2
draw_pattern_fliph_sprite_over_asm:
    push    {r4-r6, lr}
    
    cmp     r1, #0
    beq     .Lspo_fh_done
    
    tst     r2, #PIXATTR_HIPRI
    bne     .Lspo_fh_hipri
    
    /* Low priority flipped */
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     20f
    ldrb    r5, [r0, #0]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     20f
    orr     r4, r2, r4
    strb    r4, [r0, #0]
20:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     21f
    ldrb    r5, [r0, #1]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     21f
    orr     r4, r2, r4
    strb    r4, [r0, #1]
21:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     22f
    ldrb    r5, [r0, #2]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     22f
    orr     r4, r2, r4
    strb    r4, [r0, #2]
22:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     23f
    ldrb    r5, [r0, #3]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     23f
    orr     r4, r2, r4
    strb    r4, [r0, #3]
23:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     24f
    ldrb    r5, [r0, #4]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     24f
    orr     r4, r2, r4
    strb    r4, [r0, #4]
24:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     25f
    ldrb    r5, [r0, #5]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     25f
    orr     r4, r2, r4
    strb    r4, [r0, #5]
25:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     26f
    ldrb    r5, [r0, #6]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     26f
    orr     r4, r2, r4
    strb    r4, [r0, #6]
26:
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     .Lspo_fh_done
    ldrb    r5, [r0, #7]
    and     r6, r5, #PIXATTR_SPRITE_HIPRI
    cmp     r6, #0
    bne     .Lspo_fh_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    b       .Lspo_fh_done

    /* High priority flipped */
.Lspo_fh_hipri:
    ubfx    r4, r1, #24, #4
    cmp     r4, #0
    beq     30f
    ldrb    r5, [r0, #0]
    tst     r5, #PIXATTR_SPRITE
    bne     30f
    orr     r4, r2, r4
    strb    r4, [r0, #0]
30:
    ubfx    r4, r1, #28, #4
    cmp     r4, #0
    beq     31f
    ldrb    r5, [r0, #1]
    tst     r5, #PIXATTR_SPRITE
    bne     31f
    orr     r4, r2, r4
    strb    r4, [r0, #1]
31:
    ubfx    r4, r1, #16, #4
    cmp     r4, #0
    beq     32f
    ldrb    r5, [r0, #2]
    tst     r5, #PIXATTR_SPRITE
    bne     32f
    orr     r4, r2, r4
    strb    r4, [r0, #2]
32:
    ubfx    r4, r1, #20, #4
    cmp     r4, #0
    beq     33f
    ldrb    r5, [r0, #3]
    tst     r5, #PIXATTR_SPRITE
    bne     33f
    orr     r4, r2, r4
    strb    r4, [r0, #3]
33:
    ubfx    r4, r1, #8, #4
    cmp     r4, #0
    beq     34f
    ldrb    r5, [r0, #4]
    tst     r5, #PIXATTR_SPRITE
    bne     34f
    orr     r4, r2, r4
    strb    r4, [r0, #4]
34:
    ubfx    r4, r1, #12, #4
    cmp     r4, #0
    beq     35f
    ldrb    r5, [r0, #5]
    tst     r5, #PIXATTR_SPRITE
    bne     35f
    orr     r4, r2, r4
    strb    r4, [r0, #5]
35:
    and     r4, r1, #0xF
    cmp     r4, #0
    beq     36f
    ldrb    r5, [r0, #6]
    tst     r5, #PIXATTR_SPRITE
    bne     36f
    orr     r4, r2, r4
    strb    r4, [r0, #6]
36:
    ubfx    r4, r1, #4, #4
    cmp     r4, #0
    beq     .Lspo_fh_done
    ldrb    r5, [r0, #7]
    tst     r5, #PIXATTR_SPRITE
    bne     .Lspo_fh_done
    orr     r4, r2, r4
    strb    r4, [r0, #7]
    
.Lspo_fh_done:
    pop     {r4-r6, pc}
    .size draw_pattern_fliph_sprite_over_asm, .-draw_pattern_fliph_sprite_over_asm

.end
