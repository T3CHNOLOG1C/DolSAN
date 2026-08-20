#!/usr/bin/env python3
"""Standalone validator for DolSAN's ASan shadow-offset choice.

Reimplements ASan's Linux/x86_64 shadow-mapping formula independently of
compiler-rt so a candidate SHADOW_OFFSET can be checked against a reserved
address range *before* touching (or even cloning) the real compiler-rt
source. Both the offline check here and DolSAN's CMake configure-time gate
(cmake/CheckShadowLayout.cmake) call this same script, so there is exactly
one implementation of the formula to keep correct.

Formula (compiler-rt/lib/asan/asan_mapping.h, x86_64 Linux "Default" mapping):
    shadow(addr) = (addr >> 3) + SHADOW_OFFSET
    LowMem    = [0, SHADOW_OFFSET)
    LowShadow = [SHADOW_OFFSET, SHADOW_OFFSET + (SHADOW_OFFSET >> 3))
    ShadowGap = [end(LowShadow), start(HighShadow))
    HighShadow/HighMem cover the top of the 47-bit address space and are
    unaffected by SHADOW_OFFSET, so they are not modeled here.
"""

import argparse
import sys

# Top of the default 47-bit Linux x86_64 user address space ASan assumes.
KHIGH_MEM_END = (1 << 47) - 1


def parse_addr(s):
    return int(s, 0)


def compute_layout(shadow_offset):
    low_mem_end = shadow_offset
    low_shadow_start = shadow_offset
    low_shadow_end = shadow_offset + (shadow_offset >> 3)
    # ShadowGap runs from the end of LowShadow up to where HighShadow starts;
    # HighShadow covers shadow(KHIGH_MEM_END), so ShadowGap's end is
    # shadow(low_mem_end_of_high_mem) -- approximated here as the shadow of
    # the low end of HighMem, which for the default mapping is derived the
    # same way LowShadow was. We only need ShadowGap's *start* to check
    # overlap against a low reserved range, since a low reserved range can
    # never reach into HighShadow/HighMem.
    return {
        "low_mem": (0, low_mem_end),
        "low_shadow": (low_shadow_start, low_shadow_end),
        "shadow_gap_start": low_shadow_end,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--reserved-start", type=parse_addr, required=True)
    ap.add_argument("--reserved-end", type=parse_addr, required=True)
    ap.add_argument("--shadow-offset", type=parse_addr, required=True)
    args = ap.parse_args()

    if args.reserved_end <= args.reserved_start:
        print(f"error: reserved range is empty or inverted "
              f"(start={args.reserved_start:#x} end={args.reserved_end:#x})",
              file=sys.stderr)
        return 2

    layout = compute_layout(args.shadow_offset)
    low_mem_start, low_mem_end = layout["low_mem"]
    low_shadow_start, low_shadow_end = layout["low_shadow"]

    print(f"SHADOW_OFFSET     = {args.shadow_offset:#x}")
    print(f"LowMem            = [{low_mem_start:#x}, {low_mem_end:#x})")
    print(f"LowShadow         = [{low_shadow_start:#x}, {low_shadow_end:#x})")
    print(f"ShadowGap starts  = {layout['shadow_gap_start']:#x}")
    print(f"Reserved range    = [{args.reserved_start:#x}, {args.reserved_end:#x})")

    # The reserved range is only safe if it sits entirely inside LowMem,
    # i.e. entirely below SHADOW_OFFSET. If it dips into LowShadow/ShadowGap,
    # the very first real write into it will be flagged as shadow corruption
    # (this is exactly the failure this project exists to fix).
    if args.reserved_end > low_mem_start and args.reserved_start < low_mem_end:
        if args.reserved_end <= low_mem_end:
            print("OK: reserved range is fully contained in LowMem.")
            return 0

    print("FAIL: reserved range is NOT fully contained in LowMem -- it "
          "overlaps LowShadow/ShadowGap under this SHADOW_OFFSET.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
