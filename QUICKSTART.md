# LLPL Quick Start Guide

## Installation

### Prerequisites

```bash
# Install D compiler and DUB
# On Ubuntu/Debian:
sudo apt-get install dmd dub

# On Arch Linux:
sudo pacman -S dmd dub

# Or use LDC (LLVM D Compiler):
sudo apt-get install ldc dub
```

### Build the Compiler

```bash
git clone https://github.com/alectronik2/LLPL.git
cd LLPL
dub build
```

This creates the `llpl` executable in the current directory.

## Your First LLPL Program

Create a file `hello.llpl`:

```swift
extern func putchar(c: i64) -> i64

func print(msg: char*) {
    let i: i64 = 0
    while msg[i] != 0 {
        putchar(msg[i] as i64)
        i = i + 1
    }
}

func main() -> i64 {
    print("Hello, LLPL!\n")
    return 0
}
```

Compile and run:

```bash
./llpl hello.llpl -o hello.c
gcc hello.c -o hello
./hello
```

Or skip the separate `gcc` step and compile straight to a binary with
`-b`/`--binary` (invokes a system C compiler - `cc` by default, or `$CC`,
or `--cc=<path>` - and links against `runtime/runtime.c` automatically):

```bash
./llpl hello.llpl -b -o hello
./hello
```

Add `--safe` to enable runtime bounds checks on fixed-size array indexing
(`T[N]` locals, globals, and class fields):

```bash
./llpl --safe hello.llpl -b -o hello
```

