bits 64
section .text
global _start

%define SYS_EXIT  0
%define SYS_PRINT 1
%define SYS_GETPID 3
%define SYS_SLEEP 5
%define SYS_OPEN  6
%define SYS_READ  7
%define SYS_WRITE 8
%define SYS_CLOSE 9

_start:
    cld
    mov r14, rdi
    mov r15, rsi

    mov rax, SYS_PRINT
    lea rdi, [rel msg]
    mov rsi, msg_len
    int 0x80

    mov rax, SYS_PRINT
    lea rdi, [rel argv_prefix]
    mov rsi, argv_prefix_len
    int 0x80

    xor rbx, rbx
.argv_loop:
    cmp rbx, r14
    jae .argv_done
    mov rdx, [r15 + rbx * 8]
    test rdx, rdx
    jz .argv_done
    mov rdi, rdx
    call strlen
    mov rsi, rax
    mov rax, SYS_PRINT
    int 0x80
    mov rax, SYS_PRINT
    lea rdi, [rel space]
    mov rsi, 1
    int 0x80
    inc rbx
    jmp .argv_loop
.argv_done:
    mov rax, SYS_PRINT
    lea rdi, [rel nl]
    mov rsi, 1
    int 0x80

    ; SYS_SLEEP(ticks)
    mov rax, SYS_SLEEP
    mov rdi, 5
    int 0x80

    ; fd = SYS_OPEN("/boot/hello.txt", read-only)
    mov rax, SYS_OPEN
    lea rdi, [rel path]
    xor rsi, rsi
    int 0x80
    cmp rax, -1
    je .done
    mov r12, rax

    ; n = SYS_READ(fd, buf, sizeof(buf))
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [rel buf]
    mov rdx, buf_len
    int 0x80
    cmp rax, -1
    je .close
    mov r13, rax

    mov rax, SYS_PRINT
    lea rdi, [rel prefix]
    mov rsi, prefix_len
    int 0x80

    mov rax, SYS_PRINT
    lea rdi, [rel buf]
    mov rsi, r13
    int 0x80

    mov rax, SYS_PRINT
    lea rdi, [rel nl]
    mov rsi, 1
    int 0x80

.close:
    mov rax, SYS_CLOSE
    mov rdi, r12
    int 0x80

.done:
    ; SYS_EXIT()
    mov rax, SYS_EXIT
    int 0x80

    ; Should never return, but halt just in case.
    jmp $

strlen:
    xor rax, rax
.strlen_loop:
    cmp byte [rdi + rax], 0
    je .strlen_done
    inc rax
    jmp .strlen_loop
.strlen_done:
    ret

section .data
msg: db "Hello from ELF user-space!", 10
msg_len: equ $ - msg
argv_prefix: db "argv: "
argv_prefix_len: equ $ - argv_prefix
prefix: db "user read /boot/hello.txt: "
prefix_len: equ $ - prefix
path: db "/boot/hello.txt", 0
nl: db 10
space: db " "

section .bss
buf: resb 128
buf_len: equ 128
