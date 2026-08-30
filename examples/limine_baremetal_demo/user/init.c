#include "lib/llpl_sys.h"

enum {
    O_READ = 1,
    O_WRITE = 2,
    O_CREATE = 4,
    O_TRUNC = 8
};

static int bytes_equal(const char *left, const char *right, u64 size) {
    for (u64 i = 0; i < size; ++i) {
        if (left[i] != right[i]) {
            return 0;
        }
    }
    return 1;
}

static volatile u64 thread_tls_seen;

__attribute__((noreturn)) static void user_thread_main(u64 expected_tls) {
    thread_tls_seen = call2(SYS_GET_TLS, 0, 0);
    call2(SYS_THREAD_EXIT, expected_tls == thread_tls_seen ? 0x77 : 0xEE, 0);
    for (;;) __asm__ volatile("pause");
}

__attribute__((noreturn)) static void detached_thread_main(u64 unused) {
    (void)unused;
    call2(SYS_THREAD_EXIT, 0x88, 0);
    for (;;) __asm__ volatile("pause");
}

__attribute__((noreturn)) void _start(void) {
    write_s("Hello from /bin/init (ELF)\n");

    char *page = (char *)call2(SYS_MMAP, 0, 8192);
    int demand_ok = page[4096] == 0;
    page[0] = 'O';
    page[1] = 'K';
    page[2] = '\n';
    page[4096] = 'D';
    demand_ok = demand_ok && page[0] == 'O' && page[4096] == 'D';
    call2(SYS_WRITE, 3, (u64)page);
    write_s(demand_ok ? "Demand paging self-test: PASS\n" : "Demand paging self-test: FAIL\n");
    int vm_ok = demand_ok && (i64)call2(SYS_MUNMAP, (u64)page, 8192) == 0;
    char *replacement = (char *)call2(SYS_MMAP, (u64)page, 8192);
    vm_ok = vm_ok && replacement == page;
    if (vm_ok) {
        replacement[0] = 'R';
    }
    write_s(vm_ok ? "VM unmap self-test: PASS\n" : "VM unmap self-test: FAIL\n");

    const char payload[] = "userspace descriptor I/O\n";
    char readback[sizeof(payload)];
    i64 fd = (i64)call2(SYS_OPEN, (u64)"/var/user-fd-test.txt",
                           O_READ | O_WRITE | O_CREATE | O_TRUNC);
    int fd_ok = vm_ok && (i64)call2(SYS_GETPID, 0, 0) > 1 && fd >= 3;
    if (fd_ok) {
        fd_ok = (i64)call3(SYS_FD_WRITE, (u64)fd, (u64)payload,
                              sizeof(payload) - 1) == (i64)(sizeof(payload) - 1);
        fd_ok = fd_ok && (i64)call3(SYS_SEEK, (u64)fd, 0, 0) == 0;
        fd_ok = fd_ok && (i64)call3(SYS_FD_READ, (u64)fd, (u64)readback,
                                      sizeof(payload) - 1) == (i64)(sizeof(payload) - 1);
        fd_ok = fd_ok && bytes_equal(payload, readback, sizeof(payload) - 1);
        char *file_map = (char *)call3(SYS_MMAP_FILE, (u64)fd,
                                         sizeof(payload) - 1, 3);
        int file_map_ok = (i64)file_map > 0 && file_map[0] == payload[0];
        if (file_map_ok) {
            file_map[0] = 'M';
            file_map_ok = (i64)call2(SYS_MSYNC, (u64)file_map,
                                        sizeof(payload) - 1) == 0;
            file_map_ok = file_map_ok &&
                (i64)call2(SYS_MUNMAP, (u64)file_map,
                              sizeof(payload) - 1) == 0;
            file_map_ok = file_map_ok &&
                (i64)call3(SYS_SEEK, (u64)fd, 0, 0) == 0;
            file_map_ok = file_map_ok &&
                (i64)call3(SYS_FD_READ, (u64)fd, (u64)readback, 1) == 1 &&
                readback[0] == 'M';
        }
        write_s(file_map_ok ? "File mapping self-test: PASS\n" :
                                    "File mapping self-test: FAIL\n");
        fd_ok = fd_ok && file_map_ok;
        fd_ok = fd_ok && (i64)call2(SYS_CLOSE, (u64)fd, 0) == 0;
        fd_ok = fd_ok && (i64)call3(SYS_FD_READ, (u64)fd, (u64)readback, 1) < 0;
    }
    write_s(fd_ok ? "FD self-test: PASS\n" : "FD self-test: FAIL\n");

    u64 child_status = 0;
    i64 child_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/child", 0);
    int spawn_ok = child_pid > 0 &&
        (i64)call2(SYS_WAITPID, (u64)child_pid, (u64)&child_status) == child_pid &&
        child_status == 42;
    u64 exec_status = 0;
    i64 exec_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/execer", 0);
    int exec_ok = exec_pid > 0 &&
        (i64)call2(SYS_WAITPID, (u64)exec_pid, (u64)&exec_status) == exec_pid &&
        exec_status == 42;
    write_s(spawn_ok ? "Spawn/waitpid self-test: PASS\n" :
                             "Spawn/waitpid self-test: FAIL\n");
    write_s(exec_ok ? "Exec self-test: PASS\n" : "Exec self-test: FAIL\n");

    const u64 tls_value = 0x12345000;
    u64 thread_value = 0;
    i64 tid = (i64)call3(SYS_THREAD_CREATE, (u64)user_thread_main,
                            tls_value, tls_value);
    int thread_ok = tid > 0 &&
        (i64)call2(SYS_THREAD_JOIN, (u64)tid, (u64)&thread_value) == 0 &&
        thread_value == 0x77 && thread_tls_seen == tls_value;
    i64 detached_tid = (i64)call3(SYS_THREAD_CREATE,
                                     (u64)detached_thread_main, 0, 0);
    thread_ok = thread_ok && detached_tid > 0 &&
        (i64)call2(SYS_THREAD_DETACH, (u64)detached_tid, 0) == 0;
    write_s(thread_ok ? "User thread/TLS self-test: PASS\n" :
                              "User thread/TLS self-test: FAIL\n");

    /* Kernel syscall words are pointer-sized, including returned descriptors. */
    i64 pipefd[2];
    pipefd[0] = -1;
    pipefd[1] = -1;
    int pipe_ok = (i64)call2(SYS_PIPE, (u64)pipefd, 0) == 0;
    i64 duplicate = pipe_ok ? (i64)call2(SYS_DUP, pipefd[1], 0) : -1;
    pipe_ok = pipe_ok && duplicate >= 3 &&
        (i64)call2(SYS_CLOSE, pipefd[1], 0) == 0;
    static const char pipe_message[] = "pipe-data";
    char pipe_readback[sizeof(pipe_message)];
    pipe_ok = pipe_ok &&
        (i64)call3(SYS_FD_WRITE, duplicate, (u64)pipe_message,
                      sizeof(pipe_message)) == sizeof(pipe_message) &&
        (i64)call3(SYS_FD_READ, pipefd[0], (u64)pipe_readback,
                      sizeof(pipe_message)) == sizeof(pipe_message) &&
        bytes_equal(pipe_message, pipe_readback, sizeof(pipe_message));
    write_s(pipe_ok ? "  pipe dup round-trip: PASS\n" : "  pipe dup round-trip: FAIL\n");

    pipe_ok = pipe_ok && (i64)call2(SYS_DUP2, duplicate, 31) == 31;
    u64 inherit_status = 1;
    i64 inherit_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/fdinherit", 0);
    pipe_ok = pipe_ok && inherit_pid > 0 &&
        (i64)call2(SYS_WAITPID, inherit_pid, (u64)&inherit_status) == inherit_pid &&
        inherit_status == 0;
    char inherited_byte = 0;
    pipe_ok = pipe_ok &&
        (i64)call3(SYS_FD_READ, pipefd[0], (u64)&inherited_byte, 1) == 1 &&
        inherited_byte == 'I';
    write_s(pipe_ok ? "  descriptor inheritance: PASS\n" : "  descriptor inheritance: FAIL\n");
    pipe_ok = pipe_ok && (i64)call2(SYS_CLOEXEC, 31, 1) == 0;
    u64 cloexec_status = 1;
    i64 cloexec_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/fdcheck", 0);
    pipe_ok = pipe_ok && cloexec_pid > 0 &&
        (i64)call2(SYS_WAITPID, cloexec_pid, (u64)&cloexec_status) == cloexec_pid &&
        cloexec_status == 0;
    write_s(pipe_ok ? "  close-on-exec: PASS\n" : "  close-on-exec: FAIL\n");
    write_s(pipe_ok ? "Pipe/dup inheritance self-test: PASS\n" :
                            "Pipe/dup inheritance self-test: FAIL\n");

    char *heap = (char *)call2(SYS_SBRK, 8192, 0);
    int heap_ok = (i64)heap > 0;
    if (heap_ok) {
        heap[0] = 'H';
        heap[8191] = 'P';
        heap_ok = heap[0] == 'H' && heap[8191] == 'P' &&
            call2(SYS_BRK, 0, 0) == (u64)heap + 8192;
        heap_ok = heap_ok &&
            call2(SYS_SBRK, (u64)(i64)-8192, 0) == (u64)heap + 8192 &&
            call2(SYS_BRK, 0, 0) == (u64)heap;
    }
    write_s(heap_ok ? "brk/sbrk self-test: PASS\n" :
                            "brk/sbrk self-test: FAIL\n");

    void *m1 = malloc(64);
    void *m2 = malloc(128);
    int malloc_ok = m1 != 0 && m2 != 0 && m1 != m2;
    if (malloc_ok) {
        char *b1 = (char *)m1;
        b1[0] = 'A';
        b1[63] = 'Z';
        char *b2 = (char *)m2;
        b2[0] = 'B';
        b2[127] = 'Y';
        malloc_ok = b1[0] == 'A' && b1[63] == 'Z' && b2[0] == 'B' && b2[127] == 'Y';
    }
    free(m1);

    void *m3 = calloc(16, 4);
    if (malloc_ok && m3 != 0) {
        char *b3 = (char *)m3;
        int all_zero = 1;
        for (int i = 0; i < 64; i++) {
            if (b3[i] != 0) all_zero = 0;
        }
        malloc_ok = malloc_ok && all_zero;
    } else {
        malloc_ok = 0;
    }

    char *m4 = (char *)realloc(m2, 256);
    if (malloc_ok && m4 != 0) {
        malloc_ok = m4[0] == 'B' && m4[127] == 'Y'; // realloc preserved old contents
        m4[255] = 'Q';
        malloc_ok = malloc_ok && m4[255] == 'Q';
    } else {
        malloc_ok = 0;
    }
    free(m3);
    free(m4);
    write_s(malloc_ok ? "malloc self-test: PASS\n" : "malloc self-test: FAIL\n");

    u64 hello_status = 1;
    i64 hello_pid = (i64)call2(SYS_SPAWN, (u64)"/bin/hello", (u64)"foo bar baz");
    int hello_ok = hello_pid > 0 &&
        (i64)call2(SYS_WAITPID, (u64)hello_pid, (u64)&hello_status) == hello_pid &&
        hello_status == 0;
    write_s(hello_ok ? "LLPL user program self-test: PASS\n" :
                       "LLPL user program self-test: FAIL\n");

    call2(SYS_EXIT, (spawn_ok && exec_ok && fd_ok && thread_ok && pipe_ok && heap_ok && malloc_ok && hello_ok) ? 0 : 1, 0);
    for (;;) {
        __asm__ volatile("pause");
    }
}
