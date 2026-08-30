#include "llpl_sys.h"

u64 call1(u64 n, u64 a) {
    register u64 rax __asm__("rax") = n;
    register u64 rdi __asm__("rdi") = a;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi) : "rcx", "r11", "memory");
    return rax;
}

u64 call2(u64 n, u64 a, u64 b) {
    register u64 rax __asm__("rax") = n;
    register u64 rdi __asm__("rdi") = a;
    register u64 rsi __asm__("rsi") = b;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi)
                     : "rcx", "r11", "memory");
    return rax;
}

u64 call3(u64 n, u64 a, u64 b, u64 c) {
    register u64 rax __asm__("rax") = n;
    register u64 rdi __asm__("rdi") = a;
    register u64 rsi __asm__("rsi") = b;
    register u64 rdx __asm__("rdx") = c;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx)
                     : "rcx", "r11", "memory");
    return rax;
}

u64 call4(u64 n, u64 a, u64 b, u64 c, u64 d) {
    register u64 rax __asm__("rax") = n;
    register u64 rdi __asm__("rdi") = a;
    register u64 rsi __asm__("rsi") = b;
    register u64 rdx __asm__("rdx") = c;
    register u64 r10 __asm__("r10") = d;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx), "r"(r10)
                     : "rcx", "r11", "memory");
    return rax;
}
