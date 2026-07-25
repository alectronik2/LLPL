# LLPL for Sublime Text

Sublime Text support for LLPL source files.

## Features

- Syntax highlighting for `.llpl` files.
- Line and block comment toggles.
- Build variants for binary builds, C generation, build-and-run, and retained intermediate C.
- Clickable compiler diagnostics for `file:line:column` and `--> file:line:column` output.
- IntelliSense through Sublime's LSP package: compiler-backed diagnostics, completion, hover, go-to-definition, and find-references.
- Keyword/type/widget completions.
- Symbol indexing for namespaces, types, functions, macros, aliases, and UI declarations.
- Basic snippets for common declarations and control flow.
- Menu entry under `View > Syntax > LLPL`.

## Install

Copy or symlink this directory into your Sublime Text `Packages` folder as `LLPL`.

Common package locations:

- Linux: `~/.config/sublime-text/Packages/LLPL`
- macOS: `~/Library/Application Support/Sublime Text/Packages/LLPL`
- Windows: `%APPDATA%\Sublime Text\Packages\LLPL`

After installation, reopen any `.llpl` file or choose `View > Syntax > LLPL > LLPL`.

## IntelliSense

IntelliSense uses the same LLPL language server as the VS Code extension.

Requirements:

- Node.js available as `node` on `PATH`.
- The Sublime Text `LSP` package installed through Package Control.
- The LLPL compiler available as `llpl` on `PATH`, or configured in `LSP-llpl.sublime-settings`.

Install the bundled language server dependencies once:

```bash
cd ~/.config/sublime-text/Packages/LLPL/server
npm install
npm run compile
```

To use a compiler outside `PATH`, edit `LSP-llpl.sublime-settings`:

```json
{
  "clients": {
    "llpl": {
      "initializationOptions": {
        "compilerPath": "/absolute/path/to/llpl"
      }
    }
  }
}
```

## Build

The build system expects `llpl` to be available on `PATH`.

Use `Tools > Build System > LLPL`, then:

- `Build`: compile the current file to a binary next to the source file.
- `Generate C`: emit the generated C source next to the source file.
- `Build and Run`: compile and execute the binary.
- `Keep Intermediate C`: build a binary and keep the generated C source.
