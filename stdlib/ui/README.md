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

        GroupBox {
            title: "Filters"

            TextBox {
                placeholder: "Search"
            }

            ComboBox {
                text: "All"
            }

            MsgBox {
                title: "Saved"
                message: "Project settings were updated."
                icon: MSGBOX_ICON_INFO
                button_mode: MSGBOX_BUTTONS_OK
            }

            InputBox {
                title: "Rename"
                message: "New file name"
                placeholder: "notes.llpl"
                button_mode: MSGBOX_BUTTONS_OK_CANCEL
                visible: false
            }
        }

        Canvas {
            width: 100%
            preferred_height: 160
        }

        FlowBox {
            flex_grow: 1

            Picture {
                image_path: "examples/baremetal_demo/media/llpl-logo.png"
                width: 46%
                height: 140
            }

            ScrollBar {
                value: 35
                height: 140
            }
        }

        MenuBar {
            Menu {
                text: "File"

                MenuItem {
                    text: "Open"
                    icon: LIST_ICON_FOLDER
                }

                Menu {
                    text: "Recent"
                    icon: LIST_ICON_FOLDER

                    MenuItem {
                        text: "demo.llpl"
                        icon: LIST_ICON_FILE
                    }
                }
            }
        }
    }
}

func main() -> i64 {
    let root: Window = DemoWindow.build()
    root.apply_dark_theme()
    let column: Widget = root.first_child
    let canvas: Canvas = column.first_child.next_sibling.next_sibling.next_sibling.next_sibling as Canvas
    if canvas != null {
        canvas.set_stroke(0xFFE9EEF6 as u32)
        canvas.line(16, 16, 180, 120)
        canvas.set_fill(0xFF26A890 as u32)
        canvas.fill_rect(24, 64, 80, 48)
    }
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
- `Box`: transparent column container that flexes by default.
- `FlowBox`: wrapping row container that rearranges children as available width changes.
- `MenuBar`: horizontal top-level menu strip.
- `Menu`: top-level menu or submenu; nested `Menu` children open as submenus.
- `MenuItem`: clickable menu row with optional `icon` and `onClick`.
- `Panel`: framed column container.
- `Card`: elevated framed column container.
- `GroupBox`: titled framed column container for related controls.
- `MsgBox`: message dialog with `message`, `icon`, `button_mode`, `result`, `show`, `hide`, `accept`, and `cancel`.
- `InputBox`: message dialog with an editable `text` value plus `placeholder`, `ask`, and `value`.
- `Text`: lightweight label.
- `SelectableText`: text label with drag selection.
- `TextBox`: single-line text field surface using `text` and `placeholder`.
- `Button`: clickable rectangle with `onClick` support.
- `ComboBox`: compact selector using `add_option`; clicking opens a dropdown menu.
- `ProgressBar`: ranged value display using `value`, `min_value`, and `max_value`.
- `Slider`: draggable ranged value control using `value`, `min_value`, and `max_value`.
- `ScrollBar`: vertical draggable ranged control using `value`, `min_value`, and `max_value`.
- `Checkbox`: toggled boolean control using `checked`.
- `Badge`: compact label for statuses and tags.
- `List`: selectable rows with file, folder, and image icons via `add_item`, `add_folder`, and `add_image`.
- `TreeView`: hierarchical rows with folder disclosure controls via `add_folder`, `add_item`, `collapse_all`, and `expand_all`.
- `Canvas`: retained drawing surface with `point`, `line`, `rect`, `fill_rect`, `clear`, `set_stroke`, and `set_fill`.
- `Picture`: PNG image display loaded from disk via `image_path` or `set_path`.

## Interaction

Widgets track hover state automatically. Set `hover_background`,
`hover_foreground`, or `hover_border` to customize the animated hover
transition. `onHover` fires when the pointer enters a widget, and
`onHoverEnd` fires when it leaves.

`SelectableText` supports mouse-drag text selection. `Slider` and `ScrollBar`
update their `value` while dragging, and `Checkbox` toggles `checked` on click.
`ComboBox` opens a menu on click and selects an option from the dropdown.
`MenuBar` opens top-level menus on click; nested `Menu` rows open submenus,
and `MenuItem` rows can run `onClick`.
`TreeView` toggles folder expansion when a folder row is clicked.
`MsgBox` and `InputBox` button clicks set `result` to one of
`MSGBOX_RESULT_OK`, `MSGBOX_RESULT_CANCEL`, `MSGBOX_RESULT_YES`, or
`MSGBOX_RESULT_NO` and hide the widget. Use `button_mode` values
`MSGBOX_BUTTONS_OK`, `MSGBOX_BUTTONS_OK_CANCEL`, `MSGBOX_BUTTONS_YES_NO`, or
`MSGBOX_BUTTONS_YES_NO_CANCEL`; use icon values `MSGBOX_ICON_INFO`,
`MSGBOX_ICON_WARNING`, `MSGBOX_ICON_ERROR`, or `MSGBOX_ICON_QUESTION`.
`InputBox.text` stores the entered value.

The SDL backend uses SDL3_ttf for TrueType text and relayouts the root
tree on SDL window resize events. `Picture` uses SDL3's built-in PNG loader,
so no SDL_image dependency is required.

## Themes

Call `root.apply_dark_theme()` or `root.apply_light_theme()` after building
the UI tree and before creating `App`.

For the root `Window`, `title` is used as the native SDL window title and is
not rendered as centered content text. Runtime changes to `root.title` are
reflected in the SDL title bar during the app loop.

## Sizing

`width` and `height` accept integer pixels as before. Inside `ui` blocks,
`width: 50%` and `height: 40%` set `width_percent` or `height_percent`;
the SDL layout resolves those percentages against the parent content area.
Auto-sized children are recomputed on every layout pass, including after
window resize events.

The SDL backend supports a simple box model:

- `padding`: inset for container content.
- `spacing`: gap between laid-out children.
- `margin`, `margin_left`, `margin_right`, `margin_top`, `margin_bottom`: space outside a widget.
- `min_width`, `min_height`, `max_width`, `max_height`: size constraints.
- `preferred_height`: natural height for auto-sized vertical layout.
- `flex_grow`: shares leftover space with sibling flex items.
