/*
 * ARM Assembly-optimized YM2612 FM operator calculations for RP2350
 * Optimizes the critical op_calc() and op_calc1() hot paths
 * 
 * These functions are called 24 times per sample (4 operators x 6 channels)
 * at ~53kHz sample rate = ~1.3 million calls per second
 */

.syntax unified
.cpu cortex-m33
.thumb

.section .time_critical.ym2612_opt, "ax"

/* External symbols - lookup tables */
.extern sin_tab
.extern tl_tab

/* Constants */
.equ SIN_BITS, 10
.equ SIN_MASK, 0x3FF           /* (1 << SIN_BITS) - 1 = 1023 */
.equ TL_TAB_LEN, 6656          /* 13 * 2 * 256 */

/*
 * signed int op_calc(UINT32 phase, unsigned int env, unsigned int pm)
 * 
 * FM operator calculation with phase modulation
 * 
 * Input:
 *   r0 = phase (UINT32)
 *   r1 = env (unsigned int) - envelope value
 *   r2 = pm (unsigned int) - phase modulation
 * 
 * Output:
 *   r0 = signed int result from tl_tab, or 0 if p >= TL_TAB_LEN
 *
 * C equivalent:
 *   UINT32 p = (env<<3) + sin_tab[ ( (phase >> SIN_BITS) + (pm >> 1) ) & SIN_MASK ];
 *   if (p >= TL_TAB_LEN) return 0;
 *   return tl_tab[p];
 */
.global op_calc
.type op_calc, %function
.thumb_func
op_calc:
    /* r0=phase, r1=env, r2=pm */
    
    /* Calculate sin_tab index: ((phase >> SIN_BITS) + (pm >> 1)) & SIN_MASK */
    lsr     r0, r0, #SIN_BITS       /* phase >> 10 */
    add     r0, r0, r2, lsr #1      /* + (pm >> 1) */
    movw    r3, #SIN_MASK
    and     r0, r0, r3              /* & 0x3FF */
    
    /* Load sin_tab[index] */
    ldr     r3, =sin_tab
    ldr     r0, [r3, r0, lsl #2]    /* sin_tab[index] (4 bytes per entry) */
    
    /* Calculate p = (env << 3) + sin_tab[index] */
    add     r0, r0, r1, lsl #3      /* p = sin_val + (env << 3) */
    
    /* Check if p >= TL_TAB_LEN */
    movw    r3, #TL_TAB_LEN
    cmp     r0, r3
    bhs     .Lop_calc_zero
    
    /* Return tl_tab[p] */
    ldr     r3, =tl_tab
    ldr     r0, [r3, r0, lsl #2]    /* tl_tab[p] (4 bytes per entry) */
    bx      lr

.Lop_calc_zero:
    movs    r0, #0
    bx      lr

.size op_calc, . - op_calc


/*
 * signed int op_calc1(UINT32 phase, unsigned int env, unsigned int pm)
 * 
 * FM operator calculation for SLOT1 with feedback (different PM calculation)
 * 
 * Input:
 *   r0 = phase (UINT32)
 *   r1 = env (unsigned int) - envelope value
 *   r2 = pm (unsigned int) - phase modulation (feedback)
 * 
 * Output:
 *   r0 = signed int result from tl_tab, or 0 if p >= TL_TAB_LEN
 *
 * C equivalent:
 *   UINT32 p = (env<<3) + sin_tab[ ( (phase + pm) >> SIN_BITS ) & SIN_MASK ];
 *   if (p >= TL_TAB_LEN) return 0;
 *   return tl_tab[p];
 */
.global op_calc1
.type op_calc1, %function
.thumb_func
op_calc1:
    /* r0=phase, r1=env, r2=pm */
    
    /* Calculate sin_tab index: ((phase + pm) >> SIN_BITS) & SIN_MASK */
    add     r0, r0, r2              /* phase + pm */
    lsr     r0, r0, #SIN_BITS       /* >> 10 */
    movw    r3, #SIN_MASK
    and     r0, r0, r3              /* & 0x3FF */
    
    /* Load sin_tab[index] */
    ldr     r3, =sin_tab
    ldr     r0, [r3, r0, lsl #2]    /* sin_tab[index] */
    
    /* Calculate p = (env << 3) + sin_tab[index] */
    add     r0, r0, r1, lsl #3      /* p = sin_val + (env << 3) */
    
    /* Check if p >= TL_TAB_LEN */
    movw    r3, #TL_TAB_LEN
    cmp     r0, r3
    bhs     .Lop_calc1_zero
    
    /* Return tl_tab[p] */
    ldr     r3, =tl_tab
    ldr     r0, [r3, r0, lsl #2]    /* tl_tab[p] */
    bx      lr

.Lop_calc1_zero:
    movs    r0, #0
    bx      lr

.size op_calc1, . - op_calc1

.end
