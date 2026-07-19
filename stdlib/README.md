# LLPL Standard Library

A comprehensive standard library for LLPL featuring file I/O, network I/O, and advanced string manipulation utilities with modern features like namespaces and classes.

## Features

- **File I/O**: RAII-based file handling with automatic resource cleanup
- **Network I/O**: High-level TCP/UDP socket APIs with error handling
- **String Utilities**: Advanced text processing, formatting, and manipulation
- **Data Structures**: Comprehensive collection of efficient data structures (linked lists, trees, heaps, hash maps, graphs, tries)
- **SDL3 Bindings**: Complete graphics, audio, and input handling with high-level wrappers
- **Command-line Arguments**: `--name value`/`-n value` flags, positional arguments, `func main(args: string[])` support
- **YAML Parsing**: Block/flow mappings and sequences, typed scalars
- **JSON Parsing**: RFC 8259 parser and serializer, typed values
- **Namespace Organization**: Clean separation of concerns with `std::io`, `std::net`, `std::text`, `std::collections`, `std::sdl`, `std::args`, `std::yaml`, `std::json`
- **Error Handling**: Comprehensive use of `Result<T, E>` types for safe error propagation
- **Modern OOP**: Classes with constructors, destructors, and static methods

## Table of Contents

- [Installation](#installation)
- [File I/O](#file-io)
- [Network I/O](#network-io)
- [String Utilities](#string-utilities)
- [Data Structures](#data-structures)
- [SDL3 Graphics & Audio](#sdl3-graphics--audio)
- [Command-line Arguments](#command-line-arguments)
- [YAML Parsing](#yaml-parsing)
- [JSON Parsing](#json-parsing)
- [API Reference](#api-reference)

## Installation

Import the entire standard library:

```swift
import "stdlib/stdlib.llpl"
```

Or import specific modules:

```swift
import "stdlib/io/file.llpl"
import "stdlib/net/socket.llpl"
import "stdlib/text/string_utils.llpl"
```

## File I/O

### Quick Start

```swift
// Read entire file
let content: Result<String, char*> = std::io::read_file("test.txt")
if content.is_ok() {
    let text: String = content.unwrap()
    // Process text...
}

// Write file
std::io::write_file("output.txt", new String("Hello, World!"))

// Append to file
std::io::append_file("log.txt", new String("New log entry\n"))
```

### File Class

The `File` class provides RAII-based file handling with automatic cleanup:

```swift
let f: std::File = new std::File("data.txt", std::io::O_RDWR | std::io::O_CREAT)

if f.is_valid() {
    // Write data
    f.write_string(new String("Line 1\n"))
    f.write_bytes("binary data", 11)

    // Seek to beginning
    f.seek(0, std::io::SEEK_SET)

    // Read data
    let result: Result<String, char*> = f.read_string(100)
    if result.is_ok() {
        let data: String = result.unwrap()
    }

    // Get file size
    let size_result: Result<int, char*> = f.size()
    if size_result.is_ok() {
        let file_size: int = size_result.unwrap()
    }
}
// File automatically closed when f goes out of scope
```

### File Operations

```swift
// Check if file exists
if std::io::file_exists("config.json") {
    // File exists
}

// Delete file
std::io::delete_file("temp.txt")

// Rename file
std::io::rename_file("old.txt", "new.txt")
```

### Constants

```swift
// Open modes
std::io::O_RDONLY   // Read-only
std::io::O_WRONLY   // Write-only
std::io::O_RDWR     // Read-write
std::io::O_CREAT    // Create if not exists
std::io::O_TRUNC    // Truncate to zero length
std::io::O_APPEND   // Append mode

// Seek positions
std::io::SEEK_SET   // Beginning of file
std::io::SEEK_CUR   // Current position
std::io::SEEK_END   // End of file
```

## Network I/O

### TCP Server

```swift
let server: std::TcpServer = new std::TcpServer(8080)
let start_result: Result<bool, char*> = server.start(10)  // backlog of 10

if start_result.is_ok() {
    for true {  // infinite loop
        let client_result: Result<std::Socket, char*> = server.accept()

        if client_result.is_ok() {
            let client: std::Socket = client_result.unwrap()
            let recv_result: Result<String, char*> = client.recv_string(1024)

            if recv_result.is_ok() {
                let message: String = recv_result.unwrap()
                // Echo back to client
                client.send_string(new String("Echo: ") + message)
            }
        }
    }
}
```

### TCP Client

```swift
let client: std::TcpClient = new std::TcpClient()

// Connect to 127.0.0.1:8080
let connect_result: Result<bool, char*> = client.connect(127, 0, 0, 1, 8080)

if connect_result.is_ok() {
    // Send data
    client.send(new String("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))

    // Receive response
    let response: Result<String, char*> = client.recv(4096)
    if response.is_ok() {
        let data: String = response.unwrap()
        // Process response...
    }

    client.close()
}
```

### UDP Socket

```swift
let udp: std::UdpSocket = new std::UdpSocket(9000)

if udp.bind_socket().is_ok() {
    // Receive data
    let buffer: char[1024]
    let recv_result: Result<int, char*> = udp.recv_from(buffer, 1024)

    if recv_result.is_ok() {
        let bytes_recv: int = recv_result.unwrap()
        // Process data...

        // Send response
        let dest_addr: std::SockAddrIn = new std::SockAddrIn()
        dest_addr.set_port(9001)
        dest_addr.set_addr(192, 168, 1, 100)
        udp.send_to("response", 8, dest_addr)
    }
}
```

### Low-Level Socket API

```swift
let sock: std::Socket = new std::Socket(
    std::net::AF_INET,
    std::net::SOCK_STREAM,
    std::net::IPPROTO_TCP
)

// Set socket options
sock.set_reuse_addr(true)

// Bind to address
let addr: std::SockAddrIn = new std::SockAddrIn()
addr.set_port(3000)
addr.set_addr_any()
sock.bind_addr(addr)

// Listen for connections
sock.listen_backlog(5)

// Accept connection
let client_result: Result<std::Socket, char*> = sock.accept_connection()
```

## String Utilities

### String Manipulation

```swift
let s: String = new String("  Hello, World!  ")

// Trimming
let trimmed: String = std::StringUtils::trim(s)              // "Hello, World!"
let left: String = std::StringUtils::trim_start(s)          // "Hello, World!  "
let right: String = std::StringUtils::trim_end(s)           // "  Hello, World!"

// Case conversion
let upper: String = std::StringUtils::to_upper(s)           // "  HELLO, WORLD!  "
let lower: String = std::StringUtils::to_lower(s)           // "  hello, world!  "

// Splitting
let parts: Vector<String> = std::StringUtils::split(trimmed, ',')
// ["Hello", " World!"]

let words: Vector<String> = std::StringUtils::split_str(
    new String("one::two::three"),
    new String("::")
)
// ["one", "two", "three"]

// Joining
let joined: String = std::StringUtils::join(parts, new String(" | "))
// "Hello |  World!"
```

### String Searching

```swift
let text: String = new String("The quick brown fox jumps over the lazy dog")

// Check containment
let has_fox: bool = std::StringUtils::contains(text, new String("fox"))  // true

// Find index
let idx: int = std::StringUtils::index_of(text, new String("fox"))       // 16
let last: int = std::StringUtils::last_index_of(text, new String("the")) // 31

// Check prefix/suffix
let starts: bool = std::StringUtils::starts_with(text, new String("The")) // true
let ends: bool = std::StringUtils::ends_with(text, new String("dog"))     // true
```

### String Replacement

```swift
let s: String = new String("foo bar foo baz")

// Replace all occurrences
let replaced: String = std::StringUtils::replace_all(s, new String("foo"), new String("qux"))
// "qux bar qux baz"

// Replace first occurrence
let first: String = std::StringUtils::replace_first(s, new String("foo"), new String("qux"))
// "qux bar foo baz"
```

### String Padding and Formatting

```swift
let num: String = new String("42")

// Padding
let padded: String = std::StringUtils::pad_left(num, 5, '0')   // "00042"
let right: String = std::StringUtils::pad_right(num, 5, ' ')   // "42   "

// Repetition
let repeated: String = std::StringUtils::repeat(new String("Ha"), 3)  // "HaHaHa"

// Reversal
let reversed: String = std::StringUtils::reverse(new String("LLPL"))  // "LPPL"
```

### StringBuilder

For efficient string concatenation:

```swift
let sb: std::StringBuilder = new std::StringBuilder()

sb.append(new String("Name: "))
sb.append(new String("Alice"))
sb.append_char('\n')

sb.append(new String("Age: "))
sb.append_int(30)
sb.append_char('\n')

let result: String = sb.to_string()
// "Name: Alice\nAge: 30\n"

// Clear and reuse
sb.clear()
sb.append(new String("New content"))
```

### String Formatting

```swift
let args: Vector<String> = new Vector<String>()
args.push(new String("Alice"))
args.push(new String("Engineer"))
args.push(new String("42"))

let formatted: String = std::Format::format(
    new String("Name: {}, Role: {}, ID: {}"),
    args
)
// "Name: Alice, Role: Engineer, ID: 42"
```

### Character Utilities

```swift
let c: char = 'A'

// Character classification
std::CharUtils::is_alpha(c)         // true
std::CharUtils::is_digit('5')       // true
std::CharUtils::is_alphanumeric(c)  // true
std::CharUtils::is_whitespace(' ')  // true
std::CharUtils::is_upper(c)         // true
std::CharUtils::is_lower('a')       // true

// Character conversion
let lower: char = std::CharUtils::to_lower(c)  // 'a'
let upper: char = std::CharUtils::to_upper('b') // 'B'
```

## API Reference

### std::io::File

| Method | Signature | Description |
|--------|-----------|-------------|
| `constructor` | `(path: char*, flags: int)` | Open file with flags |
| `constructor` | `(path: char*, flags: int, mode: int)` | Open with explicit mode |
| `is_valid` | `() -> bool` | Check if file opened successfully |
| `read_bytes` | `(buffer: char*, size: uint) -> Result<int, char*>` | Read raw bytes |
| `write_bytes` | `(buffer: char*, size: uint) -> Result<int, char*>` | Write raw bytes |
| `read_string` | `(max_size: uint) -> Result<String, char*>` | Read as string |
| `write_string` | `(s: String) -> Result<int, char*>` | Write string |
| `seek` | `(offset: int, whence: int) -> Result<int, char*>` | Seek to position |
| `tell` | `() -> Result<int, char*>` | Get current position |
| `size` | `() -> Result<int, char*>` | Get file size |
| `read_all` | `() -> Result<String, char*>` | Read entire file |

### std::net::TcpServer

| Method | Signature | Description |
|--------|-----------|-------------|
| `constructor` | `(port: uint16)` | Create server on port |
| `start` | `(backlog: int) -> Result<bool, char*>` | Bind and listen |
| `accept` | `() -> Result<Socket, char*>` | Accept connection |
| `is_valid` | `() -> bool` | Check if valid |

### std::net::TcpClient

| Method | Signature | Description |
|--------|-----------|-------------|
| `constructor` | `()` | Create client |
| `connect` | `(a: uint8, b: uint8, c: uint8, d: uint8, port: uint16) -> Result<bool, char*>` | Connect to IP |
| `send` | `(data: String) -> Result<int, char*>` | Send data |
| `recv` | `(max_size: uint) -> Result<String, char*>` | Receive data |
| `close` | `()` | Close connection |

### std::net::Socket

| Method | Signature | Description |
|--------|-----------|-------------|
| `constructor` | `(domain: int, type: int, protocol: int)` | Create socket |
| `bind_addr` | `(addr: SockAddrIn) -> Result<bool, char*>` | Bind to address |
| `listen_backlog` | `(backlog: int) -> Result<bool, char*>` | Listen for connections |
| `accept_connection` | `() -> Result<Socket, char*>` | Accept connection |
| `connect_to` | `(addr: SockAddrIn) -> Result<bool, char*>` | Connect to address |
| `send_data` | `(buffer: char*, size: uint) -> Result<int, char*>` | Send raw data |
| `recv_data` | `(buffer: char*, size: uint) -> Result<int, char*>` | Receive raw data |
| `send_string` | `(s: String) -> Result<int, char*>` | Send string |
| `recv_string` | `(max_size: uint) -> Result<String, char*>` | Receive string |
| `set_reuse_addr` | `(enable: bool) -> Result<bool, char*>` | Set SO_REUSEADDR |
| `shutdown_socket` | `(how: int) -> Result<bool, char*>` | Shutdown socket |

### std::text::StringUtils

All methods are static:

| Method | Signature | Description |
|--------|-----------|-------------|
| `split` | `(s: String, delimiter: char) -> Vector<String>` | Split by character |
| `split_str` | `(s: String, delimiter: String) -> Vector<String>` | Split by string |
| `join` | `(strings: Vector<String>, delimiter: String) -> String` | Join strings |
| `trim` | `(s: String) -> String` | Trim both ends |
| `trim_start` | `(s: String) -> String` | Trim left |
| `trim_end` | `(s: String) -> String` | Trim right |
| `to_upper` | `(s: String) -> String` | Convert to uppercase |
| `to_lower` | `(s: String) -> String` | Convert to lowercase |
| `starts_with` | `(s: String, prefix: String) -> bool` | Check prefix |
| `ends_with` | `(s: String, suffix: String) -> bool` | Check suffix |
| `contains` | `(s: String, substr: String) -> bool` | Check substring |
| `index_of` | `(s: String, substr: String) -> int` | Find first occurrence |
| `last_index_of` | `(s: String, substr: String) -> int` | Find last occurrence |
| `replace_all` | `(s: String, old: String, new: String) -> String` | Replace all |
| `replace_first` | `(s: String, old: String, new: String) -> String` | Replace first |
| `pad_left` | `(s: String, length: int, pad_char: char) -> String` | Left padding |
| `pad_right` | `(s: String, length: int, pad_char: char) -> String` | Right padding |
| `reverse` | `(s: String) -> String` | Reverse string |
| `repeat` | `(s: String, times: int) -> String` | Repeat string |
| `is_whitespace` | `(s: String) -> bool` | Check if whitespace |

### std::text::StringBuilder

| Method | Signature | Description |
|--------|-----------|-------------|
| `constructor` | `()` | Create builder |
| `append` | `(s: String)` | Append string |
| `append_char` | `(c: char)` | Append character |
| `append_int` | `(value: int)` | Append integer |
| `to_string` | `() -> String` | Build final string |
| `clear` | `()` | Clear contents |
| `length` | `() -> int` | Get total length |

## Data Structures

The collections module provides a comprehensive set of efficient data structures. See [`collections/README.md`](collections/README.md) for detailed documentation.

### Quick Overview

```swift
import "stdlib/collections/collections.llpl"

// Linked Lists
let list: std::LinkedList<int> = new std::LinkedList<int>()
let dlist: std::DoublyLinkedList<String> = new std::DoublyLinkedList<String>()

// Stack, Queue, Deque
let stack: std::Stack<int> = new std::Stack<int>()
let queue: std::Queue<String> = new std::Queue<String>()
let deque: std::Deque<int> = new std::Deque<int>()
let buffer: std::CircularBuffer<int> = new std::CircularBuffer<int>(10)

// Trees
let rbtree: std::RBTree<int, String> = new std::RBTree<int, String>()
rbtree.insert(10, new String("value"))
let result: Result<String, char*> = rbtree.find(10)

// Heaps
let min_heap: std::BinaryHeap<int> = new std::BinaryHeap<int>()
let max_heap: std::MaxHeap<int> = new std::MaxHeap<int>()
let pq: std::PriorityQueue<String> = new std::PriorityQueue<String>()

// Hash-based
let map: std::EnhancedHashMap<String, int> = new std::EnhancedHashMap<String, int>()
let set: std::HashSet<int> = new std::HashSet<int>()

// Trie (Prefix Tree)
let trie: std::Trie = new std::Trie()
trie.insert("hello")
let words: Vector<String> = trie.get_words_with_prefix("hel")

// Graphs
let graph: std::Graph = new std::Graph(10, false)  // 10 vertices, undirected
graph.add_edge(0, 1, 5)  // edge with weight 5
let bfs_order: Vector<int> = graph.bfs(0)
```

### Available Data Structures

| Category | Data Structures |
|----------|----------------|
| **Linear** | LinkedList, DoublyLinkedList, Stack, Queue, Deque, CircularBuffer |
| **Trees** | RBTree (Red-Black Tree) |
| **Heaps** | BinaryHeap, MaxHeap, PriorityQueue |
| **Hash-based** | EnhancedHashMap, HashSet |
| **String** | Trie (Prefix Tree) |
| **Graphs** | Graph (adjacency list), GraphMatrix (adjacency matrix) |

### Performance Characteristics

| Operation | LinkedList | RBTree | HashMap | BinaryHeap | Graph (List) |
|-----------|------------|--------|---------|------------|--------------|
| Insert | O(1)* | O(log n) | O(1)† | O(log n) | O(1) |
| Search | O(n) | O(log n) | O(1)† | - | O(degree) |
| Delete | O(n) | O(log n) | O(1)† | O(log n) | O(degree) |
| Space | O(n) | O(n) | O(n) | O(n) | O(V + E) |

*At head/tail, †Average case

For complete documentation, algorithms, and examples, see:
- [`collections/README.md`](collections/README.md) - Full API documentation
- [`examples/collections/`](../examples/collections/) - Working code examples

## SDL3 Graphics & Audio

SDL3 (Simple DirectMedia Layer 3) bindings for 2D graphics, audio, and input handling. Perfect for games, simulations, and multimedia applications.

### Quick Start

```swift
import "stdlib/sdl/sdl.llpl"

func main() -> int {
    std::sdl::SDL.init(std::sdl::SDL_INIT_VIDEO)

    let window: std::sdl::Window = new std::sdl::Window(
        new String("My Game"),
        800,
        600
    )

    let renderer: std::sdl::Renderer = new std::sdl::Renderer(window)
    let events: std::sdl::EventHandler = new std::sdl::EventHandler()

    let running: bool = true
    for running {
        for events.poll() {
            if events.is_quit() {
                running = false
            }
        }

        renderer.set_draw_color(0, 0, 0, 255)
        renderer.clear()

        // Draw graphics here
        renderer.set_draw_color(255, 0, 0, 255)
        let rect: std::sdl::SDL_Rect = new std::sdl::SDL_Rect(100, 100, 200, 150)
        renderer.fill_rect(rect)

        renderer.present()
        std::sdl::SDL.delay(16)
    }

    std::sdl::SDL.quit()
    return 0
}
```

### Features

**Window & Rendering:**
- Window management (create, resize, fullscreen)
- 2D rendering (points, lines, rectangles)
- Texture loading and rendering (BMP format)
- Blend modes and transparency
- Color modulation

**Input Handling:**
- Keyboard events (key press/release)
- Continuous keyboard state
- Mouse events (button, motion, wheel)
- Mouse position and state

**Audio:**
- WAV file loading and playback
- Audio device management
- Audio streams for processing
- Multi-channel support

### Available Classes

| Class | Description |
|-------|-------------|
| `Window` | High-level window wrapper with RAII |
| `Renderer` | 2D rendering context |
| `Texture` | Texture management |
| `EventHandler` | Event polling and handling |
| `Input` | Keyboard and mouse state |
| `AudioDevice` | Audio playback device |
| `AudioStream` | Audio processing stream |
| `WavFile` | WAV file loader |
| `Colors` | Color presets |

### Common Patterns

**Animation Loop:**
```swift
let last_time: uint64 = std::sdl::SDL.get_ticks()

for running {
    let current_time: uint64 = std::sdl::SDL.get_ticks()
    let dt: float = ((current_time - last_time) as float) / 1000.0
    last_time = current_time

    // Update with delta time
    position = position + velocity * dt

    // Render
    renderer.clear()
    // Draw...
    renderer.present()
}
```

**Keyboard Input:**
```swift
let keys: uint8* = std::sdl::Input.get_keyboard_state()

if keys[std::sdl::SDLK_w as int] != 0 {
    y = y - speed * dt  // Move up
}
if keys[std::sdl::SDLK_SPACE as int] != 0 {
    // Jump
}
```

**Mouse Input:**
```swift
if events.is_mouse_button_down() {
    let mouse: std::sdl::SDL_MouseButtonEvent* = events.get_mouse_button_event()
    let x: float = (*mouse).x
    let y: float = (*mouse).y
    // Handle click at (x, y)
}
```

For complete documentation and examples, see:
- [`sdl/README.md`](sdl/README.md) - Full SDL3 API documentation
- [`examples/sdl/`](../examples/sdl/) - Complete game examples

**Note:** Requires SDL3 library installed on system. Link with `-lSDL3` when compiling.

## Command-line Arguments

`std::args::ArgParser` works with either shape of `main` this compiler
supports:

- `func main(args: string[]) -> int` - real main-specific codegen generates
  the actual C `int main(int argc, char** argv)` entry point and hands this
  function `argv + 1` (still null-terminated, the program's own path
  already excluded). The nicer of the two - reach for this one, paired
  with `parse_args()`.
- `func main(argc: i32, argv: char**) -> int` - this compiler doesn't
  special-case an *ordinary*-shaped `main` at all, so declaring it with the
  real C signature (`i32`, matching the actual 32-bit `argc` the C runtime
  passes; the language's own default `int` is 64-bit and would be a real
  ABI mismatch here) already just works. Pair it with `parse()`.

```swift
import "stdlib/args/args_parser.llpl"
using namespace std.args

func main(args: string[]) -> int {
    let parser: ArgParser = new ArgParser(new String("mytool"))
    parser.add_flag(new String("verbose"), new String("v"), new String("Enable verbose output"))
    parser.add_option_default(new String("output"), new String("o"), new String("a.out"), new String("Output file"))
    parser.add_required(new String("input"), new String("i"), new String("Input file"))

    if !parser.parse_args(args) {
        parser.print_errors()
        parser.print_help()
        return 1
    }

    let verbose: bool = parser.has_flag(new String("verbose"))
    let output: String = parser.get_value_or(new String("output"), new String("a.out"))
    let input: String = parser.get_value_or(new String("input"), new String(""))
    let rest: Vector<String> = parser.get_positional()  // non-flag arguments
    return 0
}
```

Supports `--name value`, `--name=value`, `-n value` (short form), bare
boolean flags (`--verbose`/`-v`), positional arguments, and a `--` on its
own to treat everything after it as positional even if it starts with
`-`. `parse()`/`parse_args()` return `false` if an unknown option was
seen, a value-taking option was missing its value, or a required option
(`add_required`) was never supplied - see `get_errors()`/`print_errors()`.

## YAML Parsing

`std::yaml::parse` covers a pragmatic subset of YAML 1.x, not the full
spec: block-style mappings and sequences (including a sequence of
mappings, `- key: value` continued on later, more-indented lines), flow-
style collections (`[a, b, c]`, `{k: v}`), single-/double-quoted scalars
(with backslash escapes in double-quoted ones), plain scalars auto-typed
as null/bool/int/float/string, and `#` comments. Not supported: anchors/
aliases (`&x`/`*x`), multi-line block scalars (`|`/`>`), tags (`!!foo`),
and multiple documents in one text - none of these are common in the
config-file use case this exists for.

```swift
import "stdlib/yaml/yaml_parser.llpl"
import "stdlib/io/file.llpl"
using namespace std.yaml
using namespace std.io

func main() -> int {
    let content: Result<String, char*> = read_file("config.yaml")
    if !content.is_ok() {
        return 1
    }

    let doc: YamlValue = parse(content.unwrap())

    let name: String = doc.get_or(new String("name"), YamlValue.make_string(new String("")))
        .as_string()
    let port: int = doc.get_or(new String("server"), YamlValue.make_mapping())
        .get_or(new String("port"), YamlValue.make_int(8080))
        .as_int()

    let tags: YamlValue = doc.get_or(new String("tags"), YamlValue.make_sequence())
    let i: int = 0
    while i < tags.len() {
        let tag: String = tags.get_index(i).as_string()
        i = i + 1
    }

    return 0
}
```

`YamlValue` is a manual tagged union (`is_null()`/`is_bool()`/`is_int()`/
`is_float()`/`is_string()`/`is_sequence()`/`is_mapping()`, plus the
matching `as_*()` accessors) rather than this language's real tagged-enum
feature, since a parsed document is directly self-referential (a
mapping/sequence holds more `YamlValue`s). Build values with
`YamlValue.make_null()`/`make_bool()`/`make_int()`/`make_float()`/
`make_string()`/`make_sequence()`/`make_mapping()`; read a mapping with
`get()` (returns `Optional<YamlValue>`), `get_or()` (a fallback instead of
unwrapping), or `has_key()`; read a sequence with `len()`/`get_index()`.
Parsing never fails outright - malformed input degrades to a best-effort
partial parse rather than an error.

## JSON Parsing

`std::json::parse`/`std::json::stringify` implement standards-compliant
(RFC 8259) JSON: objects, arrays, strings (backslash escapes including
`\uXXXX`), numbers (auto-typed as int or float depending on whether the
literal has a `.`/`e`/`E`), booleans, and null - in both directions,
unlike `std::yaml`, which is read-only.

```swift
import "stdlib/json/json_parser.llpl"
import "stdlib/io/file.llpl"
using namespace std.json
using namespace std.io

func main() -> int {
    let content: Result<String, char*> = read_file("config.json")
    if !content.is_ok() {
        return 1
    }

    let doc: JsonValue = parse(content.unwrap())

    let name: String = doc.get_or(new String("name"), JsonValue.make_string(new String("")))
        .as_string()
    let port: int = doc.get_or(new String("server"), JsonValue.make_object())
        .get_or(new String("port"), JsonValue.make_int(8080))
        .as_int()

    let tags: JsonValue = doc.get_or(new String("tags"), JsonValue.make_array())
    let i: int = 0
    while i < tags.len() {
        let tag: String = tags.get_index(i).as_string()
        i = i + 1
    }

    // Build a value and serialize it back to text.
    let payload: JsonValue = JsonValue.make_object()
    payload.set(new String("ok"), JsonValue.make_bool(true))
    let text: String = stringify(payload) // {"ok":true}

    return 0
}
```

`JsonValue` is a manual tagged union (`is_null()`/`is_bool()`/`is_int()`/
`is_float()`/`is_string()`/`is_array()`/`is_object()`, plus the matching
`as_*()` accessors), the same convention `YamlValue` uses and for the same
reason (a parsed document is directly self-referential). Build values with
`JsonValue.make_null()`/`make_bool()`/`make_int()`/`make_float()`/
`make_string()`/`make_array()`/`make_object()`; read an object with `get()`
(returns `Optional<JsonValue>`), `get_or()` (a fallback instead of
unwrapping), `has_key()`, or `keys()`; read an array with
`len()`/`get_index()`/`push()`; write an object's fields with `set()`.
`stringify()` serializes any `JsonValue` back to compact JSON text.

## Examples

See the example programs in the `examples/` directory:

**stdlib examples:**
- `file_example.llpl` - File I/O operations
- `tcp_server.llpl` - TCP echo server
- `tcp_client.llpl` - TCP client
- `string_demo.llpl` - String manipulation examples
- `http_server.llpl` - Full HTTP server combining all features

**collections examples:**
- `collections_demo.llpl` - Comprehensive demonstration of all data structures

**parsing examples:**
- `yaml_demo.llpl` - YAML config file round-trip and in-memory parsing
- `json_demo.llpl` - JSON config file round-trip, in-memory parsing, and serialization

**sdl examples:**
- `basic_window.llpl` - Window creation and basic rendering
- `interactive_demo.llpl` - Keyboard and mouse input handling
- `pong_game.llpl` - Complete Pong game implementation

## License

Part of the LLPL project.
