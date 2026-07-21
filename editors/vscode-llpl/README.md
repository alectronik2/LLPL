# LLPL Language Support for VS Code

Syntax highlighting, bracket/comment configuration, snippets, and a
language server (diagnostics, completion, hover, go-to-definition,
find-references) for LLPL (`.llpl`) files.

## Features

- Syntax highlighting for the full language: `namespace`, `using namespace`,
  `class`, `struct` (with `packed`), `union`, `enum`, `macro` (with
  `NAME!(args)` invocations), `constructor`/`destructor`, `func` (including
  `static func`, `interrupt func`, and operator overloads like
  `func operator+`), `let`/`const`, `alias`,
  control flow (`if`/`else`/`while`/`for`/`foreach`/`return`/`defer`/`try`/
  `catch`/`finally`/`throw`/`delete`/`match`/`case`/`default`/`unless`),
  range-based `for i in 0..5 { }`, `import`/`from`, `extern`,
  `new`/`as` casts, inline
  `asm(...)`, `#link "NAME"`/`#flags "..."` compiler directives, and the
  built-in types (`int`/`uint` and their `8`/`16`/`32`/`64`-bit forms,
  including the `i8`/`u8`/`i16`/`u16`/`i32`/`u32`/`i64`/`u64` short names,
  `char`, `bool`, `void`, `float`, `string`).
- Type-annotation aware highlighting, including pointers/pointers-to-pointers
  (`char*`, `int**`), fixed arrays (`char[17]`), and bit-fields
  (`let flags: uint32 : 3`).
- Numeric literals with `_` digit-group separators (`0x100_0000_0000`,
  `1_000_000`), float literals (`1.5`, `1.5e-5`, `1.0f`), and char literals
  (`'x'`, `'\n'`, `'\x1b'`).
- String interpolation (`"total = \(a + b)"`) highlighted as embedded code
  inside the string, including nested calls/parens.
- Comment toggling (`//` and `/* */`), bracket matching/auto-closing
  (including for char literals' `'...'`).
- Snippets for common constructs (`func`, `class`, `struct`, `union`,
  `namespace`, `using namespace`, `enum`, `macro`, `match`, `alias`,
  `unless`, `if`, `while`, `for`, range-based `for`, `defer`, `delete`,
  `try`/`catch`/`finally`, `extern`, `import`, `#link`, `#flags`, `asm`,
  `bitfield`).
- **Language server** (`server/`): diagnostics, completion, hover,
  go-to-definition and find-references, backed directly by the `llpl`
  compiler's own name resolution (`llpl --lsp-symbols <file>` - see
  `source/lspquery.d`) rather than a separate reimplementation, so it's
  always exactly as accurate as the compiler. See `server/src/server.ts`
  for the full design and its known limitations (diagnostics/completion
  update ~400ms after you stop typing, not on every keystroke; a file with
  an error currently has no completion/hover data until it's fixed; member
  completion after `x.` only works for namespace/enum paths, not yet an
  instance variable's own type).

## Installing locally

This extension isn't published to the Marketplace. To use it from source,
build the compiler, the language server, and the extension client, in that
order:

```bash
# 1. Build the llpl compiler itself (the language server shells out to it)
cd ../..
dub build

# 2. Build the language server
cd editors/vscode-llpl/server
npm install
npm run compile

# 3. Build the extension client and package it
cd ..
npm install
npm run compile
npm install -g @vscode/vsce   # once, if you don't have vsce
vsce package
code --install-extension llpl-language-0.7.0.vsix
```

Or symlink the extension folder straight into your VS Code extensions
folder for development (steps 1-2 above still apply first):

```bash
ln -s "$(pwd)" ~/.vscode/extensions/llpl-language
```

Reload VS Code afterward; `.llpl` files will be recognized automatically.
By default the language server looks for an `llpl` binary by walking up
from the workspace root (matching this repo's layout, compiler at the
root); set `llpl.compilerPath` in your VS Code settings to point at it
explicitly if auto-detection doesn't find it (e.g. a workspace that only
contains a subdirectory of this repo).
