#include "lib/llpl_sys.h"

enum {
    O_READ = 1
};

__attribute__((noreturn)) void _start(void) {
    static const char path[] = "/dev/kbd";
    static const char banner[] = "kbd_echo: type on the emulator window - keystrokes echo here\n";
    write_n(banner, sizeof(banner) - 1);

    i64 fd = (i64)call2(SYS_OPEN, (u64)path, O_READ);
    if (fd < 0) {
        static const char fail[] = "kbd_echo: could not open /dev/kbd\n";
        write_n(fail, sizeof(fail) - 1);
        for (;;) __asm__ volatile("pause");
    }

    char c;
    for (;;) {
        i64 got = (i64)call3(SYS_FD_READ, (u64)fd, (u64)&c, 1);
        if (got == 1) {
            write_n(&c, 1);
        }
    }
}
