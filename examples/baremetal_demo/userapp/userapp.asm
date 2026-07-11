bits 64
section .text
global _start

%define SYS_EXIT  0
%define SYS_PRINT 1

_start:
    cld

    ; SYS_PRINT(buf, len)
    mov rax, SYS_PRINT
    lea rdi, [rel msg]
    mov rsi, msg_len
    int 0x80

    ; SYS_EXIT()
    mov rax, SYS_EXIT
    int 0x80

    ; Should never return, but halt just in case.
    jmp $

section .data
msg: db "Hello from ELF user-space!", 10
msg_len: equ $ - msg
