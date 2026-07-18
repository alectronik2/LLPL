# Standard Library Usage Guide

## Quick Start

### Import the Standard Library

Add this to the top of your LLPL file:

```swift
import "stdlib/stdlib.llpl"
```

### Basic File Operations

```swift
// Read a file
let content: Result<String, char*> = std::io::read_file("myfile.txt")
if content.is_ok() {
    let text: String = content.unwrap()
    // Use text...
}

// Write a file
std::io::write_file("output.txt", new String("Hello, World!"))
```

### Basic Networking

```swift
// TCP Server
let server: std::TcpServer = new std::TcpServer(8080)
server.start(10)

for true {
    let client: Result<std::Socket, char*> = server.accept()
    if client.is_ok() {
        let sock: std::Socket = client.unwrap()
        sock.send_string(new String("Hello!"))
    }
}

// TCP Client
let client: std::TcpClient = new std::TcpClient()
client.connect(127, 0, 0, 1, 8080)
client.send(new String("Hello, Server!"))
let response: Result<String, char*> = client.recv(1024)
client.close()
```

### String Utilities

```swift
// Split and join
let parts: Vector<String> = std::StringUtils::split(new String("a,b,c"), ',')
let joined: String = std::StringUtils::join(parts, new String(" | "))

// Search and replace
let text: String = new String("hello world")
let idx: int = std::StringUtils::index_of(text, new String("world"))
let replaced: String = std::StringUtils::replace_all(text, new String("world"), new String("LLPL"))

// Case conversion
let upper: String = std::StringUtils::to_upper(text)
let lower: String = std::StringUtils::to_lower(upper)

// String builder
let sb: std::StringBuilder = new std::StringBuilder()
sb.append(new String("Count: "))
sb.append_int(42)
let result: String = sb.to_string()
```

## Compilation

Compile your LLPL program with the standard library:

```bash
# Compile LLPL to C
./llpl your_program.llpl -o your_program.c

# Compile C to binary (make sure to link necessary libraries)
gcc your_program.c runtime/runtime.c -o your_program

# Or use one-step compilation
./llpl your_program.llpl -b -o your_program
```

## Examples

See the `examples/stdlib/` directory for complete working examples:

- **file_example.llpl** - Comprehensive file I/O operations
- **tcp_server.llpl** - TCP echo server
- **tcp_client.llpl** - TCP client
- **string_demo.llpl** - All string utilities demonstrated
- **http_server.llpl** - Full HTTP server combining all features

## Advanced Features

### Error Handling with Result<T, E>

All I/O operations return `Result<T, E>` for safe error handling:

```swift
let result: Result<String, char*> = std::io::read_file("config.json")

if result.is_ok() {
    let content: String = result.unwrap()
    // Success path
} else {
    let error: char* = result.unwrap_err()
    // Error handling
}
```

### RAII Resource Management

Resources are automatically cleaned up when they go out of scope:

```swift
{
    let f: std::File = new std::File("test.txt", std::io::O_RDONLY)
    // Use file...
} // File automatically closed here

{
    let sock: std::Socket = new std::Socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    // Use socket...
} // Socket automatically closed here
```

### Namespace Usage

Access types and functions through namespaces:

```swift
// Fully qualified
let trimmed: String = std::text::StringUtils::trim(s)

// Or use the convenient re-exports
let trimmed: String = std::StringUtils::trim(s)

// Access constants
let flags: int = std::io::O_RDWR | std::io::O_CREAT
let domain: int = std::net::AF_INET
```

## Platform Considerations

### System Calls

The standard library requires these system calls to be available:

**File I/O:**
- `open()`
- `close()`
- `read()`
- `write()`
- `lseek()`
- `unlink()`
- `rename()`

**Networking:**
- `socket()`
- `bind()`
- `listen()`
- `accept()`
- `connect()`
- `send()`
- `recv()`
- `sendto()`
- `recvfrom()`
- `shutdown()`
- `setsockopt()`
- `htons()`, `ntohs()`, `htonl()`, `ntohl()`

### Bare Metal Usage

For bare-metal/kernel environments, you'll need to provide these system calls. See `examples/baremetal_demo/syscall.llpl` for examples of implementing these in a kernel context.

## Tips and Best Practices

1. **Always check Result types** - Don't unwrap without checking `is_ok()` first
2. **Use StringBuilder for concatenation** - More efficient than repeated `+` operations
3. **Close connections explicitly** - While RAII handles cleanup, explicit `close()` is clearer
4. **Reuse StringBuilders** - Call `clear()` and reuse instead of creating new ones
5. **Check file_exists() before operations** - Avoid errors by checking existence first

## Common Patterns

### Reading Configuration Files

```swift
func load_config(path: char*) -> Result<String, char*> {
    if !std::io::file_exists(path) {
        let err: Result<String, char*> = new Result<String, char*>()
        err.set_err("Config file not found")
        return err
    }

    return std::io::read_file(path)
}
```

### Building JSON Responses

```swift
func build_json_response(status: int, message: String) -> String {
    let sb: std::StringBuilder = new std::StringBuilder()

    sb.append(new String("{\"status\":"))
    sb.append_int(status)
    sb.append(new String(",\"message\":\""))
    sb.append(message)
    sb.append(new String("\"}"))

    return sb.to_string()
}
```

### Request/Response Pattern

```swift
func send_request(client: std::TcpClient, request: String) -> Result<String, char*> {
    let send_result: Result<int, char*> = client.send(request)
    if !send_result.is_ok() {
        return new Result<String, char*>()  // Error
    }

    return client.recv(4096)
}
```

## Troubleshooting

### "File not found" errors
- Check that paths are correct relative to working directory
- Use absolute paths when in doubt
- Verify file exists with `std::io::file_exists()`

### Socket connection failures
- Ensure the server is running before connecting
- Check that ports aren't already in use
- Verify firewall settings allow connections
- Use `set_reuse_addr(true)` on servers to avoid "Address already in use"

### String encoding issues
- The String class in prelude.llpl uses UTF-8
- StringUtils works with ASCII characters
- For Unicode handling, use the Regex class with UTF-8 support

## Performance Notes

- StringBuilder is O(n) vs O(n²) for repeated string concatenation
- File operations are buffered - use `flush()` when needed
- Socket recv/send are blocking by default
- Vector operations (used in split/join) are efficient with reference counting

## Getting Help

- See `stdlib/README.md` for full API documentation
- Check `examples/stdlib/` for working code samples
- Review `prelude.llpl` for additional utilities (Regex, HashMap, etc.)
- Refer to the main LLPL documentation in the project root
