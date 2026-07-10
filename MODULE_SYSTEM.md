## LLPL Module System

The LLPL compiler now supports a robust module system with the following features:

### Features

- **Multi-file projects**: Split your code across multiple `.llpl` files
- **Import statements**: Use `import name` to include other modules
- **Circular dependencies**: Modules can import each other without issues
- **Automatic resolution**: The compiler handles dependency order automatically
- **Search paths**: Modules are searched in current directory, `lib/`, and `modules/`

### Syntax

#### Basic Import

The canonical form is a bare module name, resolved to `name.llpl` next to the
importing file (or on a search path). Dotted segments map to subdirectories:

```swift
import graphics
import input
import drivers.serial   // resolves to drivers/serial.llpl
```

A quoted path is still accepted, for paths that aren't valid identifiers:

```swift
import "graphics.llpl"
```

#### Import with Alias

```swift
import graphics as gfx
```

### How It Works

1. **Dependency Resolution**: The compiler starts with your entry file and recursively resolves all imports
2. **Circular Detection**: When a circular import is detected, the compiler notes it and continues
3. **Forward Declarations**: All classes, functions, and methods get forward declarations in C
4. **Ordered Compilation**: Modules are compiled in dependency order

### Example: Circular Imports

**graphics.llpl**:
```swift
import input  // Can import input

class Screen {
    let buffer: char*

    constructor() {
        self.buffer = 0xB8000 as char*
    }

    func write(msg: char*) {
        // Implementation
    }
}
```

**input.llpl**:
```swift
import graphics  // Can import graphics back!

class Keyboard {
    let screen: Screen

    constructor(scr: Screen) {
        self.screen = scr
    }

    func read_key() -> char {
        // Implementation
    }
}
```

**main.llpl**:
```swift
import graphics
import input

func kernel_main() {
    let screen: Screen = new Screen()
    let keyboard: Keyboard = new Keyboard(screen)

    screen.write("Hello from modules!\n")
}
```

### Compilation

Compile the entry point file:

```bash
./llpl main.llpl -o output.c
```

The compiler will automatically:
1. Parse `main.llpl`
2. Find and parse `graphics.llpl`
3. Find and parse `input.llpl`
4. Detect the circular dependency
5. Generate C code with proper forward declarations

### Module Search Paths

The compiler searches for imported files in this order:

1. **Relative to importing file**: If you `import utils` from `/project/src/main.llpl`, it checks `/project/src/utils.llpl`
2. **Current directory**: `./utils.llpl`
3. **lib directory**: `lib/utils.llpl`
4. **modules directory**: `modules/utils.llpl`

### Best Practices

#### 1. Organize by Feature

```
project/
├── main.llpl
├── modules/
│   ├── graphics.llpl
│   ├── input.llpl
│   ├── memory.llpl
│   └── drivers/
│       ├── keyboard.llpl
│       └── serial.llpl
```

#### 2. Use Descriptive Names

```swift
import drivers.keyboard
import drivers.serial
```

#### 3. Avoid Deep Circular Dependencies

While circular imports work, try to minimize them:

**Good**:
```
main → graphics → utils
main → input → utils
```

**Works but complex**:
```
main ↔ graphics ↔ input ↔ memory ↔ main
```

#### 4. One Class Per File

For better organization:

```
graphics/
├── screen.llpl     // Screen class
├── color.llpl      // Color class
└── sprite.llpl     // Sprite class
```

### Advanced Example: Modular Kernel

**memory.llpl**:
```swift
class Allocator {
    let heap_start: uint
    let heap_end: uint

    constructor(start: uint, end: uint) {
        self.heap_start = start
        self.heap_end = end
    }

    func alloc(size: uint) -> void* {
        // Implementation
        return null
    }
}
```

**graphics.llpl**:
```swift
import memory

class Screen {
    let buffer: char*
    let allocator: Allocator

    constructor(alloc: Allocator) {
        self.allocator = alloc
        self.buffer = alloc.alloc(4000) as char*
    }

    func write(msg: char*) {
        // Implementation
    }
}
```

**drivers/serial.llpl**:
```swift
extern func outb(port: uint, value: char)
extern func inb(port: uint) -> char

class SerialPort {
    let port: uint

    constructor(port_num: uint) {
        self.port = port_num
        self.init()
    }

    func init() {
        outb(self.port + 1, 0)
        // More init...
    }

    func write(data: char) {
        outb(self.port, data)
    }
}
```

**main.llpl**:
```swift
import memory
import graphics
import drivers.serial

func kernel_main() {
    // Initialize memory
    let allocator: Allocator = new Allocator(0x100000, 0x200000)

    // Initialize graphics
    let screen: Screen = new Screen(allocator)

    // Initialize serial
    let serial: SerialPort = new SerialPort(0x3F8)

    // Use them together
    screen.write("Kernel started\n")
    serial.write(72)  // 'H'
}
```

### Compilation Output

When compiling with `-v` flag:

```
$ ./llpl main.llpl -o kernel.c -v
Compiling main.llpl...
Info: Circular import detected: /path/to/graphics.llpl
Resolved 4 modules
  - /path/to/memory.llpl
  - /path/to/graphics.llpl
  - /path/to/drivers/serial.llpl
  - /path/to/main.llpl
Code generation complete
Successfully compiled to kernel.c
```

### Technical Details

#### Forward Declaration Generation

The compiler generates forward declarations for all types and functions from all modules:

```c
// Type forward declarations
typedef struct Allocator Allocator;
typedef struct Screen Screen;
typedef struct SerialPort SerialPort;

// Function forward declarations
Allocator* Allocator_new(uint64_t start, uint64_t end);
void* Allocator_alloc(Allocator* self, uint64_t size);
Screen* Screen_new(Allocator* alloc);
void Screen_write(Screen* self, char* msg);
SerialPort* SerialPort_new(uint64_t port_num);
void SerialPort_write(SerialPort* self, char data);

// Then implementations follow...
```

This ensures that circular dependencies compile correctly in C.

#### Dependency Resolution Algorithm

1. Start with entry file
2. Parse it and extract imports
3. For each import:
   - If already parsed, skip
   - If being parsed (circular), note and skip
   - Otherwise, recursively resolve it
4. Mark as fully parsed
5. Add to compilation order

This topological sort with cycle handling ensures correct compilation order while allowing circular dependencies.

### Limitations

1. **Import once**: Each file is only compiled once, even if imported multiple times
2. **No conditional imports**: All imports are unconditional
3. **File-based**: Modules are files, not logical units - use `namespace` (see below) for logical grouping independent of file layout

Symbols aren't automatically isolated by file the way they are in some
languages, but LLPL's `namespace` blocks give you real isolation: a class or
function inside `namespace Graphics { ... }` is mangled to `Graphics_...` in
the generated C, so identically-named declarations in different namespaces
don't collide, and unqualified sibling references still resolve within the
enclosing namespace.

### Future Enhancements

- [ ] Selective imports: `import { Class1, func1 } from module`
- [ ] Module-level visibility: `public func` vs `private func`
- [ ] Package system: `import package:module`
- [ ] Precompiled modules
- [ ] Module caching

### Migration from Single-File

Old single-file code works without changes:

```swift
// kernel.llpl - still works!
class Screen { /* ... */ }
func kernel_main() { /* ... */ }
```

To migrate to modules:

1. Split into logical files
2. Add import statements
3. Recompile from main file

That's it! The compiler handles the rest.
