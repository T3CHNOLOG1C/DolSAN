# DolSAN v1 supports exactly one reserved-range profile: "gekko" -- the
# Gekko/Broadway (GameCube/Wii) fixed MEM1 address, 0x80000000. Do not
# generalize this into a fully parameterized system until a second consumer
# with a genuinely different reserved range actually exists (PLANNING.md
# section 5 explicitly scopes v1 to a single hardcoded, documented profile).

set(DOLSAN_PROFILE "gekko" CACHE STRING
    "DolSAN reserved-range profile (only 'gekko' is supported in v1)")
set_property(CACHE DOLSAN_PROFILE PROPERTY STRINGS gekko)

if(NOT DOLSAN_PROFILE STREQUAL "gekko")
    message(FATAL_ERROR "DolSAN v1 only supports DOLSAN_PROFILE=gekko (got '${DOLSAN_PROFILE}')")
endif()

# Fixed by real GameCube/Wii hardware convention (decompiled game code has
# hardcoded `dest >= 0x80000000` checks) -- do not change for the gekko
# profile. See extern/aurora/lib/dolphin/os/OSMemory.cpp's AllocMEM1.
set(DOLSAN_RESERVED_RANGE_START "0x80000000" CACHE STRING
    "Gekko/Broadway MEM1 base address (fixed, do not change)")

# melee-pc's current mem1Size default is 96 MiB (0x80000000-0x86000000,
# src/melee_main.c). mem1Size is a runtime-configurable uint32_t, so this
# gives ~255 MiB of headroom above today's value rather than tying the
# reserved range to today's exact size.
#
# Deliberately NOT equal to DOLSAN_SHADOW_OFFSET: confirmed empirically
# (tests/test_mem1_mmap_write.c originally failed with mmap EEXIST at this
# boundary) that asan_shadow_setup.cpp's InitializeShadowMemory() reserves
# one extra mmap-granularity guard page immediately *below* LowShadow
# (`shadow_start -= GetMmapGranularity()`) that isn't documented in
# asan_mapping.h's LowMem/LowShadow comment and isn't actually free for the
# consumer to use, even though the formula alone implies it is. 1 MiB of
# margin comfortably clears that (and any larger guard on a future LLVM
# version) without eating meaningfully into the headroom above.
set(DOLSAN_RESERVED_RANGE_END "0x8FF00000" CACHE STRING
    "Upper bound the computed shadow layout must clear")

# New ASan SHADOW_OFFSET (compiler-rt/lib/asan/asan_mapping.h,
# ASAN_SHADOW_OFFSET_CONST, x86_64 Linux branch -- see
# patches/0001-dolsan-shadow-offset.patch). Since LowMem is defined as
# everything below SHADOW_OFFSET, this must be comfortably >=
# DOLSAN_RESERVED_RANGE_END (see the guard-page note above -- do not set it
# exactly equal) for the reserved range to land in ordinary LowMem instead
# of LowShadow/ShadowGap -- enforced by cmake/CheckShadowLayout.cmake.
set(DOLSAN_SHADOW_OFFSET "0x90000000" CACHE STRING
    "New ASan SHADOW_OFFSET; must be comfortably >= DOLSAN_RESERVED_RANGE_END")
