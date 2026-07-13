# llplbuild

A small, YAML-configured build tool for LLPL's bare-metal targets
(`examples/baremetal_demo`, `examples/limine_baremetal_demo`) - replaces
their old hand-written Makefiles with a `build.yaml` per target, real
`debug`/`final` build configurations, incremental rebuilds, and parallel
compilation.

## Building the tool

```sh
cd tools/llplbuild
dub build
```

This fetches [dyaml](https://code.dlang.org/packages/dyaml) (the only
dependency - the main `llpl` compiler itself stays dependency-free) on
first build, and produces the `llplbuild` binary in this directory.

## Using it

Invoked the same way `make` was - from *within* the target directory,
which is expected to have its own `build.yaml`:

```sh
cd examples/baremetal_demo
../../tools/llplbuild/llplbuild build            # uses default_config
../../tools/llplbuild/llplbuild build -c debug   # a specific configuration
../../tools/llplbuild/llplbuild run              # build, then launch QEMU
../../tools/llplbuild/llplbuild clean            # remove every generated artifact
../../tools/llplbuild/llplbuild configs          # list configurations + the default
```

Options: `-f/--file` (config path, default `build.yaml`), `-c/--config`,
`--var NAME=value` (repeatable - overrides a `variables:` entry, itself
already overridable via a same-named environment variable), `-j/--jobs`
(max concurrent compile/assemble processes, default: CPU count).

## `build.yaml` schema

One config file per target directory. See
`examples/baremetal_demo/build.yaml` and
`examples/limine_baremetal_demo/build.yaml` for two real, complete
examples (GRUB/Multiboot2 and Limine respectively). The shape is a fixed
pipeline - not a generic task graph - with YAML controlling which stages
are enabled and their parameters:

```yaml
project: my-kernel
entry: kernel.llpl              # llpl source compiled to a C file of the same name
llpl_compiler: ../../llpl       # path to the llpl binary

variables:                      # ${NAME} is substituted in every string
  LIMINE_DIR: /usr/share/limine # field below; overridable via --var/env

toolchain:
  nasm: nasm
  cc: gcc
  ld: ld
  qemu: qemu-system-x86_64

common_cflags: [-m64, -ffreestanding, ...]   # applied to every configuration
default_config: final
configurations:
  debug:  { cflags: [-O0, -g] }
  final:  { cflags: [-O2] }

asm_sources:
  - src: boot.asm
    output: boot.o            # defaults to src's basename + .o if omitted

c_sources:
  - path: kernel.c             # the file `entry` compiles to
    include_dirs: [../../runtime]
  - path: ../../runtime/runtime.c
    include_dirs: [../../runtime]

link:
  output: kernel.bin
  script: linker.ld             # omit for no -T
  ldflags: [-m, elf_x86_64, -nostdlib]
  objects: [boot.o, kernel.o, runtime.o]

extra_links:                    # a second, independent link (e.g. a user
  - name: userapp                # program loaded as a boot module)
    asm_sources: [{src: userapp/userapp.asm, output: userapp.o}]
    link:
      output: userapp.elf
      script: userapp/linker.ld
      ldflags: [-m, elf_x86_64, -nostdlib, -static]
      objects: [userapp.o]

package:                        # ISO/etc. packaging - a small ordered
  output: kernel.iso              # action list rather than a hardcoded
  actions:                        # "grub"/"limine" mode, so a third
    - mkdir: isodir/boot           # bootloader is just new YAML, not new code
    - copy: {from: kernel.bin, to: isodir/boot/kernel.bin}
    - write: {to: isodir/boot/grub/grub.cfg, content: "..."}
    - require_file: {path: "${LIMINE_DIR}/limine-bios.sys", message: "..."}
    - run: "grub-mkrescue -o kernel.iso isodir"
      allow_failure: true        # like a Makefile's `... || echo Note: ...`

persistent_files:                # created only if missing, never rebuilt -
  - path: disk.img                # for state a real disk would keep across
    create: "dd if=/dev/zero of=disk.img bs=1M count=16"  # ordinary builds

run:
  args: ["-cdrom", "kernel.iso", "-serial", "stdio", "-m", "256"]
```

## Behavior notes

- **Incremental builds**: a step is skipped if every declared output
  already exists and is newer than every declared input *and* newer than
  `build.yaml` itself (editing the config invalidates everything
  downstream). Switching `-c`/`--config` is also tracked (via a small
  `.llplbuild-config` stamp file) and correctly triggers a recompile even
  though the C sources/objects on disk look unchanged.
- **Parallel builds**: independent steps (every `asm_sources` entry
  alongside every `c_sources` entry) run concurrently, capped at
  `--jobs`.
- **`package`** is one incremental unit (its inputs are the binaries it
  copies in, not each individual action) - matching the granularity a
  Makefile's own ISO rule already had.
- **`clean`** removes exactly the file set this config declares as
  outputs, including `persistent_files` (matching the old Makefiles,
  which wiped e.g. `disk.img` on `clean` too) and any top-level directory
  a `mkdir` action wrote under (e.g. `isodir/`).

## Not handled here

Bespoke, non-build-pipeline integration tests (e.g.
`examples/baremetal_demo/test-persistence.sh`, which boots a kernel
*twice* against the same disk image and greps serial-log output for
specific pass/fail markers) are intentionally not part of this schema -
they're standalone scripts that shell out to `llplbuild` for the actual
build/run steps.
