#include "lib/llpl_sys.h"

__attribute__((noreturn)) void _start(void) {
    static const char name[] = "shm-demo";
    static const char banner[] = "shm_reader: opening segment\n";
    write_n(banner, sizeof(banner) - 1);

    i64 addr = (i64)call2(SYS_SHM_OPEN, (u64)name, 0);
    if (addr < 0) {
        static const char fail[] = "shm_reader: shm_open failed\n";
        write_n(fail, sizeof(fail) - 1);
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }

    char *shared = (char *)(u64)addr;
    static const char prefix[] = "shm_reader: read \"";
    write_n(prefix, sizeof(prefix) - 1);
    write_n(shared, str_len(shared));
    static const char suffix[] = "\"\n";
    write_n(suffix, sizeof(suffix) - 1);

    call2(SYS_SHM_UNLINK, (u64)name, 0);
    static const char unlinked[] = "shm_reader: unlinked segment\n";
    write_n(unlinked, sizeof(unlinked) - 1);

    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
