# LLPL Limine Bare-Metal Demo

This example is an experimental x86-64 kernel written in LLPL. Limine loads
the kernel as a higher-half ELF and enters it in long mode with paging enabled.
The project started as a boot-protocol demo and now also exercises several
early operating-system subsystems.

## What it demonstrates

- Limine framebuffer, memory-map, HHDM, and module requests
- BIOS and optional UEFI boot from a hybrid ISO
- COM1 serial diagnostics and panic output
- a framebuffer terminal with TrueType font rendering and ANSI colors
- physical-page allocation, virtual memory, kernel and process address spaces,
- an Intel 82540EM/E1000 PCI network driver with DMA transmit/receive rings,
  and anonymous user mappings
- GDT, TSS, IDT, PIC, PIT, interrupt handling, and per-CPU state
- priority run queues, timer-driven context switching, and kernel threads
- per-thread x87/SSE/SSE2 state for floating-point user programs
- a bounded, allocation-free IRQ deferred-work queue serviced by a kernel
  worker thread
- priority-aware wait queues, blocking/wakeup primitives, and a lowest-priority
  idle thread
- an ELF64 loader and a ring 3 `/bin/init` process using `syscall`/`sysret`,
  checked user-memory copies, anonymous `mmap`, file descriptors, serial
  output, and thread exit
- an interactive ring 3 shell using the keyboard device and serial console, with
  built-ins and synchronous launch/wait of programs from `/bin`
- reference-counted kernel objects and handles
- an in-memory VFS populated from a tar initrd supplied as a Limine module
- framebuffer memory-map visualization and serial memory diagnostics

This is a development demo, not a production kernel or a stable kernel API.

## Prerequisites

Build the LLPL compiler, `llplbuild`, and the m64 assembler in the repository
before building this example. The configured toolchain also requires:

- `tcc`
- GNU `ld`
- `xorriso`
- `qemu-system-x86_64`
- a Limine installation containing `limine`, `limine-bios.sys`,
  `limine-bios-cd.bin`, and `limine-uefi-cd.bin`

`BOOTX64.EFI` is copied when present; the BIOS boot files are required.

## Build and run

Run the build tool from this directory:

```sh
../../tools/llplbuild/llplbuild build
```

`build` compiles and links `kernel.elf`. To create `kernel.iso` and launch it
in QEMU, use:

```sh
../../tools/llplbuild/llplbuild run
```

The ISO packaging is marked `run_only` in `build.yaml`, so it is performed by
`run`, not by a plain `build`. QEMU boots the ISO with 256 MiB of RAM and sends
COM1 output to the invoking terminal. Exit QEMU with `Ctrl-A`, then `X`.

The default configuration is `final`. A debug build is available with:

```sh
../../tools/llplbuild/llplbuild build -c debug
```

For a compile/assemble check without linking or packaging:

```sh
../../tools/llplbuild/llplbuild check
```

See [`../../tools/llplbuild/README.md`](../../tools/llplbuild/README.md) for
the complete build-tool reference.

## Limine location

`build.yaml` defines `LIMINE_DIR`, the directory from which the packaging
step copies Limine's executable and boot assets. Override it when Limine is
installed elsewhere:

```sh
../../tools/llplbuild/llplbuild run --var LIMINE_DIR=/path/to/limine
```

The same declared variable can also be supplied through the `LIMINE_DIR`
environment variable. An explicit `--var` override has the highest priority.

## Boot flow

`limine.conf` loads `kernel.elf` and attaches `initrd.tar` as a module at a
requested resolution of 1024x768x32. During `run`, the build tool compiles the
freestanding `user/init.c` program, copies its ELF to `initrd/bin/init`, and
creates the tar archive from `initrd/`.

At startup the kernel:

1. validates Limine's framebuffer, memory-map, and HHDM responses;
2. initializes descriptor tables, syscalls, interrupts, the timer, and memory
   management;
3. creates kernel threads, initializes the VFS from the initrd module, and
   loads the `PT_LOAD` segments of `/bin/init` into a new user process;
4. enables interrupts, draws the framebuffer demo, and leaves scheduling to
   PIT interrupts while the bootstrap context halts.

The framebuffer displays a color gradient, terminal diagnostics, and a memory
map bar. Its colors are:

- green: usable memory
- grey: reserved memory
- blue: ACPI-reclaimable and bootloader-reclaimable memory
- yellow: ACPI NVS and kernel/modules
- red: bad memory
- pink: framebuffer memory

