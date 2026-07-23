# LLPL - Low Level Programming Language

A low-level programming language with familiary syntax that compiles to C for bare-metal development.

## Features

- **Modern Syntax**: Clean syntax inspired by Swift and JavaScript
- **No Semicolons**: Statement termination without semicolons
- **No Expression Parentheses**: Clean if/while statements without parentheses
- **Classes**: Object-oriented programming with constructors and destructors
- **Automatic Reference Counting**: Memory management without manual malloc/free
- **RAII for Class Locals**: Automatic `rc_release` at scope exit, on reassignment, and at function returns
- **Traits / Bounded Generics**: Static interfaces for shared behavior (`Hashable`, `Comparable`, ...)
- **Inline Assembly**: GCC-style extended `asm(...)` statements for kernel/low-level code
- **Defer Statement**: Resource cleanup similar to Swift
- **Macros**: Compile-time expansion with `quote`/`unquote`
- **Result<T, E> with Traces**: `?` propagation captures a chained `file:line` trace
- **Panics with Hooks**: `llpl_panic("...")` prints a message and aborts; optional handler for cleanup
- **Assert Statement**: `assert(condition)` and `assert(condition, "message")` abort with a panic on failure
- **Optional Bounds Checking**: `--safe` enables runtime bounds checks on fixed-size array indexing
- **C FFI**: Easy interoperability with C code
- **Pipe operator**: And syntactic sugar like `unless`
- **Bare Metal**: Compiles to efficient C code for kernel development
- **Grammars**: ANTLR-like grammars inlined with your code
- **`embed("path")`**: bakes a file's raw bytes into the binary as a static array at compile time

## Language Syntax

### Variables

```swift
let x = 42
const PI = 314
let name = "Hello"
let foo = new Klass()
```

### Functions and function overloading

```swift
func add(a: i64, b: i64) -> i64 {
    return a + b
}

func add(a: i64, b: i64, c: i64) -> i64 {
    return a + b + c
}

func greet(name: char*) {
    print(name)
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
        // Cleanup code
    }

    func distance() -> i64 {
        return self.x * self.x + self.y * self.y
    }
}

// Usage
let p: Point = new Point(10, 20)
let dist: i64 = p.distance()

delete p
```

### Traits / Bounded Generics

A `trait` declares a contract of method signatures. An `impl Trait for Type`
block provides the bodies, allowing primitives, structs, and classes to gain
methods. Dispatch is static (monomorphization) - there are no vtables or trait
objects.

```swift
trait Hashable {
    func hash() -> u64
    func equals(other: Self) -> bool
}

impl Hashable for i64 {
    func hash() -> u64 { return self as u64 }
    func equals(other: i64) -> bool { return self == other }
}

// T must have a matching impl, checked when the generic is instantiated.
func use_hash<T: Hashable>(key: T) -> u64 {
    return key.hash()
}
```

`prelude.llpl` ships `Hashable` and `Comparable`. `HashMap<K: Hashable, V>`
uses `key.hash()` / `key.equals(other)` so `HashMap<String, V>` compares string
content, not pointer identity.

### Inline Assembly

GCC-style extended inline assembly is available through `asm(...)`:

```swift
func read_cr0() -> u64 {
    let value: u64 = 0
    asm("mov %%cr0, %0" : "=r"(value))
    return value
}

func add_asm(a: i64, b: i64) -> i64 {
    asm("addq %1, %0" : "=r"(a) : "r"(b) : "cc")
    return a
}
```

