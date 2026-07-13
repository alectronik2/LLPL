# LLPL Code Examples

## Bare-Metal Examples

The `examples/baremetal_demo` directory contains the larger GRUB/Multiboot2
demo with paging, tasks, a shell, VFS, and user ELF loading.

The `examples/limine_baremetal_demo` directory contains a smaller Limine boot
protocol companion demo. It builds a higher-half kernel ELF, publishes a
Limine framebuffer request, writes to COM1 serial, and draws directly into the
framebuffer returned by Limine.

Global variables can opt into backend/linker attributes when bare-metal ABIs
need exact ELF placement or retention:

```swift
@section(".limine_requests")
@used
@align(16)
let request: uint[4] = [1, 2, 3, 4]
```

`@section("NAME")` emits a C section attribute, `@used` prevents dead
stripping, and `@align(N)` emits an alignment attribute. These attributes are
currently supported on global `let`/`const`/`volatile` declarations.

### Symbolized Backtraces

The compiler bakes a static symbol table - one entry per compiled
function/method/constructor, with its name, declaring `.llpl` file, and
declaration line - directly into the binary as plain data (see
codegen.d's `generateBacktraceSymbolTable`). No external tool (objdump,
nm, a DWARF parser) is needed to make a bare-metal backtrace readable;
`examples/baremetal_demo/backtrace.llpl` walks the `rbp` frame-pointer
chain and resolves each return address through it:

```swift
extern func puts(s: char*) -> int

func helper(n: int) -> int {
    return n * 2
}

func main() -> int {
    let addr: uint = helper as uint
    let sym: char* = llpl_resolve_symbol(addr)
    if sym != null {
        puts(llpl_symbol_name(sym))  // "helper"
        puts(llpl_symbol_file(sym))  // "example.llpl"
    }
    return 0
}
```

`llpl_resolve_symbol(addr)` finds whichever compiled function *contains*
`addr` - it doesn't need to be an exact function-start address, which is
what makes it useful for real return addresses from a stack walk (always
a few bytes past a `call` instruction, never a function's first byte).
Resolves to a function's **declaration site**, not the exact call site
within it - the table is function-granularity, not per-instruction DWARF
line info, so two different calls into the same function report the same
line. See `test/symbol_table_demo.llpl` for the full runnable version
this is taken from.

A bare instance method reference (`f.method as uint`, no call parens)
works the same way a plain function name does - `f.bar as uint` decays to
`Foo_bar`'s address (whether `bar` was written directly in `Foo`'s body
or via an `impl Trait for Foo { ... }` block). An overloaded method can't
be referenced this way without a call's arguments to disambiguate which
one is meant - a clear compile error, not a wrong pick.

## Basic Examples

### Hello World (with C FFI)

```swift
extern func puts(s: char*) -> int

func main() -> int {
    puts("Hello from LLPL!")
    return 0
}
```

### Fibonacci

```swift
func fibonacci(n: int) -> int {
    if n <= 1 {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

func main() -> int {
    let result: int = fibonacci(10)
    return result
}
```

### Array Operations

```swift
func sum_array(arr: int*, len: int) -> int {
    let sum: int = 0
    for let i: int = 0, i < len, i = i + 1 {
        sum = sum + arr[i]
    }
    return sum
}

func main() -> int {
    let numbers: int[5]
    numbers[0] = 10
    numbers[1] = 20
    numbers[2] = 30
    numbers[3] = 40
    numbers[4] = 50

    let total: int = sum_array(numbers as int*, 5)
    return 0
}
```

### Pointer-to-Pointer

Any level of indirection is allowed - `int*`, `int**`, `int***`, ... -
`&` adds one level (`&ptr` where `ptr: int*` gives `int**`, not `int*`
again), `*` removes one. See `test/pointer_to_pointer_demo.llpl` for the
full runnable version this is taken from:

```swift
func set_via_pp(pp: int**, v: int) {
    **pp = v
}

func main() -> int {
    let x: int = 5
    let p: int* = &x
    let pp: int** = &p

    set_via_pp(pp, 42)
    return x  // 42
}
```

A statement starting with `*`, `-`, or `&` right after another statement
is only read as continuing that previous statement's expression (`foo()
* p`, a multiplication) if it stays on the *same source line* - on a new
line it's instead parsed as the start of a fresh unary expression/
statement (dereference, negate, or address-of), the same newline-
sensitive rule Go and Kotlin use to resolve the identical ambiguity.
`**pp = v` (a fresh statement, own line, right after another one) parses
correctly with no workaround needed.

### Named Arguments and Default Values

A parameter can declare a default value (`p2: string = "none"`), making it
optional at call sites that don't care about it, and any argument can be
passed by name, in any order - resolved entirely at the call site, at
compile time (no change to the callee's own generated signature, so this
works for `extern func` too). Works uniformly for free functions, methods,
constructors, generic functions, and closures. See
`test/named_args_demo.llpl` for the full runnable version this is taken
from:

```swift
func greet(name: char*, greeting: char* = "Hello") {
    puts(greeting)
    puts(name)
}

func main() -> int {
    greet("Alice", "Hi")                  // all-positional
    greet("Bob")                          // trailing default omitted
    greet(name: "Cara", greeting: "Yo")    // named, in order
    greet(greeting: "Hey", name: "Dave")   // named, any order
    return 0
}
```

Rules:
- Once a parameter has a default, every parameter after it in the same
  list must also have one - keeps a purely positional call unambiguous.
- Once any named argument appears in a call, no further positional
  argument may follow (same rule as Python/C#).
- Missing a required argument, an unknown argument name, supplying the
  same parameter twice, or exceeding a non-variadic callee's arity are all
  compile errors.

Not supported: tagged-enum variant construction (`Shape.Circle(3)`) and
macro invocations stay positional-only - their parameter lists are a
simpler `string[]`/field-list shape with no notion of a default.

## Classes and Objects

### Simple Class

```swift
class Rectangle {
    let width: int
    let height: int

    constructor(w: int, h: int) {
        self.width = w
        self.height = h
    }

    destructor() {
        // Cleanup if needed
    }

    func area() -> int {
        return self.width * self.height
    }

    func perimeter() -> int {
        return 2 * (self.width + self.height)
    }
}

func main() -> int {
    let rect: Rectangle = new Rectangle(10, 20)
    let area: int = rect.area()
    let perim: int = rect.perimeter()
    return 0
}
```

A field can also be declared without `let` - `width: int` means exactly
what `let width: int` does (still mutable, just terser). `const` and
`volatile` fields still need their keyword written out, since dropping it
would leave no way to tell them apart from a plain mutable field:

```swift
class Rectangle2 {
    width: int
    height: int

    constructor(w: int, h: int) {
        self.width = w
        self.height = h
    }
    destructor() {}
}
```

### Private Members

`private` on a field or method restricts it to the declaring class's own
body - any of its methods/constructors, or an `impl Trait for ThisClass {
... }` block targeting it, not just accesses through `self`. It's class-
scoped, not instance-scoped: one instance's own method can read *another*
instance's private field. Only fields and methods can be `private` - a
constructor always needs to be reachable via `new`, so it isn't offered
there. See `test/private_members_demo.llpl` for the full runnable version
this is taken from:

```swift
class Counter {
    private let count: int

    constructor() { self.count = 0 }
    destructor() {}

    private func bump() -> int {
        self.count = self.count + 1
        return self.count
    }

    func increment() -> int {
        return self.bump()
    }

    // Class-scoped, not instance-scoped - reading another Counter's own
    // private field from within Counter's own method is fine.
    func matches(other: Counter) -> bool {
        return self.count == other.count
    }
}

