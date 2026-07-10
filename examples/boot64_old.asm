; Multiboot2 header and 64-bit long mode setup for LLPL kernel

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

section .bss
align 4096
; Page tables for long mode
p4_table:
    resb 4096
p3_table:
    resb 4096
p2_table:
    resb 4096

; Stack
align 16
stack_bottom:
    resb 32768  ; 32 KB stack
stack_top:

section .rodata
; GDT for 64-bit mode
gdt64:
    dq 0                        ; null descriptor
.code: equ $ - gdt64
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53) ; code segment
.data: equ $ - gdt64
    dq (1<<44) | (1<<47)        ; data segment
.pointer:
    dw $ - gdt64 - 1
    dq gdt64

section .text
bits 32
global _start
extern kernel_main

_start:
    ; Set up stack
    mov esp, stack_top

    ; Debug: Write 'A' to screen to show we're booting
    mov dword [0xb8000], 0x0f410f41  ; "AA" in white

    ; Save multiboot info
    mov edi, ebx

    ; Debug: Write 'B' to show we're checking long mode
    mov dword [0xb8004], 0x0f420f42  ; "BB" in white

    ; Check for long mode support
    call check_long_mode
    test eax, eax
    jz .no_long_mode

    ; Debug: Write 'C' to show long mode is supported
    mov dword [0xb8008], 0x0f430f43  ; "CC" in white

    ; Set up paging
    call setup_page_tables

    ; Debug: Write 'D' to show paging is set up
    mov dword [0xb800c], 0x0f440f44  ; "DD" in white

    call enable_paging

    ; Debug: Write 'E' to show paging is enabled
    mov dword [0xb8010], 0x0f450f45  ; "EE" in white

    ; Load GDT
    lgdt [gdt64.pointer]

    ; Debug: Write 'F' before jump to long mode
    mov dword [0xb8014], 0x0f460f46  ; "FF" in white

    ; Jump to 64-bit code
    jmp gdt64.code:long_mode_start

.no_long_mode:
    ; Print error and halt
    mov dword [0xb8000], 0x4f4e4f4f ; "ON" in red (NO long mode)
    hlt

check_long_mode:
    ; Check for CPUID support
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
    xor eax, ecx
    jz .no_long_mode

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

setup_page_tables:
    ; Map P4[0] -> P3
    mov eax, p3_table
    or eax, 0b11  ; present + writable
    mov [p4_table], eax

    ; Map P3[0] -> P2
    mov eax, p2_table
    or eax, 0b11
    mov [p3_table], eax

    ; Map P2 entries to 2MB pages
    mov ecx, 0
.map_p2_table:
    mov eax, 0x200000
    mul ecx
    or eax, 0b10000011  ; present + writable + huge
    mov [p2_table + ecx * 8], eax

    inc ecx
    cmp ecx, 512
    jne .map_p2_table

    ret

enable_paging:
    ; Load P4 to cr3
    mov eax, p4_table
    mov cr3, eax

    ; Enable PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Enable long mode in EFER MSR
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; Enable paging
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ret

bits 64
long_mode_start:
    ; Clear segment registers
    mov ax, gdt64.data
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; Debug: Write 'G' to show we're in long mode
    mov rax, 0xb8018
    mov word [rax], 0x0f47  ; 'G' in white
    mov word [rax+2], 0x0f47

    ; Set up stack pointer
    mov rsp, stack_top

    ; Debug: Write 'H' before calling kernel
    mov rax, 0xb801c
    mov word [rax], 0x0f48  ; 'H' in white
    mov word [rax+2], 0x0f48

    ; Initialize serial port (COM1 = 0x3F8)
    mov dx, 0x3F9   ; COM1 + 1
    xor al, al
    out dx, al

    mov dx, 0x3FB   ; Line control
    mov al, 0x80
    out dx, al

    mov dx, 0x3F8   ; Divisor low
    mov al, 3
    out dx, al

    mov dx, 0x3F9   ; Divisor high
    xor al, al
    out dx, al

    mov dx, 0x3FB   ; Line control
    mov al, 3
    out dx, al

    mov dx, 0x3FA   ; FIFO control
    mov al, 0xC7
    out dx, al

    mov dx, 0x3FC   ; Modem control
    mov al, 0x0B
    out dx, al

    ; Write test message to serial
    mov dx, 0x3F8
    mov al, 'O'
    out dx, al
    mov al, 'K'
    out dx, al
    mov al, 10  ; newline
    out dx, al

    ; Call kernel main
    call kernel_main

    ; Debug: Write 'X' if kernel returns
    mov rax, 0xb8020
    mov word [rax], 0x0f58  ; 'X' in white

    ; Hang if kernel returns
.hang:
    hlt
    jmp .hang

; Port I/O functions (64-bit versions)
global outb
outb:
    mov dx, di      ; first arg (port) in rdi
    mov al, sil     ; second arg (value) in rsi
    out dx, al
    ret

global inb
inb:
    mov dx, di      ; port in rdi
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
