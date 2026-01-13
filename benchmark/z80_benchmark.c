/*
 * Z80 CPU Core Benchmark
 * 
 * This benchmark measures the performance of Z80 CPU emulation cores.
 * Build with OLD or GPX Z80 core using -DZ80_CORE=OLD or -DZ80_CORE=GPX
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* Determine which Z80 core we're using */
#ifdef USE_Z80_GPX
  #include "z80_gpx.h"
  #define Z80_CORE_NAME "Genesis-Plus-GX (GPX)"
#else
  #include "Z80.h"
  #define Z80_CORE_NAME "Original (Marat Fayzullin)"
#endif

/* Test RAM */
#define Z80_RAM_SIZE 0x2000
static uint8_t test_ram[Z80_RAM_SIZE];

/* Cycle counters */
static uint64_t total_cycles = 0;

#ifdef USE_Z80_GPX
/* GPX Z80 memory access callbacks */
static uint8_t bench_readmem(uint16_t addr) {
    return test_ram[addr & (Z80_RAM_SIZE - 1)];
}

static void bench_writemem(uint16_t addr, uint8_t val) {
    test_ram[addr & (Z80_RAM_SIZE - 1)] = val;
}

static uint8_t bench_readport(uint16_t port) {
    (void)port;
    return 0xFF;
}

static void bench_writeport(uint16_t port, uint8_t val) {
    (void)port;
    (void)val;
}

static int bench_irqcallback(int irq) {
    (void)irq;
    return 0xFF; /* RST 38h */
}

#else
/* Original Z80 core callbacks */
Z80 cpu;

void WrZ80(register word Addr, register byte Value) {
    test_ram[Addr & (Z80_RAM_SIZE - 1)] = Value;
}

byte RdZ80(register word Addr) {
    return test_ram[Addr & (Z80_RAM_SIZE - 1)];
}

void OutZ80(register word Port, register byte Value) {
    (void)Port;
    (void)Value;
}

byte InZ80(register word Port) {
    (void)Port;
    return 0xFF;
}

word LoopZ80(register Z80 *R) {
    (void)R;
    return INT_NONE;
}

void PatchZ80(register Z80 *R) {
    (void)R;
}

#endif

/* Test programs - various instruction patterns */

/* Test 1: Simple loop with 8-bit arithmetic */
static const uint8_t test_arith8[] = {
    0x3E, 0x00,       /* LD A, 0 */
    0x06, 0x00,       /* LD B, 0 */
    /* loop: */
    0x80,             /* ADD A, B */
    0x04,             /* INC B */
    0x10, 0xFC,       /* DJNZ loop (-4) */
    0x18, 0xF6,       /* JR -10 (back to LD A, 0) */
};

/* Test 2: 16-bit arithmetic and memory access */
static const uint8_t test_arith16[] = {
    0x21, 0x00, 0x10, /* LD HL, 0x1000 */
    0x01, 0x01, 0x00, /* LD BC, 1 */
    /* loop: */
    0x36, 0xAA,       /* LD (HL), 0xAA */
    0x7E,             /* LD A, (HL) */
    0x23,             /* INC HL */
    0x0B,             /* DEC BC */
    0x78,             /* LD A, B */
    0xB1,             /* OR C */
    0x20, 0xF6,       /* JR NZ, loop */
    0x18, 0xEE,       /* JR back to start */
};

/* Test 3: Stack operations */
static const uint8_t test_stack[] = {
    0x31, 0x00, 0x1F, /* LD SP, 0x1F00 */
    0x21, 0x34, 0x12, /* LD HL, 0x1234 */
    0x11, 0x78, 0x56, /* LD DE, 0x5678 */
    0x01, 0x00, 0x01, /* LD BC, 256 */
    /* loop: */
    0xE5,             /* PUSH HL */
    0xD5,             /* PUSH DE */
    0xD1,             /* POP DE */
    0xE1,             /* POP HL */
    0x23,             /* INC HL */
    0x13,             /* INC DE */
    0x0B,             /* DEC BC */
    0x78,             /* LD A, B */
    0xB1,             /* OR C */
    0x20, 0xF4,       /* JR NZ, loop */
    0x18, 0xE8,       /* JR back to start */
};

/* Test 4: Bit operations */
static const uint8_t test_bits[] = {
    0x3E, 0xFF,       /* LD A, 0xFF */
    0x06, 0x08,       /* LD B, 8 */
    /* loop: */
    0xCB, 0x3F,       /* SRL A */
    0xCB, 0x47,       /* BIT 0, A */
    0xCB, 0xC7,       /* SET 0, A */
    0xCB, 0x87,       /* RES 0, A */
    0x10, 0xF6,       /* DJNZ loop */
    0x18, 0xF0,       /* JR back to start */
};