func main() -> int {
    let c: Counter = new Counter()
    c.increment()
    // c.count       // compile error: private, only accessible from within 'Counter'
    // c.bump()       // compile error: private, only accessible from within 'Counter'
    return 0
}
```

### Linked List

```swift
class ListNode {
    let value: int
    let next: ListNode

    constructor(val: int) {
        self.value = val
        self.next = null
    }

    destructor() {
        // Automatic cleanup of 'next' via reference counting
    }

    func append(val: int) {
        let current: ListNode = self
        while current.next != null {
            current = current.next
        }
        current.next = new ListNode(val)
    }

    func length() -> int {
        let count: int = 1
        let current: ListNode = self.next
        while current != null {
            count = count + 1
            current = current.next
        }
        return count
    }
}

func main() -> int {
    let list: ListNode = new ListNode(1)
    list.append(2)
    list.append(3)
    list.append(4)

    let len: int = list.length()
    return 0
}
```

### `delete`

Classes are reference-counted: a field pointing at another class instance
already gets released automatically when its owning object's destructor
runs. `delete expr` gives an explicit way to release a reference on
demand - for an object that was never stored as anyone's field (e.g. a
`new Foo()` a container never took ownership of). It releases *this*
reference: if it was the last one, the destructor runs and the memory is
freed; if other references to the same object still exist, it survives.
Only classes are reference-counted at all - `delete` on a struct or
primitive is a compile error. See `test/delete_demo.llpl` for the full
runnable version this is taken from:

```swift
class Foo {
    let n: int
    constructor(n: int) {
        self.n = n
        puts("Foo constructed")
    }
    destructor() {
        puts("Foo destructed")
    }
}

func main() -> int {
    let f: Foo = new Foo(5)
    delete f  // prints "Foo destructed" right here
    return 0
}
```

### Weak References

`Weak<T>` (prelude.llpl) is a non-owning reference - unlike an ordinary
class-typed field, it never keeps its target alive, and safely reports
whether the target is still alive instead of leaving a dangling pointer
once it isn't. Its main use is breaking a reference cycle between two
classes that hold each other (a parent/child or doubly-linked pair): make
one direction `Weak<T>` and only the other an ordinary owning field, so
destroying the owner doesn't try to cascade back through an already-
destroyed instance. See `test/weak_reference_demo.llpl` for the full
runnable version this is taken from:

```swift
class Child {
    let name: char*
    let parent: Weak<Parent>
    constructor(name: char*) {
        self.name = name
    }
    destructor() { puts("Child destroyed") }

    func link_parent(p: Parent) {
        self.parent = new Weak<Parent>(p)
    }
}

class Parent {
    let child: Child
    constructor(name: char*) {
        self.child = new Child(name)
        self.child.link_parent(self)
    }
    destructor() { puts("Parent destroyed") }
}

func main() -> int {
    let p: Parent = new Parent("kid")

    // .upgrade() returns a real, retained reference if the target is
    // still alive (the caller now owns it, like any `new` result), or
    // null if it's already gone.
    let parent_ref: Parent = p.child.parent.upgrade()
    if parent_ref != null {
        delete parent_ref
    }

    delete p  // Parent destroyed, then Child destroyed - no crash
    return 0
}
```

`is_alive() -> bool` checks liveness without upgrading. Only meaningful
for a class `T` - `Weak<T>` relies on the same reference-counting header
every class instance already has.

### Overloading

Methods, constructors, and free functions can share a name as long as
their parameter types differ - the right one is picked at each call site
by argument type (an exact match; no implicit numeric coercion). A name
declared only once keeps its usual behavior completely unchanged; only an
actually-overloaded name needs disambiguating. See
`test/overloading_demo.llpl` for the full runnable version this is taken
from:

```swift
func describe(n: int) -> char* {
    return "an int"
}
func describe(s: char*) -> char* {
    return "a string"
}

class Box {
    let n: int

    constructor() { self.n = 0 }
    constructor(n: int) { self.n = n }

    destructor() {}

    func combine(x: int) -> int { return self.n + x }
    func combine(x: int, y: int) -> int { return self.n + x + y }
}

func main() -> int {
    puts(describe(5))     // "an int"
    puts(describe("hi"))  // "a string"

    let b: Box = new Box(10)
    print_int("b.combine(5)", b.combine(5))       // 15
    print_int("b.combine(5, 6)", b.combine(5, 6)) // 21
    return 0
}
```

Two declarations with identical parameter types (an accidental exact
duplicate, not a real overload - nothing could ever distinguish them at
a call site) is a compile error, as is a call that matches no overload.
Not supported: overloaded generic function templates (still one `func
foo<T>` per name - though a generic *class*'s own methods fully support
overloading once monomorphized), multiple `func operator+`-style
signatures for the same operator, and `extern func` re-declarations
(its C symbol is a real, fixed external name).

### `.stringof`

`x.stringof` (no call parens - `x.stringof()` already works as an ordinary
method call, no special support needed) resolves to a class's own
no-argument `stringof()` method if it defines one, or a compile-time
string literal of the type's name otherwise - the same fallback a struct
(which can't have methods at all) or a primitive gets. Casting a
class/struct value `as string` resolves the same way, instead of
reinterpreting the value as a raw `char*` - and so does string
interpolation (`"\(x)"`), implicitly, with no need to spell out
`"\(x.stringof)"`. See `test/stringof_demo.llpl` for the full runnable
version this is taken from:

```swift
class Point3D {
    let x: int
    let y: int
    let z: int

    constructor(x: int, y: int, z: int) {
        self.x = x
        self.y = y
        self.z = z
    }

    destructor() {}

    func stringof() -> string {
        if self.x == 0 && self.y == 0 && self.z == 0 {
            return "Point3D(origin)"
        }
        return "Point3D(non-origin)"
    }
}

class Plain {
    let n: int
    constructor(n: int) { self.n = n }
    destructor() {}
}

func main() -> int {
    let p: Point3D = new Point3D(1, 2, 3)
    puts(p.stringof)   // "Point3D(non-origin)" - custom method
    puts(p as string)  // same, via a cast

    let q: Plain = new Plain(5)
    puts(q.stringof)   // "Plain" - no stringof() defined, falls back to the type name

    let n: int = 42
    puts(n.stringof)   // "int" - primitives fall back too

    puts("interpolated: \(p)")  // implicit stringof inside "\(...)"
    return 0
}
```

### `.sizeof`

`x.sizeof` (no call parens) works on any typed *value*, inferring its
type - unlike the existing `sizeof(TypeName)`, which only ever takes a
real type reference. See `test/sizeof_demo.llpl` for the full runnable
version this is taken from:

```swift
struct Pair {
    let x: int
    let y: int
}