This only targets ordinary hosted programs; a freestanding/kernel target
like `examples/baremetal_demo` still needs its own `tools/llplbuild` build
(custom linker script, boot assembly, `-ffreestanding` flags) rather than
`-b` - see [Building a Kernel](#building-a-kernel) below.

## Language Syntax Cheat Sheet

### Variables
```swift
let x: i64 = 42              // Mutable variable
const MAX: i64 = 100         // Constant
let name: char* = "Bob"        // String literals are already char*, no cast needed
```

### Functions
```swift
func add(a: i64, b: i64) -> i64 {
    return a + b
}

func greet() {
    // No return value
}
```

### Classes
```swift
class Point {
    let x: i64
    let y: i64

    constructor(x: i64, y: i64) {
        self.x = x
        self.y = y
    }

    destructor() {
        // Cleanup
    }

    func distance() -> i64 {
        return self.x * self.x + self.y * self.y
    }
}

// Create instance
let p: Point = new Point(10, 20)
let d: i64 = p.distance()
```

### Control Flow

```swift
// If (no parentheses!)
if x > 10 {
    // do something
} else {
    // do something else
}

// While
while count < 10 {
    count = count + 1
}

// For loop: init, condition, update
for let i: i64 = 0, i < 10, i = i + 1 {
    // loop body
}

// for x in y: iterates a fixed array or anything implementing Iterator<T>
for item in my_vector {
    // loop body
}
```

### Defer
```swift
func process_file() {
    let file: File = new File("data.txt")
    defer file.close()  // Executes at end of function

    // Process file...
    // file.close() called automatically
}
```

### C FFI
```swift
// Declare C functions
extern func malloc(size: u64) -> void*
extern func free(ptr: void*)

// Use them
let ptr: void* = malloc(100)
defer free(ptr)
```

### Inline Assembly
```swift
func read_cr0() -> u64 {
    let value: u64 = 0
    asm("mov %%cr0, %0" : "=r"(value))
    return value
}
```

### Tuples and Destructuring
```swift
func pair() -> (i64, i64) {
    return (1, 2)
}

func main() -> i64 {
    let t: (i64, i64) = (10, 20)
    let a: i64 = t._0
    let b: i64 = t._1

    let (x, y) = pair()          // tuple destructuring

    struct Point { let x: i64; let y: i64 }
    let p = Point { x: 3, y: 4 }
    let Point { px, py } = p     // struct destructuring

    match t {
        case (u, v) => { print_int("u", u) }
    }

    return 0
}
```

### Traits and Bounded Generics
```swift
trait Hashable {
    func hash() -> u64
    func equals(other: Self) -> bool
}

impl Hashable for i64 {
    func hash() -> u64 { return self as u64 }
    func equals(other: i64) -> bool { return self == other }
}

func hash_of<T: Hashable>(v: T) -> u64 {
    return v.hash()
}
```

## Building a Kernel

### Prerequisites

```bash
sudo apt-get install nasm gcc qemu-system-x86 grub-pc-bin xorriso
```

### Build and Run

`examples/baremetal_demo` (GRUB/Multiboot2) and `examples/limine_baremetal_demo`
(Limine) are built and run with `tools/llplbuild` - a YAML-configured build
tool (see `tools/llplbuild/README.md`), not a plain Makefile:

```bash
cd examples/baremetal_demo
../../tools/llplbuild/llplbuild run       # build, then launch QEMU
```

This will:
1. Compile `kernel.llpl` to C
2. Compile the C code with the runtime
3. Assemble the bootloader
4. Link everything into a kernel binary and package a bootable ISO
5. Launch QEMU

### Kernel Output

You should see output like:
```
LLPL Bare-Metal Demo
=====================
colors: red green yellow cyan - a single log() call, tags inline
Loading a fresh GDT from LLPL...
GDT reloaded: base=0x0000000000163a00 limit=0x37
Installing IDT and remapping the PIC...
IDT installed (timer on IRQ0, keyboard on IRQ1).
Triggering a breakpoint exception (int3)...
Breakpoint (int3) handled, resuming...
...resumed after the fault handler returned via iretq.
Enabling interrupts...
Interrupts enabled.
Spawning tasks (shell + a background counter) and starting the scheduler...
spawned user task 2 from atad.elf (entry=0x1000004d0)
spawned user task 3 from wm.elf (entry=0x100003370)
spawned user task 4 from netd.elf (entry=0x100002070)
Starting the shell. Type 'help' for a list of commands.
llpl $ atad: Bus Master DMA enabled
netd: e1000 up, mac=52:54:00:12:34:56
wm: loading wallpaper...
wm: ready
ATA: primary master detected (via atad); VFS mounted (self-formats on first boot)
netd: DHCP ok, ip=10.0.2.15 gw=10.0.2.2
SELFTEST: PASS
```

By this point you have a preemptive multitasking kernel with a real
network stack (DHCP-configured, ARP/ICMP), a persistent VFS on a virtual
disk, and a windowing compositor with a mouse-driven desktop - see the
README's [Bare-Metal Demo Highlights](README.md#bare-metal-demo-highlights)
for what's actually running underneath that boot log.

## Common Patterns

### Error Handling (Return Codes)

```swift
func open_file(path: char*) -> i64 {
    if path == null {
        return -1  // Error
    }
    // ...
    return 0  // Success
}

func caller() {
    if open_file("test.txt") != 0 {
        // Handle error
    }
}
```

### Resource Management

```swift
class Buffer {
    let data: char*
    let size: i64

    constructor(size: i64) {
        self.size = size
        self.data = malloc(size) as char*
    }

    destructor() {
        if self.data != null {
            free(self.data as void*)
        }
    }
}

func use_buffer() {
    let buf: Buffer = new Buffer(1024)
    defer buf = null  // Trigger destructor

    // Use buffer...
    // Automatically cleaned up
}
```

### Error Handling with Result<T, E>
```swift
func safe_div(a: i64, b: i64) -> Result<i64, char*> {
    let r: Result<i64, char*> = new Result<i64, char*>()
    if b == 0 {
        r.set_err("division by zero")
        return r
    }
    r.set_ok(a / b)
    return r
}

func sum(a: i64, b: i64, c: i64, d: i64) -> Result<i64, char*> {
    let x: i64 = safe_div(a, b)?
    let y: i64 = safe_div(c, d)?
    let r: Result<i64, char*> = new Result<i64, char*>()
    r.set_ok(x + y)
    return r
}
```

### Panics
```swift
extern func llpl_panic(msg: char*)

func must_be_positive(n: i64) {
    if n <= 0 {
        llpl_panic("expected positive value")
    }
}
```

### Assert
```swift
func must_be_positive(n: i64) {
    assert(n > 0, "expected positive value")
}
```

### Bitwise Operations

```swift
let flags: u64 = 0
flags = flags | 1    // Set bit 0
flags = flags | 4    // Set bit 2
flags = flags & ~2   // Clear bit 1

if (flags & 1) != 0 {
    // Bit 0 is set
}
```

### Hardware I/O (Kernel)

```swift
extern func outb(port: u64, value: u8)
extern func inb(port: u64) -> u8

class SerialPort {
    let port: u64

    constructor(port: u64) {
        self.port = port
        self.init_port()
    }

    destructor() {}

    func init_port() {
        outb(self.port + 1, 0)
        // More initialization...
    }

    func write(c: u8) {
        while (inb(self.port + 5) & 32) == 0 {
            // Wait for ready
        }
        outb(self.port, c)
    }
}
```

## Debugging Tips

### Verbose Compilation

```bash
./llpl program.llpl -v
```

### Inspect Generated C

```bash
./llpl program.llpl -o output.c
cat output.c
```

### QEMU Serial Output

```bash
qemu-system-x86_64 -kernel kernel.bin -serial stdio
```

Serial port output appears in terminal.

### QEMU Debugging

```bash
qemu-system-x86_64 -kernel kernel.bin -s -S
# In another terminal:
gdb kernel.bin
(gdb) target remote :1234
(gdb) continue
```

## Type Reference

> **History:** the bare, unsized `int`/`uint` spellings were removed for a
> while (a hard compile error telling you to spell out `i64`/`u64`
> instead), then brought back with new, different semantics. `char` went
> through the same removed-then-restored arc, also with new semantics.

| LLPL Type | C Type | Size | Description |
|-----------|--------|------|-------------|
| `i8`/`i16`/`i32`/`i64` | `int8_t`...`int64_t` | 1-8 bytes | Signed integers |
| `u8`/`u16`/`u32`/`u64` | `uint8_t`...`uint64_t` | 1-8 bytes | Unsigned integers - genuinely numeric, `u8` is `uint8_t` not `char` |
| `char` | `char` | 1 byte | One byte of *text* - distinct from `u8` even though both are 8 bits |
| `int`/`uint` | `intptr_t`/`uintptr_t` | 4 or 8 bytes | Native machine word (4 on i386, 8 on x86_64) - **not** aliases of `i64`/`u64`; no implicit widening to/from a fixed-width type |
| `bool` | real C99 `bool` | 1 byte | Boolean (`<stdbool.h>`) |
| `void` | `void` | - | No value |
| `float`/`double` | `float`/`double` | 4/8 bytes | Floating point |
| `string` | `char*` | 8 bytes | Alias (`prelude.llpl`: `alias string = char*`) |
| `TypeName*` | `TypeName*` | 8 bytes | Pointer |
| `TypeName[N]` | `TypeName[N]` | N×size | Fixed array |

## Bit-fields

Class fields can declare a bit width, packing multiple fields into shared
storage - useful for hardware registers and on-disk/on-wire structures:

```
class PageEntry {
    let present: u32 : 1
    let writable: u32 : 1
    let user: u32 : 1
    let reserved: u32 : 5
    let frame: u32 : 20
}
```

Bit-fields are only valid on class fields (not globals or locals), must have
an integer or `bool` backing type, and their width can't exceed that type's
bit size.

## Operator Reference

### Arithmetic
- `+` Addition
- `-` Subtraction
- `*` Multiplication
- `/` Division
- `%` Modulo

### Comparison
- `==` Equal
- `!=` Not equal
- `<` Less than
- `>` Greater than
- `<=` Less or equal
- `>=` Greater or equal

### Logical
- `&&` Logical AND
- `||` Logical OR
- `!` Logical NOT

### Bitwise
- `&` AND
- `|` OR
- `^` XOR
- `~` NOT
- `<<` Left shift
- `>>` Right shift

### Other
- `=` Assignment
- `.` Member access
- `[]` Array subscript
- `as` Type cast

## Next Steps

- Read the full [README.md](README.md) for detailed documentation
- Browse the [full documentation site](https://alectronik2.github.io/LLPL/llpl-docs.html) - compiler CLI, standard library API, and a guided tour of every example
- Explore [examples/baremetal_demo](examples/baremetal_demo) for a complete kernel with networking and a windowing compositor
- Check out [OSDev Wiki](https://wiki.osdev.org) for OS development guides

## Getting Help

Common errors:

**"Expected declaration"** - Check your syntax. Remember: no semicolons, no parentheses around conditions.

**"Unexpected token"** - You may have missed a closing brace or used incorrect syntax.

**"No such file"** - Make sure the runtime header is in the right place: `runtime/runtime.h`

**Kernel won't boot** - Verify GRUB is installed and `grub-mkrescue` is available.

Happy coding! 🚀
