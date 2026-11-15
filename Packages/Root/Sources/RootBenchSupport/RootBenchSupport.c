#include "RootBenchSupport.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <time.h>

typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
// Exported by libsystem_malloc; not in the public headers.
extern malloc_logger_t *malloc_logger;

#define MALLOC_LOG_TYPE_ALLOCATE 2u

static _Atomic uint64_t allocations;
static pthread_t counted_thread;

static void count_allocation(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result,
                             uint32_t skip) {
    (void)a1;
    (void)a2;
    (void)a3;
    (void)result;
    (void)skip;
    if ((type & MALLOC_LOG_TYPE_ALLOCATE) && pthread_equal(pthread_self(), counted_thread)) {
        atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    }
}

void root_bench_alloc_begin(void) {
    counted_thread = pthread_self();
    atomic_store(&allocations, 0);
    malloc_logger = count_allocation;
}

uint64_t root_bench_alloc_end(void) {
    malloc_logger = NULL;
    return atomic_load(&allocations);
}

uint64_t root_bench_thread_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
