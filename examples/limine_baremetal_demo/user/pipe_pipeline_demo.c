#include "lib/llpl_sys.h"

// Reproduces shell.c's run_pipeline() writer|reader pattern in a single,
// self-contained, non-interactive program (shell.c itself needs keyboard
// input, which headless -display none boots have no way to inject) - the
// exact scenario flagged as possibly hanging: a spawned child inherits a
// pipe write end via clone_for_exec (kern/handle.llpl), the parent closes
// its own copies, the child exits and is reaped, and a second child
// blocked reading the other end is expected to see EOF once
// Kern.Pipe.writers (kern/handle.llpl) reaches 0.
__attribute__((noreturn)) void _start(void) {
    write_s("pipe_pipeline_demo: start\n");

    i64 pipe_fds[2];
    if ((i64)call2(SYS_PIPE, (u64)pipe_fds, 0) < 0) {
        write_s("pipe_pipeline_demo: pipe failed\n");
        call2(SYS_EXIT, 1, 0);
        __builtin_unreachable();
    }
    write_s("pipe_pipeline_demo: pipe created, read_fd="); write_i64(pipe_fds[0]);
    write_s(" write_fd="); write_i64(pipe_fds[1]); write_s("\n");

    // Writer stage: redirect our own fd 1 to the pipe's write end, spawn
    // the writer (inherits fd 1 = pipe write end, AND its own original fd
    // number for the write end, AND the read end too - same as any
    // clone_for_exec inheritance), then restore/close exactly as shell.c
    // does immediately after spawning.
    i64 saved_stdout = (i64)call2(SYS_DUP, 1, 0);
    call2(SYS_DUP2, (u64)pipe_fds[1], 1);
    i64 writer_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/pipe_writer_demo", (u64)"");
    write_s("pipe_pipeline_demo: spawned writer pid="); write_i64(writer_pid); write_s("\n");
    call2(SYS_DUP2, (u64)saved_stdout, 1);
    call2(SYS_CLOSE, (u64)saved_stdout, 0);
    call2(SYS_CLOSE, (u64)pipe_fds[1], 0);

    // Reader stage: redirect our own fd 0 to the pipe's read end, spawn
    // the reader, then restore/close our copy.
    i64 saved_stdin = (i64)call2(SYS_DUP, 0, 0);
    call2(SYS_DUP2, (u64)pipe_fds[0], 0);
    i64 reader_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/pipe_reader_demo", (u64)"");
    write_s("pipe_pipeline_demo: spawned reader pid="); write_i64(reader_pid); write_s("\n");
    call2(SYS_DUP2, (u64)saved_stdin, 0);
    call2(SYS_CLOSE, (u64)saved_stdin, 0);
    call2(SYS_CLOSE, (u64)pipe_fds[0], 0);

    u64 status = 0;
    write_s("pipe_pipeline_demo: waiting for writer\n");
    call2(SYS_WAITPID, (u64)writer_pid, (u64)&status);
    write_s("pipe_pipeline_demo: writer reaped\n");

    write_s("pipe_pipeline_demo: waiting for reader\n");
    call2(SYS_WAITPID, (u64)reader_pid, (u64)&status);
    write_s("pipe_pipeline_demo: reader reaped\n");

    write_s("pipe_pipeline_demo: done\n");
    call2(SYS_EXIT, 0, 0);
    __builtin_unreachable();
}
