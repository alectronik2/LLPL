#include "lib/llpl_sys.h"

typedef struct {
    u64 buf;
    u64 size;
    u64 iocp_fd;
    u64 key;
    u64 context;
} AsyncIoParams;

typedef struct {
    u64 key;
    u64 context;
    u64 bytes_transferred;
    long status;
} CompletionResult;

static void print_dec_line(const char *prefix, u64 value) {
    write_s(prefix);
    write_u64(value);
    write_s("\n");
}

static void spin(u64 iterations) {
    for (volatile u64 i = 0; i < iterations; i++) { }
}

__attribute__((noreturn)) void _start(void) {
    write_s("iocp_demo: creating pipe\n");
    // Kernel syscall words are pointer-sized, including returned
    // descriptors (see user/init.c's matching comment) - i64, not int, or
    // SYS_PIPE's 16-byte copy_to_user overflows an 8-byte `int[2]` and
    // shifts write_fd into whatever stack memory follows it.
    i64 fds[2];
    call1(SYS_PIPE, (u64)fds);
    i64 read_fd = fds[0];
    i64 write_fd = fds[1];

    write_s("iocp_demo: creating completion port\n");
    u64 iocp = call1(SYS_CREATE_IOCP, 0);

    static char buf[64];
    AsyncIoParams params;
    params.buf = (u64)buf;
    params.size = sizeof(buf) - 1;
    params.iocp_fd = iocp;
    params.key = 0x1234;
    params.context = 0x5678;

    write_s("iocp_demo: issuing async read\n");
    call2(SYS_READ_ASYNC, (u64)read_fd, (u64)&params);

    // If SYS_READ_ASYNC blocked internally, this line would never appear
    // before the pipe actually has data - it's the whole point of the demo.
    write_s("iocp_demo: still running, not blocked\n");
    spin(3000000);

    static const char msg[] = "hello from iocp_demo";
    write_s("iocp_demo: writing to pipe\n");
    call3(SYS_FD_WRITE, (u64)write_fd, (u64)msg, sizeof(msg) - 1);

    write_s("iocp_demo: waiting for completion\n");
    CompletionResult result;
    call2(SYS_GET_QUEUED_COMPLETION, iocp, (u64)&result);

    print_dec_line("iocp_demo: bytes_transferred=", result.bytes_transferred);
    write_s("iocp_demo: data=\"");
    write_n(buf, result.bytes_transferred);
    write_s("\"\n");

    write_s("iocp_demo: done\n");
    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
