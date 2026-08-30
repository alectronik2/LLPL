#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    static const char value = 'I';
    i64 rc = (i64)call3(6, 31, (u64)&value, 1);
    call2(2, rc == 1 ? 0 : 1, 0); for (;;) __asm__ volatile("pause");
}
