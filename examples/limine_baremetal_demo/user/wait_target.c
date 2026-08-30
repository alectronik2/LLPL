#include "lib/llpl_sys.h"

static void spin(u64 iterations) {
    for (volatile u64 i = 0; i < iterations; i++) { }
}

__attribute__((noreturn)) void _start(void) {
    static const char name[] = "wait-demo";
    write_s("wait_target: registering pid\n");

    u64 pid = call2(9, 0, 0);

    i64 addr = (i64)call2(SYS_SHM_CREATE, (u64)name, 4096);
    if (addr < 0) {
        write_s("wait_target: shm_create failed\n");
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }
    u64 *slot = (u64 *)(u64)addr;
    slot[0] = pid;

    write_s("wait_target: spinning before exit\n");
    spin(8000000);

    write_s("wait_target: exiting\n");
    call2(SYS_EXIT, 7, 0);
    for (;;) __asm__ volatile("pause");
}
