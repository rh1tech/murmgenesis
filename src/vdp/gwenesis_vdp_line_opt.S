/*
 * Optimized VDP line rendering for ARM Cortex-M33
 * Renders entire tile rows in assembly for maximum performance
 */

    .syntax unified
    .cpu cortex-m33
    .thumb

    .section .time_critical.vdp_line_opt, "ax", %progbits

/* External symbols */
    .extern VRAM

/* Constants */
    .equ PIXATTR_HIPRI, 0x80

/*
 * draw_line_b_simple_asm - Simplified Plane B renderer
 *
 * Optimized for the common case: no per-column scrolling, constant vertical scroll.
 *
 * C signature:
 *   void draw_line_b_simple_asm(uint8_t* scr, uint8_t* vram_nt, uint32_t col, uint32_t paty,
 *                               uint32_t ntw_mask, uint32_t background, uint32_t tile_count);
 *
 * Parameters (ARM calling convention):
 *   r0 = scr pointer (render_buffer + PIX_OVERFLOW - patx)
 *   r1 = VRAM pointer + nametable row offset (for fetching tile names)
 *   r2 = initial column (already masked)
 *   r3 = paty (0-7)
 *
 * Stack (after push, sp+36 is first stack arg):
 *   [sp+36] = ntw_mask
 *   [sp+40] = background color
 *   [sp+44] = tile count
 */
    .global draw_line_b_simple_asm
    .thumb_func
    .type draw_line_b_simple_asm, %function
