# llplbuild

`llplbuild` is the YAML-driven build tool used by LLPL's bare-metal
examples. It replaces hand-written Makefiles with a fixed, predictable
pipeline for:

- compiling LLPL to C
- compiling C to objects
- assembling NASM and `m64` sources
- linking one or more binaries
- packaging artifacts such as bootable ISOs
- running the result under QEMU
- running LLPL tests from the repo root

It is intentionally not a general task runner. The build graph shape is
defined by the tool; `build.yaml` declares the files, flags, package
actions, and run arguments for one target directory.

## Build The Tool

From the repository root:

```sh
cd tools/llplbuild
dub build
```

The tool depends on `dyaml`, fetched by Dub on first build. The main LLPL
compiler does not depend on `dyaml`.

The resulting binary is:

```sh
tools/llplbuild/llplbuild
```

## Basic Usage

For `build`, `check`, `run`, `clean`, and `configs`, run the tool from a
directory containing a `build.yaml`:

```sh
cd examples/limine_baremetal_demo
../../tools/llplbuild/llplbuild build
../../tools/llplbuild/llplbuild check
../../tools/llplbuild/llplbuild run
../../tools/llplbuild/llplbuild clean
../../tools/llplbuild/llplbuild configs
```

Commands:

- `new <directory>`: create a small hosted LLPL project template. The target
  must not already contain `build.yaml` or `main.llpl`.

- `build`: run the compile, assemble, link, and package pipeline, except packages marked `run_only`.
- `check`: run compile/assemble steps only; skip link/package.
- `run`: run `build`, including `run_only` packages, then launch the configured QEMU command.
- `clean`: remove generated outputs declared by `build.yaml`.
- `configs`: print available configurations and the default.
- `test`: run LLPL test files from the repo root; does not need `build.yaml`.

Common options:

```sh
llplbuild -f path/to/build.yaml build
llplbuild build -c debug
llplbuild build --var LIMINE_DIR=/path/to/limine
llplbuild build -j 8
```

Options:

- `-f`, `--file`: config path, default `build.yaml`.
- `-c`, `--config`: build configuration name.
- `--var NAME=value`: override a variable from `variables:`. Repeatable.
- `-j`, `--jobs`: max parallel compile/assemble/test jobs. Defaults to CPU count.
- `--dir`: test directory for `test`, default `test`.
- `--compiler`: LLPL compiler for `test`, default `./llpl`.

## Test Command

Run from the repository root:

```sh
tools/llplbuild/llplbuild test
tools/llplbuild/llplbuild test test/enum_no_commas.llpl
tools/llplbuild/llplbuild test test/foo.llpl test/bar.llpl -j 4
tools/llplbuild/llplbuild test --compiler ./llpl --dir test
```

The test command is separate from `build.yaml`. It is the same harness used
by the repo's focused `.llpl` tests.

## Minimal `build.yaml`

```yaml
project: my-kernel
entry: kernel.llpl
llpl_compiler: ../../llpl

toolchain:
  cc: gcc
  ld: ld
  qemu: qemu-system-x86_64

common_cflags:
  - -m64
  - -ffreestanding
  - -nostdlib
  - -nostdinc
  - -fno-builtin
  - -fno-stack-protector
  - -I.

c_sources:
  - path: kernel.c
    output: build/kernel.o
    include_dirs: [../../runtime]
  - path: ../../runtime/runtime.c
    output: build/runtime.o
    include_dirs: [../../runtime]

link:
  output: build/kernel.elf
  script: linker.ld
  ldflags: [-m, elf_x86_64, -nostdlib]
  objects: [build/kernel.o, build/runtime.o]

run:
  args: [-kernel, build/kernel.elf, -serial, stdio]
```

`entry` is compiled to a C file with the same stem: `kernel.llpl` becomes
`kernel.c`. Include that generated C file in `c_sources` if it should be
compiled and linked.

## Full Schema Reference

Top-level fields:

