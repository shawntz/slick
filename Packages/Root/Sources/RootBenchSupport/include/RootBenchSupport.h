#pragma once
#include <stdint.h>

// Bench support for root search: counts heap allocations made by the calling thread, through
// libmalloc's malloc_logger hook, and reads the calling thread's CPU time. For the bench only;
// never link it into the app.

// Starts counting allocations made by the calling thread.
void root_bench_alloc_begin(void);

// Stops counting and returns the allocations made by the thread that called begin.
uint64_t root_bench_alloc_end(void);

// CPU time of the calling thread in nanoseconds.
uint64_t root_bench_thread_cpu_ns(void);
