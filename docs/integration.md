# Integrating DolSAN

DolSAN builds a patched AddressSanitizer runtime whose shadow-memory layout
doesn't collide with a fixed, consumer-declared address range (v1: the
Gekko/Broadway "gekko" profile, `0x80000000`-`0x8FF00000`, see
`cmake/DolSANGekkoProfile.cmake`). This document covers how to consume it
from a CMake project; melee-pc's own top-level `CMakeLists.txt`
(`MELEE_PC_ASAN_BUILD` option) is the reference integration.

## The two things that must stay in sync

Getting a working DolSAN-linked binary requires **two** independent pieces
to agree on the relocated shadow offset, not one:

1. **The runtime** (`compiler-rt`'s `ASAN_SHADOW_OFFSET_CONST`, patched by
   `patches/0001-dolsan-shadow-offset.patch`) -- governs where the
   allocator actually poisons redzones/shadow memory.
2. **Clang's instrumentation codegen** for every ASan-instrumented
   translation unit -- a separate LLVM concern from the runtime, controlled
   by `-mllvm -asan-mapping-offset=<offset>`. This governs where the
   *inline* shadow checks compiled into your code look.

This split isn't obvious and is easy to get wrong: linking only against
DolSAN's patched runtime (without the `-mllvm` flag) builds and links fine,
and the MEM1 mmap/write collision is genuinely gone -- but real
heap-buffer-overflow bugs silently stop being caught, because the inline
checks your own code was compiled with still use the *default* offset and
look at the wrong shadow bytes. This was confirmed live during DolSAN's own
bring-up (see `tests/test_heap_overflow_still_caught.c`, which exists
specifically to catch a regression here) before the fix was in place.

**Always use the exported flag bundle, never assemble these by hand:**

```cmake
add_subdirectory(path/to/extern/dolsan dolsan-build)

target_compile_options(your_target PRIVATE ${DolSAN_ASAN_COMPILE_OPTIONS})
target_link_options(your_target PRIVATE ${DolSAN_ASAN_LINK_OPTIONS})
add_dependencies(your_target ${DolSAN_RESOURCE_DIR_TARGET})
```

`DolSAN_ASAN_COMPILE_OPTIONS` bundles `-fsanitize=address`, the `-mllvm
-asan-mapping-offset=...` codegen flag, and `-resource-dir=...` together so
they can't drift apart. Only translation units that are themselves
compiled with `-fsanitize=address` need this bundle -- code that links into
the same binary without being instrumented doesn't need the `-mllvm` flag
(it emits no inline shadow checks to get wrong), it just needs to end up in
the same final link as the instrumented code and the DolSAN runtime.

## Toolchain requirement: Clang only

DolSAN's runtime is built from LLVM `compiler-rt` with Clang. GCC's
`-fsanitize=address` uses GCC's own `libsanitizer` (a periodically-resynced
fork of the same sanitizer code, not compiler-rt itself) -- mixing
GCC-instrumented objects with DolSAN's Clang/compiler-rt-built runtime is
not a validated combination. Configure your build directory with
`-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++`. melee-pc's
integration enforces this with a `FATAL_ERROR` if the configured compiler
isn't Clang, rather than silently building something unvalidated.

## Reserved range: why it's not flush against the shadow offset

`cmake/DolSANGekkoProfile.cmake` sets `DOLSAN_RESERVED_RANGE_END`
(`0x8FF00000`) about 1 MiB below `DOLSAN_SHADOW_OFFSET` (`0x90000000`),
not equal to it. This is a real, empirically-confirmed constraint, not
overcaution: `compiler-rt/lib/asan/asan_shadow_setup.cpp`'s
`InitializeShadowMemory()` reserves one extra mmap-granularity guard page
immediately below `LowShadow` (`shadow_start -= GetMmapGranularity()`)
that `asan_mapping.h`'s own `LowMem`/`LowShadow` documentation doesn't
mention and that isn't actually free for a consumer to use, even though
the documented formula alone implies the entirety of `[0, SHADOW_OFFSET)`
is available. `tests/test_mem1_mmap_write.c` originally failed with `mmap`
`EEXIST` at exactly this boundary before the margin was added -- see that
test and `cmake/DolSANGekkoProfile.cmake`'s comments for the full story.
If you change `DOLSAN_SHADOW_OFFSET` or the reserved range, keep a margin
of at least one page (more, to be safe against a larger guard on a future
LLVM version) between them, and re-run
`scripts/verify_shadow_layout.py` plus `tests/test_mem1_mmap_write.c`
to confirm.

## UndefinedBehaviorSanitizer

PLANNING.md flagged UBSan as a secondary target, guessing it "doesn't use
shadow memory the same way and may already work." Verified empirically
(both checks use the exact `AllocMEM1`-style MEM1 mmap+write from
`tests/test_mem1_mmap_write.c`, plus a deliberate signed-integer-overflow
to confirm real bugs are still caught):

- **Standalone UBSan** (`-fsanitize=undefined`, no `address`): works today
  with the *unpatched system runtime*, no DolSAN changes needed. UBSan's
  inline checks call `__ubsan_handle_*` directly with no shadow-memory
  model at all, so there's nothing for a fixed low address like
  `0x80000000` to collide with. melee-pc's existing `MELEE_PC_UBSAN_BUILD`
  option is unaffected by anything in this project.
- **Combined `-fsanitize=address,undefined`**: works with DolSAN's
  *existing* build, no separate compiler-rt target or additional patching
  required -- building compiler-rt's `asan` target already produces the
  `RTUbsan`/`RTUbsan_cxx` objects a combined build needs, and they're
  UBSan's ordinary shadow-memory-free checks layered on top of ASan's
  (already-relocated) allocator. Use the same `DolSAN_ASAN_COMPILE_OPTIONS`
  bundle and add `,undefined` to its `-fsanitize=` flag if a consumer wants
  both together; melee-pc currently keeps `MELEE_PC_ASAN_BUILD` and
  `MELEE_PC_UBSAN_BUILD` as separate, non-combined build variants
  (CMakeLists.txt), so this isn't wired up as a build option today, just
  confirmed to work if someone wants it.

## melee-pc's integration, concretely

- `CMakeLists.txt`'s `MELEE_PC_ASAN_BUILD` option `add_subdirectory`s
  `extern/dolsan`, applies the flag bundle to the `melee-pc` target only
  (matching the pre-DolSAN behavior of only instrumenting that target, not
  `aurora_os`), and requires Clang.
- `extern/aurora/lib/dolphin/os/OSMemory.cpp`'s `AllocMEM1` gets a new
  `MELEE_PC_DOLSAN_BUILD`-gated branch using `MAP_FIXED_NOREPLACE` (safe
  once DolSAN's shadow no longer covers `0x80000000`, and preferred over
  plain `MAP_FIXED` because it fails loudly on a real, unexpected
  collision instead of silently unmapping something). The older
  `__SANITIZE_ADDRESS__`/`MELEE_PC_ASAN_BUILD` branch (plain `MAP_FIXED`,
  the pre-DolSAN workaround) is kept for anyone building `aurora_os` with
  plain system `-fsanitize=address` directly, outside melee-pc's own CMake
  plumbing -- that path still hits the real collision this project exists
  to fix (see `pc_port.md` entries (219)/(272)), it's just not deleted
  outright.
- Build in a dedicated directory (e.g. `build-dolsan-asan/`), not a reuse
  of the older GCC-configured `build-asan/`.

```bash
cmake -S . -B build-dolsan-asan -GNinja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DMELEE_PC_ASAN_BUILD=ON
cmake --build build-dolsan-asan
./build-dolsan-asan/melee-pc
```