After boot, click the QEMU display to direct keyboard input to the guest and
use the `$` prompt shown in the serial terminal. The Fish-inspired shell supports
`help`, `echo`, `cat`, `ls`, `cd`, `pwd`, `mkdir`, `touch`, `cp`, `rm`, `clear`,
`pid`, `ps`, `history`, and `exit`, with
live syntax coloring; any other command is resolved
under `/bin` and run as a child process. For example, `cat /etc/motd` reads a
file from the initrd and `child` runs `/bin/child`.
The line editor supports insertion at the cursor, Backspace/Delete,
Left/Right, Home/End, and Up/Down command history. It also provides gray inline
history autosuggestions (Right accepts one), command and path completion with
Tab, Ctrl-R prefix history search, pipelines, and input/output redirection.
History is stored in `/var/fish_history`, so it survives shell restarts during
the current boot. The current root filesystem is memory-backed, so it does not
yet survive a machine reboot.

`cp SOURCE DEST` copies files using descriptor-backed binary I/O. `rm FILE`
uses the kernel unlink operation (syscall 73), while `mkdir` and `touch` use
syscalls 74 and 75 to reach the VFS implementations. Directory removal and
recursive operations are intentionally not enabled yet.

Serial output includes initialization diagnostics, initrd/VFS checks, kernel
thread activity, and `/bin/init` output. The init program prints a greeting,
requests an anonymous page, then runs a descriptor round-trip test before
exiting.

## User file descriptors

Each process owns a locked 64-entry descriptor table; descriptors 0–2 are
reserved for future console devices. The current syscall ABI provides `open`,
`read`, `write`, `close`, and `seek` over VFS files. Every userspace path and
buffer crosses the checked page-table copy helpers, and individual descriptors
maintain independent offsets.

`/bin/init` creates `/var/user-fd-test.txt`, writes a payload, seeks to the
beginning, reads and verifies the payload, closes the descriptor, and checks
that a subsequent read fails. A successful run prints `FD self-test: PASS`.

Processes also receive stable kernel PIDs and parent/child links. Process exit
records a status, reparents orphaned children to the kernel process, and wakes
threads blocked in `wait_process(parent, pid, &status)`. Syscall 9 exposes the
current PID; syscall 2 now exits the process as well as its current thread.
Collecting an exited child performs one-time resource teardown: it destroys the
child's VMA tree, releases its mapped frames and user page-table hierarchy, and
drops its descriptor table. A boot-time integration test creates a synthetic
child, maps memory into it, exits it, and verifies its status and reclaimed
resources through `wait_process`.

Anonymous mappings are demand-paged: `mmap` reserves a VMA without allocating
physical storage, and the first valid user access installs a zero-filled 4 KiB
page. Protection violations and accesses outside a user VMA still terminate
the faulting thread. `/bin/init` touches two separate pages and verifies their
zero-fill and persistence; success prints `Demand paging self-test: PASS`.

`clone_process_address_space` duplicates the VMA layout while sharing present
frames with incremented references. Writable leaves in both address spaces are
changed to read-only software-marked COW entries. A subsequent user write fault
copies the original page, installs a private writable leaf, invalidates the TLB
entry, and releases that address space's reference to the shared frame.
Read-only pages remain read-only rather than becoming implicitly copyable. The
kernel boot test verifies initial sharing, copied contents, parent/child write
isolation, reference counts, and cleanup of both cloned processes.

## File mappings and process execution

Syscall 11 creates a lazy file-backed mapping from an open descriptor. Pages
are populated from the VFS on first access. Writable mappings initially remain
read-only so the first write fault can mark the leaf dirty; syscall 12 (`msync`)
writes dirty pages back for shared mappings and restores write tracking.
Unmapping or reaping a process also flushes shared dirty pages. Private and
read-only mappings never write back.

Syscalls 13–15 provide `spawn`, `exec`, and `waitpid`. Spawn uses the reusable
ELF loader and establishes normal parent/child ownership. Waitpid blocks on the
process wait queue and returns the collected exit status. In this small kernel,
exec is a supervised replacement transition: it launches the requested image,
waits internally, propagates its status, and never resumes the previous image.
The init program validates direct spawning and an exec transition with the
separate `/bin/child` and `/bin/execer` images.

## User threads

Syscalls 16–20 provide user-thread creation, thread exit, join, detach, and TLS
base inspection. Each user thread receives a demand-paged 16 KiB user stack, a
stable kernel thread ID, its entry argument in `RDI`, and an independent FS-base
TLS value restored on every context switch. Join returns the thread exit value;
detached threads are reclaimed by the existing reaper. Process exit marks all
other threads as zombies and removes ready siblings from scheduler queues.

Syscall 10 unmaps user memory. `MM.vm_drop_memory` releases mapped 4 KiB page
frames, invalidates active TLB entries, and prunes empty PT, PD, and PDPT
tables. `/bin/init` verifies teardown by unmapping an anonymous page and
remapping the same address; success prints `VM unmap self-test: PASS`.

## Deferred interrupt work

Interrupt handlers can queue a non-capturing callback for execution by the
kernel deferred-work thread:

