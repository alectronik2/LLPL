#include "lib/llpl_sys.h"

enum {
    O_READ = 1
};

__attribute__((noreturn)) void _start(void) {
    static const char path[] = "/dev/mouse";
    write_s("mouse_demo: move the mouse over the emulator window\n");

    i64 fd = (i64)call2(SYS_OPEN, (u64)path, O_READ);
    if (fd < 0) {
        write_s("mouse_demo: could not open /dev/mouse\n");
        for (;;) __asm__ volatile("pause");
    }

    unsigned char packet[3];
    for (;;) {
        i64 got = (i64)call3(SYS_FD_READ, (u64)fd, (u64)packet, 3);
        if (got != 3) continue;

        unsigned char flags = packet[0];
        // 9-bit signed deltas: sign bit from byte0, magnitude from byte1/2 -
        // the standard simplified decode (ignores the rare overflow bits).
        i64 dx = (i64)(unsigned char)packet[1];
        if (flags & 0x10) dx -= 256;
        i64 dy = (i64)(unsigned char)packet[2];
        if (flags & 0x20) dy -= 256;

        write_s("dx="); write_i64(dx);
        write_s(" dy="); write_i64(dy);
        write_s(" buttons=");
        write_s((flags & 0x01) ? "L" : "-");
        write_s((flags & 0x02) ? "R" : "-");
        write_s((flags & 0x04) ? "M" : "-");
        write_s("\n");
    }
}
