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
git clone <repository-url>
cd LLPL
dub build
```

This creates the `llpl` executable in the current directory.

## Your First LLPL Program

Create a file `hello.llpl`:

```swift
extern func putchar(c: int) -> int

func print(msg: char*) {
    let i: int = 0
    while msg[i] != 0 {
        putchar(msg[i] as int)
        i = i + 1
    }
}

func main() -> int {
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

This only targets ordinary hosted programs; a freestanding/kernel target
like `examples/baremetal_demo` still needs its own Makefile (custom linker
script, boot assembly, `-ffreestanding` flags) rather than `-b`.

## Language Syntax Cheat Sheet

### Variables
```swift
let x: int = 42              // Mutable variable
const MAX: int = 100         // Constant
let name: char* = "Bob"      // String literals are already char*, no cast needed
```

### Functions
```swift
func add(a: int, b: int) -> int {
    return a + b
}

func greet() {
    // No return value
}
```

### Classes
```swift
class Point {
    let x: int
    let y: int

    constructor(x: int, y: int) {
        self.x = x
        self.y = y
    }

    destructor() {
        // Cleanup
    }

    func distance() -> int {
        return self.x * self.x + self.y * self.y
    }
}

// Create instance
let p: Point = new Point(10, 20)
let d: int = p.distance()
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
for let i: int = 0, i < 10, i = i + 1 {
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
extern func malloc(size: uint) -> void*
extern func free(ptr: void*)

// Use them
let ptr: void* = malloc(100)
defer free(ptr)
```

## Building a Kernel

### Prerequisites

```bash
sudo apt-get install nasm gcc qemu-system-x86 grub-pc-bin xorriso
```

### Build and Run

```bash
cd examples
make run
```

This will:
1. Compile the LLPL kernel to C
2. Compile C to object files
3. Link with bootloader
4. Run in QEMU

### Kernel Output

You should see:
```
LLPL Kernel v0.1
================

Initializing serial port...
Testing control flow:
...
Kernel initialization complete!
System halted.
```

## Common Patterns

### Error Handling (Return Codes)

```swift
func open_file(path: char*) -> int {
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
    let size: int

    constructor(size: int) {
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

### Bitwise Operations

```swift
let flags: uint = 0
flags = flags | 1    // Set bit 0
flags = flags | 4    // Set bit 2
flags = flags & ~2   // Clear bit 1

if (flags & 1) != 0 {
    // Bit 0 is set
}
```

### Hardware I/O (Kernel)

```swift
extern func outb(port: uint, value: char)
extern func inb(port: uint) -> char

class SerialPort {
    let port: uint

    constructor(port: uint) {
        self.port = port
        self.init_port()
    }

    destructor() {}

    func init_port() {
        outb(self.port + 1, 0)
        // More initialization...
    }

    func write(c: char) {
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

| LLPL Type | C Type | Size | Description |
|-----------|--------|------|-------------|
| `int` | `int64_t` | 8 bytes | Signed integer |
| `uint` | `uint64_t` | 8 bytes | Unsigned integer |
| `int32` | `int32_t` | 4 bytes | Signed 32-bit integer |
| `uint32` | `uint32_t` | 4 bytes | Unsigned 32-bit integer |
| `int16` | `int16_t` | 2 bytes | Signed 16-bit integer |
| `uint16` | `uint16_t` | 2 bytes | Unsigned 16-bit integer |
| `char` | `char` | 1 byte | Character |
| `bool` | `int` | 4 bytes | Boolean |
| `void` | `void` | - | No value |
| `TypeName*` | `TypeName*` | 8 bytes | Pointer |
| `TypeName[N]` | `TypeName[N]` | N×size | Fixed array |

## Bit-fields

Class fields can declare a bit width, packing multiple fields into shared
storage - useful for hardware registers and on-disk/on-wire structures:

```
class PageEntry {
    let present: uint32 : 1
    let writable: uint32 : 1
    let user: uint32 : 1
    let reserved: uint32 : 5
    let frame: uint32 : 20
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
- Explore [examples/kernel.llpl](examples/kernel.llpl) for a complete kernel
- Check out [OSDev Wiki](https://wiki.osdev.org) for OS development guides

## Getting Help

Common errors:

**"Expected declaration"** - Check your syntax. Remember: no semicolons, no parentheses around conditions.

**"Unexpected token"** - You may have missed a closing brace or used incorrect syntax.

**"No such file"** - Make sure the runtime header is in the right place: `runtime/runtime.h`

**Kernel won't boot** - Verify GRUB is installed and `grub-mkrescue` is available.

Happy coding! 🚀