```yaml
project: string                  # required, display/name metadata
entry: string                    # required, root LLPL file
llpl_compiler: string            # optional, default ../../llpl
variables: map<string, string>   # optional
toolchain: map                   # optional
common_cflags: [string]          # optional
default_config: string           # required if configurations is present
configurations: map              # optional
asm_sources: [asm-source]        # optional
m64_sources: [m64-source]        # optional
c_sources: [c-source]            # optional
link: link-spec                  # optional
extra_links: [extra-link]        # optional
package: package-spec            # optional
persistent_files: [persistent]   # optional
run: run-spec                    # optional
```

### Variables

Variables are substituted in string fields using `${NAME}`:

```yaml
variables:
  LIMINE_DIR: /usr/share/limine

package:
  actions:
    - copy: {from: "${LIMINE_DIR}/limine-bios.sys", to: isodir/boot/limine/limine-bios.sys}
```

Precedence:

1. values in `build.yaml`
2. same-named environment variables
3. explicit `--var NAME=value`

Only variables declared in `variables:` are resolved from the environment.

### Toolchain

All entries are optional:

```yaml
toolchain:
  nasm: nasm
  m64: ../../tools/assembler/build/m64
  cc: gcc
  ld: ld
  qemu: qemu-system-x86_64
```

Defaults are the values shown above.

### Configurations

Configurations add C flags on top of `common_cflags`:

```yaml
common_cflags: [-m64, -ffreestanding]

default_config: final
configurations:
  debug:
    cflags: [-O0, -g]
  final:
    cflags: [-O2]
```

Use one with:

```sh
llplbuild build -c debug
```

Changing configuration updates `.llplbuild-config`, which invalidates C
compile steps even when source file mtimes are unchanged.

### C Sources

```yaml
c_sources:
  - path: kernel.c
    output: build/kernel.o
    include_dirs: [../../runtime]
    cflags: [-Wall]
```

Fields:

- `path`: required.
- `output`: optional, defaults to basename with `.o`.
- `include_dirs`: optional, emits `-I <dir>` for each entry.
- `cflags`: optional, appended after common/config cflags for this source.

If a `c_sources` entry's `path` is the generated C file for `entry`, the
tool also depends it on the project LLPL source set so imported module
changes rebuild the object.

### Assembly Sources

NASM:

```yaml
asm_sources:
  - src: boot64.asm
    output: build/boot.o
```

`m64` assembler:

```yaml
m64_sources:
  - src: hal/isr.m64
    output: build/isr.o
```

`output` is optional and defaults to the source basename with `.o`.

### Link

```yaml
link:
  output: build/kernel.elf
  script: linker.ld
  ldflags: [-m, elf_x86_64, -nostdlib]
  objects: [build/boot.o, build/kernel.o, build/runtime.o]
```

Fields:

- `output`: required.
- `script`: optional. When present, emits `-T <script>`.
- `ldflags`: optional.
- `objects`: optional, but normally required for useful links.

### Extra Links

`extra_links` builds additional independent binaries or shared objects.
Each entry can have its own LLPL, C, NASM, `m64`, and link steps.

```yaml
extra_links:
  - name: userapp
    llpl_sources:
      - src: userapp/main.llpl
        c_output: build/userapp.c
        output: build/userapp.o
        include_dirs: [., ../../runtime]
        cflags: [-mcmodel=large]
    asm_sources:
      - src: userapp/start.asm
        output: build/userapp_start.o
    c_sources:
      - path: userapp/support.c
        output: build/support.o
    link:
      output: build/userapp.elf
      script: userapp/linker.ld
      ldflags: [-m, elf_x86_64, -nostdlib, -static]
      objects: [build/userapp_start.o, build/userapp.o, build/support.o]
```

`llpl_sources` fields:

- `src`: required.
- `c_output`: optional, defaults to source path with `.c`.
- `output`: optional, defaults to source path with `.o`.
- `include_dirs`: optional.
- `cflags`: optional.

### Package

Packaging is an ordered action list guarded by one package output. If the
package output is newer than all package inputs, all package actions are
skipped.

Set `run_only: true` to skip package actions during `llplbuild build` and
run them only as part of `llplbuild run`.

