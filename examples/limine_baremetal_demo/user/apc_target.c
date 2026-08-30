#include "lib/llpl_sys.h"

static void print_counter(const char *prefix, u64 counter) {
    write_s(prefix);
    write_u64(counter);
    write_s("\n");
}

// Invoked directly by the kernel-injected APC trampoline (see
// Kern.maybe_deliver_apc, kern/thread.llpl) - a plain function taking one
// argument, called on this thread's own stack while it's mid-loop below.
// It just returns normally; the trampoline's own tail handles the
// SYS_APC_RETURN syscall that resumes the interrupted loop.
static volatile int apc_fired = 0;

void apc_handler(void *arg) {
    apc_fired = 1;
}

__attribute__((noreturn)) void _start(void) {
    static const char name[] = "apc-demo";
    static const char banner[] = "apc_target: registering\n";
    write_n(banner, sizeof(banner) - 1);

    u64 pid = call2(9, 0, 0);
    u64 tid = call2(SYS_GETTID, 0, 0);

    i64 addr = (i64)call2(SYS_SHM_CREATE, (u64)name, 4096);
    if (addr < 0) {
        static const char fail[] = "apc_target: shm_create failed\n";
        write_n(fail, sizeof(fail) - 1);
        call2(SYS_EXIT, 1, 0);
        for (;;) __asm__ volatile("pause");
    }

    u64 *slots = (u64 *)(u64)addr;
    slots[0] = pid;
    slots[1] = tid;
    slots[2] = (u64)apc_handler;

    static const char ready[] = "apc_target: looping\n";
    write_n(ready, sizeof(ready) - 1);

    u64 counter = 0;
    while (1) {
        counter++;
        if (apc_fired) {
            print_counter("apc_target: APC delivered mid-loop, counter=", counter);
            apc_fired = 0;
        }
        if ((counter % 2000000) == 0) {
            print_counter("apc_target: counter=", counter);
        }
    }
}
