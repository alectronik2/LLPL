#include "lib/llpl_sys.h"

// Writes directly to fd 4 (the pipe write end's own fd number, inherited
// unchanged from the orchestrator via clone_for_exec - no dup2 aliasing
// involved) rather than through fd 1, to isolate whether the remaining
// hang is specific to a descriptor being reachable under two different
// fd numbers at once.
__attribute__((noreturn)) void _start(void) {
    static const char msg[] = "hello from pipe_writer_demo\n";
    call3(SYS_FD_WRITE, 4, (u64)msg, sizeof(msg) - 1);
    write_s("pipe_writer_demo: wrote via fd 4, exiting\n");
    call2(SYS_EXIT, 0, 0);
    __builtin_unreachable();
}
