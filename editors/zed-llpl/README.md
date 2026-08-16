# LLPL for Zed

This extension adds LLPL support to Zed:

- `.llpl` language detection
- Tree-sitter-backed highlighting, bracket matching, indentation, and outline
- Compiler-backed LSP integration for diagnostics, completion, hover, go-to-definition, and references

Install it locally from Zed with `zed: extensions` -> `Install Dev Extension`, then select `editors/zed-llpl`.

The language server runs the bundled `server/out/server.js` with Zed's Node runtime. It auto-detects an `llpl` compiler binary from the workspace `PATH` or by walking upward from the workspace root.
