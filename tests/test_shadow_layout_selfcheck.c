// Confirms the *actual compiled artifact* matches
// scripts/verify_shadow_layout.py's offline prediction -- not just that the
// source patch looks right. Two independent checks:
//   1. The runtime's effective offset (exposed via the public
//      __asan_shadow_memory_dynamic_address interface symbol, which
//      asan_shadow_setup.cpp's InitializeShadowMemory() always populates
//      with the active shadow_start, const-offset builds included) equals
//      DOLSAN_SHADOW_OFFSET.
//   2. Sample addresses across the whole reserved range report as
//      unpoisoned/ordinary memory (__asan_region_is_poisoned), i.e. they
//      fall in LowMem rather than LowShadow/ShadowGap.
#include <stdio.h>

#include "dolsan_test_profile.h"

extern unsigned long __asan_shadow_memory_dynamic_address;
extern void *__asan_region_is_poisoned(void *beg, unsigned long size);

static int check_unpoisoned(unsigned long addr, const char *label) {
    void *poisoned = __asan_region_is_poisoned((void *) addr, 8);
    if (poisoned != 0) {
        fprintf(stderr, "FAIL: %s (%#lx) reports poisoned at %p -- it should be "
                        "ordinary LowMem, not shadow/gap\n", label, addr, poisoned);
        return 1;
    }
    printf("OK: %s (%#lx) is unpoisoned ordinary memory\n", label, addr);
    return 0;
}

int main(void) {
    int failures = 0;

    if (__asan_shadow_memory_dynamic_address != DOLSAN_SHADOW_OFFSET) {
        fprintf(stderr,
                "FAIL: runtime's effective shadow offset is %#lx, expected "
                "DOLSAN_SHADOW_OFFSET=%#lx -- the compiled compiler-rt artifact "
                "does not match the patch/profile\n",
                __asan_shadow_memory_dynamic_address, (unsigned long) DOLSAN_SHADOW_OFFSET);
        failures++;
    } else {
        printf("OK: runtime effective shadow offset == DOLSAN_SHADOW_OFFSET (%#lx)\n",
               (unsigned long) DOLSAN_SHADOW_OFFSET);
    }

    unsigned long start = DOLSAN_RESERVED_RANGE_START;
    unsigned long end = DOLSAN_RESERVED_RANGE_END;
    unsigned long mid = start + (end - start) / 2;

    failures += check_unpoisoned(start, "reserved range start");
    failures += check_unpoisoned(mid, "reserved range midpoint");
    failures += check_unpoisoned(end - 8, "reserved range end - 8");

    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("All shadow-layout self-checks passed\n");
    return 0;
}
