# LLPL Language Support for VS Code

Syntax highlighting, bracket/comment configuration, and snippets for
[LLPL](../../README.md) (`.llpl`) files.

## Features

- Syntax highlighting for the full language: `namespace`, `class`, `struct`
  (with `packed`), `enum`, `constructor`/`destructor`, `func` (including
  `interrupt func` and operator overloads like `func operator+`), `let`/
  `const`, `alias`, control flow (`if`/`else`/`while`/`for`/`return`/`defer`/
  `match`/`case`/`default`), `import`, `extern`, `new`/`as` casts, inline
  `asm(...)`, and the built-in types (`int`, `uint`, `int16`/`uint16`/
  `int32`/`uint32`, `char`, `bool`, `void`).
- Type-annotation aware highlighting, including pointers (`char*`), fixed
  arrays (`char[17]`), and bit-fields (`let flags: uint32 : 3`).
- Comment toggling (`//` and `/* */`), bracket matching/auto-closing.
- Snippets for common constructs (`func`, `class`, `struct`, `namespace`,
  `enum`, `match`, `alias`, `if`, `while`, `for`, `extern`, `import`, `asm`,
  `bitfield`).

## Installing locally

This extension isn't published to the Marketplace. To use it from source:

```bash
cd editors/vscode-llpl
npm install -g @vscode/vsce   # once, if you don't have vsce
vsce package
code --install-extension llpl-language-0.2.0.vsix
```

Or symlink it straight into your VS Code extensions folder for development:

```bash
ln -s "$(pwd)" ~/.vscode/extensions/llpl-language
```

Reload VS Code afterward; `.llpl` files will be recognized automatically.
