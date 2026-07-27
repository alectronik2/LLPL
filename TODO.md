# TODO - Feature Roadmap

## HIGH PRIORITY

### Async & Concurrency (Phase 1)
- [ ] Thread primitives (spawn, join)
- [ ] Mutex and RwLock types
- [ ] Atomic types for synchronization
- [ ] Channel type for thread communication (mpsc)
- [ ] Task/thread local storage
- [ ] Documentation and examples

### Async & Concurrency (Phase 2)
- [ ] Event loop runtime (executor)
- [ ] Async/await syntax in parser
- [ ] Future/Promise types
- [ ] Async channel variants
- [ ] Timeout support
- [ ] Integration with stdlib

### Struct Serialization
- [ ] Derive macro for `serialize`/`deserialize`
- [ ] JSON serialization of structs
- [ ] JSON deserialization to structs
- [ ] YAML serialization (extend existing parser)
- [ ] Binary format support
- [ ] Nested struct serialization
- [ ] Optional field handling
- [ ] Tests and examples

## MEDIUM PRIORITY

### UI Widgets (Expansion)
- [ ] TextInput widget (single-line text entry)
- [ ] MultilineText widget
- [ ] Dropdown / ComboBox widget
- [ ] RadioButton group widget
- [ ] TabView widget
- [ ] Scrollbar widget (standalone)
- [ ] Menu system (top bar, context menus)
- [ ] Dialog boxes (modal windows)
- [ ] File browser widget
- [ ] Styling system (colors, fonts, borders)

### Reflection & Introspection
- [ ] Runtime type information (RTTI)
- [ ] Generic type inspection
- [ ] Field metadata
- [ ] Method introspection
- [ ] Dynamic dispatch support
- [ ] Constructor auto-discovery

### REPL / Interactive Mode
- [ ] Interactive CLI for LLPL
- [ ] Line editing (history, completion)
- [ ] Incremental compilation
- [ ] Expression evaluation
- [ ] Variable inspection
- [ ] Function definition

### Better Error Messages
- [ ] Colored error output
- [ ] Source code context display
- [ ] Suggestion engine (did you mean?)
- [ ] Error categorization
- [ ] Warning system (deprecation, style)

## LOWER PRIORITY

### Networking APIs
- [ ] Socket types (TCP, UDP)
- [ ] Socket operations (bind, listen, connect)
- [ ] HTTP client wrapper
- [ ] HTTPS/TLS support
- [ ] DNS resolution
- [ ] Tests and examples

### Testing Framework
- [ ] Test function macros (#[test])
- [ ] Assertion macros (assert_eq!, etc.)
- [ ] Test runner
- [ ] Benchmark support
- [ ] Test discovery and filtering

### Boot/Baremetal Improvements
- [ ] UEFI boot support (alternative to Multiboot2)
- [ ] Fix 64-bit bootloader assembly
- [ ] Device tree support
- [ ] ARM64 support
- [ ] RISC-V support

### Graphics Enhancements
- [ ] 2D graphics library (shapes, transforms)
- [ ] Sprite system
- [ ] Animation support
- [ ] Text rendering improvements
- [ ] Vector graphics (SVG support)

### Performance
- [ ] Optimize generated C code
- [ ] Better monomorphization (reduce code bloat)
- [ ] Inline hints for codegen
- [ ] Profiling support
- [ ] Benchmarking tools

## DEFERRED / NICE-TO-HAVE

- [ ] Pattern matching enhancements
- [ ] Exhaustiveness checking for match
- [ ] Better generic error messages
- [ ] Constraint-based type inference
- [ ] Module visibility (pub/private)
- [ ] Re-exports and public use
- [ ] Documentation generation (docgen)
- [ ] IDE support (LSP)
- [ ] Debugger integration (GDB/LLDB)

## KNOWN ISSUES TO FIX

### Compiler
- [ ] Integer type narrowing warnings
- [ ] Unused variable detection
- [ ] Dead code detection
- [ ] Better cycle detection in circular imports

### Runtime
- [ ] Improve panic/error stack traces
- [ ] Better memory leak detection
- [ ] GC integration (optional mark-sweep)

### Docs
- [ ] Complete API documentation
- [ ] More tutorial examples
- [ ] Architecture documentation
- [ ] Performance tuning guide

## COMPLETED IN THIS SESSION ✅

- [x] Fix List/TreeView widget rendering (malloc heap allocation)
- [x] Fix string extraction in list items (get_list_item_at)
- [x] Fix char literal casting in filesystem.llpl
- [x] Fix namespace resolution (using namespace priority)
- [x] Fix collections_demo compilation
- [x] Fix interactive_demo compilation
- [x] Update WORKING_NOW documentation
- [x] Create comprehensive TODO list

## Session Statistics

**Files Modified:**
- source/codegen.d - namespace resolution fix
- examples/sdl/ui_dsl_app.llpl - UI rendering fixes
- stdlib/ui/sdl.llpl - malloc heap allocation fixes
- stdlib/io/filesystem.llpl - char literal fixes
- examples/sdl/interactive_demo.llpl - type fixes
- examples/collections/collections_demo.llpl - using namespace

**Bugs Fixed:** 6
**Files Updated:** 7
**New Features:** Filesystem I/O bindings
**Tests Passing:** 70/70 (LLPL test suite)

---

## Notes

- Async/concurrency is the highest-impact next feature (2-3 sessions)
- Serialization is secondary but valuable (1-2 sessions)
- UI widget expansion is incremental (can be done in parallel)
- Focus on what enables real applications (async first)
