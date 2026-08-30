#include "lib/llpl_sys.h"

typedef struct {
    u64 vector;
    u64 error_code;
    u64 fault_addr;
    u64 rip;
} ExceptionInfo;

static void write_hex(u64 v) {
    static const char digits[] = "0123456789abcdef";
    char buf[18];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        buf[2 + i] = digits[(v >> ((15 - i) * 4)) & 0xF];
    }
    write_n(buf, 18);
}

static void print_hex_line(const char *prefix, u64 value) {
    write_s(prefix);
    write_hex(value);
    write_s("\n");
}

// Invoked by the kernel's exception-delivery trampoline (see
// Kern.handle_user_exception, kern/thread.llpl) with an ExceptionInfo* in
// rdi. Returns normally - the trampoline's own tail invokes
// SYS_EXCEPTION_RETURN, which terminates this process (notify-then-
// terminate: there's no way to resume at the fault site in this version).
void exception_handler(ExceptionInfo *info) {
    write_s("seh_demo: exception handler running\n");
    print_hex_line("seh_demo: vector=", info->vector);
    print_hex_line("seh_demo: error_code=", info->error_code);
    print_hex_line("seh_demo: fault_addr=", info->fault_addr);
    print_hex_line("seh_demo: rip=", info->rip);
}

__attribute__((noreturn)) void _start(void) {
    write_s("seh_demo: registering handler\n");
    call2(SYS_SET_EXCEPTION_HANDLER, (u64)exception_handler, 0);

    write_s("seh_demo: about to divide by zero\n");
    volatile u64 zero = 0;
    volatile u64 boom = 42 / zero;
    (void)boom;

    write_s("seh_demo: should never reach here\n");
    call2(SYS_EXIT, 1, 0);
    for (;;) __asm__ volatile("pause");
}