func main() -> int {
    let n: int = 5
    let p: Pair = Pair { x: 1, y: 2 }

    let a: uint = n.sizeof        // 8 - same as sizeof(int)
    let b: uint = p.sizeof        // 16 - same as sizeof(Pair)
    let c: uint = sizeof(int)     // the type-only spelling still works
    return 0
}
```

A class-typed value's `.sizeof` reflects the *pointer's* size, not the
underlying object's - classes are always heap-allocated and accessed by
pointer, so that's what the value itself actually is at runtime.

## Control Flow

### Nested Loops

```swift
func print_multiplication_table(size: int) {
    for let i: int = 1, i <= size, i = i + 1 {
        for let j: int = 1, j <= size, j = j + 1 {
            let product: int = i * j
            // Print product
        }
    }
}
```

### Range-Based `for`

`for i in start..end { ... }` counts from `start` up to (not including)
`end` - sugar for `foreach let i in ... { ... }`, spelled without `let`
and using `for` instead of `foreach`. The bounds can be any expression,
not just literals, and nests like any other loop. See
`test/range_for_demo.llpl` for the full runnable version this is taken
from:

```swift
func main() -> int {
    for i in 0..5 {
        print_int("i", i)  // 0, 1, 2, 3, 4
    }
    return 0
}
```

### `for`/`foreach` Over Custom Iterators

`for item in collection { ... }` and `foreach let item in collection {
... }` both already work for any fixed-size array *and* for any class
implementing the iterator protocol: an `iter_has_next() -> bool` and
`iter_next() -> T` method pair (an optional `iter_reset()` is called
automatically before the loop if present, so an object can be looped over
more than once without resetting iteration state by hand). `String` and
`HashMap<K, V>` (in `prelude.llpl`) already implement this by defining
those methods directly in their own bodies.

`trait Iterator<T> { func iter_has_next() -> bool; func iter_next() -> T }`
(also in `prelude.llpl`) formalizes this convention so a class can
document/opt into it explicitly via an `impl` block instead, with the
usual trait/impl arity checking catching a missing method at compile
time. `for`/`foreach` dispatch on either style identically - a class
implementing the protocol via `impl Iterator<T> for X { ... }` is exactly
as foreach-able as one that writes the methods inline. See
`test/iterator_trait_demo.llpl` for the full runnable version this is
taken from:

```swift
class Countdown {
    let n: int
    constructor(n: int) { self.n = n }
    destructor() {}
}

impl Iterator<int> for Countdown {
    func iter_has_next() -> bool {
        return self.n > 0
    }
    func iter_next() -> int {
        self.n = self.n - 1
        return self.n + 1
    }
}

func main() -> int {
    let c: Countdown = new Countdown(3)
    for x in c {
        print_int("x", x)  // 3, 2, 1
    }
    return 0
}
```

The trait's own `<T>` and an impl's `<int>` type argument are a
signature-writing convenience, not type-checked against the impl's
concrete methods - a trait's return/param types are never resolved or
generate code (traits are signature-only everywhere in this language);
only the method names and arities are verified to match.

### Conditional Logic

```swift
func max(a: int, b: int) -> int {
    if a > b {
        return a
    } else {
        return b
    }
}

func clamp(value: int, min: int, max: int) -> int {
    if value < min {
        return min
    } else if value > max {
        return max
    } else {
        return value
    }
}
```

### `if` as an Expression

`if cond { expr } else { expr }` can be used anywhere an expression is
expected, not just as a statement - `else` is mandatory (there's no
sensible value for a branch that's never taken), and each branch must end
with an expression to supply its value. Earlier statements in a branch
still run for their side effects/bindings; only the last one supplies the
value. See `test/if_expr_demo.llpl` for the full runnable version this is
taken from:

```swift
func classify(n: int) -> char* {
    return if n < 0 {
        "negative"
    } else if n == 0 {
        "zero"
    } else {
        "positive"
    }
}

func main() -> int {
    let x: int = if true { 128 } else { 256 }

    // type inferred from the branches, no explicit annotation needed
    let y = if false { 1 } else { 2 }

    // earlier statements run for their side effects; only the trailing
    // expression supplies the branch's value
    let z: int = if true {
        let a: int = 10
        let b: int = 20
        a + b
    } else {
        0
    }
    return 0
}
```

Both branches' trailing expressions must resolve to the same type (a
mismatch is a compile error, the same "nominal, single-type" stance this
compiler takes elsewhere). A bare, unparenthesized `if` as the very last
line of a branch is parsed as a nested if-*statement*, not this
if-expression's value (there's no other way to tell them apart at that
position) - wrap it in parens (`(if ... else ...)`) to use a nested
if-expression as a branch's trailing value.

### Implicit Returns

A function/method/lambda body's trailing bare expression is its return
value, unless the return type is `void` - `func square(n: int) -> int { n
* n }` behaves exactly like `func square(n: int) -> int { return n * n }`.
Only the true *last* statement counts; an expression anywhere else in the
body is still just evaluated for its side effects and discarded, same as
today. See `test/implicit_return_demo.llpl` for the full runnable version
this is taken from:

```swift
func square(n: int) -> int {
    n * n
}

// earlier statements still run for their side effects/bindings
func sum_of_squares(a: int, b: int) -> int {
    let sa: int = square(a)
    let sb: int = square(b)
    sa + sb
}

// explicit `return` still works, including mixed with an implicit one
func abs_value(n: int) -> int {
    if n < 0 {
        return -n
    }
    n
}
```

Composes with `if` as an expression the same way any other trailing
expression does - including the same parenthesization rule when the
if-expression is itself the very last thing in the body (a bare, un-
parenthesized `if` there is parsed as a statement, not this function's
implicit return value):

```swift
func abs_value2(n: int) -> int {
    (if n < 0 { -n } else { n })
}
```

## Enums and Pattern Matching

### Plain Enums

A bare `enum` is sugar for a namespace of auto-incrementing int constants -
`EnumName.MEMBER` resolves just like any other namespaced value:

```swift
enum Color {
    RED,
    GREEN,
    BLUE = 10,
    YELLOW // continues from 11
}

func main() -> int {
    let c: int = Color.BLUE
    return c
}
```

### Tagged Enums (Sum Types)

Give any member a `(field: type, ...)` list and the whole `enum` becomes a
tagged union instead: each variant can carry its own, independently-typed
data. A variant is always constructed by calling it - `Shape.Circle(3)`,
or `Shape.Triangle()` for a zero-field variant - never as a bare value.

```swift
enum Shape {
    Circle(radius: int),
    Rectangle(width: int, height: int),
    Triangle(base: int, height: int)
}
```

`match` destructures a tagged enum with `case EnumName.Variant(binding,
...)`, binding each field to a fresh name for that case's body - see
`test/tagged_enums_demo.llpl` for the full runnable version this is taken
from:

```swift
func area(s: Shape) -> int {
    match s {
        case Shape.Circle(radius) => {
            return 3 * radius * radius
        }
        case Shape.Rectangle(width, height) => {
            return width * height
        }
        case Shape.Triangle(base, height) => {
            return (base * height) / 2
        }
    }
    return -1 // unreachable - every variant is handled above
}
```

A tagged enum is a natural fit for error handling too - a `Result`-style
type where the error case carries its own message:

```swift
enum Result {
    Ok(value: int),
    Err(message: char*)
}

func safe_divide(a: int, b: int) -> Result {
    if b == 0 {
        return Result.Err("division by zero")
    }
    return Result.Ok(a / b)
}
```

A destructuring `case` and an ordinary equality `case` (string/int
literals, as elsewhere in this doc) can appear in the same `match`, and
`default` still works as the catch-all for either.

### Match with Tuple and Struct Patterns

`match` also understands tuple patterns, struct patterns, and the `_`
wildcard:

```swift
struct Point {
    let x: int
    let y: int
}

func describe(t: (int, int)) -> char* {
    match t {
        case (x, y) => {
            if x == 0 && y == 0 { return "origin" }
            if x == 0 { return "on y-axis" }
            if y == 0 { return "on x-axis" }
            return "somewhere"
        }
    }
    return ""
}

func classify(p: Point) -> char* {
    match p {
        case Point { x, y } => {
            if x == 0 && y == 0 { return "origin" }
            return "somewhere"
        }
    }
    return ""
}
```

Patterns can be nested (`case ((a, b), c) => ...`) and used alongside
ordinary `case` alternatives and `default`.

## Closures and Lambdas

A closure type is written `(ParamType, ...) -> ReturnType`. A lambda
literal is `func[captures](params) -> ReturnType { ... }` - the capture
list is explicit, so a missing capture is a compile error rather than a
silently wrong closure. Each capture's *current value* is snapshotted (by
value, not by reference) into the closure's own environment at the moment
the lambda expression runs - changing the original variable afterwards
never affects an already-created closure:

```swift
func make_adder(n: int) -> (int) -> int {
    return func[n](x: int) -> int {
        return x + n
    }
}