```yaml
package:
  output: kernel.iso
  run_only: true
  actions:
    - require_file:
        path: "${LIMINE_DIR}/limine-bios.sys"
        message: "Limine assets not found"
    - mkdir: isodir/boot/limine
    - copy: {from: kernel.elf, to: isodir/boot/kernel.elf}
    - write:
        to: isodir/boot/grub/grub.cfg
        content: |
          set timeout=0
          menuentry "LLPL" {
            multiboot2 /boot/kernel.bin
            boot
          }
    - run: "grub-mkrescue -o kernel.iso isodir"
```

Actions:

- `mkdir: path`: create a directory with parents.
- `copy: {from: src, to: dst}`: copy a file.
- `write: {to: path, content: text}`: write a text file.
- `run: "command string"`: execute through `/bin/sh -c`.
- `require_file: {path: file, message: text}`: fail early if a file is missing.

Any package action can set:

```yaml
allow_failure: true
```

When set, a failing action logs a warning and the build continues.

### Persistent Files

Persistent files are created only if missing during ordinary builds, but
`clean` removes them.

```yaml
persistent_files:
  - path: disk.img
    create: "dd if=/dev/zero of=disk.img bs=1M count=16"
```

This is useful for disk images or other stateful files that should survive
incremental rebuilds.

### Run

```yaml
run:
  args: ["-cdrom", "kernel.iso", "-serial", "stdio", "-m", "256"]
```

`llplbuild run` runs a full build first, then launches:

```text
<toolchain.qemu> <run.args...>
```

The QEMU process inherits the terminal so serial output remains live.

## Pipeline Order

The main pipeline is:

1. `entry` LLPL source -> generated C
2. top-level NASM and `m64` sources -> objects
3. top-level C sources -> objects
4. top-level link
5. each `extra_links` entry
6. package gate and package actions
7. persistent file creation

Independent compile/assemble steps run in parallel, capped by `--jobs`.
Link/package/run steps run in order.

## Incremental Builds

A step is skipped when every declared output:

- exists
- is newer than every declared input
- is newer than `build.yaml`

Config changes also invalidate C compilation via `.llplbuild-config`.

For the root generated C file, llplbuild conservatively treats every
`.llpl` file under the project directory, the compiler project config
`llpl.json` found next to or above `entry`, and `prelude.llpl` as inputs.
This avoids reimplementing the compiler's module resolver in the build
tool while still catching import-path changes.

Embedded assets referenced with `embed("path")` are also tracked as
inputs.

## Clean Behavior

`llplbuild clean` removes:

- generated C for `entry`
- object outputs from C, NASM, and `m64` sources
- top-level link output
- extra link generated C, objects, and link outputs
- package output
- top-level directories created by package `mkdir` actions
- persistent files
- `.llplbuild-config`

It removes only paths declared by the active config file.

## Console Output

llplbuild prints Cargo-style status lines and a progress bar on interactive
terminals. Colors and progress control sequences are disabled when stdout
is not a terminal or when `TERM=dumb`.

Build-step subprocess output is captured and replayed on failure after the
progress line is cleared, so compiler diagnostics do not overwrite the
progress display.

The final QEMU process for `llplbuild run` is not captured; it inherits the
terminal for interactive serial output.

## Troubleshooting

Missing Limine assets:

```sh
../../tools/llplbuild/llplbuild build --var LIMINE_DIR=/path/to/limine
```

Different optimization/debug flags:

```sh
../../tools/llplbuild/llplbuild configs
../../tools/llplbuild/llplbuild build -c debug
```

Force a rebuild:

```sh
../../tools/llplbuild/llplbuild clean
../../tools/llplbuild/llplbuild build
```

Limit parallelism when diagnosing output:

```sh
../../tools/llplbuild/llplbuild build -j 1
```

QEMU fails with `gtk initialization failed`:

The build succeeded and QEMU started, but the current environment has no
GTK display. Use a headless QEMU option in `run.args`, for example `-nographic`,
or run from an environment with a display.

## Real Examples

See:

- `examples/baremetal_demo/build.yaml`
- `examples/limine_baremetal_demo/build.yaml`

Those files are the source of truth for the current GRUB/Multiboot2 and
Limine bare-metal demo builds.

Standalone integration scripts, such as
`examples/baremetal_demo/test-persistence.sh`, intentionally remain outside
the `build.yaml` schema. They shell out to `llplbuild` for build/run work
and keep scenario-specific assertions in ordinary scripts.