```llpl
func finish_io(arg: void*) {
    // Runs in thread context; allocation and blocking operations are allowed.
}

func device_irq(arg: void*) {
    if !Kern.Deferred.queue(finish_io, arg) {
        // The fixed 64-entry queue is full, or the callback captures state.
    }
}
```

Enqueueing is bounded and performs no allocation. Capturing closures are
rejected because retaining their environment is not IRQ-safe. Callers should
pass any required state through `arg` and ensure it remains valid until the
callback runs. `Kern.Deferred.dropped_count()` reports queue-overflow drops.
The PIT queues a serial heartbeat once per second as a working example.
When no work is pending, the deferred worker blocks on a wait queue rather
than yielding repeatedly. Enqueueing work wakes it from interrupt context.

## Waiting and wakeups

Kernel threads can block without polling:

```llpl
let waiters = new Kern.WaitQueue()

// In thread context:
Kern.block_current(waiters)

// In thread or interrupt context:
Kern.wake_one(waiters)
Kern.wake_all(waiters)

// Returns true when explicitly woken, false when 250 ms expires.
let signaled = Kern.block_current_timeout_ms(waiters, 250)
```

`wake_one` selects the numerically lowest, highest-priority waiter. All queue
operations use intrusive thread links and perform no allocation after the
wait queue is created. Condition-variable implementations can use
`prepare_block_current()` to register a waiter while holding their condition
lock, then call `scheduler_yield()` after releasing it. A priority-31 idle
thread provides a scheduling target when every ordinary thread is blocked.
Timed waits are also available in tick form through
`block_current_timeout_ticks()`; normal wakeups cancel the pending deadline.

## Synchronization primitives

Sleeping mutexes and counting semaphores build on the same wait queues:

```llpl
let mutex = new Kern.BlockingMutex()
if mutex.lock_timeout_ms(100) {
    // protected work
    mutex.unlock()
}

let available = new Kern.Semaphore(0)
available.post()
available.wait()
```

`BlockingMutex` is non-recursive and only its owning thread may unlock it. It provides
`try_lock`, `lock`, and tick/millisecond timed locking. `Semaphore` provides
`try_wait`, `wait`, timed waits, `post(amount)`, and `value`. Contended callers
sleep instead of polling; wakeups remain priority-aware. Semaphore posting
rejects counter overflow.

Condition variables provide `wait(mutex)`, timed waits, `signal()`, and
`broadcast()`. Waiting atomically registers the caller and releases its
`BlockingMutex`; the mutex is reacquired before the call returns, including
after a timeout.

Blocking mutexes implement priority inheritance. A higher-priority waiter
donates its effective priority to the owner, including through bounded nested
mutex chains. Unlocking recomputes the owner priority from its base priority
and any other mutexes it still holds.

## Thread lifecycle and statistics

Kernel threads can terminate with `thread_exit(value)`. A joinable thread keeps
its exit value until `join_thread(thread, &value)` collects it. Alternatively,
`detach_thread(thread)` transfers cleanup to the kernel reaper. Stack memory is
never released by the exiting thread itself: joiners or the reaper reclaim it
only after a context switch has moved execution onto another stack.

`thread_stats(thread)` returns runtime ticks, context-switch count, wakeups,
voluntary yields, and total ticks spent sleeping or blocked. Priority APIs now
distinguish the requested base priority from the effective inherited priority;
`thread_priority()` reports the current effective value.

Kernel startup runs a coordinated multi-threaded self-test covering mutex
ownership, priority donation/restoration, condition signaling and timeouts,
semaphores, join exit values, detached reaping, and scheduler statistics. A
successful boot prints `Sync self-test: PASS` to COM1; failures print the
individual assertion names.

Threads can also sleep on the PIT clock without busy-waiting:

```llpl
Kern.sleep_ticks(5)
Kern.sleep_ms(250)
```

Non-zero millisecond delays round up to the next 10 ms PIT tick. Sleeping
threads live in an intrusive deadline-ordered queue; the timer interrupt moves
expired threads directly onto their priority run queues without allocating.

## Pipes and descriptor duplication

Processes can create a blocking 4096-byte pipe with syscall 21. Reads sleep
while an open writer could still produce data, writes sleep while the buffer is
full, closing the last writer produces EOF, and writing without readers returns
an error. Pipe wait queues are allocation-free after construction.

Syscalls 22 and 23 implement `dup` and `dup2`. Duplicated descriptors share the
same open descriptor, including its pipe endpoint or file offset. Spawned
processes inherit descriptors by default. Syscall 24 controls close-on-exec;
flagged descriptors are omitted when the new executable's descriptor table is
built. Kernel startup exercises pipe I/O, duplication, inheritance, and
close-on-exec from user space.

## Message queues

