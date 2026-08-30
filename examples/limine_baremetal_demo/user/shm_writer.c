#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    static const char name[] = "shm-demo";
    static const char message[] = "hello from shm_writer";
    static const char banner[] = "shm_writer: creating segment\n";
    write_n(banner, sizeof(banner) - 1);

    i64 addr = (i64)call2(SYS_SHM_CREATE, (u64)name, 4096);
    if (addr < 0) {
        static const char fail[] = "shm_writer: shm_create failed\n";
        write_n(fail, sizeof(fail) - 1);
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }

    char *shared = (char *)(u64)addr;
    for (u64 i = 0; i < sizeof(message); i++) {
        shared[i] = message[i];
    }

    static const char done[] = "shm_writer: wrote message, exiting\n";
    write_n(done, sizeof(done) - 1);

    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
