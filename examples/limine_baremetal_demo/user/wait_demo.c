#include "lib/llpl_sys.h"

static void spin(u64 iterations) {
    for (volatile u64 i = 0; i < iterations; i++) { }
}

static volatile u64 event_fd;
static volatile int main_has_set_event = 0;
static volatile int waiter_woke_early = 0;

void waiter_thread_entry(void *arg) {
    write_s("wait_demo: waiter thread blocking on event\n");
    call1(SYS_WAIT_HANDLE, event_fd);
    if (!main_has_set_event) {
        waiter_woke_early = 1;
    }
    write_s("wait_demo: waiter thread woke up\n");
    call2(SYS_THREAD_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}

__attribute__((noreturn)) void _start(void) {
    write_s("wait_demo: creating event\n");
    event_fd = call2(SYS_CREATE_EVENT, 1, 0); // manual-reset, initially unsignaled

    write_s("wait_demo: spawning waiter thread\n");
    u64 tid = call3(SYS_THREAD_CREATE, (u64)waiter_thread_entry, 0, 0);

    // Give the waiter thread time to actually reach SYS_WAIT_HANDLE and
    // block before we set the event, so a premature wake would be visible.
    spin(3000000);
    write_s("wait_demo: setting event\n");
    main_has_set_event = 1;
    call1(SYS_SET_EVENT, event_fd);

    call2(SYS_THREAD_JOIN, tid, 0);
    if (waiter_woke_early) {
        write_s("wait_demo: FAIL - waiter woke before event was set\n");
    } else {
        write_s("wait_demo: PASS - event wait/set ordering correct\n");
    }

    // Cross-process wait: wait_target reports its pid via shm (an fd
    // number from SYS_CREATE_EVENT wouldn't mean anything in a different
    // process's own fd table, so this half needs a real kernel object -
    // SYS_OPEN_PROCESS - not an Event).
    write_s("wait_demo: opening wait_target's shm segment\n");
    static const char name[] = "wait-demo";
    i64 addr = -1;
    for (int attempt = 0; attempt < 50 && addr < 0; attempt++) {
        addr = (i64)call2(SYS_SHM_OPEN, (u64)name, 0);
        if (addr < 0) spin(2000000);
    }
    if (addr < 0) {
        write_s("wait_demo: shm_open failed\n");
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }
    u64 target_pid = ((u64 *)(u64)addr)[0];

    write_s("wait_demo: opening process handle\n");
    i64 proc_fd = (i64)call1(SYS_OPEN_PROCESS, target_pid);
    if (proc_fd < 0) {
        write_s("wait_demo: open_process failed\n");
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }

    write_s("wait_demo: waiting for target process to exit\n");
    call1(SYS_WAIT_HANDLE, (u64)proc_fd);
    write_s("wait_demo: target process exited, wait returned\n");

    write_s("wait_demo: done\n");
    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
