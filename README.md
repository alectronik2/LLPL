# LLPL - Low Level Programming Language

A low-level programming language with Swift/JavaScript-like syntax that compiles to C for bare-metal x86_64 kernel development.

## Features

- **Modern Syntax**: Clean syntax inspired by Swift and JavaScript
- **No Semicolons**: Statement termination without semicolons
- **No Expression Parentheses**: Clean if/while statements without parentheses
- **Classes**: Object-oriented programming with constructors and destructors
- **Automatic Reference Counting**: Memory management without manual malloc/free
- **Defer Statement**: Resource cleanup similar to Swift
- **Macros**: Compile-time expansion with `quote`/`unquote`
- **C FFI**: Easy interoperability with C code
- **Bare Metal**: Compiles to efficient C code for kernel development

## Language Syntax

### Variables

```swift
let x: int = 42
const PI: int = 314
let name: char* = "Hello"
```

### Functions

```swift
func add(a: int, b: int) -> int {
    return a + b
}

func greet(name: char*) {
    print(name)
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
        // Cleanup code
    }

    func distance() -> int {
        return self.x * self.x + self.y * self.y
    }
}

// Usage
let p: Point = new Point(10, 20)
let dist: int = p.distance()
```

### Control Flow

```swift
// If statements (no parentheses!)
if x > 10 {
    print("Big")
} else {
    print("Small")
}

// While loops
while count < 10 {
    count = count + 1
}

// For loops (init, condition, update)
for let i: int = 0, i < 10, i = i + 1 {
    print(".")
}
```

### Defer Statement

```swift
func open_file() {
    let file: File = new File("test.txt")
    defer file.close()

    // File will be automatically closed when function returns
    // even on early returns or errors
}
```

### Macros

Macros expand at compile time. A macro can use `quote { ... }` to produce
statements, or `quote(expr)` to produce an expression. Inside quoted syntax,
macro arguments are inserted explicitly with `unquote(...)`.

```swift
macro assignTwice(target, value) {
    quote {
        unquote(target) = unquote(value)
        unquote(target) = unquote(target) + 1
    }
}

macro square(value) {
    quote(unquote(value) * unquote(value))
}

func compute() -> int {
    let x: int = 0
    assignTwice!(x, 41)
    return square!(x)
}
```

### C FFI

```swift
// Declare external C functions
extern func outb(port: uint, value: char)
extern func inb(port: uint) -> char

// Use them directly
outb(0x3F8, 65)  // Output 'A' to serial port
```

### Type Casting

```swift
let addr: uint = 0xB8000
let buffer: char* = addr as char*
```

## Building

### Prerequisites

- D compiler (DMD, LDC, or GDC)
- DUB (D package manager)
- GCC (for compiling generated C code)
- NASM (for assembling boot code)
- QEMU (for testing)
- GRUB tools (optional, for creating bootable ISOs)

### Build the Compiler

```bash
dub build
```

This creates the `llpl` compiler executable.

### Compile LLPL Code

```bash
./llpl input.llpl -o output.c
```

Or compile straight to a native binary with `-b`/`--binary`, which
generates the C internally and invokes a system C compiler (`cc` by
default - override with `--cc=<path>` or `$CC`) linked against
`runtime/runtime.c`:

```bash
./llpl input.llpl -b -o output
```

This targets ordinary hosted programs only - a freestanding/kernel target
like `examples/baremetal_demo` needs its own Makefile-based build instead
(custom linker script, boot assembly, `-ffreestanding` flags), not `-b`.

## Example: Bare Metal Kernel

A complete kernel example is provided in `examples/kernel.llpl`.

### Building the Kernel

```bash
cd examples
make
```

This will:
1. Build the LLPL compiler
2. Compile `kernel.llpl` to C
3. Compile the C code with the runtime
4. Assemble the bootloader
5. Link everything into a kernel binary

### Running the Kernel

```bash
cd examples
make run
```

This launches QEMU and runs your kernel. You should see output like:

```
LLPL Kernel v0.1
================

Initializing serial port...
Testing control flow:
  Loop iteration:   Loop iteration:   Loop iteration:   Loop iteration:   Loop iteration:
For loop test:
  Step   Step   Step
Conditional test: PASSED

Kernel initialization complete!
System halted.
```

## Project Structure