Syntax: `asm("template" : outputs : inputs : clobbers)`. Operands use
constraint-string-then-expression pairs (`"=r"(dest)`), exactly like GCC's
extended asm. Multiple template strings are concatenated.

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
for let i: i64 = 0, i < 10, i = i + 1 {
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

func compute() -> i64 {
    let x: i64 = 0
    assignTwice!(x, 41)
    return square!(x)
}
```

### Result<T, E> and Error Traces

`Result<T, E>` is a generic "value or error" box from `prelude.llpl`. The `?`
operator unwraps a `Result` or returns early with the error; each propagation
step records the call-site location, building a chained trace.

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

func sum_of_divisions(a: i64, b: i64, c: i64, d: i64) -> Result<i64, char*> {
    let first: i64 = safe_div(a, b)?   // trace starts here on error
    let second: i64 = safe_div(c, d)?  // chained here if this fails
    let r: Result<i64, char*> = new Result<i64, char*>()
    r.set_ok(first + second)
    return r
}

func main() -> i64 {
    let r: Result<i64, char*> = sum_of_divisions(10, 0, 20, 4)
    if r.is_err() {
        // r.get_trace() might return "file:14 -> file:21"
    }
    return 0
}
```

### Panics

`llpl_panic("message")` prints the message and aborts on hosted targets. A
panic handler can be installed for logging or cleanup; it runs before the
default halt/abort.

```swift
extern func llpl_panic(msg: char*)
extern func llpl_set_panic_handler(handler: (char*) -> void)

func my_handler(msg: char*) {
    // log msg, clean up resources, etc.
}

func main() -> i64 {
    llpl_set_panic_handler(my_handler)
    llpl_panic("unrecoverable error")
    return 0
}
```

### Assert Statement

`assert(condition)` aborts with a panic if `condition` is false. An optional
second argument provides a custom panic message.

```swift
func main() -> i64 {
    assert(1 == 1)
    assert(2 > 1, "two is greater than one")
    // assert(1 == 2, "this would panic")
    return 0
}
```

### C FFI

```swift
// Declare external C functions
extern func outb(port: u64, value: u8)
extern func inb(port: u64) -> u8

// Use them directly
outb(0x3F8, 65)  // Output 'A' to serial port
```

### Type Casting

```swift
let addr: u64 = 0xB8000
let buffer = addr as u8*
```

## Building

### Prerequisites

- D compiler (DMD, LDC, or GDC)
- DUB (D package manager)
- GCC (for compiling generated C code)
- NASM (for assembling boot code)
- QEMU (for testing)
- GRUB tools (optional, for creating bootable ISOs)
- Limine (optional, for the specific example)

### Build the Compiler

```bash
dub build
```

This creates the `llpl` compiler executable.

If your code imports the standard library (`import stdlib..."`), set
`LLPL_HOME` to this repo's root first, so those imports resolve regardless
of where the importing file lives - see `MODULE_SYSTEM.md`'s "Module
Search Paths" section for details:

```bash
export LLPL_HOME=$(pwd)
```

### Compile LLPL Code

```bash
./llpl input.llpl -o output.c
```

All CLI flags:

| Flag | What it does |
|---|---|
| `-o`, `--output` | Output file path - a `.c` source file, or (with `-b`) a native binary. |
| `-b`, `--binary` | Compile straight to a native binary instead of emitting C - invokes a system C compiler (see `--cc`). |
| `--cc` | C compiler to invoke in `--binary` mode. Defaults to `$CC`, falling back to `cc`. |
| `--keep-c` | Keep the intermediate `.c` file in `--binary` mode even on success. |
| `-v`, `--verbose` | Verbose output. |
| `--safe` | Enable runtime safety checks - currently, bounds-checked fixed-size array indexing. Off by default. |
| `--dce` | Dead-code elimination. On by default. |
| `--lsp-symbols` | Analyze a file and dump diagnostics/symbols/usages as JSON, for editor tooling. |
| `-h`, `--help` | Help text. |

Or compile straight to a native binary with `-b`/`--binary`, which
generates the C internally and invokes a system C compiler (`cc` by
default - override with `--cc=<path>` or `$CC`) linked against
`runtime/runtime.c`:

```bash
./llpl input.llpl -b -o output
```

Add `--safe` to enable runtime bounds checks on fixed-size array indexing:

```bash
./llpl --safe input.llpl -b -o output
```

This currently checks one-dimensional fixed-size arrays (`T[N]`) declared
as locals, globals, or class fields; pointer indexing and array parameters
that have decayed to pointers are not checked.

This targets ordinary hosted programs only - a freestanding/kernel target
like `examples/baremetal_demo` needs its own `tools/llplbuild` build
instead (custom linker script, boot assembly, `-ffreestanding` flags),
not `-b` - see [Example: Bare Metal Kernel](#example-bare-metal-kernel)
below.

### Web Playground

`playground/` has a local web playground - write LLPL in the browser and
see the generated C plus the compiled program's real output side by side.
See `playground/README.md` (local use only - it compiles and runs
whatever source is submitted, with no sandboxing).

```bash
cd playground && node server.js   # then open http://localhost:8787
```

## Example: Bare Metal Kernel

Complete kernel examples are provided in `examples/baremetal_demo` (GRUB/
Multiboot2) and `examples/limine_baremetal_demo` (Limine). Both are built
and run with `tools/llplbuild` - a YAML-configured build tool (see
`tools/llplbuild/README.md`) that replaced their old Makefiles, supporting
`debug`/`final` build configurations, incremental/parallel builds, and a
`build.yaml` per target instead of hand-written recipes.

### Building the Kernel

```bash
cd examples/baremetal_demo
../../tools/llplbuild/llplbuild build            # final (optimized) build
../../tools/llplbuild/llplbuild build -c debug    # unoptimized, with -g
```

This will:
1. Compile `kernel.llpl` to C
2. Compile the C code with the runtime
3. Assemble the bootloader
4. Link everything into a kernel binary and package a bootable ISO

### Running the Kernel

```bash
cd examples/baremetal_demo
../../tools/llplbuild/llplbuild run
```

This launches QEMU and runs your kernel. You should see output like:

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
disk, and a windowing compositor with a mouse-driven desktop - not just a
"hello world" that halts. See [Bare-Metal Demo Highlights](#bare-metal-demo-highlights)
below for what's actually running underneath that boot log.

## Bare-Metal Demo Highlights

`examples/baremetal_demo` isn't a toy - past boot it has a real
round-robin preemptive scheduler, a page-table-based VMM, a custom
dynamic ELF loader (`ldso.llpl`) linking `-shared`/PIE user programs
against a shared `libsys.so`, and a persistent VFS on top of a virtual
ATA disk. On top of that:

- **Networking** (`userapp/netd.llpl`): a from-scratch e1000 NIC driver
  (Ethernet TX/RX descriptor rings, ARP, IPv4, ICMP echo, and a DHCP
  client over a minimal UDP layer) that negotiates a real address from
  QEMU SLIRP's DHCP server at boot, falling back to a static address only
  if nothing answers. `ping`/`traceroute` are thin clients of its single
  blocking `OP_PING` operation.
- **Graphical ping monitor** (`userapp/pingview.llpl`): a windowed client
  of that same `OP_PING` operation, rendering a live auto-scaling bar
  graph of round-trip latency plus sent/received/loss stats - run it with
  `run /boot/pingview.elf [ip]`.
- **Windowing compositor** (`userapp/wm.llpl`): owns the real framebuffer
  exclusively behind a shared-memory arena protocol (`userapp/
  wm_protocol.llpl`/`wm_client.llpl`), compositing draggable, resizable,
  semi-transparent windows (title bar, drop shadow, and a corner resize
  grip) over a compile-time-embedded wallpaper photo (see `embed()`
  below) - `editor.elf`, `filebrowser.elf`, `terminal.elf`, and a windowed
  `tetris.elf` all run as ordinary clients of it.
- **`embed("path")`**: a compiler builtin that bakes a file's raw bytes
  into the compiled binary as a static array at compile time - used here
  for the desktop wallpaper and cursor image, with no filesystem
  dependency or on-target image decoding needed (see `test/
  embed_demo.llpl` for the general feature, independent of this demo).

## Project Structure

```
LLPL/
├── source/
│   ├── main.d          # Compiler entry point
│   ├── lexer.d         # Lexical analyzer
│   ├── parser.d        # Parser (tokens → AST)
│   ├── ast.d           # AST node definitions
│   ├── codegen.d       # C code generator
│   ├── modules.d       # Module resolution / import search paths
│   ├── grammar.d       # Inline ANTLR-like grammar support
│   ├── errors.d        # Diagnostics
│   └── lspquery.d      # Editor/LSP-facing queries (hover, go-to-def, ...)
├── runtime/
│   ├── runtime.h       # Runtime header
│   └── runtime.c       # Reference counting, memory management, YAML/JSON parsers
├── prelude.llpl         # Auto-imported: Result<T,E>, Hashable, Comparable, ...
├── stdlib/              # import stdlib.* - collections, io, json, yaml, net, text, args, sdl
├── tools/llplbuild/     # YAML-driven build tool used by both example kernels
├── examples/
│   ├── baremetal_demo/         # Flagship demo: GRUB/Multiboot2 kernel (see below)
│   ├── limine_baremetal_demo/  # Same idea, booted via Limine instead of GRUB
│   ├── collections/, regex/, embed_demo/, modules/, sdl/  # smaller focused examples
├── editors/vscode-llpl/ # VS Code extension (syntax highlighting + LSP client)
├── playground/          # Local web playground (see Web Playground below)
├── EXAMPLES.md           # Long-form language walkthrough
├── MODULE_SYSTEM.md      # Import resolution / module search paths
├── dub.json             # D project configuration
└── README.md            # This file
```

## Type System

### Primitive Types

> **History:** the old unsized `int`/`uint` were removed for a while (a
> compile error telling you to spell out `i64`/`u64` instead), then
> brought back with new, different semantics - see below. `char` went
> through the same removed-then-restored arc, also with new semantics
> (split from `u8` rather than merged into it).

- `i8/i16/i32/i64` - sized signed integers
- `u8/u16/u32/u64` - sized unsigned integers, genuinely numeric (`u8`
  generates C `uint8_t`, not `char`)
- `char` - one byte of *text* (generates C `char`); `char*` is a C
  string. Distinct from `u8` even though both are 8 bits - a raw numeric
  byte (a pixel value, a network octet) is `u8`; a character is `char`
- `int`/`uint` - a third, separate integer family, **not** aliases of
  `i64`/`u64` - native machine-word-sized (C `intptr_t`/`uintptr_t`: 4
  bytes on i386, 8 bytes on x86_64). No implicit widening to/from a
  fixed-width type in either direction (an explicit `as` cast is always
  required), since the actual width isn't known until the generated C is
  compiled for its target
- `bool` - Boolean (true/false)
- `void` - No value
- `string` - alias for `char*`, a C string, null terminated
- `String` - Sugar class 

### Pointer Types

```swift
let ptr: i64* = &value
let arr: u8[80]  // Fixed-size array
```

### Class Types

Classes with single inheritance, complete with virtual and override. All classes are reference-counted automatically. No need for manual memory management!

## Memory Management

Classes are reference-counted:

- `new` allocates and sets the reference count to 1
- A field pointing at another class instance is released automatically
  when its *owning* object's destructor runs (cascading, not scope-based -
  there's no implicit release when a local variable simply goes out of
  scope)
- `delete expr` releases a reference explicitly - for an object that was
  never stored as anyone's field. If it was the last reference, the
  destructor runs and the memory is freed
- `Weak<T>` (see `EXAMPLES.md`) holds a non-owning reference that never
  keeps its target alive and safely reports whether it's still alive -
  use it to break a reference cycle between two classes that hold each
  other, so releasing one doesn't cascade back through the other

```swift
class Container {
    let item: MyClass
    constructor(item: MyClass) { self.item = item }
    destructor() {}  // self.item is released here, automatically
}

func example() {
    let obj: MyClass = new MyClass()
    let c: Container = new Container(obj)  // Container now owns obj
    delete c  // releases obj too, via Container's destructor
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
- `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=` (compound
  assignment - `x += y` desugars to `x = x + y`)
- `++`, `--` (postfix increment/decrement - `i++` desugars to `i = i + 1`,
  same as `i += 1`; only recognized as their own statement or
  parenthesized, not spliced into a larger expression like `i++ + 5`)
- `.` (member access)
- `[]` (array indexing)
- `->` (function return type)

## Limitations

Current implementation limitations:

- No garbage collection (uses reference counting)

## Future Enhancements

Potential improvements:

- [X] Better memory allocator
- [X] String type
- [X] Array bounds checking (optional)
- [X] Generic types
- [X] Module system
- [X] Inline assembly
- [ ] Optimization passes
- [X] Better error messages
- [X] Type inference
- [X] Pattern matching
- [X] Single inheritance + virtual/override
- [X] Inline grammars (ANTLR-like)
- [X] `embed()` compile-time file embedding

## Contributing

This is a demonstration compiler. Feel free to extend it for your own projects!

## License

MIT License - feel free to use for any purpose.

## Example Programs

### Hello World

```swift
extern func print_char(c: char)

func print(msg: char*) {
    let i: i64 = 0
    while msg[i] != 0 {
        print_char(msg[i])
        i = i + 1
    }
}

func kernel_main() {
    let where = "world"
    print("Hello, \(where)!\n")
}
```

### Linked List

```swift
class Node {
    let value: i64
    let next: Node

    constructor(value: i64) {
        self.value = value
        self.next = null
    }

    destructor() {
        if self.next != null {
            // Next node will be auto-released
        }
    }
}

func add_node(head: Node, value: i64) -> Node {
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
- YAML and JSON parsers
- String and StringBuilder class

All LLPL objects start with a `RefCount` structure, allowing the runtime to manage their lifetime.

## Tips for Kernel Development

1. **Start Simple**: Begin with basic output (VGA text mode or serial)
2. **Test Incrementally**: Use `defer` for cleanup to avoid memory leaks
3. **Use Classes**: Organize hardware drivers as classes
4. **External Functions**: Declare low-level x86 operations as `extern func` and `volatile`
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
