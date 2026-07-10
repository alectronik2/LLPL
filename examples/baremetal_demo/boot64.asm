; Working 64-bit bootloader for LLPL
; Based on proven patterns for mode transition

section .multiboot
align 8
header_start:
    dd 0xe85250d6                           ; magic number
    dd 0                                    ; architecture (i386)
    dd header_end - header_start            ; header length
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))

    ; Framebuffer request tag: ask GRUB for a 1024x768x32 linear
    ; framebuffer. GRUB reports back whatever it actually set up (not
    ; necessarily this exact mode) via the framebuffer info tag in the
    ; multiboot info structure handed to us in EBX - see fb.llpl, which
    ; walks that tag list rather than assuming these numbers.
    align 8
fb_tag_start:
    dw 5                                    ; type = framebuffer
    dw 0                                    ; flags
    dd fb_tag_end - fb_tag_start            ; size - covers this *whole*
                                             ; tag (type+flags+size+payload),
                                             ; not just the payload below -
                                             ; getting this wrong desyncs
                                             ; GRUB's tag-list parser, which
                                             ; then misreads payload bytes
                                             ; as a bogus next tag.
    dd 1024                                 ; width
    dd 768                                  ; height
    dd 32                                   ; depth (bits per pixel)
fb_tag_end:

    ; End tag
    align 8
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
; multiboot2's info-structure pointer (handed to us in EBX at entry) - saved
; immediately, before CPUID (which clobbers EBX as a side effect) can
; destroy it. Always a 32-bit physical address in this boot protocol.
multiboot_ptr:
    resd 1
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

    ; Save the multiboot info pointer (EBX) *before* anything that might
    ; clobber it - CPUID (used below) writes EBX as a side effect even
    ; when its result isn't the register we care about.
    mov [multiboot_ptr], ebx

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

    ; Update CS with far jump
    push 0x08
    mov eax, long_mode_entry
    push eax
    retf

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
    mov ecx, 2 * 4096 / 4
    xor eax, eax
    rep stosd

    ; PML4[0] -> PDPT
    mov eax, pdpt
    or eax, 0x03  ; present + writable
    mov [pml4], eax

    ; Identity-map the first 4GB directly from the PDPT using four 1GB
    ; pages (present + writable + huge/PS) - no PD or PT needed at all.
    ; A linear framebuffer from GRUB/VBE can sit well above the 2MB this
    ; used to map (often just under the 4GB boundary, in PCI MMIO space),
    ; so a single 2MB huge page isn't enough once fb.llpl needs to reach
    ; it. 1GB pages need CPUID.80000001H:EDX.Page1GB, which every CPU this
    ; project targets (real x86-64 since ~2010, and QEMU's default -cpu)
    ; has - same trust-the-target-hardware trade-off as the rest of this
    ; boot code (no runtime feature probe).
    mov eax, 0x83
    mov edi, pdpt
    mov ecx, 4
.fill_pdpt:
    mov [edi], eax
    add eax, 0x40000000
    add edi, 8
    loop .fill_pdpt

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

    ; Call kernel_main(multiboot_ptr) - System V AMD64: first integer
    ; argument in RDI. `mov edi, ...` zero-extends into RDI, which is
    ; correct here since multiboot_ptr is always a 32-bit physical address.
    xor rbp, rbp
    mov edi, [multiboot_ptr]
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

; Returns _kernel_end (set by linker64.ld, just past .bss) so pagealloc.llpl
; knows where the kernel image ends and free physical memory can start.
global get_kernel_end
extern _kernel_end
get_kernel_end:
    mov rax, _kernel_end
    ret
