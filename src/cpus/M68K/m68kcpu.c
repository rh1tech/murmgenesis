/* ======================================================================== */
/*                            MAIN 68K CORE                                 */
/* ======================================================================== */

extern int vdp_68k_irq_ack(int int_level);

#define m68ki_cpu m68k
#define MUL (7)

/* ======================================================================== */
/* ================================ INCLUDES ============================== */
/* ======================================================================== */

#ifndef BUILD_TABLES
  #ifndef TABLES_FULL
    #include "m68ki_cycles.h"
  #else
    #include "m68ki_cycles_full.h"
  #endif
#endif

#include "m68kconf.h"
#include "m68kcpu.h"
#include "m68kops.h"
#include "gwenesis_savestate.h"

/* Enable assembly-optimized instruction handlers */
/* Disabled: 256KB jump table doesn't fit in RAM */
#define USE_ASM_INSTRUCTION_HANDLERS 0

/* Enable opcode profiling to identify hot instructions */
#define M68K_OPCODE_PROFILING 1

/* ======================================================================== */
/* ====================== OPCODE PROFILING ================================ */
/* ======================================================================== */

#if M68K_OPCODE_PROFILING

/* Track top N most frequent opcodes (compressed - only stores unique opcodes) */
#define PROFILE_TOP_N 32

typedef struct {
    uint16_t opcode;
    uint32_t count;
} opcode_profile_entry_t;

static opcode_profile_entry_t opcode_profile[PROFILE_TOP_N];
static uint32_t profile_total_count = 0;
static uint32_t profile_report_threshold = 10000000; /* Report every 10M instructions */

/* Fast inline profiler - just increment if already tracked */
void m68k_profile_opcode(uint16_t opcode) {
    profile_total_count++;
    
    /* Check if this opcode is already in our top list */
    for (int i = 0; i < PROFILE_TOP_N; i++) {
        if (opcode_profile[i].opcode == opcode) {
            opcode_profile[i].count++;
            /* Bubble up if count exceeds previous entry */
            while (i > 0 && opcode_profile[i].count > opcode_profile[i-1].count) {
                opcode_profile_entry_t tmp = opcode_profile[i];
                opcode_profile[i] = opcode_profile[i-1];
                opcode_profile[i-1] = tmp;
                i--;
            }
            return;
        }
    }
    
    /* New opcode - add to list if we have space or it would make top N */
    for (int i = 0; i < PROFILE_TOP_N; i++) {
        if (opcode_profile[i].count == 0) {
            opcode_profile[i].opcode = opcode;
            opcode_profile[i].count = 1;
            return;
        }
    }
    
    /* Replace lowest entry if this opcode might be hot */
    if (opcode_profile[PROFILE_TOP_N-1].count < 100) {
        opcode_profile[PROFILE_TOP_N-1].opcode = opcode;
        opcode_profile[PROFILE_TOP_N-1].count = 1;
    }
}