func main() -> int {
    let add5: (int) -> int = make_adder(5)
    let result: int = add5(10) // 15
    return 0
}
```

Prefix a capture with `&` to capture it **by reference** instead. The
closure stores a pointer to the original variable, so reads see live values
and assignments write back to the enclosing scope. Nested lambdas can
re-capture an outer reference capture, with all closures aliasing the same
original variable. See `test/closures_by_ref.llpl` for a runnable example.

> Lifetime is the programmer's responsibility: a reference-capturing
> closure must not outlive the variable it points to.

A closure can be passed around like any other value - as a function
argument, or stored in and called through a class field - see
`test/closures_demo.llpl` for the full runnable version this is taken from:

```swift
func apply_twice(f: (int) -> int, x: int) -> int {
    return f(f(x))
}

class Counter {
    let count: int
    let step: (int) -> int

    constructor(start: int, step_fn: (int) -> int) {
        self.count = start
        self.step = step_fn
    }

    destructor() {}

    func advance() {
        self.count = self.step(self.count)
    }
}
```

A lambda with no captures at all just omits the `[...]`:

```swift
let doubler: (int) -> int = func(x: int) -> int {
    return x * 2
}
```

## Namespaces

`namespace Name { ... }` groups functions/classes/structs/consts under a
`Name.member` prefix, and nests - `namespace Foo.Bar { ... }` is sugar for
`namespace Foo { namespace Bar { ... } }`, and the two spellings mix
freely. See `test/nested_namespace_demo.llpl` for the full runnable
version this is taken from:

```swift
namespace Graphics.Utils {
    const VERSION = 2

    func describe() {
        puts("Graphics.Utils")
    }

    namespace Deep {
        func hello() {
            puts("Graphics.Utils.Deep")
        }
    }
}

func main() -> int {
    Graphics.Utils.describe()
    Graphics.Utils.Deep.hello()
    puts("\(Graphics.Utils.VERSION)")
    return 0
}
```

### Namespace Aliases

`alias NAME = a.b` can also name a *namespace path* rather than a single
symbol - a short prefix for a deeply-nested namespace, usable anywhere
the real path would be (function calls, types, `new`). See
`test/namespace_alias_demo.llpl` for the full runnable version this is
taken from:

```swift
namespace HAL {
    namespace Foo {
        class Bar {
            let n: int
            constructor(n: int) { self.n = n }
            destructor() {}
            func value() -> int { return self.n }
        }

        func greet() {
            puts("hello from HAL.Foo")
        }
    }
}

alias hf = HAL.Foo

func main() -> int {
    hf.greet()
    let b: hf.Bar = new hf.Bar(7)
    return 0
}
```

Unlike an ordinary symbol alias (`alias name = a.b.c` naming one
function/class/struct/global directly), a namespace alias's target is
never itself a real symbol - only a prefix of ones that are (`HAL.Foo`
has no symbol of its own, only members like `HAL.Foo.Bar`) - which is how
the compiler tells the two kinds apart.

## Modules and Imports

Files are compiled together by following their `import` statements. A plain
import makes every top-level declaration from the target file available in
the importing file:

```swift
import graphics
```

Dotted paths become directory separators, and quoted paths are accepted for
names that aren't valid identifiers:

```swift
import drivers.serial
import "weird-path.llpl"
```

An alias lets you qualify names through a shorter prefix:

```swift
import graphics as G

func main() -> int {
    G.clear_screen()
    return 0
}
```

Selective imports pull in only the named symbols (optionally renaming them),
which is useful for keeping large imports tidy or resolving name clashes:

```swift
import { Point, draw as render } from graphics

func main() -> int {
    let p: Point = Point { x: 1, y: 2 }
    render(p)
    return 0
}
```

See `test/import_alias.llpl` and `test/import_selective.llpl` for runnable
examples.

## Named Array Literals

`alias NAME = [ ... ]` names an array literal at compile time only - it
never becomes its own addressable C symbol. Every reference to `NAME` is
expanded back into these same element expressions, either as a whole
array-typed initializer, or spliced into a *larger* array literal it
appears as one element of. Useful for centralizing repeated magic-number
sequences without needing them to live at a shared memory location -
`examples/limine_baremetal_demo/limine.llpl` uses this for the Limine
boot protocol's request IDs (four `uint64` words, the first two shared by
every request, the last two naming which request it is), instead of
repeating all four inline at every request struct in `kernel.llpl`. See
`test/array_alias_demo.llpl` for the full runnable version this is taken
from:

```swift
alias limine_common_magic = [
    0xc7b1dd30df4c8b88,
    0x0a82e883a194f07b
]

// Spliced, not nested: limine_common_magic's 2 elements plus these 2
// give a 4-element array, matching LimineFramebufferRequest.id's type.
alias limine_framebuffer_request_id = [
    limine_common_magic,
    0x9d5827dcd881dd75,
    0xa3148604f6fab11b
]

@section(".limine_requests") @used
let framebuffer_request: LimineFramebufferRequest = LimineFramebufferRequest {
    id: limine_framebuffer_request_id,
    revision: 0,
    response: 0
}
```

A bare `alias NAME = value` (no brackets right after `=`) is unaffected -
that's still the existing symbol/type alias grammar (`alias string =
char*`).

## Generics

A generic function, class, or struct takes a `<T, ...>` type-parameter
list right after its name. A generic declaration is a template - it's
never compiled directly; each concrete type it's actually used with gets
its own real, fully-typed copy generated the first time that combination
is seen (monomorphization, the same strategy C++ templates use):

```swift
func max_of<T>(a: T, b: T) -> T {
    if a > b {
        return a
    }
    return b
}

struct Pair<A, B> {
    let first: A
    let second: B
}

func main() -> int {
    let m: int = max_of(3, 7)      // T inferred as int - always from
    let n: int = max_of(100, 42)   // arguments, never written explicitly
    let p: Pair<int, int>
    p.first = 1
    p.second = 2
    return 0
}
```

A generic function's type parameters are always inferred from its
arguments - there's no `identity<int>(5)` call syntax - so every type
parameter must appear in at least one parameter's type; a generic
class/struct, on the other hand, is always instantiated explicitly
(`Pair<int, int>`, `new Vector<int>(...)`), since there's often nothing to
infer it from at the point it's constructed.

`sizeof(Type)` is available too (mainly for writing generic containers
that need an element's byte size for allocation).

### Generic Standard Library Containers

`prelude.llpl` builds four generic containers on top of this - `Vector<T>`
(a growable array), `Optional<T>`, `LinkedList<T>`, and `HashMap<K, V>` -
available in every program without an import. See `test/generics_demo.llpl`
for the full runnable version this is taken from:

```swift
func main() -> int {
    let numbers: Vector<int> = new Vector<int>()
    numbers.push(10)
    numbers.push(20)

    let maybe: Optional<int> = new Optional<int>()
    maybe.set(99)
    if maybe.is_some() {
        let value: int = maybe.get()
    }

    let list: LinkedList<int> = new LinkedList<int>()
    list.push_front(1)

    let ages: HashMap<int, int> = new HashMap<int, int>()
    ages.insert(1, 30)
    let found: Optional<int> = ages.get(1) // HashMap.get() returns Optional<V>

    return 0
}
```

`HashMap<K: Hashable, V>` hashes/compares keys via `key.hash()`/
`key.equals(other)` (see [Traits/Interfaces](#traitsinterfaces) below) -
`prelude.llpl` provides `Hashable` impls for `int`/`uint`/`char`/`char*`,
the `char*` one hashing/comparing by actual string content, not pointer
identity. `Vector<T>` can't hold an explicitly-pointer element type
(`Vector<char*>`) either, since that would need a real pointer-to-pointer C
type this language's type system can't express - use a one-field wrapper
struct around the pointer instead if you need that.

## Traits/Interfaces

A `trait` is a compile-time-only contract - method signatures, no bodies.
`impl TraitName for TargetType { ... }` is how a primitive, struct, or
class actually gains a method body for it - the only way, since none of
those have inline method-declaration syntax of their own for an arbitrary
trait. Dispatch is entirely static (monomorphization, like every other
generic in this language) - there's no vtable, no trait-object/dynamic
dispatch, no heterogeneous "any Comparable" collection through a shared
pointer type.

```swift
trait Comparable {
    func compare(other: Self) -> int
}

