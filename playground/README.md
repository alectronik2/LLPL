# LLPL Playground

A local web playground for LLPL: write source in the browser, and see the
generated C alongside the compiled program's actual output.

## Running it

```sh
# From the repo root, build the compiler first if you haven't:
dub build --force

# Then start the playground:
cd playground
node server.js
```

Open `http://localhost:8787`. Requires `gcc` on `PATH` (the same
toolchain `run_tests.sh` uses) and Node.js; no `npm install` needed - the
server has no dependencies, and the frontend loads CodeMirror from a CDN.

Set `PORT` to use a different port (`PORT=3000 node server.js`).

## What it does

Each "Run" click sends the editor's source to `POST /api/compile`, which:

1. Writes it to a fresh temp directory and runs the real `llpl` binary
   (`llpl main.llpl -o main.c`). Compile errors are returned as-is.
2. Compiles the generated C with `gcc` (linking `runtime/runtime.c`),
   matching exactly how `test/`/`examples/*.llpl` are built.
3. Runs the resulting binary with a 5-second timeout and returns its
   stdout/stderr/exit code.

The generated C is always shown once step 1 succeeds, even if steps 2-3
fail (e.g. an `extern func` with no real definition - `llpl` doesn't
resolve those, only `gcc` does).

The "Symbol table" pane shows the compiler's own baked-in backtrace
symbol table (`codegen.d`'s `generateBacktraceSymbolTable` - see
`EXAMPLES.md`'s "Symbolized Backtraces" section) filtered down to just
the functions/methods/constructors your snippet itself declares: each
one's real C symbol name and declaration line, exactly what
`llpl_resolve_symbol` would report for that function in a real panic
backtrace.

## Security - local use only

**This executes arbitrary, unsandboxed code submitted through the
browser.** Step 1 runs a real compiler on arbitrary input, and step 3
*runs the resulting native binary* on whatever machine hosts the server.
There is no container, VM, seccomp filter, or user/network isolation here
- only process-level timeouts (compile/gcc/run) and output-size limits,
which bound *runtime* but not what a malicious program could do to the
host while it runs (filesystem access, network access, etc., are all
available to it exactly as they would be to any other process you run
yourself).

This is fine for your own local experimentation. Do **not**:
- expose this server on a network or the internet,
- run it as a shared/multi-tenant service,
- run it with elevated privileges,

without first putting a real sandbox (a locked-down container or VM with
no meaningful filesystem/network access) between this server and the
compile/run steps.