/* Print profile report */
void m68k_print_opcode_profile(void) {
    printf("\n=== M68K Opcode Profile (Top %d, total=%lu) ===\n", PROFILE_TOP_N, profile_total_count);
    for (int i = 0; i < PROFILE_TOP_N && opcode_profile[i].count > 0; i++) {
        uint16_t op = opcode_profile[i].opcode;
        uint32_t count = opcode_profile[i].count;
        float pct = (100.0f * count) / profile_total_count;
        
        /* Decode opcode type */
        const char* name = "???";
        if ((op & 0xF000) == 0x6000) {
            uint8_t cond = (op >> 8) & 0xF;
            uint8_t disp = op & 0xFF;
            const char* conds[] = {"BRA","BSR","BHI","BLS","BCC","BCS","BNE","BEQ",
                                   "BVC","BVS","BPL","BMI","BGE","BLT","BGT","BLE"};
            name = conds[cond];
            if (disp == 0) printf("%2d: %04X %-8s.W  %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
            else if (disp == 0xFF) printf("%2d: %04X %-8s.L  %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
            else printf("%2d: %04X %-8s.B  %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xC000) == 0x0000 && (op & 0xF000) != 0x0000) {
            if ((op & 0xF100) == 0x7000) name = "MOVEQ";
            else name = "imm-op";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xC000) == 0x4000) {
            if ((op & 0xFF00) == 0x4E00) {
                if (op == 0x4E71) name = "NOP";
                else if (op == 0x4E75) name = "RTS";
                else if ((op & 0xFFF0) == 0x4E60) name = "MOVE USP";
                else if ((op & 0xFFF8) == 0x4E50) name = "LINK";
                else if ((op & 0xFFF8) == 0x4E58) name = "UNLK";
                else name = "misc";
            } else if ((op & 0xFFC0) == 0x4EC0) name = "JMP";
            else if ((op & 0xFFC0) == 0x4E80) name = "JSR";
            else if ((op & 0xFF00) == 0x4200) name = "CLR.B";
            else if ((op & 0xFF00) == 0x4240) name = "CLR.W";
            else if ((op & 0xFF00) == 0x4280) name = "CLR.L";
            else if ((op & 0xF1C0) == 0x41C0) name = "LEA";
            else name = "misc";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0x2000) {
            name = "MOVE.L";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0x3000) {
            name = "MOVE.W";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0x1000) {
            name = "MOVE.B";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF100) == 0x5000) {
            name = "ADDQ";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF100) == 0x5100) {
            name = "SUBQ";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0xD000) {
            name = "ADD";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0x9000) {
            name = "SUB";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0xB000) {
            name = "CMP/EOR";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0xC000) {
            name = "AND/MUL";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0x8000) {
            name = "OR/DIV";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else if ((op & 0xF000) == 0xE000) {
            name = "SHIFT";
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        } else {
            printf("%2d: %04X %-12s %8lu (%5.2f%%)\n", i+1, op, name, count, pct);
        }
    }
    printf("================================================\n\n");
}

/* Check if we should print profile (called periodically) */
void m68k_check_profile_report(void) {
    static uint32_t last_report = 0;
    if (profile_total_count - last_report >= profile_report_threshold) {
        m68k_print_opcode_profile();
        last_report = profile_total_count;
    }
}

#endif /* M68K_OPCODE_PROFILING */

/* ======================================================================== */
/* ====================== EXPORTS FOR ASSEMBLY CORE ====================== */
/* ======================================================================== */

/* Export pointers to static tables for assembly-optimized core */
const unsigned char *m68k_cycles_table = m68ki_cycles;
void (**m68k_instruction_table)(void) = (void (**)(void))m68ki_instruction_jump_table;

/* Helper function for assembly core - fetches next instruction word */
uint16_t m68k_fetch_opcode(void) {
    REG_IR = m68ki_read_imm_16();
#if M68K_OPCODE_PROFILING
    m68k_profile_opcode(REG_IR);
#endif
    return REG_IR;
}

/* Helper function for assembly core - check and process pending interrupts */
void m68k_check_interrupts(void) {
    m68ki_check_interrupts();
}

/* ======================================================================== */
/* ================= ASSEMBLY OPTIMIZED INSTRUCTION HANDLERS ============== */
/* ======================================================================== */

#if USE_ASM_INSTRUCTION_HANDLERS

/* External assembly handlers */
extern void m68k_op_bne_8_asm(void);
extern void m68k_op_beq_8_asm(void);
extern void m68k_op_bpl_8_asm(void);
extern void m68k_op_bmi_8_asm(void);
extern void m68k_op_bcc_8_asm(void);
extern void m68k_op_bcs_8_asm(void);
extern void m68k_op_bra_8_asm(void);
extern void m68k_op_nop_asm(void);

/*
 * Small lookup table for assembly handlers
 * Maps condition code (from opcode bits 8-11) to assembly handler
 * For Bcc instructions: opcode 0110 cccc dddd dddd
 * cc = 0000 = BRA, 0001 = BSR, 0010 = BHI, 0011 = BLS
 *      0100 = BCC, 0101 = BCS, 0110 = BNE, 0111 = BEQ
 *      1010 = BPL, 1011 = BMI, etc.
 */
static void (*asm_branch_handlers[16])(void) = {
    m68k_op_bra_8_asm,  /* 0: BRA */
    NULL,               /* 1: BSR - not optimized yet */
    NULL,               /* 2: BHI */
    NULL,               /* 3: BLS */
    m68k_op_bcc_8_asm,  /* 4: BCC */
    m68k_op_bcs_8_asm,  /* 5: BCS */
    m68k_op_bne_8_asm,  /* 6: BNE */
    m68k_op_beq_8_asm,  /* 7: BEQ */
    NULL,               /* 8: BVC */
    NULL,               /* 9: BVS */
    m68k_op_bpl_8_asm,  /* A: BPL */
    m68k_op_bmi_8_asm,  /* B: BMI */
    NULL,               /* C: BGE */
    NULL,               /* D: BLT */
    NULL,               /* E: BGT */
    NULL,               /* F: BLE */
};

/*
 * Try to dispatch to assembly handler for current instruction
 * Returns 1 if handled by assembly, 0 if not
 */
int m68k_try_asm_handler(void) {
    uint16_t opcode = REG_IR;
    
    /* Check for Bcc.B instructions: 0110 cccc dddd dddd where d != 00 */
    if ((opcode & 0xF000) == 0x6000) {
        uint8_t displacement = opcode & 0xFF;
        if (displacement != 0x00 && displacement != 0xFF) {
            /* 8-bit displacement branch */
            uint8_t condition = (opcode >> 8) & 0x0F;
            void (*handler)(void) = asm_branch_handlers[condition];
            if (handler) {
                handler();
                return 1;
            }
        }
    }
    
    /* Check for NOP: 0x4E71 */
    if (opcode == 0x4E71) {
        m68k_op_nop_asm();
        return 1;
    }
    
    return 0;
}

#endif /* USE_ASM_INSTRUCTION_HANDLERS */

/* ======================================================================== */
/* ================================= DATA ================================= */
/* ======================================================================== */

#ifdef BUILD_TABLES
static unsigned char m68ki_cycles[0x10000];
#endif

static int irq_latency;

m68ki_cpu_core m68k;


/* ======================================================================== */
/* =============================== CALLBACKS ============================== */
/* ======================================================================== */

/* Default callbacks used if the callback hasn't been set yet, or if the
 * callback is set to NULL
 */

#if M68K_EMULATE_INT_ACK == OPT_ON
/* Interrupt acknowledge */
static int default_int_ack_callback(int int_level)
{
  CPU_INT_LEVEL = 0;
  return M68K_INT_ACK_AUTOVECTOR;
}
#endif

#if M68K_EMULATE_RESET == OPT_ON
/* Called when a reset instruction is executed */
static void default_reset_instr_callback(void)
{
}
#endif

#if M68K_TAS_HAS_CALLBACK == OPT_ON
/* Called when a tas instruction is executed */
static int default_tas_instr_callback(void)
{
  return 1; // allow writeback
}
#endif

#if M68K_EMULATE_FC == OPT_ON
/* Called every time there's bus activity (read/write to/from memory */
static void default_set_fc_callback(unsigned int new_fc)
{
}
#endif


/* ======================================================================== */
/* ================================= API ================================== */
/* ======================================================================== */

/* Access the internals of the CPU */
unsigned int m68k_get_reg(m68k_register_t regnum)
{
  switch(regnum)
  {
    case M68K_REG_D0:  return m68ki_cpu.dar[0];
    case M68K_REG_D1:  return m68ki_cpu.dar[1];
    case M68K_REG_D2:  return m68ki_cpu.dar[2];
    case M68K_REG_D3:  return m68ki_cpu.dar[3];
    case M68K_REG_D4:  return m68ki_cpu.dar[4];
    case M68K_REG_D5:  return m68ki_cpu.dar[5];
    case M68K_REG_D6:  return m68ki_cpu.dar[6];
    case M68K_REG_D7:  return m68ki_cpu.dar[7];
    case M68K_REG_A0:  return m68ki_cpu.dar[8];
    case M68K_REG_A1:  return m68ki_cpu.dar[9];
    case M68K_REG_A2:  return m68ki_cpu.dar[10];
    case M68K_REG_A3:  return m68ki_cpu.dar[11];
    case M68K_REG_A4:  return m68ki_cpu.dar[12];
    case M68K_REG_A5:  return m68ki_cpu.dar[13];
    case M68K_REG_A6:  return m68ki_cpu.dar[14];
    case M68K_REG_A7:  return m68ki_cpu.dar[15];
    case M68K_REG_PC:  return MASK_OUT_ABOVE_32(m68ki_cpu.pc);
    case M68K_REG_SR:  return  m68ki_cpu.t1_flag        |
                  (m68ki_cpu.s_flag << 11)              |
                   m68ki_cpu.int_mask                   |
                  ((m68ki_cpu.x_flag & XFLAG_SET) >> 4) |
                  ((m68ki_cpu.n_flag & NFLAG_SET) >> 4) |
                  ((!m68ki_cpu.not_z_flag) << 2)        |
                  ((m68ki_cpu.v_flag & VFLAG_SET) >> 6) |
                  ((m68ki_cpu.c_flag & CFLAG_SET) >> 8);
    case M68K_REG_SP:  return m68ki_cpu.dar[15];
    case M68K_REG_USP:  return m68ki_cpu.s_flag ? m68ki_cpu.sp[0] : m68ki_cpu.dar[15];
    case M68K_REG_ISP:  return m68ki_cpu.s_flag ? m68ki_cpu.dar[15] : m68ki_cpu.sp[4];
#if M68K_EMULATE_PREFETCH
    case M68K_REG_PREF_ADDR:  return m68ki_cpu.pref_addr;
    case M68K_REG_PREF_DATA:  return m68ki_cpu.pref_data;
#endif
    case M68K_REG_IR:  return m68ki_cpu.ir;
    default:      return 0;
  }
}

void m68k_set_reg(m68k_register_t regnum, unsigned int value)
{
  switch(regnum)
  {
    case M68K_REG_D0:  REG_D[0] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D1:  REG_D[1] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D2:  REG_D[2] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D3:  REG_D[3] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D4:  REG_D[4] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D5:  REG_D[5] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D6:  REG_D[6] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_D7:  REG_D[7] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A0:  REG_A[0] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A1:  REG_A[1] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A2:  REG_A[2] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A3:  REG_A[3] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A4:  REG_A[4] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A5:  REG_A[5] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A6:  REG_A[6] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_A7:  REG_A[7] = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_PC:  m68ki_jump(MASK_OUT_ABOVE_32(value)); return;
    case M68K_REG_SR:  m68ki_set_sr(value); return;
    case M68K_REG_SP:  REG_SP = MASK_OUT_ABOVE_32(value); return;
    case M68K_REG_USP:  if(FLAG_S)
                REG_USP = MASK_OUT_ABOVE_32(value);
              else
                REG_SP = MASK_OUT_ABOVE_32(value);
              return;
    case M68K_REG_ISP:  if(FLAG_S)
                REG_SP = MASK_OUT_ABOVE_32(value);
              else
                REG_ISP = MASK_OUT_ABOVE_32(value);
              return;
    case M68K_REG_IR:  REG_IR = MASK_OUT_ABOVE_16(value); return;
#if M68K_EMULATE_PREFETCH
    case M68K_REG_PREF_ADDR:  CPU_PREF_ADDR = MASK_OUT_ABOVE_32(value); return;
#endif
    default:      return;
  }
}

/* Set the callbacks */
#if M68K_EMULATE_INT_ACK == OPT_ON
void m68k_set_int_ack_callback(int  (*callback)(int int_level))
{
  CALLBACK_INT_ACK = callback ? callback : default_int_ack_callback;
}
#endif

#if M68K_EMULATE_RESET == OPT_ON
void m68k_set_reset_instr_callback(void  (*callback)(void))
{
  CALLBACK_RESET_INSTR = callback ? callback : default_reset_instr_callback;
}
#endif

#if M68K_TAS_HAS_CALLBACK == OPT_ON
void m68k_set_tas_instr_callback(int  (*callback)(void))
{
  CALLBACK_TAS_INSTR = callback ? callback : default_tas_instr_callback;
}
#endif

#if M68K_EMULATE_FC == OPT_ON
void m68k_set_fc_callback(void  (*callback)(unsigned int new_fc))
{
  CALLBACK_SET_FC = callback ? callback : default_set_fc_callback;
}
#endif

#ifdef LOGERROR

extern void error(char *format, ...);
extern uint16 v_counter;
#endif

/* ASG: rewrote so that the int_level is a mask of the IPL0/IPL1/IPL2 bits */
/* KS: Modified so that IPL* bits match with mask positions in the SR
 *     and cleaned out remenants of the interrupt controller.
 */
void m68k_update_irq(unsigned int mask)
{
  /* Update IRQ level */
  CPU_INT_LEVEL |= (mask << 8);
  
#ifdef LOGERROR
  error("[%d(%d)][%d(%d)] m68k IRQ Level = %d(0x%02x) (%x)\n", v_counter, m68k.cycles/3420, m68k.cycles, m68k.cycles%3420,CPU_INT_LEVEL>>8,FLAG_INT_MASK,m68k_get_reg(M68K_REG_PC));
#endif
}

void m68k_set_irq(unsigned int int_level)
{
  /* Set IRQ level */
  CPU_INT_LEVEL = int_level << 8;
  
#ifdef LOGERROR
  error("[%d(%d)][%d(%d)] m68k IRQ Level = %d(0x%02x) (%x)\n", v_counter, m68k.cycles/3420, m68k.cycles, m68k.cycles%3420,CPU_INT_LEVEL>>8,FLAG_INT_MASK,m68k_get_reg(M68K_REG_PC));
#endif
}

/* IRQ latency (Fatal Rewind, Sesame's Street Counting Cafe)*/
void m68k_set_irq_delay(unsigned int int_level)
{
  /* Prevent reentrance */
  if (!irq_latency)
  {
    /* This is always triggered from MOVE instructions (VDP CTRL port write) */
    /* We just make sure this is not a MOVE.L instruction as we could be in */
    /* the middle of its execution (first memory write).                   */
    if ((REG_IR & 0xF000) != 0x2000)
    {
      /* Finish executing current instruction */
      USE_CYCLES(CYC_INSTRUCTION[REG_IR]);

      /* One instruction delay before interrupt */
      irq_latency = 1;
      m68ki_trace_t1() /* auto-disable (see m68kcpu.h) */
      m68ki_use_data_space() /* auto-disable (see m68kcpu.h) */
      REG_IR = m68ki_read_imm_16();
      m68ki_instruction_jump_table[REG_IR]();
      m68ki_exception_if_trace() /* auto-disable (see m68kcpu.h) */
      irq_latency = 0;
    }

    /* Set IRQ level */
    CPU_INT_LEVEL = int_level << 8;
  }
  
#ifdef LOGERROR
  error("[%d(%d)][%d(%d)] m68k IRQ Level = %d(0x%02x) (%x)\n", v_counter, m68k.cycles/3420, m68k.cycles, m68k.cycles%3420,CPU_INT_LEVEL>>8,FLAG_INT_MASK,m68k_get_reg(M68K_REG_PC));
#endif

  /* Check interrupt mask to process IRQ  */
  m68ki_check_interrupts(); /* Level triggered (IRQ) */
}

void m68k_run(unsigned int cycles) 
{
    //  printf("m68K_run current_cycles=%d add=%d STOP=%x\n",m68k.cycles,cycles,CPU_STOPPED);

  /* Make sure CPU is not already ahead */
  if (m68k.cycles >= cycles)
  {
    return;
  }

  /* Check interrupt mask to process IRQ if needed */
  m68ki_check_interrupts();

  /* Make sure we're not stopped */
  if (CPU_STOPPED)
  {
    m68k.cycles = cycles;
    return;
  }

  /* Save end cycles count for when CPU is stopped */
  m68k.cycle_end = cycles;

  /* Return point for when we have an address error (TODO: use goto) */
  m68ki_set_address_error_trap() /* auto-disable (see m68kcpu.h) */

#ifdef LOGERROR
  error("[%d][%d] m68k run to %d cycles (%x), irq mask = %x (%x)\n", v_counter, m68k.cycles, cycles, m68k.pc,FLAG_INT_MASK, CPU_INT_LEVEL);
#endif

  while (m68k.cycles < cycles)
  {
    /* Set tracing accodring to T1. */
    m68ki_trace_t1() /* auto-disable (see m68kcpu.h) */

    /* Set the address space for reads */
    m68ki_use_data_space() /* auto-disable (see m68kcpu.h) */

#ifdef HOOK_CPU
    /* Trigger execution hook */
    if (cpu_hook)
      cpu_hook(HOOK_M68K_E, 0, REG_PC, 0);
#endif

    /* Decode next instruction */
    REG_IR = m68ki_read_imm_16();

//    printf("PC=%x IR=%x CYCLES=%d \n",m68k.pc,REG_IR,CYC_INSTRUCTION[REG_IR]);

    /* Execute instruction */
    m68ki_instruction_jump_table[REG_IR]();
    USE_CYCLES(CYC_INSTRUCTION[REG_IR]);

    /* Trace m68k_exception, if necessary */
    m68ki_exception_if_trace(); /* auto-disable (see m68kcpu.h) */
  }
}

int m68k_cycles(void)
{
  return CYC_INSTRUCTION[REG_IR];
}

int m68k_cycles_run(void)
{
	return m68k.cycle_end - m68k.cycles;
}

int m68k_cycles_master(void)
{
	return m68k.cycles;
}

void m68k_init(void)
{
#ifdef BUILD_TABLES
  static uint emulation_initialized = 0;

  /* The first call to this function initializes the opcode handler jump table */
  if(!emulation_initialized)
  {
    m68ki_build_opcode_table();
    emulation_initialized = 1;
  }
#endif

#ifdef M68K_OVERCLOCK_SHIFT
  m68k.cycle_ratio = 1 << M68K_OVERCLOCK_SHIFT;
#endif

#if M68K_EMULATE_INT_ACK == OPT_ON
  m68k_set_int_ack_callback(NULL);
#endif
#if M68K_EMULATE_RESET == OPT_ON
  m68k_set_reset_instr_callback(NULL);
#endif
#if M68K_TAS_HAS_CALLBACK == OPT_ON
  m68k_set_tas_instr_callback(NULL);
#endif
#if M68K_EMULATE_FC == OPT_ON
  m68k_set_fc_callback(NULL);
#endif
}

/* Pulse the RESET line on the CPU */
void m68k_pulse_reset(void)
{
  /* Clear all stop levels */
  CPU_STOPPED = 0;
#if M68K_EMULATE_ADDRESS_ERROR
  CPU_RUN_MODE = RUN_MODE_BERR_AERR_RESET;
#endif

  /* Turn off tracing */
  FLAG_T1 = 0;
  m68ki_clear_trace()

  /* Interrupt mask to level 7 */
  FLAG_INT_MASK = 0x0700;
  CPU_INT_LEVEL = 0;
  irq_latency = 0;

  /* Go to supervisor mode */
  m68ki_set_s_flag(SFLAG_SET);

  /* Invalidate the prefetch queue */
#if M68K_EMULATE_PREFETCH
  /* Set to arbitrary number since our first fetch is from 0 */
  CPU_PREF_ADDR = 0x1000;
#endif /* M68K_EMULATE_PREFETCH */

  /* Read the initial stack pointer and program counter */
  m68ki_jump(0);
  REG_SP = m68ki_read_imm_32();
  REG_PC = m68ki_read_imm_32();
  m68ki_jump(REG_PC);

#if M68K_EMULATE_ADDRESS_ERROR
  CPU_RUN_MODE = RUN_MODE_NORMAL;
#endif

  USE_CYCLES(CYC_EXCEPTION[EXCEPTION_RESET]);
}

void m68k_pulse_halt(void)
{
  /* Pulse the HALT line on the CPU */
  CPU_STOPPED |= STOP_LEVEL_HALT;
}

void m68k_clear_halt(void)
{
  /* Clear the HALT line on the CPU */
  CPU_STOPPED &= ~STOP_LEVEL_HALT;
}

void gwenesis_m68k_save_state() {
  SaveState *state;
  state = saveGwenesisStateOpenForWrite("m68k");
  
  saveGwenesisStateSetBuffer(state, "REG_D", REG_D, sizeof(REG_D));
  saveGwenesisStateSet(state, "SR", m68ki_get_sr());
  saveGwenesisStateSet(state, "REG_PC", REG_PC);
  saveGwenesisStateSet(state, "REG_SP", REG_SP);
  saveGwenesisStateSet(state, "REG_USP", REG_USP);
  saveGwenesisStateSet(state, "REG_ISP", REG_ISP);
  saveGwenesisStateSet(state, "REG_IR", REG_IR);

  saveGwenesisStateSet(state, "m68k_cycle_end", m68k.cycle_end);
  saveGwenesisStateSet(state, "m68k_cycles", m68k.cycles);
  saveGwenesisStateSet(state, "m68k_int_level", m68k.int_level);
  saveGwenesisStateSet(state, "m68k_stopped", m68k.stopped);
}

void gwenesis_m68k_load_state() {
  SaveState *state = saveGwenesisStateOpenForRead("m68k");
  saveGwenesisStateGetBuffer(state, "REG_D", REG_D, sizeof(REG_D));

  m68ki_set_sr(saveGwenesisStateGet(state, "SR"));
  REG_PC = saveGwenesisStateGet(state, "REG_PC");
  REG_SP = saveGwenesisStateGet(state, "REG_SP");
  REG_USP = saveGwenesisStateGet(state, "REG_USP");
  REG_ISP = saveGwenesisStateGet(state, "REG_ISP");
  REG_IR = saveGwenesisStateGet(state, "REG_IR");

  m68k.cycle_end = saveGwenesisStateGet(state, "m68k_cycle_end");
  m68k.cycles = saveGwenesisStateGet(state, "m68k_cycles");
  m68k.int_level = saveGwenesisStateGet(state, "m68k_int_level");
  m68k.stopped = saveGwenesisStateGet(state, "m68k_stopped");

}

/* ======================================================================== */
/* ============================== END OF FILE ============================= */
/* ======================================================================== */
