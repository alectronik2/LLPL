#include "lib/llpl_sys.h"

// Simplest possible pipe-across-spawn test: no dup2 aliasing at all - the
// writer/reader children inherit the pipe under its own fd numbers only
// (fd 3 = read, fd 4 = write, via clone_for_exec), never reachable under
// two different fd numbers at once. Isolates whether the remaining hang
// (after fixing the DescriptorTable.get() leaks in hal/syscall.llpl) is
// specific to fd-duplication/aliasing (shell.c's dup2-based redirection
// pattern, see pipe_pipeline_demo.c) or present even in this bare case.
__attribute__((noreturn)) void _start(void) {
    write_s("pipe_simple_demo: start\n");

    i64 pipe_fds[2];
    if ((i64)call2(SYS_PIPE, (u64)pipe_fds, 0) < 0) {
        write_s("pipe_simple_demo: pipe failed\n");
        call2(SYS_EXIT, 1, 0);
        __builtin_unreachable();
    }
    write_s("pipe_simple_demo: pipe created, read_fd="); write_i64(pipe_fds[0]);
    write_s(" write_fd="); write_i64(pipe_fds[1]); write_s("\n");

    i64 writer_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/pipe_writer_demo", (u64)"");
    write_s("pipe_simple_demo: spawned writer pid="); write_i64(writer_pid); write_s("\n");
    // Close our own copy of the write end now, before spawning the
    // reader - otherwise the reader would also inherit it via
    // clone_for_exec (kern/handle.llpl) and never see EOF, since it
    // would itself be one of the outstanding write-end references it's
    // waiting to drop to zero. (This exact ordering mistake is what the
    // very first version of this test had - a self-deadlock in the test
    // program, not a kernel bug.)
    call2(SYS_CLOSE, (u64)pipe_fds[1], 0);

    i64 reader_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/pipe_reader_demo", (u64)"");
    write_s("pipe_simple_demo: spawned reader pid="); write_i64(reader_pid); write_s("\n");
    call2(SYS_CLOSE, (u64)pipe_fds[0], 0);

    u64 status = 0;
    write_s("pipe_simple_demo: waiting for writer\n");
    call2(SYS_WAITPID, (u64)writer_pid, (u64)&status);
    write_s("pipe_simple_demo: writer reaped\n");

    write_s("pipe_simple_demo: waiting for reader\n");
    call2(SYS_WAITPID, (u64)reader_pid, (u64)&status);
    write_s("pipe_simple_demo: reader reaped\n");

    write_s("pipe_simple_demo: done\n");
    call2(SYS_EXIT, 0, 0);
    __builtin_unreachable();
}