impl Comparable for int {
    func compare(other: int) -> int {
        if self < other { return -1 }
        if self > other { return 1 }
        return 0
    }
}

// A bounded generic type parameter - T must have a matching `impl`,
// checked at monomorphization time.
func max_of<T: Comparable>(a: T, b: T) -> T {
    if a.compare(b) >= 0 {
        return a
    }
    return b
}
```

`Self` inside a trait's signatures or a matching `impl` block's bodies
refers to whatever concrete type that `impl` targets - it isn't a reserved
keyword, just a name resolved by substitution the same way a generic `T`
already is. An `impl` is valid if it defines a same-named method for every
one its trait declares; deeper signature mismatches are left for the C
backend to catch, same as everywhere else in this compiler. A trait can
have at most one bound per type parameter in v1 (no `T: A + B`), no default
method bodies, and an `impl` target must be concrete - `impl X for
Vector<int>` (a generic type) is rejected.

`prelude.llpl` ships `Hashable` (`hash() -> uint`, `equals(other: Self) ->
bool`, with impls for `int`/`uint`/`char`/`char*` and `String` - the `char*`
and `String` impls hash/compare by actual string content, not pointer
identity), `Comparable` (`compare(other: Self) -> int`, with impls for
`int`/`uint`/`char`), and the operator-overloading traits below. See
`test/traits_demo.llpl` and `test/test_hashmap_string.llpl` for full runnable
versions.

### Operator Overloading

`func operator+(other: T) -> T` (and `-`/`*`/`/`/`%`/`==`/`!=`/`<`/`>`/`<=`/
`>=`/`&`/`|`/`^`/`<<`/`>>`/unary `-`/`!`/`~`/`[]`) is a special method name
form usable two ways: as an ordinary inline method on a `class`, or - the
only option for a `struct` or primitive, neither of which have inline
method syntax for anything - through `impl SomeTrait for TargetType { ... }`.
Both forms resolve to the exact same internal method name (`op_add` for
`+`, etc. - see `ast.operatorMethodName`), so `a + b` dispatches identically
either way once a matching method exists:

```swift
struct Vec2 {
    let x: int
    let y: int
}

trait Add {
    func operator+(other: Self) -> Self
}

impl Add for Vec2 {
    func operator+(other: Vec2) -> Vec2 {
        let r: Vec2
        r.x = self.x + other.x
        r.y = self.y + other.y
        return r
    }
}

// Works through a bounded generic function too, same as any other trait.
func sum_pair<T: Add>(a: T, b: T) -> T {
    return a + b
}

func main() -> int {
    let a: Vec2
    a.x = 1
    a.y = 2
    let b: Vec2
    b.x = 10
    b.y = 20
    let c: Vec2 = a + b        // Vec2 { x: 11, y: 22 }
    let d: Vec2 = sum_pair(a, b) // same result, via the bound
    return 0
}
```

`prelude.llpl` ships `Add`, `Sub`, `Neg` (unary `-`), and `Mul` as traits,
deliberately *without* impls for the primitive types - plain `+`/`-`/`*`
already works unconditionally on `int`/`uint`/`char` with no bound needed,
and `impl Add for int` would recurse (its own `self + other` body would
dispatch straight back into that same impl, since there's no way to spell
"the native operator, not this overload" once one exists for a type). These
traits exist for user-defined arithmetic types like `Vec2` that have no
native operator to begin with. Validation is nominal/name-only (see above),
so an impl's parameter doesn't have to be `Self` either - `impl Mul for
Vec2 { func operator*(scalar: int) -> Vec2 { ... } }` (scaling by a plain
`int`) is perfectly valid.

## Pipe Operator

`x |> f` desugars to `f(x)`; `x |> f(a, b)` desugars to `f(x, a, b)` - x is
always inserted as the function's first argument. Chains left to right,
so `x |> f |> g` is `g(f(x))`. It binds looser than every other operator
(parsed just above assignment), so `a + b |> f` means `f(a + b)`, and the
right-hand side is always a callable reference (a bare name, or already
applied to its own trailing args) rather than a general expression:

```swift
func double_it(x: int) -> int {
    return x * 2
}

func add(a: int, b: int) -> int {
    return a + b
}

func main() -> int {
    let a: int = 5 |> double_it              // double_it(5) = 10
    let b: int = 5 |> double_it |> add(1)     // add(double_it(5), 1) = 11
    return 0
}
```

## Nullable Types

`T?` is sugar for the generic `Optional<T>` class (see "Generics" above).
A `let`/assignment target typed `T?` auto-wraps a plain value (building a
real `Optional<T>` and calling `.set(...)` on it), or an empty `Optional`
for `null` or a bare `let x: T?` with no initializer at all - see
`test/pipe_nullable_demo.llpl` for the full runnable version this is taken
from:

```swift
func main() -> int {
    let maybe: int? = 42     // sugar for a real Optional<int>, set to 42
    if maybe.is_some() {
        let value: int = maybe.get()
    }

    let nothing: int? = null // an empty Optional<int>
    let default_empty: int?  // also starts out empty, no initializer needed

    return 0
}
```

Pipe and nullable types compose naturally - a function returning `T?` can
sit at the end of a pipeline:

```swift
func parse_positive(s: char*) -> int? {
    if s[0] == 0 {
        return null
    }
    // ... digit-by-digit parsing, returning null on any non-digit ...
    return 123 // placeholder
}

func main() -> int {
    let parsed: int? = "123" |> parse_positive
    if parsed.is_some() {
        let n: int = parsed.get()
    }
    return 0
}
```

A `T?` global variable isn't supported (its initializer needs a real
function call - `Optional_T_new()`/`.set()` - which isn't a valid C static
initializer); declare it as a local inside a function instead.

## Struct Literals

`Name { field: value, ... }` constructs a struct value directly - every
field must be given, by name, though not necessarily in declaration
order. Structs only, never a class (use `new` for those):

```swift
struct Point {
    let x: int
    let y: int
}

func main() -> int {
    let p: Point = Point { x: 1, y: 2 }
    let p2: Point = Point { y: 4, x: 3 } // order doesn't matter
    return 0
}
```

A generic struct's type arguments always come from context - the
enclosing `let`/return's declared type - rather than being written in the
literal itself (there's often nothing else to infer them from):

```swift
struct Pair<A, B> {
    let first: A
    let second: B
}

func main() -> int {
    let coords: Pair<int, int> = Pair { first: 10, second: 20 }
    return 0
}
```

A struct literal works anywhere a comma/paren/bracket already gives it an
unambiguous end - a call argument, inside `(...)`, as a field value in
another struct literal - but a *bare* one directly as an if/while/for/
match/foreach condition is rejected (it would be ambiguous with that
construct's own following `{ body }`); wrap it in parens there instead.

## Tuples and Destructuring

Tuple types are written `(T, U, ...)`, tuple literals are written `(a, b, ...)`,
and tuples are value types (they are implemented as generic structs in the
prelude, with positional fields `_0`, `_1`, etc.).

```swift
struct Point {
    let x: int
    let y: int
}

