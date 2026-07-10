; Fixed 64-bit bootloader for LLPL

section .multiboot
align 8
multiboot_header_start:
    dd 0xe85250d6                ; magic
    dd 0                         ; architecture 0 (protected mode i386)
    dd multiboot_header_end - multiboot_header_start
    dd 0x100000000 - (0xe85250d6 + 0 + (multiboot_header_end - multiboot_header_start))

    ; End tag
    dw 0
    dw 0
    dd 8
multiboot_header_end:

section .bss
align 4096
p4_table:
    resb 4096
p3_table:
    resb 4096
p2_table:
    resb 4096
stack_bottom:
    resb 16384
stack_top:

section .text
bits 32
global _start
extern kernel_main

_start:
    mov esp, stack_top

    ; VGA test - write 'S' for start
    mov dword [0xb8000], 0x0f530f53

    ; Check multiboot
    cmp eax, 0x36d76289
    jne .no_multiboot

    ; Check CPUID
    call check_cpuid
    test eax, eax
    jz .no_cpuid

    ; Check long mode
    call check_long_mode
    test eax, eax
    jz .no_long_mode

    ; Setup paging
    call setup_page_tables
    call enable_paging

    ; Load 64-bit GDT
    lgdt [gdt64.pointer]

    ; Update code segment with far return
    mov eax, 0x08
    push eax
    lea eax, [rel long_mode_start]
    push eax
    retf

.no_multiboot:
    mov dword [0xb8000], 0x4f4d4f4d  ; "MM"
    hlt
.no_cpuid:
    mov dword [0xb8000], 0x4f434f43  ; "CC"
    hlt
.no_long_mode:
    mov dword [0xb8000], 0x4f4c4f4c  ; "LL"
    hlt

check_cpuid:
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 1 << 21
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    cmp eax, ecx
    je .no_cpuid
    mov eax, 1
    ret
.no_cpuid:
    xor eax, eax
    ret

check_long_mode:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode

    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .no_long_mode

    mov eax, 1
    ret
.no_long_mode:
    xor eax, eax
    ret

setup_page_tables:
    ; Zero out tables
    mov edi, p4_table
    mov ecx, 4096 * 3 / 4
    xor eax, eax
    rep stosd

    ; P4[0] -> P3
    mov eax, p3_table
    or eax, 0x03  ; present, writable
    mov [p4_table], eax

    ; P3[0] -> P2
    mov eax, p2_table
    or eax, 0x03
    mov [p3_table], eax

    ; Identity map first 2MB with huge pages
    mov eax, 0x00000083  ; present, writable, huge page
    mov [p2_table], eax

    ret

enable_paging:
    ; Load P4 into CR3
    mov eax, p4_table
    mov cr3, eax

    ; Enable PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Enable long mode
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; Enable paging
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ret

section .rodata
align 8
gdt64:
    dq 0                                              ; null
.code: equ $ - gdt64
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53)         ; code segment
.data: equ $ - gdt64
    dq (1<<44) | (1<<47)                              ; data segment
.pointer:
    dw .pointer - gdt64 - 1
    dq gdt64

section .text
bits 64
long_mode_start:
    ; Setup segments
    mov ax, 0x10
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; Write 'OK' to VGA to confirm 64-bit mode
    mov rax, 0xb8000
    mov word [rax], 0x0f4f
    mov word [rax+2], 0x0f4b

    ; Setup stack
    mov rsp, stack_top

    ; Call kernel
    call kernel_main

    ; Hang
.hang:
    hlt
    jmp .hang

; 64-bit I/O functions
global outb
outb:
    mov rdx, rdi
    mov rax, rsi
    out dx, al
    ret

global inb
inb:
    mov rdx, rdi
    xor rax, rax
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
