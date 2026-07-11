# LLPL Limine Bare-Metal Demo

This is a smaller companion to `baremetal_demo` that boots through the
Limine boot protocol instead of GRUB's Multiboot2 path.

It demonstrates:

- a 64-bit higher-half Limine kernel ELF
- Limine request markers and a framebuffer request
- serial output through COM1
- direct framebuffer drawing using Limine's framebuffer response

The config uses Limine's current `resource(argument):/path` form, for
example `boot():/boot/kernel.elf`.

Build:

```sh
make
```

Run:

```sh
make run
```

The ISO rule expects Limine tooling/assets to be available locally. It uses
`limine bios-install`, `limine-bios.sys`, `limine-bios-cd.bin`, and
`limine-uefi-cd.bin` from `$(LIMINE_DIR)`, defaulting to `/usr/share/limine`.
Override it when your install layout differs:

```sh
make LIMINE_DIR=/path/to/limine
```
