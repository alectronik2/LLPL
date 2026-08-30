#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    char value = 0; i64 rc = (i64)call3(5, 31, (u64)&value, 1);
    call2(2, rc < 0 ? 0 : 1, 0); for (;;) __asm__ volatile("pause");
}
