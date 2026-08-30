#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    call2(14, (u64)"/bin/child", (u64)"child hello from execer");
    call2(2, 99, 0);
    for (;;) __asm__ volatile("pause");
}
