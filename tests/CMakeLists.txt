# DolSAN's own standalone test suite (PLANNING.md section 8, step 1) --
# proves the built runtime works in isolation before melee-pc ever links
# against it.

enable_language(C)

# Fast, no-build-required gate: re-run the same calculator used at
# configure time (cmake/CheckShadowLayout.cmake already ran it once and
# would have failed the configure if it disagreed, but registering it here
# too means `ctest` alone reproduces the full gate sequence).
add_test(
    NAME shadow_layout_calculator
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/verify_shadow_layout.py"
            --reserved-start "${DOLSAN_RESERVED_RANGE_START}"
            --reserved-end   "${DOLSAN_RESERVED_RANGE_END}"
            --shadow-offset  "${DOLSAN_SHADOW_OFFSET}")

set(DOLSAN_TEST_PROFILE_DEFS
    "DOLSAN_RESERVED_RANGE_START=${DOLSAN_RESERVED_RANGE_START}UL"
    "DOLSAN_RESERVED_RANGE_END=${DOLSAN_RESERVED_RANGE_END}UL"
    "DOLSAN_SHADOW_OFFSET=${DOLSAN_SHADOW_OFFSET}UL")

function(dolsan_add_asan_test name source)
    add_executable(${name} ${source})
    add_dependencies(${name} dolsan_resource_dir)
    target_compile_definitions(${name} PRIVATE ${DOLSAN_TEST_PROFILE_DEFS})
    # The exact flag bundle a real consumer (melee-pc) must use -- see
    # CMakeLists.txt's file-level comment for why both the runtime patch
    # and the -mllvm codegen flag are required together.
    target_compile_options(${name} PRIVATE ${DolSAN_ASAN_COMPILE_OPTIONS} -g -O0)
    target_link_options(${name} PRIVATE ${DolSAN_ASAN_LINK_OPTIONS})
    add_test(NAME ${name} COMMAND ${name})
endfunction()

dolsan_add_asan_test(test_mem1_mmap_write test_mem1_mmap_write.c)

dolsan_add_asan_test(test_shadow_layout_selfcheck test_shadow_layout_selfcheck.c)

# This one is EXPECTED to abort with ASan's heap-buffer-overflow report --
# ctest passes when the process exits non-zero AND the report is present,
# fails if it exits 0 (the exact silent-sanitizer regression this project
# hit during its own bring-up).
dolsan_add_asan_test(test_heap_overflow_still_caught test_heap_overflow_still_caught.c)
set_tests_properties(test_heap_overflow_still_caught PROPERTIES
    PASS_REGULAR_EXPRESSION "AddressSanitizer: heap-buffer-overflow")
