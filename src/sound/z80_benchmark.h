/*
 * Z80 In-Game Benchmark
 * 
 * Enable Z80_BENCHMARK to measure Z80 execution performance during gameplay.
 * Results are printed every Z80_BENCHMARK_INTERVAL frames.
 */

#ifndef Z80_BENCHMARK_H
#define Z80_BENCHMARK_H

#include <stdint.h>

/* Set to 1 to enable Z80 benchmarking */
#define Z80_BENCHMARK 1

/* Print results every N frames */
#define Z80_BENCHMARK_INTERVAL 300

#if Z80_BENCHMARK

/* Benchmark statistics */
typedef struct {
    uint64_t total_time_us;      /* Total time spent in Z80 execution (microseconds) */
    uint64_t total_cycles;       /* Total Z80 cycles executed */
    uint32_t call_count;         /* Number of z80_run calls */
    uint32_t frame_count;        /* Frame counter for interval reporting */
} Z80BenchmarkStats;

extern Z80BenchmarkStats z80_bench_stats;

/* Initialize benchmark stats */
void z80_benchmark_init(void);

/* Start timing a Z80 execution block */
uint64_t z80_benchmark_start(void);

/* End timing and accumulate stats */
void z80_benchmark_end(uint64_t start_time, int cycles_executed);

/* Check if it's time to report and print stats */
void z80_benchmark_frame_end(void);

/* Get current time in microseconds */
uint64_t z80_benchmark_get_time_us(void);

#else

/* No-op macros when benchmarking is disabled */
#define z80_benchmark_init()
#define z80_benchmark_start() (0)
#define z80_benchmark_end(start, cycles)
#define z80_benchmark_frame_end()

#endif /* Z80_BENCHMARK */

#endif /* Z80_BENCHMARK_H */