func split() -> (int, int) {
    return (10, 20)
}

func main() -> int {
    // Explicit tuple type and positional access
    let t: (int, int) = (1, 2)
    let a: int = t._0
    let b: int = t._1

    // Type inference works too
    let inferred = (3, 4)

    // Multi-value return + destructuring
    let (x, y) = split()

    // Struct destructuring
    let p = Point { x: 7, y: 8 }
    let Point { px, py } = p

    // Nested patterns
    let nested = ((100, 200), 300)
    let ((u, v), w) = nested

    return 0
}
```

Tuples are a normal value type, so they can be nested, returned from functions,
and destructured with `let`/`const`. The positional accessors are `_0`, `_1`,
`_2`, etc. Tuple arity is currently limited to 2..8.

## Result<T, E> and the `?` Operator

`Result<T, E>` (in `prelude.llpl`, alongside `Optional<T>`) is a generic
"value or error" box - built the same way as `Optional<T>`, a plain class
with `set_ok`/`set_err`/`is_ok`/`is_err`/`get_ok`/`get_err`, since a
generic tagged enum can't infer both `T` and `E` from either variant's
constructor alone (see its doc comment in `prelude.llpl`).

`expr?` unwraps an `Optional<T>`/`Result<T, E>` inline: it evaluates to
the wrapped value on Some/Ok, or returns early out of the *enclosing*
function with an equivalent None/Err otherwise - the enclosing function
must itself return a compatible Optional/Result. See
`test/struct_literals_result_demo.llpl` for the full runnable version this
is taken from:

```swift
func safe_div(a: int, b: int) -> Result<int, char*> {
    let r: Result<int, char*> = new Result<int, char*>()
    if b == 0 {
        r.set_err("division by zero")
        return r
    }
    r.set_ok(a / b)
    return r
}

// If either division fails, this returns early with that same failure,
// never reaching the addition.
func sum_of_divisions(a: int, b: int, c: int, d: int) -> Result<int, char*> {
    let first: int = safe_div(a, b)?
    let second: int = safe_div(c, d)?
    let result: Result<int, char*> = new Result<int, char*>()
    result.set_ok(first + second)
    return result
}
```

Each `?` propagation step records the call-site `file:line` in the returned
`Result`'s `trace` field. If the error travels through several functions the
trace is chained (`a.llpl:5 -> b.llpl:12`). Use `get_trace()` to read it:

```swift
func main() -> int {
    let r: Result<int, char*> = sum_of_divisions(10, 0, 20, 4)
    if r.is_err() {
        let trace: char* = r.get_trace()
        if trace != null {
            // trace might be "examples.llpl:14 -> examples.llpl:21"
        }
    }
    return 0
}
```

## throw/try/catch/finally

`throw value`, `try { ... } catch (e: T) { ... } finally { ... }`, and
`Result<T, E>?` use LLPL's SJLJ exception runtime. The compiler emits an
explicit handler stack and an x86_64 register save/restore jump buffer, so
`throw` can cross LLPL function boundaries on hosted and bare-metal targets
without libc or platform unwind tables.

Cross-function throws need an explicit catch type, such as `catch (e: int)`.
Local `throw`/`?` paths can still infer the type when no annotation is
present. See `test/throw_try_demo.llpl` and `test/try_catch_demo.llpl` for
runnable examples:

```swift
func safe_div(a: int, b: int) -> Result<int, int> {
    if b == 0 {
        throw -1
    }
    let r: Result<int, int> = new Result<int, int>()
    r.set_ok(a / b)
    return r
}

func main() -> int {
    try {
        let x: int = safe_div(10, 2)?
        print_int("x", x)      // prints 5
        throw 7
    } catch (e: int) {
        print_int("caught", e) // prints 7
    } finally {
        puts("finally always runs")
    }
    return 0
}
```

`catch` and `finally` are each independently optional, but at least one of
them must be present - a bare `try { }` with neither is a parse error.
The parens around the caught variable are optional too - `catch e`,
`catch e: int`, `catch (e)`, and `catch (e: int)` all parse the same way.
`catch (e: T)` catches thrown values whose static type string matches `T`.
If the type annotation is omitted, the compiler infers the type from local
`throw` or failed `Result<T, E>?` paths in the try body. A `finally` block
runs on normal completion, after a caught error, before any `return` from
inside the try or catch block, and before a throw crosses outward through
that try.

Known limitations:
- One error type per `try` block - no catching more than one distinct error
  type in the same try.
- The SJLJ register save/restore runtime is currently implemented for
  x86_64.
- `Optional<T>`'s `None` isn't catchable via `catch` (there's no error
  *value* to bind `e` to) - a plain `?`/`is_none()` still works inside a
  `try`, it just propagates out of the enclosing function as it does
  today, unaffected by an enclosing try aimed at a different (Result)
  error.
- This unwinds through LLPL-registered frames; it cannot safely cross
  arbitrary external C callbacks that never return to LLPL-generated code.

## Panics

`llpl_panic("message")` halts the program with a message. On hosted targets it
prints to stderr and calls `abort()`. A custom handler can be installed for
logging or last-ditch cleanup:

```swift
extern func llpl_panic(msg: char*)
extern func llpl_set_panic_handler(handler: (char*) -> void)

func log_panic(msg: char*) {
    // write msg to a serial log, free global resources, etc.
}

func main() -> int {
    llpl_set_panic_handler(log_panic)
    llpl_panic("unrecoverable error")
    return 0
}
```

## Inline Assembly

GCC-style extended inline assembly is available through `asm(...)`:

```swift
func read_cr0() -> uint {
    let value: uint = 0
    asm("mov %%cr0, %0" : "=r"(value))
    return value
}

func atomic_inc(p: int*) -> int {
    let one: int = 1
    let old: int = 0
    asm("lock; xaddq %0, %1"
        : "=r"(old), "+m"(*p)
        : "0"(one)
        : "cc", "memory")
    return old
}
```

Syntax: `asm("template" : outputs : inputs : clobbers)`. Outputs and inputs
are comma-separated `"constraint"(expression)` pairs. Multiple consecutive
string literals are concatenated into one template, so multi-line assembly is
straightforward. See `generateAsm` in `source/codegen.d` for the exact mapping
to GCC extended asm.

## Macros

### Quote and Unquote

```swift
macro assignTwice(target, value) {
    quote {
        unquote(target) = unquote(value)
        unquote(target) = unquote(target) + 1
    }
}

macro twice(value) {
    quote(unquote(value) + unquote(value))
}

func main() -> int {
    let x: int = 0
    assignTwice!(x, 20)
    return twice!(x)
}
```

`quote { ... }` expands to statements. `quote(expr)` expands to an expression.
Identifiers inside `quote` are copied literally; use `unquote(arg)` where a
macro argument should be spliced into the generated syntax.

## Bitwise Operations

### Flag Management

```swift
let FLAG_READ: uint = 1
let FLAG_WRITE: uint = 2
let FLAG_EXECUTE: uint = 4

func has_flag(flags: uint, flag: uint) -> bool {
    return (flags & flag) != 0 as bool
}

func set_flag(flags: uint, flag: uint) -> uint {
    return flags | flag
}

func clear_flag(flags: uint, flag: uint) -> uint {
    return flags & ~flag
}

func main() -> int {
    let permissions: uint = 0

    // Set read and write
    permissions = set_flag(permissions, FLAG_READ)
    permissions = set_flag(permissions, FLAG_WRITE)

    // Check if executable
    if has_flag(permissions, FLAG_EXECUTE) {
        // Not executed
    }

    return 0
}
```

### Bit Manipulation

```swift
func is_power_of_two(n: uint) -> bool {
    return n != 0 && (n & (n - 1)) == 0 as bool
}

