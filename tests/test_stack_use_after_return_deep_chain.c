// Isolated A/B repro for the real melee-pc stack-use-after-return false
// positive. Root-caused (this session) to os_alloc_compat.c's
// heapTrace()/check_bogus_size()/inline alloc-tracer pattern: small,
// address-taken `bt[N]` locals (fed to backtrace()) inside functions that
// are called extremely frequently from the allocator hot path, each
// guarded by an early `if (!enabled) return;` that skips writing to `bt`
// on essentially every call. ASan's "does this function need a fake
// stack" decision is static (any address-taken local anywhere in the
// function forces it), so this pattern produces very high-frequency,
// same-size-class fake-stack allocate/free churn on a single thread even
// though the array is almost never actually touched.
//
// This file has two entry points, selected by argv[1]:
//   "clean" -- a background thread calls several small helper functions in
//              a tight loop, each with an address-taken local array (via
//              backtrace()) and an early-return guard that's taken on
//              (almost) every call -- matching the real pattern exactly.
//              No real bug. MUST exit 0 with no ASan report.
//   "buggy" -- unchanged real stack-use-after-return sanity check: a
//              function returns a pointer to its own local, the caller
//              dereferences it after return. MUST still abort with a real
//              report -- proves detection isn't just globally disabled.
//
// See tests/CMakeLists.txt for how this is run (looped, high iteration
// count -- this pattern may not reproduce on every single call).
#include <execinfo.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ITERATIONS 200000

static volatile int g_enabled_but_always_false = 0; // never set -- matches
                                                      // real code's getenv()
                                                      // gate defaulting off

// ---- "clean" path: matches os_alloc_compat.c's real functions ----

__attribute__((noinline)) static void heap_trace_like(void) {
    void *bt[12];
    if (!g_enabled_but_always_false) {
        return;
    }
    int n = backtrace(bt, 12);
    backtrace_symbols_fd(bt, n, 2);
}

__attribute__((noinline)) static void check_bogus_size_like(unsigned size) {
    void *bt[32];
    if (!g_enabled_but_always_false) {
        return;
    }
    int n = backtrace(bt, 32);
    backtrace_symbols_fd(bt, n, 2);
    (void) size;
}

__attribute__((noinline)) static void alloc_1k_tracer_like(void) {
    if (g_enabled_but_always_false) {
        void *bt[16];
        int n = backtrace(bt, 16);
        backtrace_symbols_fd(bt, n, 2);
    }
}

// Mirrors OSAllocFromHeap/OSFreeToHeap calling these tracer helpers on
// every single allocation -- the actual hot-path shape.
__attribute__((noinline)) static void *fake_alloc(unsigned size) {
    heap_trace_like();
    check_bogus_size_like(size);
    alloc_1k_tracer_like();
    return malloc(size > 0 ? size : 1);
}

static void *clean_thread_main(void *arg) {
    (void) arg;
    for (int i = 0; i < ITERATIONS; i++) {
        void *p = fake_alloc((unsigned) (16 + (i % 64)));
        free(p);
    }
    return NULL;
}

// ---- "buggy" path: a real stack-use-after-return (unchanged) ----

static volatile unsigned char *g_stale_ptr;

__attribute__((noinline)) static void escape_local_pointer(void) {
    unsigned char local[64];
    memset((void *) local, 0xAB, sizeof(local));
    g_stale_ptr = local; // deliberately escapes -- the bug
}

__attribute__((noinline)) static void disturb_stack(void) {
    unsigned char filler[256];
    memset(filler, 0, sizeof(filler));
}

static void *buggy_thread_main(void *arg) {
    (void) arg;
    escape_local_pointer();
    disturb_stack();
    unsigned char v = g_stale_ptr[0];
    printf("buggy: read stale value %u (should not reach here)\n", v);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "clean") != 0 && strcmp(argv[1], "buggy") != 0)) {
        fprintf(stderr, "usage: %s clean|buggy\n", argv[0]);
        return 2;
    }

    pthread_t t;
    void *(*entry)(void *) = (strcmp(argv[1], "clean") == 0) ? clean_thread_main : buggy_thread_main;
    if (pthread_create(&t, NULL, entry, NULL) != 0) {
        perror("pthread_create");
        return 1;
    }
    pthread_join(t, NULL);

    printf("%s: completed without a false report\n", argv[1]);
    return 0;
}
