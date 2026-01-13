/*
 * Z80 In-Game Benchmark Implementation
 */

#include "z80_benchmark.h"

#if Z80_BENCHMARK

#include <stdio.h>
#include "pico/stdlib.h"

/* Global benchmark stats */
Z80BenchmarkStats z80_bench_stats;

/* Core name - set by the z80inst*.c file that includes this */
#ifdef USE_Z80_GPX
static const char *z80_core_name = "GPX";
#else
static const char *z80_core_name = "OLD";
#endif

void z80_benchmark_init(void) {
    z80_bench_stats.total_time_us = 0;
    z80_bench_stats.total_cycles = 0;
    z80_bench_stats.call_count = 0;
    z80_bench_stats.frame_count = 0;
}

uint64_t z80_benchmark_get_time_us(void) {
    return time_us_64();
}

uint64_t z80_benchmark_start(void) {
    return time_us_64();
}

void z80_benchmark_end(uint64_t start_time, int cycles_executed) {
    uint64_t end_time = time_us_64();
    z80_bench_stats.total_time_us += (end_time - start_time);
    z80_bench_stats.total_cycles += cycles_executed;
    z80_bench_stats.call_count++;
}

void z80_benchmark_frame_end(void) {
    z80_bench_stats.frame_count++;
    
    if (z80_bench_stats.frame_count >= Z80_BENCHMARK_INTERVAL) {
        /* Calculate statistics */
        double time_ms = (double)z80_bench_stats.total_time_us / 1000.0;
        double time_per_frame_us = (double)z80_bench_stats.total_time_us / (double)z80_bench_stats.frame_count;
        double effective_mhz = 0.0;
        
        if (z80_bench_stats.total_time_us > 0) {
            effective_mhz = (double)z80_bench_stats.total_cycles / (double)z80_bench_stats.total_time_us;
        }
        
        double cycles_per_frame = (double)z80_bench_stats.total_cycles / (double)z80_bench_stats.frame_count;
        double calls_per_frame = (double)z80_bench_stats.call_count / (double)z80_bench_stats.frame_count;
        
        printf("\n=== Z80 Benchmark (%s core) ===\n", z80_core_name);
        printf("  Frames: %lu\n", (unsigned long)z80_bench_stats.frame_count);
        printf("  Total Z80 time: %.2f ms (%.1f us/frame)\n", time_ms, time_per_frame_us);
        printf("  Total cycles: %llu (%.0f/frame)\n", 
               (unsigned long long)z80_bench_stats.total_cycles, cycles_per_frame);
        printf("  Calls: %lu (%.1f/frame)\n", 
               (unsigned long)z80_bench_stats.call_count, calls_per_frame);
        printf("  Effective speed: %.2f MHz\n", effective_mhz);
        printf("  Frame budget used: %.2f%%\n", (time_per_frame_us / 16666.67) * 100.0);
        printf("================================\n\n");
        
        /* Reset for next interval */
        z80_bench_stats.total_time_us = 0;
        z80_bench_stats.total_cycles = 0;
        z80_bench_stats.call_count = 0;
        z80_bench_stats.frame_count = 0;
    }
}

#endif /* Z80_BENCHMARK */
