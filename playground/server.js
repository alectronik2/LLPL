#!/usr/bin/env node
// Local-only LLPL playground server. Compiles submitted LLPL source with
// the real `llpl` binary, then (if that succeeds) compiles the generated
// C with gcc and runs it, returning the generated C and the program's
// output alongside any compiler errors.
//
// This executes arbitrary user-submitted code as a real, unsandboxed
// process on whatever machine runs this server (see README.md) - it is
// meant to be run on localhost for your own experimentation, not exposed
// on a network or served to untrusted users without a real sandbox
// (container/VM) in front of it.

'use strict';

const http = require('http');
const fs = require('fs/promises');
const fsSync = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFile } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const LLPL_BIN = path.join(REPO_ROOT, process.platform === 'win32' ? 'llpl.exe' : 'llpl');
const RUNTIME_DIR = path.join(REPO_ROOT, 'runtime');
const RUNTIME_C = path.join(RUNTIME_DIR, 'runtime.c');
const PUBLIC_DIR = path.join(__dirname, 'public');

const PORT = process.env.PORT ? Number(process.env.PORT) : 8787;
const MAX_SOURCE_BYTES = 64 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024;
const COMPILE_TIMEOUT_MS = 10_000;
const GCC_TIMEOUT_MS = 15_000;
const RUN_TIMEOUT_MS = 5_000;

if (!fsSync.existsSync(LLPL_BIN)) {
    console.error(`error: compiler binary not found at ${LLPL_BIN}`);
    console.error(`Build it first: dub build --force (from ${REPO_ROOT})`);
    process.exit(1);
}

// Runs `file` with `args`, capturing stdout/stderr as strings (truncated
// to MAX_OUTPUT_BYTES) instead of throwing on a non-zero exit or timeout -
// every caller here needs to inspect a failed run's own output, not just
// get an exception. Inherits this server's own environment by default -
// gcc needs its normal PATH/env to find its own internal cc1 component;
// only the final execution of the user's compiled binary opts into a
// deliberately minimal env (see compileAndRun).
function run(file, args, opts) {
    return new Promise((resolve) => {
        execFile(file, args, {
            cwd: opts.cwd,
            timeout: opts.timeoutMs,
            killSignal: 'SIGKILL',
            maxBuffer: MAX_OUTPUT_BYTES,
            env: opts.env || process.env,
        }, (error, stdout, stderr) => {
            const timedOut = !!(error && error.killed && error.signal === 'SIGKILL');
            // A string error.code (e.g. "ENOENT") means the executable
            // itself couldn't be spawned at all - genuinely useful to
            // surface. A numeric error.code is just its exit code (an
            // ordinary nonzero exit, already reported below) and a
            // timeout is reported via `timedOut` - execFile's own
            // "Command failed: ..." wrapper text adds nothing in either
            // case, so it's suppressed rather than shown as if it were
            // the program's own stderr.
            const spawnError = error && typeof error.code === 'string';
            const errText = stderr || (spawnError ? String(error.message) : '');
            resolve({
                exitCode: error && typeof error.code === 'number' ? error.code : (error ? null : 0),
                timedOut,
                stdout: truncate(stdout),
                stderr: truncate(errText),
            });
        });
    });
}

