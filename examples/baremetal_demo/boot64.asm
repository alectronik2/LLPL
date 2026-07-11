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

; 64-bit Task State Segment. We only populate RSP0, the kernel stack the CPU
; switches to when a ring-3 task is interrupted. The kernel updates RSP0 on
; every context switch so it always points to the current task's own kernel
; stack. The rest of the TSS is zero.
align 16
tss:
    resb 104

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

; Helpers used by the LLPL GDT/VMM modules to set up the TSS and page tables.
global get_pml4
get_pml4:
    mov rax, pml4
    ret

global get_tss
get_tss:
    mov rax, tss
    ret

global get_kernel_stack_top
get_kernel_stack_top:
    mov rax, stack_top
    ret

global set_tss_rsp0
set_tss_rsp0:
    mov rax, tss
    mov [rax + 4], rdi
    ret

global load_tss
load_tss:
    ltr di
    ret

; Preemptive multitasking (task.llpl): the timer IRQ (vector 32) is wired
; to this instead of a plain `interrupt func` - GCC's __attribute__((interrupt))
; generates its own fixed prologue/epilogue around a fixed stack, with no
; way to swap RSP out from under it mid-handler and iretq from a *different*
; stack than the one the interrupt arrived on, which is exactly what a
; context switch needs to do. So this hand-writes the save/restore, and
; only the scheduling *decision* is LLPL (Task.schedule_next, called here
; with the just-saved stack pointer, returning the one to resume).
;
; When entering from ring 3 the CPU switches to the TSS's RSP0 stack before
; pushing the interrupt frame, so the user task's own stack pointer does not
; need to be valid. The full SS/RSP/RFLAGS/CS/RIP frame (five words) is pushed
; for ring-3 entries, while ring-0 entries push only RFLAGS/CS/RIP (three
; words). In both cases our 15 GPR pushes sit on top of the CPU-pushed frame
; and iretq pops the right number of words automatically based on the saved
; CS's privilege level, exactly matching Task.llpl's TrapFrame layout.
global timer_isr_entry
extern Task_schedule_next
timer_isr_entry:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rdi, rsp        ; arg0 (System V) = the just-preempted task's frame
    call Task_schedule_next
    mov rsp, rax        ; rax (System V return) = the task to resume's frame

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq

; System-call entry point for ring-3 tasks. The IDT gate for vector 0x80 is
; configured with DPL=3 and IST=1, so a user `int 0x80` arrives here on the
; IST stack with the full interrupt frame already saved.
;
; ABI at entry: RAX = syscall number, RDI = arg1, RSI = arg2, RDX = arg3.
; Return value is placed back into the saved RAX slot so the user task sees
; it after iretq.
global syscall_isr_entry
extern Syscall_dispatch
extern Task_is_current_dead
extern Task_pick_next
syscall_isr_entry:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Load dispatch arguments from the saved user frame.
    ; Offsets are relative to RSP after our 15 pushes (R15 is at offset 0).
    mov rdi, [rsp + 112]        ; user RAX -> syscall number
    mov rsi, [rsp + 72]         ; user RDI -> arg1
    mov rdx, [rsp + 80]         ; user RSI -> arg2
    mov rcx, [rsp + 88]         ; user RDX -> arg3
    call Syscall_dispatch
    mov [rsp + 112], rax        ; write return value into saved RAX

    ; If the syscall was SYS_EXIT, switch away from the dead task now instead
    ; of returning to it.
    call Task_is_current_dead
    test eax, eax
    jz .return

    mov rdi, rsp
    call Task_pick_next
    mov rsp, rax

.return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq

; Called once, by Task.start(), to make the very first switch from plain
; boot-time execution into the task table - never returns. Identical to
; timer_isr_entry's restore half, just fed a stack pointer directly instead
; of one a real interrupt produced; Task.spawn() fakes up a TrapFrame ahead
; of time (RIP = the task's entry point) for exactly this to jump into.
global start_first_task
start_first_task:
    mov rsp, rdi        ; arg0 (System V) = the frame to resume

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    iretq
