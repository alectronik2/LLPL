; Working 64-bit bootloader for LLPL
; Based on proven patterns for mode transition

section .multiboot
align 8
header_start:
    dd 0xe85250d6                           ; magic number
    dd 0                                    ; architecture (i386)
    dd header_end - header_start            ; header length
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))

    ; End tag
    dw 0
    dw 0
    dd 8
header_end:

section .bss
align 4096
pml4:
    resb 4096
pdpt:
    resb 4096
pd:
    resb 4096
stack_bottom:
    resb 16384
stack_top:

section .data
align 16
gdt64:
    dq 0                                         ; null descriptor
.code: equ $ - gdt64
    dq 0x00af9a000000ffff                       ; 64-bit code segment
.data: equ $ - gdt64
    dq 0x00cf92000000ffff                       ; 64-bit data segment
.end:

gdt64_pointer:
    dw gdt64.end - gdt64 - 1
    dq gdt64

section .text
bits 32
global _start
extern kernel_main

_start:
    ; Set up stack
    mov esp, stack_top

    ; Clear direction flag
    cld

    ; VGA test
    mov dword [0xb8000], 0x2f4b2f4f  ; "OK" in green

    ; Check multiboot magic
    cmp eax, 0x36d76289
    jne error

    ; Check CPUID
    call check_cpuid
    test eax, eax
    jz error

    ; Check long mode
    call check_long_mode
    test eax, eax
    jz error

    ; Set up page tables
    call setup_paging

    ; Enable paging and long mode
    call enable_long_mode

    ; Load 64-bit GDT
    lgdt [gdt64_pointer]

    ; Far jump using absolute addressing
    jmp 0x08:long_mode_entry

error:
    mov dword [0xb8000], 0x4f524f45  ; "ERR" in red
    cli
    hlt
    jmp $

check_cpuid:
    ; Try to flip ID bit in EFLAGS
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
    ; Check for extended CPUID
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode

    ; Check for long mode
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .no_long_mode

    mov eax, 1
    ret
.no_long_mode:
    xor eax, eax
    ret

setup_paging:
    ; Clear page tables
    mov edi, pml4
    mov ecx, 3 * 4096 / 4
    xor eax, eax
    rep stosd

    ; Set up page tables (identity map first 2MB)
    ; PML4[0] -> PDPT
    mov eax, pdpt
    or eax, 0x03  ; present + writable
    mov [pml4], eax

    ; PDPT[0] -> PD
    mov eax, pd
    or eax, 0x03
    mov [pdpt], eax

    ; PD[0] -> 2MB page
    mov eax, 0x83  ; present + writable + huge page
    mov [pd], eax

    ret

enable_long_mode:
    ; Load PML4 address into CR3
    mov eax, pml4
    mov cr3, eax

    ; Enable PAE in CR4
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Enable long mode in EFER
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8  ; LM bit
    wrmsr

    ; Enable paging in CR0
    mov eax, cr0
    or eax, 1 << 31  ; PG bit
    or eax, 1 << 16  ; WP bit
    mov cr0, eax

    ret

bits 64
long_mode_entry:
    ; Reload segment registers
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Set up stack
    mov rsp, stack_top

    ; Clear the screen
    mov rdi, 0xb8000
    mov rcx, 80 * 25
    mov ax, 0x0f20
    rep stosw

    ; Write success message
    mov rdi, 0xb8000
    mov rax, 0x0f360f34  ; "46"
    stosq
    mov rax, 0x0f4f0f34  ; "4O"
    stosq
    mov rax, 0x0f200f4b  ; "K "
    stosq

    ; Call kernel main
    call kernel_main

    ; Hang
    cli
.loop:
    hlt
    jmp .loop

; 64-bit I/O functions
global outb
outb:
    ; Parameters: rdi = port, rsi = value
    mov rdx, rdi
    mov rax, rsi
    out dx, al
    ret

global inb
inb:
    ; Parameter: rdi = port
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