draw_line_b_simple_asm:
    push    {r4-r11, lr}
    
    /* Load stack parameters */
    ldr     r4, [sp, #36]           @ r4 = ntw_mask
    ldr     r5, [sp, #40]           @ r5 = background
    ldr     r6, [sp, #44]           @ r6 = tile_count
    
    /* Setup registers:
     * r0 = not used after init (we use r7 for scr)
     * r1 = VRAM + nt_row_offset (for nametable access)
     * r2 = col
     * r3 = paty (overwritten, saved to r8)
     * r4 = ntw_mask
     * r5 = background
     * r6 = tile_count (loop counter)
     * r7 = scr pointer
     * r8 = paty * 4
     * r9 = 28 (for vflip: 7*4)
     * r10 = background word (bg|bg|bg|bg)
     * r11, r12, lr = scratch
     */
    mov     r7, r0                  @ r7 = scr pointer
    lsl     r8, r3, #2              @ r8 = paty * 4 for pattern offset
    mov     r9, #28                 @ r9 = 28 for vflip calc (7*4)
    
    /* Pre-calculate background word for fast fill */
    orr     r10, r5, r5, lsl #8
    orr     r10, r10, r10, lsl #16  @ r10 = bg|bg|bg|bg for 32-bit store

.Ltile_loop:
    /* Fetch tile name from nametable (big-endian 16-bit) */
    /* Address = r1 + col*2 */
    add     r11, r1, r2, lsl #1     @ r11 = nametable address
    ldrb    r3, [r11, #0]           @ high byte
    ldrb    r12, [r11, #1]          @ low byte
    orr     r11, r12, r3, lsl #8    @ r11 = name = (high << 8) | low
    
    /* Extract tile index and calculate pattern base address */
    ubfx    r12, r11, #0, #11       @ tile_index = name & 0x7FF
    lsl     r12, r12, #5            @ tile_addr = index * 32 bytes
    
    /* Handle vertical flip: pattern row = vflip ? (7-paty) : paty */
    tst     r11, #0x1000            @ test vflip bit
    ite     eq
    addeq   r12, r12, r8            @ + paty*4 (no flip)
    addne   r12, r12, r9            @ + 28 (flip: row 7)
    it      ne
    subne   r12, r12, r8            @ - paty*4 (flip: 28 - paty*4)
    
    /* Load pattern data from VRAM 
     * VRAM is an array, so =VRAM gives us the base address directly
     */
    ldr     r3, =VRAM               @ r3 = VRAM base address (array, not pointer)
    ldr     lr, [r3, r12]           @ lr = pattern data (4 bytes = 8 pixels)
    
    /* Extract attributes: palette (bits 14:13) + priority (bit 15) */
    ubfx    r12, r11, #13, #2       @ palette = (name >> 13) & 3
    lsl     r12, r12, #4            @ shift to bits 5:4 position
    tst     r11, #0x8000            @ test priority bit
    it      ne
    orrne   r12, r12, #PIXATTR_HIPRI    @ set priority flag
    
    /* Check horizontal flip */
    tst     r11, #0x0800
    bne     .Lflip
    
    /* === No horizontal flip - draw 8 pixels in order === */
    /* Pattern pixel layout (Genesis VDP):
     * Byte 0: PIX0 (bits 7:4), PIX1 (bits 3:0)
     * Byte 1: PIX2 (bits 7:4), PIX3 (bits 3:0)
     * Byte 2: PIX4 (bits 7:4), PIX5 (bits 3:0)
     * Byte 3: PIX6 (bits 7:4), PIX7 (bits 3:0)
     * In little-endian 32-bit load:
     * lr = [Byte3][Byte2][Byte1][Byte0] = bits 31:0
     * PIX0 = bits 7:4,   PIX1 = bits 3:0
     * PIX2 = bits 15:12, PIX3 = bits 11:8
     * PIX4 = bits 23:20, PIX5 = bits 19:16
     * PIX6 = bits 31:28, PIX7 = bits 27:24
     */
    
    /* Fast path: all transparent (pattern == 0) */
    cmp     lr, #0
    beq     .Lbackground
    
    /* PIX0 = bits 7:4 -> scr[0] */
    ubfx    r3, lr, #4, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #0]            @ transparent: store background
    orrne   r3, r3, r12             @ opaque: combine with attrs
    strbne  r3, [r7, #0]
    
    /* PIX1 = bits 3:0 -> scr[1] */
    ubfx    r3, lr, #0, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #1]
    orrne   r3, r3, r12
    strbne  r3, [r7, #1]
    
    /* PIX2 = bits 15:12 -> scr[2] */
    ubfx    r3, lr, #12, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #2]
    orrne   r3, r3, r12
    strbne  r3, [r7, #2]
    
    /* PIX3 = bits 11:8 -> scr[3] */
    ubfx    r3, lr, #8, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #3]
    orrne   r3, r3, r12
    strbne  r3, [r7, #3]
    
    /* PIX4 = bits 23:20 -> scr[4] */
    ubfx    r3, lr, #20, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #4]
    orrne   r3, r3, r12
    strbne  r3, [r7, #4]
    
    /* PIX5 = bits 19:16 -> scr[5] */
    ubfx    r3, lr, #16, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #5]
    orrne   r3, r3, r12
    strbne  r3, [r7, #5]
    
    /* PIX6 = bits 31:28 -> scr[6] */
    ubfx    r3, lr, #28, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #6]
    orrne   r3, r3, r12
    strbne  r3, [r7, #6]
    
    /* PIX7 = bits 27:24 -> scr[7] */
    ubfx    r3, lr, #24, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #7]
    orrne   r3, r3, r12
    strbne  r3, [r7, #7]
    
    b       .Lnext_tile

.Lbackground:
    /* Fill 8 pixels with background color using 32-bit stores */
    str     r10, [r7, #0]
    str     r10, [r7, #4]
    b       .Lnext_tile

.Lflip:
    /* === Horizontal flip - draw 8 pixels in reverse order === */
    
    /* Fast path: all transparent */
    cmp     lr, #0
    beq     .Lbackground
    
    /* PIX7 -> scr[0] */
    ubfx    r3, lr, #24, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #0]
    orrne   r3, r3, r12
    strbne  r3, [r7, #0]
    
    /* PIX6 -> scr[1] */
    ubfx    r3, lr, #28, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #1]
    orrne   r3, r3, r12
    strbne  r3, [r7, #1]
    
    /* PIX5 -> scr[2] */
    ubfx    r3, lr, #16, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #2]
    orrne   r3, r3, r12
    strbne  r3, [r7, #2]
    
    /* PIX4 -> scr[3] */
    ubfx    r3, lr, #20, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #3]
    orrne   r3, r3, r12
    strbne  r3, [r7, #3]
    
    /* PIX3 -> scr[4] */
    ubfx    r3, lr, #8, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #4]
    orrne   r3, r3, r12
    strbne  r3, [r7, #4]
    
    /* PIX2 -> scr[5] */
    ubfx    r3, lr, #12, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #5]
    orrne   r3, r3, r12
    strbne  r3, [r7, #5]
    
    /* PIX1 -> scr[6] */
    ubfx    r3, lr, #0, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #6]
    orrne   r3, r3, r12
    strbne  r3, [r7, #6]
    
    /* PIX0 -> scr[7] */
    ubfx    r3, lr, #4, #4
    cmp     r3, #0
    itee    eq
    strbeq  r5, [r7, #7]
    orrne   r3, r3, r12
    strbne  r3, [r7, #7]

.Lnext_tile:
    /* Advance to next tile */
    add     r7, r7, #8              @ scr += 8
    add     r2, r2, #1              @ col++
    and     r2, r2, r4              @ col &= ntw_mask
    subs    r6, r6, #1              @ tile_count--
    bne     .Ltile_loop
    
    pop     {r4-r11, pc}
    .size draw_line_b_simple_asm, .-draw_line_b_simple_asm

    .end
