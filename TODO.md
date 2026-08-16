# TODO - Current Roadmap

This file tracks forward-looking work only. Completed session notes belong in
commit messages or `WORKING_NOW.md`, not in the roadmap.

## High Priority

### Async & Concurrency
- [x] Parse `async func` and `await`
- [x] Lower async functions to frame/start/poll ABIs
- [x] Provide async layout reports with `--emit-async-layout`
- [x] Add runtime task/executor primitives in `prelude.llpl` and `runtime/`
- [x] Cover async lowering, task join, pending futures, methods, and diagnostics in tests
- [x] Add cancellation semantics
- [x] Add timeout helpers around futures/tasks
- [x] Add async channels or queues
- [ ] Document hosted and kernel async patterns in `README.md` or a dedicated guide

### Synchronization
- [x] Add hosted user-mode `Thread<T>` APIs
- [ ] Standardize thread/task primitive APIs across hosted and kernel targets
- [x] Add portable atomic runtime types
- [ ] Add compiler intrinsics for atomics
- [x] Add `Mutex` and `RwLock` stdlib types
- [x] Add task/thread-local storage
- [x] Add tests for interrupt-context restrictions and scheduler interactions

### Serialization
- [ ] Define stable reflection metadata contracts for structs/classes/enums
- [ ] Add JSON serialization of structs
- [ ] Add JSON deserialization into typed structs
- [ ] Extend YAML support beyond parsing
- [ ] Add binary serialization format support
- [ ] Support nested structs, arrays, and optional/default fields
- [ ] Add tests and examples

## Medium Priority

### Diagnostics
- [ ] Add colored error output
- [ ] Add source context snippets
- [ ] Add suggestion engine for nearby names/imports
- [ ] Add warning categories for unused variables, dead code, and narrowing casts
- [ ] Improve generic/trait instantiation error messages
- [ ] Improve circular import diagnostics

### UI Widgets
- [ ] TextInput widget
- [ ] MultilineText widget
- [ ] Dropdown / ComboBox widget
- [ ] RadioButton group widget
- [ ] TabView widget
- [ ] Standalone scrollbar widget
- [ ] Menu system with top-bar and context menus
- [ ] Modal dialog boxes
- [ ] File browser widget
- [ ] Styling system for colors, fonts, and borders

### Reflection & Introspection
- [x] Runtime reflection entry points for type and field metadata
- [ ] Generic type inspection
- [ ] Method metadata
- [ ] Constructor metadata
- [ ] Enum variant metadata
- [ ] Reflection docs and examples beyond `examples/reflection_demo.llpl`

### Tooling
- [ ] REPL / interactive CLI
- [ ] Line editing with history and completion
- [ ] Incremental compilation mode
- [ ] Expression evaluation and variable inspection
- [ ] Documentation generator
- [ ] Expand editor/LSP feature coverage

## Lower Priority

### Networking APIs
- [ ] Stabilize hosted socket wrapper APIs
- [ ] Add UDP socket support
- [ ] Add HTTP client wrapper
- [ ] Add HTTPS/TLS support
- [ ] Add DNS resolution
- [ ] Add tests and examples

### Testing & Benchmarking
- [x] `unittest { ... }` compilation through `--unittest`
- [x] Unified test runner through `tools/llplbuild test`
- [ ] Test discovery/filtering ergonomics
- [ ] Assertion macros or helpers such as `assert_eq`
- [ ] Benchmark runner
- [ ] Fuzz corpus minimization workflow

### Bare-Metal Improvements
- [x] GRUB/Multiboot2 example kernel
- [x] Limine example kernel
- [x] x86_64 interrupt functions and hidden-runtime-path checks
- [ ] UEFI-first boot path documentation
- [ ] Device tree support
- [ ] ARM64 support
- [ ] RISC-V support
- [ ] More hardware driver examples

### Graphics
- [ ] 2D graphics primitives
- [ ] Sprite system
- [ ] Animation helpers
- [ ] Text rendering improvements
- [ ] Vector graphics / SVG support

### Performance
- [ ] Optimize generated C for common expression patterns
- [ ] Reduce monomorphized generic code size
- [ ] Add inline hints or attributes for codegen
- [ ] Add profiling hooks
- [ ] Add benchmark snapshots for generated code

## Deferred

- [ ] Exhaustiveness checking for `match`
- [ ] Constraint-based type inference
- [ ] Re-exports and public-use ergonomics
- [ ] Debugger integration with GDB/LLDB
- [ ] Optional tracing or leak-detection runtime mode