func count_bits(n: uint) -> int {
    let count: int = 0
    while n != 0 {
        count = count + 1
        n = n & (n - 1)
    }
    return count
}

func reverse_bits(n: uint) -> uint {
    let result: uint = 0
    for let i: int = 0, i < 64, i = i + 1 {
        result = result << 1
        result = result | (n & 1)
        n = n >> 1
    }
    return result
}
```

## Defer Statement

### Resource Management

```swift
extern func open_file(path: char*) -> int
extern func close_file(fd: int)
extern func read_file(fd: int, buf: char*, size: int) -> int

func process_file(path: char*) -> int {
    let fd: int = open_file(path)

    if fd < 0 {
        return -1
    }

    defer close_file(fd)

    let buffer: char[1024]
    let bytes: int = read_file(fd, buffer as char*, 1024)

    // File automatically closed when function returns
    return bytes
}
```

### Multiple Defers

```swift
func complex_operation() {
    let resource1: Resource = new Resource()
    defer resource1.cleanup()

    let resource2: Resource = new Resource()
    defer resource2.cleanup()

    let resource3: Resource = new Resource()
    defer resource3.cleanup()

    // All resources cleaned up in reverse order
    // resource3, resource2, resource1
}
```

## Hardware Programming

### Port I/O

```swift
extern func outb(port: uint, value: char)
extern func inb(port: uint) -> char

let COM1: uint = 1016

func serial_init() {
    outb(COM1 + 1, 0)
    outb(COM1 + 3, 128)
    outb(COM1 + 0, 3)
    outb(COM1 + 1, 0)
    outb(COM1 + 3, 3)
    outb(COM1 + 2, 199)
    outb(COM1 + 4, 11)
}

func serial_write(c: char) {
    while (inb(COM1 + 5) & 32) == 0 {
        // Wait for ready
    }
    outb(COM1, c)
}
```

### Memory-Mapped I/O

```swift
let VGA_BUFFER: uint = 753664  // 0xB8000

func vga_put_char(x: int, y: int, c: char, color: char) {
    let buffer: char* = VGA_BUFFER as char*
    let index: int = ((y * 80) + x) * 2
    buffer[index] = c
    buffer[index + 1] = color
}

func vga_clear_screen() {
    let buffer: char* = VGA_BUFFER as char*
    for let i: int = 0, i < 80 * 25 * 2, i = i + 2 {
        buffer[i] = 0
        buffer[i + 1] = 15
    }
}
```

### PIC (Programmable Interrupt Controller)

```swift
let PIC1_COMMAND: uint = 32
let PIC1_DATA: uint = 33
let PIC2_COMMAND: uint = 160
let PIC2_DATA: uint = 161

func pic_remap(offset1: char, offset2: char) {
    // Save masks
    let mask1: char = inb(PIC1_DATA)
    let mask2: char = inb(PIC2_DATA)

    // Start initialization
    outb(PIC1_COMMAND, 17)
    outb(PIC2_COMMAND, 17)

    // Set offsets
    outb(PIC1_DATA, offset1)
    outb(PIC2_DATA, offset2)

    // Configure cascading
    outb(PIC1_DATA, 4)
    outb(PIC2_DATA, 2)

    // Set 8086 mode
    outb(PIC1_DATA, 1)
    outb(PIC2_DATA, 1)

    // Restore masks
    outb(PIC1_DATA, mask1)
    outb(PIC2_DATA, mask2)
}
```

### Persistent Filesystem (`examples/baremetal_demo`)

`examples/baremetal_demo` builds on the port-I/O basics above with a real
disk driver and a small filesystem on top of it:

- `ata.llpl` (`namespace ATA`) - a primary-master ATA PIO disk driver
  (28-bit LBA, polling, no IRQs/DMA), targeting QEMU's IDE controller
  (`-drive file=disk.img,format=raw,if=ide`).
- `vfs.llpl` (`namespace VFS`) - a small persistent filesystem on top of
  it: directories, files, path resolution (absolute/relative/`..`), and a
  fixed-size inode table + free-block bitmap loaded into RAM at boot via
  `KHeap.kmalloc` (the kernel's real reclaiming heap) and flushed back to
  disk on every mutation. Self-formats an unrecognized disk on first boot.
- New shell commands: `ls`, `cd`, `pwd`, `mkdir`, `touch`, `cat`, `write`,
  `rm`.

Since there's no way to script keyboard input into headless QEMU,
`VFS.selftest()` (called once at boot, before the interactive shell
starts) exercises every operation end to end and logs a single
`SELFTEST: PASS`/`FAIL` line - and checks for a `/selftest/proof.txt` a
*previous* boot would have left behind before recreating it, logging
`PERSISTENCE: PASS`/`SKIP`. `make test-persistence` in that directory
automates the actual two-boot proof (fresh disk, then the same disk
image again) via serial-log capture, with no human ever needing to type
into the shell.

Alongside it, `tmpfs.llpl` (`namespace TmpFS`) exposes whatever files
GRUB loaded as multiboot2 *modules* (grub.cfg's `module2 /path/to/file
NAME` directive - the Makefile's `$(ISO)` target adds two demo ones) as a
small read-only, purely in-memory filesystem: unlike `VFS`, there's no
disk I/O or allocation at all - a module's bytes are already sitting in
ordinary (identity-mapped) RAM the moment the kernel starts, so reading
one is just a memory copy out of the address multiboot2's modules tag
hands back. Gone on the next reboot, same as a real tmpfs - there's
nothing to persist.

`VFS` mounts it at `/boot` through **real mount-point dispatch**, not a
shell-level string check: `VFS.resolve(path) -> Node` (a tagged enum -
`Disk(idx)`, `TmpfsRoot`, `TmpfsFile(idx)`, or `NotFound`) is the one
path-resolution entry point every command (`ls`/`cd`/`cat`/`pwd`) matches
on, and `cwd` itself is a `Node` - so `cd /boot` genuinely moves into the
mount, and *relative* references from there (no `/boot/` prefix needed)
resolve correctly until `cd ..` returns to the disk root. `ls` at the disk
root also lists `boot` itself (synthesized - it isn't a real on-disk
entry, see `cmd_ls`), and typing exactly that name resolves the same way
`/boot` does, so it's actually discoverable rather than something you'd
only find by already knowing to look for it:

```
llpl $ ls
d -   selftest
d -   boot
llpl $ cd boot
llpl $ pwd
/boot
llpl $ ls
m 25  hello.txt
m 116 readme.txt
llpl $ cat hello.txt
Hello from a GRUB module!
llpl $ cd ..
llpl $ pwd
/
```

`VFS.selftest()` (boot-time, no keyboard needed) exercises this
dispatch directly - resolving `/boot` and `boot`, resolving a module
through it, and a full `cd boot` / `cd ..` round trip - alongside
`TmpFS.selftest()` checking the demo modules themselves are found and
readable.

### Per-Process Virtual Memory and Ring-3 User Tasks (`examples/baremetal_demo`)

The demo kernel now has a real per-process virtual-memory manager:

- `vmm.llpl` (`namespace VMM`) walks and allocates x86-64 page tables.
  Each user task gets its own `AddressSpace` (a fresh PML4) that keeps
  the kernel's low identity mapping while isolating user mappings above
  4GB.
- `syscall.llpl` (`namespace Syscall`) implements an `int 0x80` ABI:
  `RAX` = syscall number, `RDI`/`RSI`/`RDX` = arguments, return in `RAX`.
  Supported syscalls: `SYS_EXIT` (0), `SYS_PRINT` (1), `SYS_MMAP` (2).
- `task.llpl` gained `Task.spawn_user()` and per-task page-table switching
  (`CR3` and `TSS.RSP0` are updated on every context switch). Kernel tasks
  continue to run in ring 0; user tasks run in ring 3.
- `gdt.llpl` installs ring-3 code/data descriptors and a 64-bit TSS.
- A tiny user test program in `userapp/userapp.asm` is loaded as a GRUB
  multiboot2 module and mapped into the user address space. It exercises
  `SYS_MMAP`, copies a string into the freshly mapped page, prints it via
  `SYS_PRINT`, and exits with `SYS_EXIT`:

```nasm
bits 64
_start:
    mov rax, 2          ; SYS_MMAP
    xor rdi, rdi        ; hint = 0
    mov rsi, 1          ; pages = 1
    xor rdx, rdx        ; flags = 0
    int 0x80

    mov r8, rax         ; save buffer
    mov rdi, rax
    lea rsi, [rel msg]
    mov rcx, msg_len
    rep movsb

    mov rax, 1          ; SYS_PRINT
    mov rdi, r8
    mov rsi, msg_len
    int 0x80

    mov rax, 0          ; SYS_EXIT
    int 0x80

