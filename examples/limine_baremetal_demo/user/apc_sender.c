#include "lib/llpl_sys.h"

static void spin(u64 iterations) {
    for (volatile u64 i = 0; i < iterations; i++) { }
}

__attribute__((noreturn)) void _start(void) {
    static const char name[] = "apc-demo";
    write_s("apc_sender: opening segment\n");

    // apc_target never exits (it loops until killed), so there's no
    // wait_process-based way to sequence "target has shm_create'd" before
    // spawning this - retry instead of assuming an arrival order.
    i64 addr = -1;
    for (int attempt = 0; attempt < 50 && addr < 0; attempt++) {
        addr = (i64)call2(SYS_SHM_OPEN, (u64)name, 0);
        if (addr < 0) spin(2000000);
    }
    if (addr < 0) {
        write_s("apc_sender: shm_open failed\n");
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }

    u64 *slots = (u64 *)(u64)addr;
    u64 target_pid = slots[0];
    u64 target_tid = slots[1];
    u64 callback = slots[2];

    // Give apc_target a moment to reach its loop.
    spin(5000000);

    write_s("apc_sender: queuing APC\n");
    call4(SYS_QUEUE_APC, target_pid, target_tid, callback, 0);

    // Give the target a moment to actually get preempted and run it.
    spin(5000000);

    write_s("apc_sender: terminating target\n");
    call2(SYS_TERMINATE, target_pid, 1);

    write_s("apc_sender: done\n");
    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
