#include "lib/llpl_sys.h"

// Reads directly from fd 3 (the pipe read end's own fd number, inherited
// unchanged from the orchestrator via clone_for_exec - no dup2 aliasing
// involved) - reads until SYS_FD_READ returns 0 (EOF, meaning
// Kern.Pipe.writers reached 0 - see kern/handle.llpl) and reports whether
// that actually happened, rather than hanging forever if it doesn't.
__attribute__((noreturn)) void _start(void) {
    write_s("pipe_reader_demo: reading from fd 3 until EOF\n");

    char buffer[128];
    u64 total = 0;
    for (int iterations = 0; iterations < 1000000; ++iterations) {
        i64 got = (i64)call3(SYS_FD_READ, 3, (u64)buffer, sizeof(buffer) - 1);
        if (got < 0) {
            write_s("pipe_reader_demo: read error\n");
            call2(SYS_EXIT, 1, 0);
            __builtin_unreachable();
        }
        if (got == 0) {
            write_s("pipe_reader_demo: EOF reached, total bytes=");
            char digits[21];
            u64 at = sizeof(digits);
            u64 magnitude = total;
            do {
                digits[--at] = '0' + (char)(magnitude % 10);
                magnitude /= 10;
            } while (magnitude);
            call2(SYS_WRITE, sizeof(digits) - at, (u64)(digits + at));
            write_s("\n");
            call2(SYS_EXIT, 0, 0);
            __builtin_unreachable();
        }
        buffer[got] = 0;
        write_s("pipe_reader_demo: got chunk: ");
        write_s(buffer);
        write_s("\n");
        total += (u64)got;
    }

    write_s("pipe_reader_demo: gave up waiting for EOF\n");
    call2(SYS_EXIT, 2, 0);
    __builtin_unreachable();
}
