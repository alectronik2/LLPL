#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    static char cmdline[128];
    u64 got = call2(SYS_GET_COMMAND_LINE, (u64)cmdline, sizeof(cmdline));
    if (got > 0) {
        write_s("child: command line: ");
        write_s(cmdline);
        write_s("\n");
    } else {
        write_s("child: no command line\n");
    }

    static const char message[] = "child process ran\n";
    call2(1, sizeof(message) - 1, (u64)message);
    call2(2, 42, 0);
    for (;;) __asm__ volatile("pause");
}
