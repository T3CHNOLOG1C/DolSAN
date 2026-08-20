// Confirms DolSAN's relocated shadow offset didn't accidentally build a
// disabled sanitizer: a deliberate heap-buffer-overflow must still abort
// with ASan's standard report. This is also a regression test for a real
// bug found during this project's own bring-up: patching only
// compiler-rt's runtime SHADOW_OFFSET builds fine and fixes the MEM1
// collision, but silently stops catching real bugs, because Clang's
// instrumentation codegen (a separate LLVM concern from the runtime) still
// emits inline shadow checks using the *default* offset unless every
// ASan-instrumented TU is also compiled with
// `-mllvm -asan-mapping-offset=<DOLSAN_SHADOW_OFFSET>`. See
// CMakeLists.txt's DolSAN_ASAN_COMPILE_OPTIONS, which bundles both, and
// tests/CMakeLists.txt, which builds this test with that exact bundle.
#include <stdlib.h>

int main(void) {
    volatile char *buf = malloc(16);
    buf[20] = 'A'; // deliberate heap-buffer-overflow
    free((void *) buf);
    return 0;
}
