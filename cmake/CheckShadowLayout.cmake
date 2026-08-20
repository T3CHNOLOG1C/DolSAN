# Configure-time gate: fail loudly if the reserved range (DolSANGekkoProfile)
# overlaps the shadow layout computed for the chosen SHADOW_OFFSET. A silent
# collision here is worse than no ASan at all -- it would produce a runtime
# that *looks* built but aborts (or worse, misreports) on the very memory it
# exists to protect. See PLANNING.md section 5.
#
# Shells out to scripts/verify_shadow_layout.py rather than reimplementing
# the shadow(addr) formula in CMake's own math() (finicky/version-dependent
# hex handling) -- this way there is exactly one implementation, used both
# here and for offline validation, so they can't drift apart.

find_package(Python3 REQUIRED COMPONENTS Interpreter)

execute_process(
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/verify_shadow_layout.py"
            --reserved-start "${DOLSAN_RESERVED_RANGE_START}"
            --reserved-end   "${DOLSAN_RESERVED_RANGE_END}"
            --shadow-offset  "${DOLSAN_SHADOW_OFFSET}"
    RESULT_VARIABLE _dolsan_layout_rc
    OUTPUT_VARIABLE _dolsan_layout_report
    ERROR_VARIABLE  _dolsan_layout_error)

message(STATUS "DolSAN shadow-layout check:\n${_dolsan_layout_report}")

if(NOT _dolsan_layout_rc EQUAL 0)
    message(FATAL_ERROR
        "DolSAN shadow-layout check FAILED: reserved range "
        "${DOLSAN_RESERVED_RANGE_START}-${DOLSAN_RESERVED_RANGE_END} overlaps the "
        "shadow region computed for DOLSAN_SHADOW_OFFSET=${DOLSAN_SHADOW_OFFSET}.\n"
        "${_dolsan_layout_error}\n"
        "Raise DOLSAN_SHADOW_OFFSET or shrink DOLSAN_RESERVED_RANGE_END and reconfigure.")
endif()
