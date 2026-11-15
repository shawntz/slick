#pragma once
#include <stdint.h>

// Counts heap allocations made by the calling thread, through libmalloc's malloc_logger hook (the
// hook MallocStackLogging uses). For benchmarks and tests only; never link it into the app.

// Starts counting allocations made by the calling thread.
void bench_alloc_count_begin(void);

// Stops counting and returns the allocations made by the thread that called begin.
uint64_t bench_alloc_count_end(void);

// A monotonic clock in nanoseconds.
uint64_t bench_now_ns(void);
