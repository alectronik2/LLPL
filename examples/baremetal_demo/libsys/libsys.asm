bits 64

%define SYS_EXIT      0
%define SYS_PRINT     1
%define SYS_MMAP      2
%define SYS_GETPID    3
%define SYS_YIELD     4
%define SYS_SLEEP     5
%define SYS_OPEN      6
%define SYS_READ      7
%define SYS_WRITE     8
%define SYS_CLOSE     9
%define SYS_MSG_SEND  10
%define SYS_MSG_RECV  11
%define SYS_MSG_REPLY 12

section .text

global sys_exit
global sys_print
global sys_mmap
global sys_getpid
global sys_yield
global sys_sleep
global sys_open
global sys_read
global sys_write
global sys_close
global sys_msg_send
global sys_msg_recv
global sys_msg_reply
global sys_strlen
global sys_puts

sys_exit:
    mov rax, SYS_EXIT
    int 0x80
    ret

sys_print:
    mov rax, SYS_PRINT
    int 0x80
    ret

sys_mmap:
    mov rax, SYS_MMAP
    int 0x80
    ret

sys_getpid:
    mov rax, SYS_GETPID
    int 0x80
    ret

sys_yield:
    mov rax, SYS_YIELD
    int 0x80
    ret

sys_sleep:
    mov rax, SYS_SLEEP
    int 0x80
    ret

sys_open:
    mov rax, SYS_OPEN
    int 0x80
    ret

sys_read:
    mov rax, SYS_READ
    int 0x80
    ret

sys_write:
    mov rax, SYS_WRITE
    int 0x80
    ret

sys_close:
    mov rax, SYS_CLOSE
    int 0x80
    ret

sys_msg_send:
    mov rax, SYS_MSG_SEND
    int 0x80
    ret

sys_msg_recv:
    mov rax, SYS_MSG_RECV
    int 0x80
    ret

sys_msg_reply:
    mov rax, SYS_MSG_REPLY
    int 0x80
    ret

sys_strlen:
    xor rax, rax
.loop:
    cmp byte [rdi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret

sys_puts:
    push rdi
    call sys_strlen
    pop rdi
    mov rsi, rax
    mov rax, SYS_PRINT
    int 0x80
    ret