// Pulls the compiler's own baked-in backtrace symbol table back out of
// the generated C (see codegen.d's generateBacktraceSymbolTable) - one
// entry per compiled function/method/constructor, exactly the data
// llpl_resolve_symbol uses for symbolized panic backtraces. Reading it
// straight out of the emitted `{ "name", (void*)CName, "file.llpl", N },`
// lines is far simpler than teaching the compiler a second, machine-
// readable output format just for this playground pane - the C *is*
// already that format, one entry per line.
const SYMBOL_ENTRY_RE =
    /\{\s*"((?:[^"\\]|\\.)*)",\s*\(void\*\)([A-Za-z_][A-Za-z0-9_]*),\s*"((?:[^"\\]|\\.)*)",\s*(-?\d+)\s*\}/g;

function unescapeCString(s) {
    return s.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
}

function extractSymbolTable(generatedC) {
    const tableMatch = generatedC.match(/LLPL_Symbol llpl_symbol_table\[\] = \{([\s\S]*?)\n\};/);
    if (!tableMatch) return [];
    const symbols = [];
    for (const m of tableMatch[1].matchAll(SYMBOL_ENTRY_RE)) {
        const file = unescapeCString(m[3]);
        // The full table also includes every prelude.llpl/generic-
        // instantiation function pulled in along the way (String,
        // HashMap<K,V>, Hashable/Comparable impls, ...) - real, but noisy
        // for a playground snippet whose own source is only ever
        // main.llpl; only what the user actually wrote is worth a table.
        if (file !== 'main.llpl') continue;
        symbols.push({
            name: unescapeCString(m[1]),
            cName: m[2],
            file,
            line: Number(m[4]),
        });
    }
    symbols.sort((a, b) => a.line - b.line);
    return symbols;
}

function truncate(s) {
    if (!s) return '';
    s = s.toString();
    if (s.length > MAX_OUTPUT_BYTES) {
        return s.slice(0, MAX_OUTPUT_BYTES) + '\n... (truncated)';
    }
    return s;
}

async function compileAndRun(source) {
    const workDir = await fs.mkdtemp(path.join(os.tmpdir(), 'llpl-playground-'));
    // Compiler/gcc error text quotes these by their real, ephemeral temp
    // path (e.g. "/tmp/llpl-playground-xyz/main.llpl:3:5") - meaningless
    // (and a little sensitive) to whoever's looking at the playground, so
    // it's rewritten back to the plain filename the editor pane implies.
    const hide = (s) => s ? s.split(workDir + path.sep).join('') : s;
    try {
        const srcPath = path.join(workDir, 'main.llpl');
        const cPath = path.join(workDir, 'main.c');
        const binPath = path.join(workDir, 'main.bin');

        await fs.writeFile(srcPath, source, 'utf8');

        const compile = await run(LLPL_BIN, [srcPath, '-o', cPath], {
            cwd: workDir,
            timeoutMs: COMPILE_TIMEOUT_MS,
        });
        const compileOk = compile.exitCode === 0 && fsSync.existsSync(cPath);
        if (!compileOk) {
            return {
                compile: {
                    ok: false,
                    stderr: hide(compile.stderr || compile.stdout),
                    timedOut: compile.timedOut,
                },
                generatedC: null,
                run: null,
            };
        }

        const generatedC = await fs.readFile(cPath, 'utf8');
        const symbols = extractSymbolTable(generatedC);

        const gcc = await run('gcc', [cPath, RUNTIME_C, '-I', RUNTIME_DIR, '-o', binPath], {
            cwd: workDir,
            timeoutMs: GCC_TIMEOUT_MS,
        });
        if (gcc.exitCode !== 0 || !fsSync.existsSync(binPath)) {
            return {
                compile: { ok: true, stderr: compile.stderr, timedOut: false },
                generatedC,
                symbols,
                run: { ran: false, gccError: hide(gcc.stderr || gcc.stdout), timedOut: gcc.timedOut },
            };
        }

        const exec = await run(binPath, [], {
            cwd: workDir,
            timeoutMs: RUN_TIMEOUT_MS,
            // Deliberately minimal environment for the executed program -
            // no inherited shell/session variables to leak.
            env: { PATH: process.env.PATH || '' },
        });

        return {
            compile: { ok: true, stderr: compile.stderr, timedOut: false },
            generatedC,
            symbols,
            run: {
                ran: true,
                stdout: exec.stdout,
                stderr: exec.stderr,
                exitCode: exec.exitCode,
                timedOut: exec.timedOut,
            },
        };
    } finally {
        await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
    }
}

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
};

async function serveStatic(req, res) {
    let reqPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (reqPath === '/') reqPath = '/index.html';
    const filePath = path.normalize(path.join(PUBLIC_DIR, reqPath));
    if (!filePath.startsWith(PUBLIC_DIR)) {
        res.writeHead(403);
        res.end('Forbidden');
        return;
    }
    try {
        const data = await fs.readFile(filePath);
        const ext = path.extname(filePath);
        res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
        res.end(data);
    } catch (e) {
        res.writeHead(404);
        res.end('Not found');
    }
}

async function readBody(req) {
    const chunks = [];
    let total = 0;
    for await (const chunk of req) {
        total += chunk.length;
        if (total > MAX_SOURCE_BYTES * 2) {
            throw new Error('request body too large');
        }
        chunks.push(chunk);
    }
    return Buffer.concat(chunks).toString('utf8');
}

const server = http.createServer(async (req, res) => {
    if (req.method === 'POST' && req.url === '/api/compile') {
        try {
            const body = await readBody(req);
            let source;
            try {
                source = JSON.parse(body).source;
            } catch (e) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid JSON body' }));
                return;
            }
            if (typeof source !== 'string' || source.length === 0) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Missing "source" string' }));
                return;
            }
            if (source.length > MAX_SOURCE_BYTES) {
                res.writeHead(413, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: `Source too large (max ${MAX_SOURCE_BYTES} bytes)` }));
                return;
            }
            const result = await compileAndRun(source);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(result));
        } catch (e) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: String(e && e.message || e) }));
        }
        return;
    }
    if (req.method === 'GET') {
        await serveStatic(req, res);
        return;
    }
    res.writeHead(405);
    res.end('Method not allowed');
});

server.listen(PORT, () => {
    console.log(`LLPL playground running at http://localhost:${PORT}`);
    console.log(`Using compiler: ${LLPL_BIN}`);
});
