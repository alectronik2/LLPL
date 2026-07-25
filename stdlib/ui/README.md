# LLPL UI DSL Runtime

`stdlib/ui/sdl.llpl` is the first graphical backend for the `ui` DSL.
It targets the existing SDL3 bindings and expects DSL components to lower
into ordinary LLPL classes with public fields and an `add_child(child)`
method.

## Minimal App

```llpl
import stdlib.ui.sdl

using namespace std.ui

ui DemoWindow: Window {
    title: "LLPL UI"
    width: 640
    height: 420

    Column {
        spacing: 12

        Text {
            text: "Hello"
        }

        Button {
            text: "Click"
            hover_background: 0xFF4D8DFF as u32
            onClick: {
                puts("clicked")
            }
            onHover: {
                puts("hover")
            }
        }

        ProgressBar {
            value: 68
            text: "Loading"
        }

        SelectableText {
            text: "Drag to select this text"
        }
    }
}

func main() -> i64 {
    let root: Window = DemoWindow.build()
    root.apply_dark_theme()
    let app: App = new App("LLPL UI", 640, 420, root)
    if !app.is_valid() {
        return 1
    }
    app.run()
    return 0
}
```

## Widgets

- `Window`: root container, column layout by default.
- `Column`: vertical child layout.
- `Row`: horizontal child layout.
- `Panel`: framed column container.
- `Card`: elevated framed column container.
- `Text`: lightweight label.
- `SelectableText`: text label with drag selection.
- `Button`: clickable rectangle with `onClick` support.
- `ProgressBar`: ranged value display using `value`, `min_value`, and `max_value`.
- `Slider`: draggable ranged value control using `value`, `min_value`, and `max_value`.
- `Checkbox`: toggled boolean control using `checked`.
- `Badge`: compact label for statuses and tags.

## Interaction

Widgets track hover state automatically. Set `hover_background`,
`hover_foreground`, or `hover_border` to customize the animated hover
transition. `onHover` fires when the pointer enters a widget, and
`onHoverEnd` fires when it leaves.

`SelectableText` supports mouse-drag text selection. `Slider` updates its
`value` while dragging, and `Checkbox` toggles `checked` on click.

The SDL backend uses SDL3_ttf for TrueType text and relayouts the root
tree on SDL window resize events.

## Themes

Call `root.apply_dark_theme()` or `root.apply_light_theme()` after building
the UI tree and before creating `App`.
