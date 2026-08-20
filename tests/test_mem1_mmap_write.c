// Mirrors extern/aurora/lib/dolphin/os/OSMemory.cpp's AllocMEM1 exactly:
// mmap the Gekko/Broadway MEM1 base at a fixed address and write across the
// whole reserved range, including right at its boundaries. Must not trigger
// a false ASan shadow-corruption abort -- this is the collision DolSAN
// exists to fix (see PLANNING.md and the (272) pc_port.md entry).
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "dolsan_test_profile.h"

int main(void) {
    size_t size = DOLSAN_RESERVED_RANGE_END - DOLSAN_RESERVED_RANGE_START;
    void *addr = (void *) DOLSAN_RESERVED_RANGE_START;

    void *result = mmap(addr, size, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (result == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    if (result != addr) {
        fprintf(stderr, "mmap landed at %p, expected exactly %p\n", result, addr);
        return 1;
    }

    unsigned char *bytes = (unsigned char *) result;
    // Boundary bytes specifically: the very first byte of the range and the
    // very last byte before DOLSAN_RESERVED_RANGE_END.
    bytes[0] = 0xAA;
    bytes[size - 1] = 0xBB;
    // Full-range write, mirroring hsd_80393DA0's boot-time memset -- the
    // actual first real write into MEM1 that aborts under stock ASan.
    memset(result, 0x55, size);

    if (bytes[0] != 0x55 || bytes[size - 1] != 0x55) {
        fprintf(stderr, "readback mismatch after memset\n");
        return 1;
    }

    printf("OK: mmap+write across [%#lx, %#lx) survived\n",
           DOLSAN_RESERVED_RANGE_START, DOLSAN_RESERVED_RANGE_END);
    return 0;
}