Named message queues provide message-oriented IPC in addition to byte-stream
pipes and shared memory. `mq_create` (syscall 66) creates a bounded queue and
returns a waitable descriptor; unrelated processes can rendezvous with
`mq_open` (67). `mq_send` (69) and `mq_receive` (70) block when the queue is
full or empty, preserve message boundaries, and deliver higher numeric
priorities first while retaining FIFO order among equal priorities. Messages
may contain up to 4096 bytes, and queue depths may range from 1 to 1024.

`mq_receive` leaves the oldest eligible message queued and returns `EMSGSIZE`
when the supplied buffer is too small. A queue descriptor works with the
ordinary close, dup, inheritance, close-on-exec, and wait-handle operations.
`mq_unlink` (68) removes the name immediately while existing descriptors keep
the queue alive.

## Freestanding C compatibility

`user/include` and `user/lib/libc.c` provide the libc subset needed by an
embedded Lua runtime: memory and string operations, character classification,
decimal and integer conversion, descriptor-backed `FILE` streams, formatted
output (including floating point), `errno`, C locale stubs, clocks, and
`setjmp`/`longjmp`. Unsupported filesystem mutations such as `remove` and
`rename` currently fail with `EINVAL`; Lua's OS library should expose those as
unavailable until matching kernel operations are added.

## Lua

The initrd includes an official Lua 5.4.9 interpreter at `/bin/lua`, built as
a static freestanding user ELF. It supports script files and a basic keyboard
REPL, with the base, coroutine, table, string, UTF-8, math, debug, package,
I/O, and restricted OS libraries registered. Native dynamic modules and host
commands are unavailable; `package` can still load pure Lua modules from the
initrd or writable memory filesystem.

```text
lua /etc/lua_smoke.lua
lua
```

## Text editor

`/bin/edit` is a small full-screen editor for Lua source files. It provides
insertion and backspace editing, arrow-key navigation, vertical scrolling,
Ctrl-S save, Ctrl-Q quit, an unsaved-change guard, and ANSI highlighting for
Lua keywords, comments, strings, and numbers.

```text
edit /etc/lua_smoke.lua
```

## TinyGL

The maintained C99 TinyGL software renderer is built as `build/libTinyGL.a`.
The `/bin/tinygl` demonstration renders a depth-tested, smoothly rotating
multicolored cube into a private 320x240 color buffer. Use the arrow keys to
adjust its rotation and Q to return to the shell.

```text
tinygl
```

Syscall 71 returns the display dimensions and packed `0x00RRGGBB` surface
format. Syscall 72 validates and presents a userspace color buffer centered on
the display. It copies each row through kernel-owned staging memory, so an
application never receives the physical framebuffer address. The init program
checks framebuffer discovery and invalid-surface rejection on every boot.

The shell registers each foreground child with the kernel. Ctrl-C therefore
terminates the active program (including `/bin/tinygl`) with conventional exit
status 130 and returns to the shell prompt.

## Process heap

Each user process owns a demand-paged heap beginning at `0x40000000`, below a
fixed `0x60000000` ceiling. Syscall 25 implements `brk`: passing zero queries the
current break, growth reserves anonymous writable virtual memory, and shrinking
unmaps complete pages above the new break. Syscall 26 implements signed `sbrk`
and returns the previous break on success. Overflow, underflow, and collisions
with existing mappings are rejected. The init self-test grows across two pages,
faults both pages in, and then returns the break to its original value.

## Thread priorities

The scheduler provides 32 priority levels. Priority `0` is the highest and
priority `31` is the lowest. Priorities can be inspected or changed while a
thread is running:

```llpl
let old_priority = Kern.thread_priority(thread)

if !Kern.set_thread_priority(thread, 8) {
    // Invalid thread/state or priority outside 0..31.
}

// Change the calling thread and yield immediately so the new ordering applies.
Kern.set_current_thread_priority(20)
```

Changing a ready thread removes it from its old run queue and inserts it into
the new queue atomically without allocating memory. Changing a running,
sleeping, or newly created thread updates the priority used the next time it is
made ready. Passing `false` as the second argument to
`set_current_thread_priority` suppresses its automatic yield.

## Source layout

| Path | Purpose |
| --- | --- |
| `kernel.llpl` | Limine requests and top-level kernel initialization |
| `hal/` | x86-64 CPU, descriptor tables, interrupts, PIC/PIT, serial, and syscalls |
| `mm/` | page-frame allocator, paging, heap, and address spaces |
| `kern/` | processes, threads/scheduler, timers, handles, and VFS |
| `lib/` | terminal/font rendering, spinlocks, and kernel objects |
| `initrd/` | files packed into the boot initrd |
| `user/` | freestanding init, LLPL shell, user programs, syscall bindings, and linker script |
| `limine.conf` | Limine boot entry and module configuration |
| `build.yaml` | compiler, linker, ISO packaging, and QEMU configuration |
| `linker.ld` | higher-half kernel linker script |
