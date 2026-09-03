# LLPL widget toolkit

This example is split into a platform-neutral retained-mode toolkit and an
SDL3 adapter. `toolkit.llpl` has no SDL dependency; a bare-metal port implements
`gui.Canvas` and `gui.Platform` for its framebuffer, timer, mouse, and keyboard.

Build and run from this directory:

```sh
../../llpl -b --cc cc demo.llpl -o demo
./demo
```

The current vertical slice includes a QNX Photon-inspired desktop, movable,
resizable, and closable windows, real font rendering, panels, labels, buttons, hit testing,
hover/pressed state, click dispatch, and a backend-neutral application loop.
