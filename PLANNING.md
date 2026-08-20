# DolSAN — Planning Document

**Status:** Planning only. Nothing has been implemented yet. This document is written for
whichever agent/engineer picks up implementation next — it assumes no prior context beyond
what's written here.

## 1. Problem statement

Native recompilation projects that port Gekko/Broadway (GameCube/Wii PowerPC) games to
x86_64/aarch64 (e.g. [melee-pc](https://github.com/T3CHNOLOG1C/OpenMelee), and presumably
others in this space — Metroid Prime, Zelda, etc.) commonly need to emulate the console's
fixed low-memory region (GameCube "MEM1") at a **specific, non-negotiable host address**.

This isn't a stylistic choice. Decompiled game code frequently contains hardcoded checks
like `if (dest >= 0x80000000)` to distinguish "this is a MEM1-resident pointer" from
everything else (ARAM, other memory spaces) — logic that only produces correct behavior if
MEM1 is mapped at exactly `0x80000000` on the host too. Moving it breaks gameplay-critical
code paths, not just cosmetics. (melee-pc confirmed this the hard way — an earlier attempt
to map MEM1 at `0x20000000` instead silently broke DMA routing for archive/asset loads.
See `extern/aurora/lib/dolphin/os/OSMemory.cpp` in the melee-pc tree for the full story.)

**The collision:** AddressSanitizer's shadow memory isn't just a "reserved gap" you can
route around with `ASAN_OPTIONS`. On Linux x86_64, ASan's default memory layout is roughly:

```
LowMem:    [0x000000000000, 0x00007fff7fff]
LowShadow: [0x00007fff8000, 0x00008fff6fff]   <-- overlaps 0x80000000!
ShadowGap: [0x00008fff7000, 0x0002008fff6fff]
HighShadow:[...]
HighMem:   [...]
```

`0x80000000` (2 GiB) falls squarely inside `LowShadow`. The very first real write into that
address range (in melee-pc's case, a crash-handler alt-stack `memset` during early boot)
gets flagged by ASan's own instrumentation as "you just wrote into my shadow memory" and the
process aborts — confirmed live, not theoretical. `ASAN_OPTIONS=protect_shadow_gap=0` does
**not** help: that option only stops ASan from `mprotect`-ing the separate `ShadowGap`
region, and has no effect on `LowShadow` itself.

This isn't fixable at the application level. The shadow offset formula
(`shadow_addr = (app_addr >> 3) + offset`) has its `offset` baked into `libasan.so`/
`libsanitizer` at the sanitizer runtime's own **build time** (`kDefaultShadowOffset64` in
compiler-rt, or the equivalent in GCC's libsanitizer fork of the same code) — not something
an env var, linker flag, or `__asan_*` weak symbol override can change at the target
application's build or run time.

**The fix has to be a custom-built sanitizer runtime with a different shadow offset** — one
chosen so its shadow regions don't overlap whatever fixed low-memory range the target game's
console architecture needs (`0x80000000`-`0x82000000` for GameCube/Wii MEM1, with headroom
for larger MEM1 sizes some ports may configure).

## 2. Goal

Build **DolSAN**: a sanitizer runtime (starting with AddressSanitizer; UndefinedBehaviorSanitizer
is a secondary target since it doesn't use shadow memory the same way and may already work —
verify this early, it may not need any of DolSAN's changes at all) forked from upstream LLVM
`compiler-rt`, with a **relocated, and ideally configurable, shadow memory layout** that
avoids the Gekko/Broadway fixed-MEM1 address range — packaged so it's trivially reusable as a
git submodule by melee-pc *and* by other, currently-unwritten or unknown, Gekko/Broadway
recompilation projects with the same architectural constraint.

Non-goals (explicitly out of scope unless a later phase decides otherwise):
- Supporting non-Gekko/Broadway recompilation projects with unrelated memory layouts.
- A general-purpose "configure any shadow offset for any purpose" tool — the config surface
  should be scoped to "where does your emulated console memory live," not arbitrary.
- Windows support (melee-pc and likely peer projects target Linux/macOS primarily; revisit
  if a real consumer needs it).

## 3. Why fork compiler-rt (LLVM) rather than GCC's libsanitizer

melee-pc's toolchain on the reference dev machine is GCC 16.1.1, whose `libsanitizer` is
itself a periodically-resynced fork of LLVM compiler-rt's sanitizer runtimes — so the actual
shadow-mapping logic to patch is nearly identical either way. Prefer basing DolSAN on
**upstream LLVM compiler-rt** specifically because:

- It's more standalone-buildable. GCC's `libsanitizer` is nested inside the full GCC source
  tree and its build system assumes it's part of a full GCC bootstrap; compiler-rt has a
  documented standalone build path (`-DCOMPILER_RT_BUILD_STANDALONE=ON` or building it as
  part of an LLVM checkout with `-DLLVM_ENABLE_RUNTIMES=compiler-rt`).
- Consuming projects aren't guaranteed to use GCC. A compiler-rt-based ASan can be linked
  with GCC (`-fsanitize=address` accepts a custom runtime path via linker flags) or Clang.
- Upstream LLVM has better multi-arch (x86_64 *and* aarch64) support already factored into
  the same codebase, which matters for section 6 below.

Verify this reasoning against the actual consuming toolchains before committing — if it
turns out melee-pc (and peer projects) are hard-committed to GCC specifically and linking a
Clang/LLVM-built runtime against GCC-compiled objects proves troublesome in practice, revisit
and consider forking GCC's `libsanitizer` instead. Don't take this section as unquestionable;
it's the current best guess, not a locked-in decision.

## 4. Where the actual patch goes (research starting point, not verified against source yet)

In LLVM compiler-rt, the x86_64 Linux ASan shadow offset is defined in
`compiler-rt/lib/asan/asan_mapping.h`, typically as a constant like:

```cpp
#  define SHADOW_OFFSET (0x7fff8000ULL)   // kDefaultShadowOffset64, exact name/value varies by LLVM version
```

The task: choose a **new** offset such that the resulting `LowShadow`/`HighShadow`/`ShadowGap`
regions it produces don't cover `0x80000000`–`0x82000000` (MEM1, with margin for larger
configured sizes — check `aurora::g_config.mem1Size` in melee-pc for the actual configurable
range, don't hardcode melee-pc's current default blindly), **and** don't break ASan's other
invariants (shadow regions still need to cover the addresses real allocations, stack, and
heap actually land at on this host/OS; verify against `/proc/self/maps` for typical Linux
x86_64 process layouts, not just eyeball it).

This requires:
1. Reading `compiler-rt/lib/sanitizer_common/sanitizer_platform.h` and `asan_mapping.h` for
   whichever LLVM version is targeted, to understand the *actual* current formula (the values
   sketched above are illustrative from general knowledge, not verified against a specific
   LLVM version's source — check before trusting them).
2. Computing a candidate offset, then **validating** it doesn't overlap MEM1's range using
   the same math ASan itself uses (write a small standalone calculator/test, don't just trust
   arithmetic done by hand).
3. Building a test ASan runtime with the new offset and confirming empirically (a trivial
   test program that `mmap(MAP_FIXED)`s the MEM1 range, like melee-pc's own
   `OSMemory.cpp:AllocMEM1` does, then writes to it) that it no longer aborts.

## 5. Reuse mechanism (how other projects consume this)

Design target: a consuming project (melee-pc first, others later) adds DolSAN as a git
submodule, points its build at DolSAN's built runtime instead of the system `libasan`, and
declares its emulated-memory address range via a small config surface — a CMake option or a
header the consumer defines before DolSAN's headers are included, e.g.:

```cmake
set(DOLSAN_RESERVED_RANGES "0x80000000-0x82000000" CACHE STRING
    "Address ranges DolSAN's shadow layout must not overlap (typically the console's emulated fixed-address memory)")
```

DolSAN's build should **fail loudly** at configure time if the computed shadow layout
overlaps a declared reserved range, rather than silently producing a broken runtime — this
is the whole point of the project; a silent collision is worse than the current "just don't
use ASan" status quo, since it'd produce misleading crash reports.

Exact mechanism (compile-time constant vs. a small set of pre-validated named profiles vs.
fully parameterized) is an open design decision for whoever implements this — pick whichever
is simplest to get right and correctly validated first; a fully general parameterized
offset is nice-to-have, not required for v1. A single hardcoded, well-documented "gekko"
profile covering the `0x80000000`-range case is a legitimate, sufficient v1 if it ships
correctly and is clearly labeled as the only supported profile so far.

## 6. Architecture scope: x86_64 now, aarch64 planned

**Phase 1 (x86_64 Linux):** the immediate, concrete need — melee-pc's dev environment is
x86_64 Linux. Get this working and validated first.

**Phase 2 (aarch64):** flagged as a real future need because Gekko/Broadway recompilation
projects have an obvious audience on Apple Silicon (macOS/aarch64) and ARM Linux, and ASan's
default aarch64 shadow layout has its own, different collision risk that needs independent
research — don't assume the x86_64 fix transfers directly. `sanitizer_platform.h` has
separate aarch64 shadow constants; research those specifically when this phase starts,
they are NOT the same formula/values as x86_64.

Don't attempt phase 2 in the same pass as phase 1 unless phase 1 is fully done and validated
first — get one architecture right and proven before generalizing.

## 7. Suggested repo structure (starting point, adjust as needed)

```
DolSAN/
  PLANNING.md              (this file)
  README.md                (short pointer to PLANNING.md + build/usage once it exists)
  LICENSE                  (match compiler-rt's upstream license — Apache 2.0 with LLVM
                             exceptions — do not pick an incompatible license)
  compiler-rt/              (submodule or subtree of llvm-project's compiler-rt, or a
                             fork thereof, pinned to a specific LLVM release tag)
  patches/                  (the actual DolSAN diffs against upstream compiler-rt, kept as
                             a clean patch series so rebasing onto newer LLVM releases stays
                             tractable — do NOT hand-edit the vendored compiler-rt tree
                             directly without also maintaining a patch file)
  cmake/                    (build integration: how a consumer links against DolSAN's
                             runtime instead of the system one)
  tests/                    (the MEM1-mmap-and-write smoke test from section 4.3, plus
                             any shadow-layout collision self-checks)
  docs/
    integration.md          (how melee-pc, specifically, should consume this once it exists)
```

## 8. Validation plan before calling this "done" for a consumer

1. Standalone: DolSAN's own test suite (section 7's `tests/`) passes — MEM1-range mmap +
   write doesn't trigger a false shadow-corruption abort, and DolSAN still catches *real*
   memory errors (a deliberate heap-buffer-overflow test case should still be caught —
   don't accidentally build a sanitizer that's silently disabled everywhere).
2. Integration: melee-pc links against DolSAN instead of system ASan, boots successfully
   past the crash-handler setup that aborted with stock ASan (see this session's
   `melee_pc_asan_ubsan_mem1_collision` finding for the exact repro), and can run a full
   soak (boot -> match -> results) without a false-positive abort.
3. Real bug-finding: run DolSAN against melee-pc's known, currently-undiagnosed stage-switch
   heap-corruption bug (see melee-pc's pc_port.md entry 272 and the
   `melee_pc_stage_switch_corruption` memory note) and confirm it produces a useful,
   accurate report — this is the actual motivating use case, not just "doesn't crash on
   boot."

## 9. Context for why this project exists (for whoever picks this up cold)

This was scoped out of a live debugging session on melee-pc (2026-08-20), while chasing a
real, still-unfixed heap-corruption bug: any Melee stage crashes (at varying, inconsistent
crash sites — a heap-corruption signature) when loaded as the *second* stage in a play
session, but works fine as the first. Plain-gdb backtraces got several *other*, unrelated
bugs fixed that same session, but weren't enough to pin down this one — a sanitizer would
directly show the corrupting write instead of the much-later crash it causes. ASan was the
obvious tool, and turned out to be unusable as-is for exactly the reason this document
describes. DolSAN is the fix for that gap, scoped to be useful beyond just this one bug.