section .data
msg: db "Hello from user-space mmap!", 10
msg_len: equ $ - msg
```

Boot output now includes the user task's message after the shell prompt:

```
user task spawned (entry=0x100000000)
Starting the shell. Type 'help' for a list of commands.
llpl $ Hello from user-space mmap!
```

## Slice<T>

A bounds-checked *view* into memory someone else owns - `{ptr, len}`, a
plain value type (like `Pair<A, B>`, not an owning container: no
constructor/destructor, nothing to allocate or free). Replaces a raw `T*`
passed around together with a separately-tracked count - nothing stops
those two from drifting out of sync, or an index from running off the
end - with one value `slice_get`/`slice_set` actually validate before
touching memory:

```swift
func sum(s: Slice<int>) -> int {
    let total: int = 0
    let i: uint = 0
    while i < s.len {
        total = total + slice_get(s, i)
        i = i + 1
    }
    return total
}

func main() -> int {
    let arr: int[5]
    arr[0] = 10
    arr[1] = 20
    let view: Slice<int> = Slice { ptr: arr as int*, len: 2 }
    return sum(view) // 30
}
```

Out-of-bounds `slice_get`/`slice_set` calls `llpl_panic` (prelude.llpl)
rather than reading/writing past `len` - see [Panics](#panics) below for
what that does on each target. `Vector<T>.get()`/`.set()` are bounds-checked
the same way now, and `Vector<T>.as_slice()` returns a `Slice<T>` view of
exactly its live elements (valid only until the next reallocating `push`),
so a function like `sum` above works on a fixed array, a `Vector<T>`, or
any other buffer without needing to know which. See `test/slice_demo.llpl`
for the full runnable version this is taken from.

## Regular Expressions

A regex literal is `/pattern/` (`Regex`, in `prelude.llpl`). `match()`
tests whether a pattern matches anywhere in a string; `captures()` runs it
once and returns a `RegexMatch` for inspecting capture groups:

```swift
let r = /([a-z]+)-([0-9]+)/
let m = r.captures("id-42!")
m.is_match()      // true
m.group(0)        // "id-42" (the whole match) - a String
m.group(1)        // "id"
m.group(2)        // "42"
m.group_start(2)  // byte offset of group 2's start in the original text
m.group_end(2)
m.has_group(3)    // false - this pattern only has 2 groups
```

### Iterating Every Match

`find_all(text)` returns a `RegexMatchIterator` implementing the
`foreach` iterator protocol, so it works directly in a `foreach` loop -
each yielded `RegexMatch`'s `group_start`/`group_end` are positions into
the *original* text, even though finding "the next match" internally means
re-searching a suffix of it. See `test/regex_replace_demo.llpl` for the
full runnable version this is taken from:

```swift
func main() -> int {
    let digits = /[0-9]+/
    let text: char* = "abc 123 def 4567 ghi"

    foreach let m in digits.find_all(text) {
        puts(m.group(0).c_str())  // "123", then "4567"
    }
    return 0
}
```

### Replacement

`replace()` substitutes just the first match; `replace_all()` substitutes
every non-overlapping one. Both return a `String`, and both accept
`$0`/`$1`/... backreferences in the replacement text (`$0` is the whole
match; `$$` is a literal `$`):

```swift
func main() -> int {
    let digits = /[0-9]+/
    let text: char* = "abc 123 def 4567 ghi"
    digits.replace(text, "#")      // "abc # def 4567 ghi"
    digits.replace_all(text, "#")  // "abc # def # ghi"

    let pair = /([a-z]+)-([0-9]+)/
    pair.replace("id-42!", "$2:$1")  // "42:id!"
    return 0
}
```

## Data Structures

### Stack

A real, complete `Stack` - unlike a raw `int*`, `self.data`'s bounds are
checked on every push/pop:

```swift
class Stack {
    let data: Slice<int>
    let backing: int*
    let capacity: int
    let top: int

    constructor(cap: int) {
        self.capacity = cap
        self.top = 0
        self.backing = llpl_alloc((cap as uint) * sizeof(int)) as int*
        self.data = Slice { ptr: self.backing, len: cap as uint }
    }

    destructor() {
        llpl_free(self.backing as char*)
    }

    func push(value: int) -> bool {
        if self.top >= self.capacity {
            return false
        }
        slice_set(self.data, self.top as uint, value)
        self.top = self.top + 1
        return true
    }

    func pop() -> int {
        if self.top == 0 {
            return -1
        }
        self.top = self.top - 1
        return slice_get(self.data, self.top as uint)
    }

    func is_empty() -> bool {
        return self.top == 0
    }
}
```

### Ring Buffer

```swift
class RingBuffer {
    let data: Slice<char>
    let backing: char*
    let size: int
    let read_pos: int
    let write_pos: int

    constructor(size: int) {
        self.size = size
        self.read_pos = 0
        self.write_pos = 0
        self.backing = llpl_alloc(size as uint) as char*
        self.data = Slice { ptr: self.backing, len: size as uint }
    }

    destructor() {
        llpl_free(self.backing as char*)
    }

    func write(value: char) -> bool {
        let next: int = (self.write_pos + 1) % self.size

        if next == self.read_pos {
            return false // Buffer full
        }

        slice_set(self.data, self.write_pos as uint, value)
        self.write_pos = next
        return true
    }

    func read() -> int {
        if self.read_pos == self.write_pos {
            return -1 // Buffer empty
        }

        let value: char = slice_get(self.data, self.read_pos as uint)
        self.read_pos = (self.read_pos + 1) % self.size
        return value as int
    }

    func available() -> int {
        if self.write_pos >= self.read_pos {
            return self.write_pos - self.read_pos
        } else {
            return self.size - self.read_pos + self.write_pos
        }
    }
}
```

## Tips and Tricks

### Type Casting

```swift
// Cast integer to pointer
let addr: uint = 4096
let ptr: char* = addr as char*

// Cast pointer to integer
let ptr_val: uint = ptr as uint

// Cast between pointer types
let void_ptr: void* = ptr as void*
let int_ptr: int* = void_ptr as int*
```

### Hex and Binary Masks

```swift
// Hexadecimal
let hex_value: uint = 0xDEADBEEF
let port_addr: uint = 0x3F8

// Bit masks
let mask: uint = 0xFF
let masked: uint = hex_value & mask

// Bit shifts for multiplication/division
let doubled: uint = hex_value << 1
let halved: uint = hex_value >> 1
```

### Conditional Assignments

```swift
func get_min(a: int, b: int) -> int {
    let result: int = a
    if b < a {
        result = b
    }
    return result
}
```

---

For more examples, see:
- `examples/kernel.llpl` - Full bare metal kernel
- `test/simple.llpl` - Simple test program
- README.md - Full language documentation
