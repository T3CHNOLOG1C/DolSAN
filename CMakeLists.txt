cmake_minimum_required(VERSION 3.25)
project(DolSAN LANGUAGES NONE)

# DolSAN builds a patched AddressSanitizer runtime (forked from LLVM
# compiler-rt) whose shadow-memory layout doesn't collide with a fixed,
# consumer-declared address range -- see PLANNING.md for the full story.
#
# Two independent things must agree on the relocated shadow offset for this
# to actually work, and both are handled here so a consumer never has to
# get this right by hand:
#   1. compiler-rt's *runtime* (ASAN_SHADOW_OFFSET_CONST, patched by
#      patches/0001-dolsan-shadow-offset.patch) -- governs where the
#      allocator/redzone poisoning actually happens.
#   2. Clang's *instrumentation codegen* for every ASan-instrumented TU
#      (-mllvm -asan-mapping-offset=...) -- governs where the inline shadow
#      checks compiled into consumer code look. This is a *separate* LLVM
#      knob from the runtime and is easy to miss: patching only the runtime
#      builds and links fine and the MEM1 mmap/write no longer aborts, but
#      real heap-buffer-overflow bugs silently go uncaught (confirmed live
#      during this project's own bring-up -- see tests/test_heap_overflow_still_caught.c,
#      which fails loudly if this flag is ever dropped from the bundle
#      below).
#
# DolSAN_ASAN_COMPILE_OPTIONS/DolSAN_ASAN_LINK_OPTIONS bundle everything a
# consumer needs so both stay in sync by construction.

option(DOLSAN_BUILD_TESTS "Build DolSAN's own standalone test suite" ON)

if(NOT CMAKE_C_COMPILER)
    set(CMAKE_C_COMPILER clang)
endif()
if(NOT CMAKE_CXX_COMPILER)
    set(CMAKE_CXX_COMPILER clang++)
endif()

include(cmake/DolSANGekkoProfile.cmake)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
include(cmake/CheckShadowLayout.cmake)

# --- Step 1: patch series must be applied before compiler-rt configures ---
add_custom_target(dolsan_apply_patches ALL
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/apply-patches.sh"
    COMMENT "DolSAN: applying patch series to vendored compiler-rt"
    VERBATIM)

# --- Step 2: build compiler-rt's asan target as a nested, independent
# CMake project (ExternalProject) rather than add_subdirectory() -- keeps
# compiler-rt's own project()/compiler-detection machinery fully isolated
# from whatever CMakeLists included this one (e.g. melee-pc's), and matches
# the exact standalone configure this project validated by hand
# (PLANNING.md Phase 3). ---
include(ExternalProject)

set(DOLSAN_COMPILER_RT_SRC "${CMAKE_CURRENT_SOURCE_DIR}/llvm-project/compiler-rt")
set(DOLSAN_COMPILER_RT_BUILD "${CMAKE_CURRENT_BINARY_DIR}/compiler-rt-build")

ExternalProject_Add(dolsan_compiler_rt
    SOURCE_DIR "${DOLSAN_COMPILER_RT_SRC}"
    BINARY_DIR "${DOLSAN_COMPILER_RT_BUILD}"
    DEPENDS dolsan_apply_patches
    CMAKE_ARGS
        -DCMAKE_C_COMPILER=clang
        -DCMAKE_CXX_COMPILER=clang++
        -DCMAKE_C_COMPILER_TARGET=x86_64-pc-linux-gnu
        -DCMAKE_CXX_COMPILER_TARGET=x86_64-pc-linux-gnu
        -DCMAKE_BUILD_TYPE=Release
        -DCOMPILER_RT_BUILD_STANDALONE=ON
        -DLLVM_CMAKE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/llvm-project/llvm/cmake/modules
        -DCOMPILER_RT_BUILD_SANITIZERS=ON
        -DCOMPILER_RT_BUILD_BUILTINS=OFF
        -DCOMPILER_RT_BUILD_XRAY=OFF
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
        -DCOMPILER_RT_BUILD_PROFILE=OFF
        -DCOMPILER_RT_BUILD_MEMPROF=OFF
        -DCOMPILER_RT_BUILD_ORC=OFF
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
        -DCMAKE_C_FLAGS=-DDOLSAN_SHADOW_OFFSET=${DOLSAN_SHADOW_OFFSET}ULL
        -DCMAKE_CXX_FLAGS=-DDOLSAN_SHADOW_OFFSET=${DOLSAN_SHADOW_OFFSET}ULL
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target asan
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS
        "${DOLSAN_COMPILER_RT_BUILD}/lib/linux/libclang_rt.asan-x86_64.a"
        "${DOLSAN_COMPILER_RT_BUILD}/lib/linux/libclang_rt.asan-x86_64.so"
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE)

# --- Step 3: stage a resource-dir overlay (system resource dir + our asan
# files on top) that consumers point -resource-dir= at. ---
set(DolSAN_RESOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/resource-dir")

add_custom_command(
    OUTPUT "${DolSAN_RESOURCE_DIR}/.stamp"
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build_resource_dir.sh"
            clang "${DOLSAN_COMPILER_RT_BUILD}" "${DolSAN_RESOURCE_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${DolSAN_RESOURCE_DIR}/.stamp"
    DEPENDS dolsan_compiler_rt
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build_resource_dir.sh"
    COMMENT "DolSAN: staging resource-dir overlay"
    VERBATIM)

add_custom_target(dolsan_resource_dir ALL DEPENDS "${DolSAN_RESOURCE_DIR}/.stamp")

# --- Exported flag bundle -- see the file-level comment above for why both
# halves are required together. ---
set(DolSAN_ASAN_COMPILE_OPTIONS
    -fsanitize=address
    -mllvm -asan-mapping-offset=${DOLSAN_SHADOW_OFFSET}
    -resource-dir=${DolSAN_RESOURCE_DIR})
set(DolSAN_ASAN_LINK_OPTIONS
    -fsanitize=address
    -resource-dir=${DolSAN_RESOURCE_DIR})

# Propagate to whichever project add_subdirectory()'d us (e.g. melee-pc).
get_directory_property(_dolsan_has_parent PARENT_DIRECTORY)
if(_dolsan_has_parent)
    set(DolSAN_RESOURCE_DIR "${DolSAN_RESOURCE_DIR}" PARENT_SCOPE)
    set(DolSAN_ASAN_COMPILE_OPTIONS "${DolSAN_ASAN_COMPILE_OPTIONS}" PARENT_SCOPE)
    set(DolSAN_ASAN_LINK_OPTIONS "${DolSAN_ASAN_LINK_OPTIONS}" PARENT_SCOPE)
    set(DolSAN_RESOURCE_DIR_TARGET dolsan_resource_dir PARENT_SCOPE)
endif()

if(DOLSAN_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
