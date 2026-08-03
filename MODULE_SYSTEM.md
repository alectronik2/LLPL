## LLPL Module System

The LLPL compiler now supports a robust module system with the following features:

### Features

- **Multi-file projects**: Split your code across multiple `.llpl` files
- **Import statements**: Use `import name` to include other modules
- **Directory imports**: Use `import folder` to include every direct `.llpl` file in that directory
- **Aliases and selective imports**: Import a module under an alias or import selected symbols
- **Explicit exports**: Use `public` to opt a module into a public import surface
- **Circular dependencies**: Modules can import each other without issues
- **Automatic resolution**: The compiler handles dependency order automatically
- **Search paths**: Modules are searched relative to the importing file, the entry file, project config paths, `$LLPL_HOME`, current directory, `lib/`, and `modules/`

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

#### Directory Import

If a file import is not found, the resolver checks for a matching directory.
Every direct `.llpl` file in that directory is imported in sorted order:

```swift
import hal      // imports hal/cpu.llpl, hal/gdt.llpl, hal/serial.llpl, ...
import mm       // imports direct .llpl files under mm/
```

Directory imports are shallow. They do not recursively import subdirectories;
put explicit imports inside the files that need deeper modules.

Aliases and selective import lists are intentionally not allowed on directory
imports because there is no single target module to alias or filter.

#### Import with Alias

```swift
import graphics as gfx
```

#### Selective Import

```swift
import { Screen, draw as draw_screen } from graphics
```

Selective imports bind only the named exported symbols into the importing
module. Use ordinary module imports when you want the full module surface.

#### Public Exports

Modules are backwards-compatible by default: if a module contains no `public`
declarations, every top-level symbol remains exportable to imports.

Once a module contains at least one `public` declaration, only declarations marked
`public` are exported to other modules:

```swift
public func exposed() -> i64 {
    return 7
}

func helper() -> i64 {
    return 9
}
```

`helper` can still be used inside its own module, but it cannot be imported
selectively or through a module alias from another file. Marking a namespace as
`public` exports the declarations inside it:

```swift
public namespace HAL.IDT {
    func init() {
    }
}
```

### How It Works

1. **Dependency Resolution**: The compiler starts with your entry file and recursively resolves all imports
2. **Circular Detection**: When a circular import is detected, the compiler notes it and continues
3. **Directory Expansion**: Directory imports expand to a sorted list of direct `.llpl` files
4. **Forward Declarations**: All classes, functions, and methods get forward declarations in C
5. **Ordered Compilation**: Modules are compiled in dependency order

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
2. **Entry file directory**: lets nested modules use project-root imports such as `import hal.cpu`
3. **`$LLPL_HOME`**, if set: e.g. `import std.io.file` checks `$LLPL_HOME/stdlib/io/file.llpl`
4. **Project config paths**: `source_roots` and `import_paths` from the nearest `llpl.json`, if present
5. **Current directory**: `./utils.llpl`
6. **lib directory**: `lib/utils.llpl`
7. **modules directory**: `modules/utils.llpl`

For every file lookup, the resolver also maps `std/...` to `stdlib/...`, so:

```swift
import std.text.string_utils
```

resolves to `stdlib/text/string_utils.llpl` under `$LLPL_HOME` or another
search root.

If no file is found, the same roots are checked for a directory import. For
example, `import hal` checks `hal.llpl` first, then a `hal/` directory.

`$LLPL_HOME` is what lets every standard library module (and anything
that imports one) write `import std.*` instead of a relative path
like `"../../stdlib/..."` whose correctness depends on how deeply nested
the importing file happens to be. Set it once to this repository's own
root:

```sh
export LLPL_HOME=/path/to/LLPL
```

Compiling from within the repo's own root directory works even without
`LLPL_HOME` set (the current-directory search path already covers it),
but any project living elsewhere needs `LLPL_HOME` for its `std.*`
imports - including transitively, since `std.yaml.yaml_parser` and
`std.json.json_parser` themselves import `std.text.string_utils` this
same way.

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
3. **Directory imports are shallow**: nested directories require explicit imports
4. **Directory imports cannot be aliased or selective**: aliases/selective imports require a single target file
5. **File-based**: Modules are files, not logical units - use `namespace` (see below) for logical grouping independent of file layout

Symbols aren't automatically isolated by file the way they are in some
languages, but LLPL's `namespace` blocks give you real isolation: a class or
function inside `namespace Graphics { ... }` is mangled to `Graphics_...` in
the generated C, so identically-named declarations in different namespaces
don't collide, and unqualified sibling references still resolve within the
enclosing namespace.

### Future Enhancements

- [ ] Package system: `import package:module`
- [ ] Precompiled modules

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
