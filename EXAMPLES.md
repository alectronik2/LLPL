# LLPL Code Examples

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

## Data Structures

### Stack

```swift
class Stack {
    let data: int*
    let capacity: int
    let top: int

    constructor(cap: int) {
        self.capacity = cap
        self.top = 0
        // In real code, allocate data array
    }

    destructor() {
        // Free data array
    }

    func push(value: int) -> bool {
        if self.top >= self.capacity {
            return false as bool
        }
        self.data[self.top] = value
        self.top = self.top + 1
        return true as bool
    }

    func pop() -> int {
        if self.top == 0 {
            return -1
        }
        self.top = self.top - 1
        return self.data[self.top]
    }

    func is_empty() -> bool {
        return self.top == 0 as bool
    }
}
```

### Ring Buffer

```swift
class RingBuffer {
    let buffer: char*
    let size: int
    let read_pos: int
    let write_pos: int

    constructor(size: int) {
        self.size = size
        self.read_pos = 0
        self.write_pos = 0
        // Allocate buffer
    }

    destructor() {
        // Free buffer
    }

    func write(data: char) -> bool {
        let next: int = (self.write_pos + 1) % self.size

        if next == self.read_pos {
            return false as bool  // Buffer full
        }

        self.buffer[self.write_pos] = data
        self.write_pos = next
        return true as bool
    }

    func read() -> int {
        if self.read_pos == self.write_pos {
            return -1  // Buffer empty
        }

        let data: char = self.buffer[self.read_pos]
        self.read_pos = (self.read_pos + 1) % self.size
        return data as int
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