```
LLPL/
├── source/
│   ├── main.d          # Compiler entry point
│   ├── lexer.d         # Lexical analyzer
│   ├── parser.d        # Parser (tokens → AST)
│   ├── ast.d           # AST node definitions
│   └── codegen.d       # C code generator
├── runtime/
│   ├── runtime.h       # Runtime header
│   └── runtime.c       # Reference counting & memory management
├── examples/
│   ├── kernel.llpl     # Sample kernel
│   ├── boot.asm        # x86 bootloader
│   ├── linker.ld       # Linker script
│   └── Makefile        # Build system
├── dub.json            # D project configuration
└── README.md           # This file
```

## Type System

### Primitive Types

- `int` - 64-bit signed integer
- `uint` - 64-bit unsigned integer
- `char` - 8-bit character
- `bool` - Boolean (true/false)
- `void` - No value

### Pointer Types

```swift
let ptr: int* = &value
let arr: char[80]  // Fixed-size array
```

### Class Types

All classes are reference-counted automatically. No need for manual memory management!

## Memory Management

LLPL uses automatic reference counting (ARC):

- Objects are allocated with `new`
- Reference count is incremented on assignment
- Reference count is decremented when variables go out of scope
- Objects are automatically freed when reference count reaches zero

```swift
func example() {
    let obj: MyClass = new MyClass()
    // obj is automatically freed at end of function
}
```

## Operators

### Arithmetic
- `+`, `-`, `*`, `/`, `%`

### Comparison
- `==`, `!=`, `<`, `>`, `<=`, `>=`

### Logical
- `&&` (and), `||` (or), `!` (not)

### Bitwise
- `&`, `|`, `^`, `~`, `<<`, `>>`

### Other
- `=` (assignment)
- `.` (member access)
- `[]` (array indexing)
- `->` (function return type)

## Limitations

Current implementation limitations:

- No garbage collection (uses reference counting)
- No generics/templates
- No exceptions (use return codes)
- No standard library (you're building the kernel!)
- Simple bump allocator (can't free individual objects)
- No closures or lambdas
- No string type (use char*)

## Future Enhancements

Potential improvements:

- [ ] Better memory allocator
- [ ] String type
- [ ] Array bounds checking (optional)
- [ ] Generic types
- [ ] Module system
- [ ] Inline assembly
- [ ] Optimization passes
- [ ] Better error messages
- [ ] Type inference
- [ ] Pattern matching

## Contributing

This is a demonstration compiler. Feel free to extend it for your own projects!

## License

MIT License - feel free to use for any purpose.

## Example Programs

### Hello World

```swift
extern func print_char(c: char)

func print(msg: char*) {
    let i: int = 0
    while msg[i] != 0 {
        print_char(msg[i])
        i = i + 1
    }
}

func kernel_main() {
    print("Hello, World!\n")
}
```

### Linked List

```swift
class Node {
    let value: int
    let next: Node

    constructor(value: int) {
        self.value = value
        self.next = null
    }

    destructor() {
        if self.next != null {
            // Next node will be auto-released
        }
    }
}

func add_node(head: Node, value: int) -> Node {
    let node: Node = new Node(value)
    node.next = head
    return node
}
```

## Architecture

### Compilation Pipeline

1. **Lexer** (`lexer.d`): Source code → Tokens
2. **Parser** (`parser.d`): Tokens → AST
3. **Code Generator** (`codegen.d`): AST → C code
4. **C Compiler**: C code → Object files
5. **Linker**: Object files → Kernel binary

### Runtime

The runtime library (`runtime.c`) provides:

- Reference counting primitives
- Memory allocation (bump allocator)
- Basic string functions (memcpy, memset, strlen)

All LLPL objects start with a `RefCount` structure, allowing the runtime to manage their lifetime.

## Tips for Kernel Development

1. **Start Simple**: Begin with basic output (VGA text mode or serial)
2. **Test Incrementally**: Use `defer` for cleanup to avoid memory leaks
3. **Use Classes**: Organize hardware drivers as classes
4. **External Functions**: Declare low-level x86 operations as `extern func`
5. **Debug with Serial**: Use COM1 serial port for debugging output

## Troubleshooting

### Compiler won't build
- Ensure you have D compiler and DUB installed
- Run `dub --version` to verify

### Kernel won't boot
- Check that boot.asm is assembled correctly
- Verify linker script addresses
- Try running with `-serial stdio` in QEMU to see serial output

### Generated C code errors
- Check that all types are declared before use
- Verify extern function declarations match C signatures
- Look for mismatched pointer types

## Resources

- [OSDev Wiki](https://wiki.osdev.org) - Bare metal programming
- [D Language](https://dlang.org) - The D programming language
- [QEMU Documentation](https://www.qemu.org/docs/master/) - Emulator docs

## Contact

For questions or improvements, open an issue on the repository.

Happy kernel hacking! 🚀