/* Test 5: Block operations */
static const uint8_t test_block[] = {
    0x21, 0x00, 0x10, /* LD HL, 0x1000 */
    0x11, 0x00, 0x11, /* LD DE, 0x1100 */
    0x01, 0x00, 0x01, /* LD BC, 256 */
    0xED, 0xB0,       /* LDIR */
    0x21, 0x00, 0x11, /* LD HL, 0x1100 */
    0x01, 0x00, 0x01, /* LD BC, 256 */
    0x3E, 0x55,       /* LD A, 0x55 */
    0xED, 0xB1,       /* CPIR */
    0x18, 0xEB,       /* JR back to start */
};

typedef struct {
    const char *name;
    const uint8_t *code;
    size_t size;
} TestProgram;

static TestProgram tests[] = {
    { "8-bit Arithmetic", test_arith8, sizeof(test_arith8) },
    { "16-bit Arithmetic + Memory", test_arith16, sizeof(test_arith16) },
    { "Stack Operations", test_stack, sizeof(test_stack) },
    { "Bit Operations", test_bits, sizeof(test_bits) },
    { "Block Operations", test_block, sizeof(test_block) },
};

#define NUM_TESTS (sizeof(tests) / sizeof(tests[0]))

/* Get current time in microseconds */
static uint64_t get_time_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

/* Run a single benchmark */
static void run_benchmark(int test_idx, uint64_t cycles_to_run) {
    TestProgram *test = &tests[test_idx];
    
    /* Clear RAM and load test program at address 0 */
    memset(test_ram, 0, Z80_RAM_SIZE);
    memcpy(test_ram, test->code, test->size);
    
#ifdef USE_Z80_GPX
    /* Initialize GPX Z80 */
    z80_gpx_init(NULL, bench_irqcallback);
    z80_gpx_set_mem_handlers(bench_readmem, bench_writemem);
    z80_gpx_set_port_handlers(bench_readport, bench_writeport);
    z80_gpx_reset();
#else
    /* Initialize original Z80 */
    memset(&cpu, 0, sizeof(cpu));
    cpu.IPeriod = 1;
    cpu.ICount = 0;
    cpu.Trace = 0;
    cpu.Trap = 0x0009;
    ResetZ80(&cpu);
#endif
    
    printf("  Test: %-30s ", test->name);
    fflush(stdout);
    
    uint64_t start_time = get_time_us();
    uint64_t cycles_done = 0;
    
    /* Run in chunks */
    const int chunk_size = 10000;
    while (cycles_done < cycles_to_run) {
        int to_run = (cycles_to_run - cycles_done > chunk_size) ? 
                      chunk_size : (int)(cycles_to_run - cycles_done);
        
#ifdef USE_Z80_GPX
        z80_gpx_run(to_run);
        cycles_done += to_run;
#else
        int executed = ExecZ80(&cpu, to_run);
        cycles_done += (to_run - executed);
        if (executed > 0) cycles_done += executed; /* Handle negative returns */
#endif
    }
    
    uint64_t end_time = get_time_us();
    uint64_t elapsed_us = end_time - start_time;
    
    double mhz = (double)cycles_done / (double)elapsed_us;
    double ms = (double)elapsed_us / 1000.0;
    
    printf("%8.2f ms, %6.2f MHz effective\n", ms, mhz);
    
    total_cycles += cycles_done;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    
    printf("===========================================\n");
    printf("  Z80 CPU Core Benchmark\n");
    printf("  Core: %s\n", Z80_CORE_NAME);
    printf("===========================================\n\n");
    
    /* Number of Z80 cycles to run per test */
    const uint64_t cycles_per_test = 10000000; /* 10 million cycles */
    
    printf("Running %zu tests, %llu cycles each...\n\n", 
           NUM_TESTS, (unsigned long long)cycles_per_test);
    
    uint64_t total_start = get_time_us();
    
    for (size_t i = 0; i < NUM_TESTS; i++) {
        run_benchmark(i, cycles_per_test);
    }
    
    uint64_t total_end = get_time_us();
    uint64_t total_elapsed = total_end - total_start;
    
    printf("\n-------------------------------------------\n");
    printf("Total: %llu cycles in %.2f ms\n", 
           (unsigned long long)total_cycles,
           (double)total_elapsed / 1000.0);
    printf("Overall: %.2f MHz effective\n", 
           (double)total_cycles / (double)total_elapsed);
    printf("===========================================\n");
    
    return 0;
}
