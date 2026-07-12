# LLPL Limine Bare-Metal Demo

This is a smaller companion to `baremetal_demo` that boots through the
Limine boot protocol instead of GRUB's Multiboot2 path.

It demonstrates:

- a 64-bit higher-half Limine kernel ELF
- Limine request markers plus framebuffer, memory-map, and HHDM requests
- serial output through COM1
- direct framebuffer drawing using Limine's framebuffer response
- memory-map diagnostics for usable, reserved, framebuffer,
  bootloader-reclaimable, and kernel/module regions
- a small HHDM probe that reads physical memory through Limine's
  higher-half direct map offset

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

At boot, serial output prints each Limine memory-map entry as
`base..end len type`, then prints the HHDM offset and a physical-memory probe
performed through `hhdm_offset + physical_address`. When a framebuffer is
available, the demo also draws a horizontal memory-map bar below the color
gradient:

- green: usable
- grey: reserved and related reserved classes
- blue: bootloader-reclaimable
- yellow: kernel and modules
- pink: framebuffer
