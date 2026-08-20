// Shared constants for DolSAN's test suite, kept in sync with
// cmake/DolSANGekkoProfile.cmake via -D defines passed at compile time
// (tests/CMakeLists.txt). Not meant to be installed/consumed outside
// tests/.
#ifndef DOLSAN_TEST_PROFILE_H
#define DOLSAN_TEST_PROFILE_H

#ifndef DOLSAN_RESERVED_RANGE_START
#error "DOLSAN_RESERVED_RANGE_START must be defined by the build (see tests/CMakeLists.txt)"
#endif
#ifndef DOLSAN_RESERVED_RANGE_END
#error "DOLSAN_RESERVED_RANGE_END must be defined by the build (see tests/CMakeLists.txt)"
#endif
#ifndef DOLSAN_SHADOW_OFFSET
#error "DOLSAN_SHADOW_OFFSET must be defined by the build (see tests/CMakeLists.txt)"
#endif

#endif // DOLSAN_TEST_PROFILE_H
