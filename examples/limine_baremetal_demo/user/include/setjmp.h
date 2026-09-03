#ifndef LLPL_SETJMP_H
#define LLPL_SETJMP_H
typedef struct { unsigned long rbx, rbp, r12, r13, r14, r15, rsp, rip; } jmp_buf[1];
int setjmp(jmp_buf) __attribute__((returns_twice));
void longjmp(jmp_buf, int) __attribute__((noreturn));
#endif
