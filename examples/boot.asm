; Multiboot2 header for GRUB
section .multiboot
align 8
multiboot_header_start:
    dd 0xe85250d6                ; magic number
    dd 0                         ; architecture (0 = i386)
    dd multiboot_header_end - multiboot_header_start
    dd -(0xe85250d6 + (multiboot_header_end - multiboot_header_start))

    ; End tag
    dw 0
    dw 0
    dd 8
multiboot_header_end:

; Stack
section .bss
align 16
stack_bottom:
    resb 16384  ; 16 KB stack
stack_top:

; Boot code
section .text
bits 32
global _start
extern kernel_main

_start:
    ; Set up stack
    mov esp, stack_top

    ; Clear interrupts
    cli

    ; Call kernel main
    call kernel_main

    ; Hang if kernel returns
.hang:
    hlt
    jmp .hang

; Port I/O functions
global outb
outb:
    mov dx, [esp + 4]   ; port
    mov al, [esp + 8]   ; value
    out dx, al
    ret

global inb
inb:
    mov dx, [esp + 4]   ; port
    xor eax, eax
    in al, dx
    ret

global enable_interrupts
enable_interrupts:
    sti
    ret

global disable_interrupts
disable_interrupts:
    cli
    ret
