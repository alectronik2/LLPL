# LLPL SDL3 Bindings

Comprehensive SDL3 (Simple DirectMedia Layer 3) bindings for graphics, audio, and input.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Window & Rendering](#window--rendering)
- [Input Handling](#input-handling)
- [Audio](#audio)
- [Examples](#examples)
- [API Reference](#api-reference)

## Installation

### Prerequisites

SDL3 must be installed on your system. Install via your package manager:

```bash
# Ubuntu/Debian
sudo apt-get install libsdl3-dev

# macOS (Homebrew)
brew install sdl3

# Arch Linux
sudo pacman -S sdl3
```

### Usage in LLPL

Import the SDL3 module:

```swift
import "stdlib/sdl/sdl.llpl"
```

Compile with SDL3 linking:

```bash
./llpl your_program.llpl -o your_program.c
gcc your_program.c runtime/runtime.c -lSDL3 -o your_program
```

## Quick Start

### Minimal Window

```swift
import "stdlib/sdl/sdl.llpl"

func main() -> int {
    // Initialize SDL
    std::sdl::SDL.init(std::sdl::SDL_INIT_VIDEO)

    // Create window
    let window: std::sdl::Window = new std::sdl::Window(
        new String("My Window"),
        800,
        600
    )

    // Create renderer
    let renderer: std::sdl::Renderer = new std::sdl::Renderer(window)

    // Event loop
    let events: std::sdl::EventHandler = new std::sdl::EventHandler()
    let running: bool = true

    for running {
        for events.poll() {
            if events.is_quit() {
                running = false
            }
        }

        renderer.set_draw_color(0, 100, 200, 255)  // Blue
        renderer.clear()
        renderer.present()

        std::sdl::SDL.delay(16)  // ~60 FPS
    }

    std::sdl::SDL.quit()
    return 0
}
```

## Window & Rendering

### Window Management

```swift
// Create window with flags
let window: std::sdl::Window = new std::sdl::Window(
    new String("Title"),
    800,
    600,
    std::sdl::SDL_WINDOW_RESIZABLE | std::sdl::SDL_WINDOW_BORDERLESS
)

// Check if window created successfully
if !window.is_valid() {
    // Handle error
}

// Modify window
window.set_title(new String("New Title"))
window.set_size(1024, 768)
window.show()
window.hide()

// Get window size
let (width, height) = window.get_size()
```

**Window Flags:**
- `SDL_WINDOW_FULLSCREEN` - Fullscreen window
- `SDL_WINDOW_RESIZABLE` - Resizable window
- `SDL_WINDOW_BORDERLESS` - No window border
- `SDL_WINDOW_HIDDEN` - Start hidden
- `SDL_WINDOW_MAXIMIZED` - Start maximized
- `SDL_WINDOW_MINIMIZED` - Start minimized
- `SDL_WINDOW_HIGH_PIXEL_DENSITY` - High DPI support

### Rendering

```swift
let renderer: std::sdl::Renderer = new std::sdl::Renderer(window)

// Clear screen
renderer.set_draw_color(0, 0, 0, 255)  // Black
renderer.clear()

// Draw shapes
renderer.set_draw_color(255, 0, 0, 255)  // Red

// Point
renderer.draw_point(100.0, 100.0)

// Line
renderer.draw_line(0.0, 0.0, 800.0, 600.0)

// Rectangle (outline)
let rect: std::sdl::SDL_Rect = new std::sdl::SDL_Rect(100, 100, 200, 150)
renderer.draw_rect(rect)

// Filled rectangle
renderer.fill_rect(rect)

// Floating point rectangle
let frect: std::sdl::SDL_FRect = new std::sdl::SDL_FRect(50.5, 50.5, 100.0, 100.0)
renderer.fill_frect(frect)

// Present to screen
renderer.present()
```

### Colors

```swift
// Create color manually
let color: std::sdl::SDL_Color = new std::sdl::SDL_Color(255, 128, 0, 255)

// Or use presets
let red: std::sdl::SDL_Color = std::sdl::Colors.red()
let blue: std::sdl::SDL_Color = std::sdl::Colors.blue()
let green: std::sdl::SDL_Color = std::sdl::Colors.green()
let white: std::sdl::SDL_Color = std::sdl::Colors.white()
let black: std::sdl::SDL_Color = std::sdl::Colors.black()

// Use with renderer
renderer.set_draw_color_from_color(color)
```

**Available Color Presets:**
- `black()`, `white()`, `gray()`
- `red()`, `green()`, `blue()`
- `yellow()`, `cyan()`, `magenta()`
- `transparent()`

### Textures

```swift
// Load texture from BMP file
let texture_result: Result<std::sdl::Texture, char*> = renderer.load_texture("image.bmp")

if texture_result.is_ok() {
    let texture: std::sdl::Texture = texture_result.unwrap()

    // Render texture at position
    renderer.render_texture_simple(texture, 100, 100)

    // Or with source and destination rectangles
    let src: std::sdl::SDL_Rect = new std::sdl::SDL_Rect(0, 0, 64, 64)
    let dst: std::sdl::SDL_Rect = new std::sdl::SDL_Rect(200, 200, 128, 128)
    renderer.render_texture(texture, &src, &dst)

    // Modify texture
    texture.set_alpha(128)  // 50% transparent
    texture.set_color_mod(255, 0, 0)  // Tint red
    texture.set_blend_mode(std::sdl::SDL_BLENDMODE_BLEND)
}
```

## Input Handling

### Event Polling

```swift
let events: std::sdl::EventHandler = new std::sdl::EventHandler()

for events.poll() {
    // Check event type
    if events.is_quit() {
        running = false
    }

    if events.is_key_down() {
        let key_event: std::sdl::SDL_KeyboardEvent* = events.get_key_event()
        if (*key_event).key == std::sdl::SDLK_ESCAPE {
            running = false
        }
    }

    if events.is_key_up() {
        // Handle key release
    }

    if events.is_mouse_button_down() {
        let mouse_event: std::sdl::SDL_MouseButtonEvent* = events.get_mouse_button_event()
        let x: float = (*mouse_event).x
        let y: float = (*mouse_event).y
        let button: uint8 = (*mouse_event).button
    }

    if events.is_mouse_motion() {
        let motion_event: std::sdl::SDL_MouseMotionEvent* = events.get_mouse_motion_event()
        let x: float = (*motion_event).x
        let y: float = (*motion_event).y
    }
}
```

### Keyboard State

For continuous input (e.g., holding keys):

```swift
let keys: uint8* = std::sdl::Input.get_keyboard_state()

if keys[std::sdl::SDLK_w as int] != 0 {
    // W key is pressed
}

if keys[std::sdl::SDLK_SPACE as int] != 0 {
    // Space is pressed
}

// Arrow keys
if keys[std::sdl::SDLK_UP as int] != 0 {
    // Up arrow
}
```

**Common Keycodes:**
- `SDLK_ESCAPE`, `SDLK_RETURN`, `SDLK_SPACE`, `SDLK_BACKSPACE`, `SDLK_TAB`
- `SDLK_a` through `SDLK_z`
- `SDLK_UP`, `SDLK_DOWN`, `SDLK_LEFT`, `SDLK_RIGHT`

### Mouse State

```swift
// Get current mouse position
let (x, y) = std::sdl::Input.get_mouse_position()

// Get mouse button state
let state: u32 = std::sdl::Input.get_mouse_state()

// Check specific buttons
if state & (1 << (std::sdl::SDL_BUTTON_LEFT - 1)) != 0 {
    // Left button is pressed
}
```

## Audio

### Playing WAV Files

```swift
// Simple WAV playback
let result: Result<bool, char*> = std::sdl::Audio.play_wav("sound.wav")

if !result.is_ok() {
    let error: char* = result.unwrap_err()
    // Handle error
}
```

### Audio Devices

```swift
// Get audio device count
let num_devices: int = std::sdl::Audio.get_num_playback_devices()

// Get device name
let device_name: String = std::sdl::Audio.get_device_name(0)

// Create audio specification
let spec: std::sdl::SDL_AudioSpec = new std::sdl::SDL_AudioSpec(
    44100,  // Sample rate
    2,      // Channels (stereo)
    std::sdl::SDL_AUDIO_S16LSB  // Format
)

// Open audio device
let device: std::sdl::AudioDevice = new std::sdl::AudioDevice(spec, true)

if device.is_valid() {
    device.resume()  // Start playback
    // ... play audio ...
    device.pause()   // Pause playback
}
```

### Audio Streams

```swift
// Load WAV file
let wav: std::sdl::WavFile = new std::sdl::WavFile("music.wav")

if wav.is_valid() {
    // Create audio stream
    let stream: std::sdl::AudioStream = new std::sdl::AudioStream(
        wav.get_spec(),
        wav.get_spec()
    )

    // Bind to device
    stream.bind_to_device(device)

    // Put audio data
    stream.put_data(wav.get_buffer() as void*, wav.get_length() as int)
    stream.flush()

    device.resume()
}
```

## Examples

### Animation Loop

```swift
let last_time: uint64 = std::sdl::SDL.get_ticks()

for running {
    let current_time: uint64 = std::sdl::SDL.get_ticks()
    let dt: float = ((current_time - last_time) as float) / 1000.0
    last_time = current_time

    // Update game objects with dt
    player_x = player_x + velocity_x * dt

    // Render
    renderer.clear()
    // ... draw ...
    renderer.present()
}
```

### Moving Object with Keyboard

```swift
let x: float = 100.0
let y: float = 100.0
let speed: float = 200.0

let keys: uint8* = std::sdl::Input.get_keyboard_state()

if keys[std::sdl::SDLK_UP as int] != 0 {
    y = y - speed * dt
}
if keys[std::sdl::SDLK_DOWN as int] != 0 {
    y = y + speed * dt
}
if keys[std::sdl::SDLK_LEFT as int] != 0 {
    x = x - speed * dt
}
if keys[std::sdl::SDLK_RIGHT as int] != 0 {
    x = x + speed * dt
}

// Draw at position
let rect: std::sdl::SDL_FRect = new std::sdl::SDL_FRect(x, y, 50.0, 50.0)
renderer.fill_frect(rect)
```

### Collision Detection

```swift
func rects_collide(r1: std::sdl::SDL_FRect, r2: std::sdl::SDL_FRect) -> bool {
    return (
        r1.x < r2.x + r2.w &&
        r1.x + r1.w > r2.x &&
        r1.y < r2.y + r2.h &&
        r1.y + r1.h > r2.y
    )
}

let player_rect: std::sdl::SDL_FRect = new std::sdl::SDL_FRect(x, y, 50.0, 50.0)
let enemy_rect: std::sdl::SDL_FRect = new std::sdl::SDL_FRect(200.0, 200.0, 50.0, 50.0)

if rects_collide(player_rect, enemy_rect) {
    // Collision!
}
```

## API Reference

### Core Functions

| Function | Description |
|----------|-------------|
| `SDL.init(flags)` | Initialize SDL subsystems |
| `SDL.quit()` | Shutdown SDL |
| `SDL.get_error()` | Get last error message |
| `SDL.get_ticks()` | Get milliseconds since SDL init |
| `SDL.delay(ms)` | Delay for milliseconds |

### Window Class

| Method | Description |
|--------|-------------|
| `constructor(title, w, h)` | Create window with default flags |
| `constructor(title, w, h, flags)` | Create window with flags |
| `is_valid()` | Check if window created successfully |
| `set_title(title)` | Change window title |
| `get_size()` | Get (width, height) |
| `set_size(w, h)` | Resize window |
| `show()` / `hide()` | Show/hide window |

### Renderer Class

| Method | Description |
|--------|-------------|
| `constructor(window)` | Create renderer for window |
| `clear()` | Clear rendering target |
| `present()` | Update screen |
| `set_draw_color(r, g, b, a)` | Set drawing color |
| `draw_point(x, y)` | Draw point |
| `draw_line(x1, y1, x2, y2)` | Draw line |
| `draw_rect(rect)` | Draw rectangle outline |
| `fill_rect(rect)` | Draw filled rectangle |
| `load_texture(path)` | Load texture from BMP |
| `render_texture(tex, src, dst)` | Render texture |

### EventHandler Class

| Method | Description |
|--------|-------------|
| `poll()` | Poll for event (returns bool) |
| `wait()` | Wait for event |
| `is_quit()` | Check if quit event |
| `is_key_down()` / `is_key_up()` | Check key events |
| `is_mouse_button_down()` | Check mouse button |
| `is_mouse_motion()` | Check mouse movement |

### Input Class

| Static Method | Description |
|---------------|-------------|
| `get_keyboard_state()` | Get key state array |
| `get_mouse_position()` | Get (x, y) position |
| `get_mouse_state()` | Get button state bitmask |

### Audio Classes

| Class | Description |
|-------|-------------|
| `AudioDevice` | Audio playback/recording device |
| `AudioStream` | Audio processing stream |
| `WavFile` | WAV file loader |
| `Audio` | Static audio utilities |

## Performance Tips

1. **Use FRect for smooth movement** - Integer rectangles can cause jittery movement
2. **Limit frame rate** - Use `SDL.delay(16)` for ~60 FPS
3. **Batch rendering** - Draw similar objects together
4. **Use delta time** - Scale movement by `dt` for frame-rate independence
5. **Reuse objects** - Don't create new rectangles every frame

## Complete Example Programs

See `examples/sdl/` for full examples:
- `basic_window.llpl` - Basic rendering and shapes
- `interactive_demo.llpl` - Keyboard and mouse input
- `pong_game.llpl` - Complete Pong game

## Troubleshooting

**Window doesn't appear:**
- Check `window.is_valid()` after creation
- Ensure SDL initialized with `SDL_INIT_VIDEO`
- Call `window.show()` if created hidden

**Black screen:**
- Call `renderer.present()` after drawing
- Check draw color isn't same as clear color
- Ensure objects are within window bounds

**Input not working:**
- Poll events in loop with `events.poll()`
- For continuous input, use `Input.get_keyboard_state()`
- Check scancode values are correct

**Audio not playing:**
- Verify WAV file format is supported
- Check audio device initialization
- Ensure `device.resume()` was called

## License

SDL3 is licensed under the zlib license. These bindings are part of the LLPL standard library.
