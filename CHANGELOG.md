# LLPL Changelog

## Version 0.2.0 - Module System & 64-bit Support

### Major Features

#### ✨ Module System with Circular Import Support

**What's New:**
- Import other LLPL files with `import "path.llpl"`
- Full support for circular dependencies between modules
- Automatic dependency resolution
- Multi-file project support

**Example:**
```swift
// graphics.llpl
import "input.llpl"  // Can import input

class Screen {
    func write(msg: char*) { /* ... */ }
}

// input.llpl
import "graphics.llpl"  // Can import graphics back!

class Keyboard {
    let screen: Screen
    func read() -> char { /* ... */ }
}

// main.llpl
import "graphics.llpl"
import "input.llpl"

func kernel_main() {
    let screen: Screen = new Screen()
    let kb: Keyboard = new Keyboard()
}
```

**Technical Details:**
- Topological sort with cycle detection
- Forward declarations for all types and functions
- Search paths: current directory, `lib/`, `modules/`
- Compile entry file: `./llpl main.llpl -o output.c`

#### 🚀 64-bit Architecture Support

**What's New:**
- Full x86-64 long mode support
- 64-bit integers (`int` = int64_t, `uint` = uint64_t)
- Proper 64-bit calling conventions
- Page table setup for long mode
- 64-bit GDT and paging

**Build Options:**
```bash
# 64-bit kernel (default)
make ARCH=64bit

# 32-bit kernel (legacy)
make ARCH=32bit
```

**Technical Details:**
- Long mode initialization in `boot64.asm`
- PAE and 2MB page tables
- System V AMD64 ABI calling convention
- Kernel code model (`-mcmodel=kernel`)
- Red zone disabled for kernel compatibility

### New Compiler Features

#### Module Resolver
- **File**: `source/modules.d`
- Resolves all imports recursively
- Handles circular dependencies gracefully
- Reports import order in verbose mode

#### Enhanced Code Generator
- Generates forward declarations for all modules
- Supports multi-module compilation
- Proper ordering of definitions
- Module-aware symbol generation

#### Updated Parser
- New `import` keyword
- Import statement parsing
- Module path resolution
- Optional import aliases (syntax ready)

### File Structure

```
LLPL/
├── source/
│   ├── main.d           # Updated for module system
│   ├── modules.d        # NEW: Module resolver
│   ├── lexer.d          # Added "import" keyword
│   ├── parser.d         # Added import parsing
│   ├── ast.d            # Added ImportStmt node
│   └── codegen.d        # Multi-module generation
├── examples/
│   ├── boot64.asm       # NEW: 64-bit bootloader
│   ├── linker64.ld      # NEW: 64-bit linker script
│   ├── Makefile         # Updated for 64-bit/32-bit
│   └── modules/         # NEW: Multi-file examples
│       ├── main.llpl
│       ├── graphics.llpl
│       └── input.llpl
├── MODULE_SYSTEM.md     # NEW: Module system docs
└── CHANGELOG.md         # This file
```

### Breaking Changes

#### Type Sizes
- `int` changed from int32_t to int64_t
- `uint` changed from uint32_t to uint64_t
- Affects binary compatibility with 32-bit code

**Migration:**
```swift
// Old 32-bit code
let x: uint = 100  // Was 32-bit

// New 64-bit code
let x: uint = 100  // Now 64-bit

// For 32-bit explicitly (not yet supported)
// let x: uint32 = 100
```

#### Compilation Target
- Default target is now 64-bit
- Use `make ARCH=32bit` for 32-bit builds
- 32-bit requires old `boot.asm` and `linker.ld`

### New Examples

#### Modular Kernel
Location: `examples/modules/`

Demonstrates:
- Multi-file project structure
- Circular imports (graphics ↔ input)
- Module organization
- Proper dependency handling

**Compile:**
```bash
./llpl examples/modules/main.llpl -o output.c -v
```

Output shows:
```
Info: Circular import detected: /path/to/graphics.llpl
Resolved 3 modules
  - /path/to/input.llpl
  - /path/to/graphics.llpl
  - /path/to/main.llpl
```

### Compiler Invocation

#### Verbose Mode
```bash
./llpl input.llpl -o output.c -v
```

Shows:
- Number of modules resolved
- List of all imported files
- Circular dependency warnings
- Compilation progress

#### Regular Mode
```bash
./llpl input.llpl -o output.c
```

Just shows: `Successfully compiled to output.c`

### Architecture Comparison

| Feature | 32-bit | 64-bit |
|---------|--------|--------|
| Integer size | 32-bit | 64-bit |
| Pointer size | 32-bit | 64-bit |
| Boot mode | Protected mode | Long mode |
| Page size | 4KB | 2MB (huge pages) |
| Calling convention | cdecl | System V AMD64 |
| Register usage | EAX, EBX, etc. | RAX, RDI, RSI, etc. |
| Stack alignment | 4 bytes | 16 bytes |

### Building

#### 64-bit Kernel (Default)
```bash
cd examples
make clean
make              # or make ARCH=64bit
```

#### 32-bit Kernel (Legacy)
```bash
cd examples
make clean
make ARCH=32bit
```

#### Test with QEMU
```bash
make run          # Boots from ISO
```

### Known Issues

1. **Serial output**: Serial port initialization needs adjustment for 64-bit
2. **VGA buffer**: Address casting warnings (expected for bare metal)
3. **Empty destructors**: Generate unused variable warnings

### Future Enhancements

- [ ] Import aliases: `import "module" as alias`
- [ ] Selective imports: `import { Class } from "module"`
- [ ] Module visibility: `public`/`private` keywords
- [ ] Explicit 32-bit types: `int32`, `uint32`
- [ ] Package manager
- [ ] Precompiled modules
- [ ] Namespace isolation

### Documentation

- **Module System**: See `MODULE_SYSTEM.md`
- **Quick Start**: See `QUICKSTART.md`
- **Examples**: See `EXAMPLES.md`
- **Full Guide**: See `README.md`

### Compatibility

#### Backwards Compatibility
- Single-file programs work unchanged
- No module system required for simple programs
- Old kernel examples remain compatible

#### Forward Compatibility
- Module system is additive
- Can gradually migrate to modules
- Mixed single-file and multi-file projects work

### Performance

- **Compilation**: Slightly slower due to multi-pass parsing
- **Runtime**: No performance difference (same generated C code)
- **Binary Size**: Identical to single-file compilation

### Testing

All features tested with:
- Single-file kernel
- Multi-file modular kernel
- Circular dependency scenarios
- Both 32-bit and 64-bit compilation

### Contributors

- Module system design and implementation
- 64-bit bootloader and long mode setup
- Enhanced code generator
- Documentation and examples

---

## Version 0.1.0 - Initial Release

- Swift/JavaScript-like syntax
- Classes with constructors/destructors
- Reference counting
- Control flow: if, while, for
- Defer statement
- C FFI
- Basic 32-bit kernel support
