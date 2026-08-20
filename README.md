# DolSAN

A patched AddressSanitizer runtime (forked from LLVM `compiler-rt`) for Gekko/Broadway
(GameCube/Wii PowerPC) → x86_64/aarch64 native recompilation projects, with a
shadow-memory layout that doesn't collide with the fixed low-memory address
(`0x80000000`, GameCube "MEM1") these projects need to emulate at an exact,
non-relocatable host address.

**Status: implemented and validated on x86_64 Linux.** Standalone tests pass
(`ctest`), and a real consumer (melee-pc) boots past the exact collision that
aborted stock ASan instantly. See [PLANNING.md](PLANNING.md) for the full
design rationale and [docs/integration.md](docs/integration.md) for how to
consume it, including two non-obvious requirements the design didn't
anticipate. aarch64 is unstarted (Phase 2, see PLANNING.md section 6).

Motivating project: [OpenMelee](https://github.com/T3CHNOLOG1C/OpenMelee).

## The problem, in short

Decompiled Gekko/Broadway game code has hardcoded checks like
`dest >= 0x80000000` to identify MEM1-resident pointers — logic that only
works if MEM1 is mapped at exactly `0x80000000` on the host too. But ASan's
default Linux/x86_64 shadow memory (`LowShadow`, roughly
`0x7fff8000`-`0x8fff7000`) overlaps that address, so the first real write
into MEM1 gets flagged as shadow corruption and the process aborts —
`ASAN_OPTIONS=protect_shadow_gap=0` does not fix this, since the shadow
offset is baked into `libasan.so` at the sanitizer runtime's own build time.
DolSAN relocates that offset so a declared reserved range (MEM1) falls in
ordinary instrumented memory instead of ASan's own shadow table.

## Quick start

```bash
git submodule update --init --recursive   # pulls the sparse llvm-project checkout
cmake -S . -B build -GNinja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build build
ctest --test-dir build --output-on-failure
```

This clones just `compiler-rt` + the CMake bits it needs (~50 MB, not a full
`llvm-project` checkout), applies `patches/`, builds the ASan runtime, stages
a `-resource-dir=` overlay, and runs the test suite: the offline
shadow-layout calculator, a full MEM1 mmap+write, a runtime self-check, and a
deliberate heap-buffer-overflow that must still be caught.

## Consuming DolSAN from another CMake project

```cmake
add_subdirectory(path/to/extern/dolsan dolsan-build)
target_compile_options(your_target PRIVATE ${DolSAN_ASAN_COMPILE_OPTIONS})
target_link_options(your_target PRIVATE ${DolSAN_ASAN_LINK_OPTIONS})
add_dependencies(your_target ${DolSAN_RESOURCE_DIR_TARGET})
```

Requires Clang (DolSAN's runtime is built with it; GCC's `-fsanitize=address`
uses GCC's own `libsanitizer` fork instead of `compiler-rt`, an unvalidated
combination). See [docs/integration.md](docs/integration.md) for why the
compile-options bundle matters — patching only the runtime is **not**
sufficient on its own, a real bug found during this project's own bring-up.

melee-pc's own `CMakeLists.txt` (`MELEE_PC_ASAN_BUILD` option) is the
reference integration.

## Scope: v1 "gekko" profile

DolSAN v1 supports exactly one reserved-range profile
(`cmake/DolSANGekkoProfile.cmake`): Gekko/Broadway MEM1 at
`0x80000000`-`0x8FF00000`, with the shadow offset relocated to `0x90000000`.
Configure-time gate (`cmake/CheckShadowLayout.cmake`) fails loudly, not
silently, if a change to these values would reopen the collision. A fully
general "declare any reserved range" system is explicitly out of scope until
a second, genuinely different consumer needs it — see PLANNING.md section 5.

UndefinedBehaviorSanitizer needs none of this: confirmed empirically that
both standalone `-fsanitize=undefined` and combined
`-fsanitize=address,undefined` work with zero DolSAN-specific changes (UBSan
doesn't use shadow memory at all). See docs/integration.md.

## Repo layout

```
PLANNING.md              Design rationale and validation plan (read this first)
docs/integration.md      How to consume DolSAN; the two-part offset requirement
llvm-project/             Vendored compiler-rt (sparse checkout, pinned to llvmorg-22.1.8)
patches/                  DolSAN's diffs against upstream compiler-rt, as a patch series
cmake/                    The "gekko" profile and the configure-time collision gate
scripts/                  Patch application, shadow-layout calculator, resource-dir staging
tests/                    MEM1 mmap/write, heap-overflow-still-caught, shadow self-check
CMakeLists.txt            Orchestrates all of the above into one buildable target
```

## License

Apache License 2.0 with LLVM Exceptions (matches upstream `compiler-rt`), see
[LICENSE](LICENSE).
