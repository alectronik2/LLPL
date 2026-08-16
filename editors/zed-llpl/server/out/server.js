"use strict";
// LLPL language server.
//
// This doesn't reimplement any part of the LLPL compiler - it shells out to
// the real `llpl` binary's `--lsp-symbols <file>` query mode (see
// source/lspquery.d), which runs the normal module-resolve + codegen
// pipeline and dumps everything as JSON:
//
//   { diagnostics: [{message, file, line, column}],
//     symbols:     [{name, kind, file, line, column, signature}],
//     usages:      [{name, file, line, column}],
//     locals:      [{name, type, file, line, column, scopeName, kind}] }
//
// `symbols` is declaration sites (functions, classes, structs, macros,
// globals, plus class methods/fields with dotted names like
// "Console_Screen.write"). `usages` is every resolved reference site the
// compiler's own name resolution walked past while generating C - which is
// what makes go-to-definition and find-references correct in a language
// with namespace-qualified and sibling-resolved names: the mangled name at
// a usage site (e.g. "HAL_outb" for an unqualified `outb(...)` call made
// from inside `namespace HAL`) is something only the compiler's resolver
// actually knows.
//
// Known limitations (see the exact spots below for why):
//  - Diagnostics/completion/hover/etc. update on open + ~400ms after you
//    stop typing (a temp file is analyzed, not live keystrokes streamed
//    into the compiler - there's no incremental/partial parse mode).
//  - A file with a syntax/type error currently has NO symbol data at all
//    until it's fixed (no error-recovering parse) - you still get the
//    diagnostic explaining why, just not completion/hover for that file
//    in the meantime.
//  - Member completion after `x.` uses compiler-reported local types when
//    `x` is a local/parameter, and namespace/enum-prefix filtering for
//    paths like `Console.Color.`. It still depends on the most recent
//    successful analysis of the current file.
//  - Go-to-definition/find-references highlight a short marker at the
//    target position rather than the full identifier: the compiler
//    reports where a name starts, not how long the source token was
//    (mangled names like "Console_Screen.write" don't map 1:1 back onto
//    what's actually written in the source).
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
const node_1 = require("vscode-languageserver/node");
const vscode_languageserver_textdocument_1 = require("vscode-languageserver-textdocument");
const child_process_1 = require("child_process");
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const url_1 = require("url");
const EMPTY_RESULT = { diagnostics: [], symbols: [], usages: [] };
const KEYWORDS = [
    'import', 'from', 'namespace', 'using', 'class', 'struct', 'union', 'packed', 'enum', 'macro',
    'constructor', 'destructor', 'func', 'inline', 'let', 'const', 'volatile', 'private', 'static', 'virtual',
    'override', 'if', 'else', 'while', 'do', 'for', 'foreach', 'in', 'with', 'return', 'continue', 'break', 'defer',
    'until', 'unless', 'try', 'catch', 'finally', 'throw', 'delete', 'assert', 'asm', 'new', 'true', 'false', 'null',
    'extern', 'as', 'match', 'case', 'default', 'alias', 'operator', 'trait', 'ui',
    'impl', 'quote', 'unquote', 'interrupt', 'property', 'unittest',
    'sizeof', 'self', 'super', 'int', 'uint', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32',
    'int64', 'uint64', 'u8', 'u16', 'u32', 'u64', 'i8', 'i16', 'i32', 'i64',
    'char', 'bool', 'void', 'float', 'string',
];
const UI_WIDGETS = [
    'Window', 'Column', 'Row', 'Panel', 'Card', 'Text', 'SelectableText',
    'Button', 'ProgressBar', 'Slider', 'Checkbox', 'Badge',
];
const UI_PROPERTIES = [
    'title', 'text', 'width', 'height', 'padding', 'spacing', 'preferred_height',
    'background', 'hover_background', 'foreground', 'hover_foreground', 'border',
    'hover_border', 'accent', 'track', 'selection', 'value', 'min_value',
    'max_value', 'checked', 'selectable', 'onClick', 'onHover', 'onHoverEnd',
];
const UI_METHODS = [
    'build', 'run', 'is_valid', 'apply_dark_theme', 'apply_light_theme',
    'add_child', 'render',
];
const connection = (0, node_1.createConnection)(node_1.ProposedFeatures.all);
const documents = new node_1.TextDocuments(vscode_languageserver_textdocument_1.TextDocument);
let compilerPath = 'llpl';
// entryPath (the real, on-disk path used as the analysis entry point) -> its
// most recent analysis. Completion/hover/definition/references search the
// union of every cached result, so a project stays fully navigable as long
// as at least one of its files has been analyzed this session - and since
// each analysis already includes everything that file transitively
// imports, opening just the entry point of a program is usually enough.
const cache = new Map();
const debounceTimers = new Map();
// Walks up from `startDir` looking for an executable file literally named
// `llpl` (`llpl.exe` on Windows, tried first since that's what `dub build`
// actually produces there) - the layout this extension ships in:
// editors/vscode-llpl/server under a checkout that builds the compiler to
// its repo root. Falls back to bare "llpl"/"llpl.exe", relying on PATH, if
// that search comes up empty.
function findCompiler(startDir) {
    const names = process.platform === 'win32' ? ['llpl.exe', 'llpl'] : ['llpl'];
    let dir = startDir;
    for (let i = 0; i < 12; i++) {
        for (const name of names) {
            const candidate = path.join(dir, name);
            if (fs.existsSync(candidate)) {
                try {
                    fs.accessSync(candidate, fs.constants.X_OK);
                    return candidate;
                }
                catch {
                    // Exists but isn't executable - keep looking upward.
                }
            }
        }
        const parent = path.dirname(dir);
        if (parent === dir)
            break;
        dir = parent;
    }
    return process.platform === 'win32' ? 'llpl.exe' : 'llpl';
}
function runQuery(entryPath) {
    return new Promise((resolve) => {
        (0, child_process_1.execFile)(compilerPath, ['--lsp-symbols', entryPath], { maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => {
            if (err && !stdout) {
                connection.console.error(`llpl --lsp-symbols failed: ${err.message}`);
                resolve(EMPTY_RESULT);
                return;
            }
            try {
                resolve(JSON.parse(stdout));
            }
            catch {
                resolve(EMPTY_RESULT);
            }
        });
    });
}
function toDiagnostic(d) {
    const line = Math.max(0, d.line - 1);
    const col = Math.max(0, d.column - 1);
    return {
        severity: node_1.DiagnosticSeverity.Error,
        range: { start: { line, character: col }, end: { line, character: col + 1 } },
        message: d.message,
        source: 'llpl',
    };
}
// realPath -> the document version its analysis was started for, so a
// slower-to-resolve analyze() from an older edit can't clobber the cache
// after a newer one has already landed - see the version check below.
const latestRequested = new Map();
// Analyzes `document` by writing its *live editor buffer* (not what's on
// disk) to a sibling temp file and running the compiler on that, so
// diagnostics/completion reflect what you're currently typing rather than
// lagging behind your last save. The temp file lives next to the real one
// so relative `import`s from it still resolve. Every reference to the temp
// file's path in the result is rewritten back to the real document's path
// afterward; everything else (its imports) is analyzed as last saved.
async function analyze(document) {
    const realPath = (0, url_1.fileURLToPath)(document.uri);
    const myVersion = document.version;
    latestRequested.set(realPath, myVersion);
    const dir = path.dirname(realPath);
    const tmpPath = path.join(dir, `.llpl-lsp-${process.pid}-${Date.now()}.llpl`);
    fs.writeFileSync(tmpPath, document.getText());
    let result;
    try {
        result = await runQuery(tmpPath);
    }
    finally {
        fs.unlink(tmpPath, () => { });
    }
    // A newer edit was analyzed (and possibly already finished) while this
    // request for an older snapshot was still in flight - drop it rather
    // than let it overwrite the cache with stale data.
    if (latestRequested.get(realPath) !== myVersion)
        return;
    const patch = (file) => (file === tmpPath ? realPath : file);
    result.diagnostics.forEach((d) => { d.file = patch(d.file); });
    result.symbols.forEach((s) => { s.file = patch(s.file); });
    result.usages.forEach((u) => { u.file = patch(u.file); });
    (result.locals || []).forEach((local) => { local.file = patch(local.file); });
    cache.set(realPath, result);
    const diagnostics = result.diagnostics
        .filter((d) => d.file === realPath)
        .map(toDiagnostic);
    connection.sendDiagnostics({ uri: document.uri, diagnostics });
}
function allSymbols() {
    const seen = new Map();
    for (const result of cache.values()) {
        for (const s of result.symbols) {
            seen.set(`${s.name}\0${s.file}\0${s.line}\0${s.column}`, s);
        }
    }
    return [...seen.values()];
}
function allUsages() {
    const usages = [];
    for (const result of cache.values())
        usages.push(...result.usages);
    return usages;
}
function allLocals() {
    const locals = [];
    for (const result of cache.values())
        locals.push(...(result.locals || []));
    return locals;
}
// Finds the resolved symbol name under (file, 1-based line/column): first
// checks whether the position falls at-or-after a recorded usage on that
// line (covering namespace-qualified/sibling-resolved references, where
// the mangled name differs from the raw source text - see the module
// comment), then falls back to a declaration site on that line. The `<=64`
// slack bounds how far right of a usage's start column still counts as
// "on" it, since the compiler doesn't report token lengths.
function resolveAt(file, line, column) {
    let best = null;
    for (const u of allUsages()) {
        if (u.file !== file || u.line !== line || u.column > column)
            continue;
        if (!best || u.column > best.column)
            best = u;
    }
    if (best && column - best.column <= 64)
        return best.name;
    for (const s of allSymbols()) {
        if (s.file === file && s.line === line && Math.abs(s.column - column) <= 64) {
            return s.name;
        }
    }
    return null;
}
function toLocation(file, line, column) {
    const start = { line: Math.max(0, line - 1), character: Math.max(0, column - 1) };
    return {
        uri: (0, url_1.pathToFileURL)(file).toString(),
        range: { start, end: { line: start.line, character: start.character + 1 } },
    };
}
function kindToCompletionKind(kind) {
    switch (kind) {
        case 'function': return node_1.CompletionItemKind.Function;
        case 'method': return node_1.CompletionItemKind.Method;
        case 'class': return node_1.CompletionItemKind.Class;
        case 'struct': return node_1.CompletionItemKind.Struct;
        case 'union': return node_1.CompletionItemKind.Struct;
        case 'macro': return node_1.CompletionItemKind.Snippet;
        case 'field': return node_1.CompletionItemKind.Field;
        case 'variable': return node_1.CompletionItemKind.Variable;
        case 'trait': return node_1.CompletionItemKind.Interface;
        default: return node_1.CompletionItemKind.Text;
    }
}
connection.onInitialize((params) => {
    const configured = params.initializationOptions?.compilerPath;
    if (configured) {
        compilerPath = configured;
    }
    else {
        const folders = params.workspaceFolders;
        const startDir = folders && folders.length > 0
            ? (0, url_1.fileURLToPath)(folders[0].uri)
            : (params.rootUri ? (0, url_1.fileURLToPath)(params.rootUri) : process.cwd());
        compilerPath = findCompiler(startDir);
    }
    connection.console.log(`llpl compiler: ${compilerPath}`);
    return {
        capabilities: {
            textDocumentSync: node_1.TextDocumentSyncKind.Incremental,
            completionProvider: { triggerCharacters: ['.'] },
            hoverProvider: true,
            definitionProvider: true,
            referencesProvider: true,
        },
    };
});
documents.onDidOpen((change) => {
    void analyze(change.document);
});
documents.onDidChangeContent((change) => {
    const uri = change.document.uri;
    const existing = debounceTimers.get(uri);
    if (existing)
        clearTimeout(existing);
    debounceTimers.set(uri, setTimeout(() => {
        debounceTimers.delete(uri);
        void analyze(change.document);
    }, 400));
});
documents.onDidClose((change) => {
    const uri = change.document.uri;
    const existing = debounceTimers.get(uri);
    if (existing)
        clearTimeout(existing);
    debounceTimers.delete(uri);
});
connection.onHover((params) => {
    const realPath = (0, url_1.fileURLToPath)(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name)
        return null;
    const sym = allSymbols().find((s) => s.name === name);
    if (!sym) {
        const local = allLocals().find((l) => l.file === realPath && l.name === name);
        if (!local)
            return null;
        return {
            contents: {
                kind: node_1.MarkupKind.Markdown,
                value: `\`\`\`llpl\n${local.kind} ${local.name}: ${local.type}\n\`\`\`\n\n*${local.scopeName}* - ${path.basename(local.file)}:${local.line}`,
            },
        };
    }
    return {
        contents: {
            kind: node_1.MarkupKind.Markdown,
            value: `\`\`\`llpl\n${sym.signature}\n\`\`\`\n\n*${sym.kind}* - ${path.basename(sym.file)}:${sym.line}`,
        },
    };
});
connection.onDefinition((params) => {
    const realPath = (0, url_1.fileURLToPath)(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name)
        return null;
    const sym = allSymbols().find((s) => s.name === name);
    return sym ? toLocation(sym.file, sym.line, sym.column) : null;
});
connection.onReferences((params) => {
    const realPath = (0, url_1.fileURLToPath)(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name)
        return [];
    const locations = allUsages()
        .filter((u) => u.name === name)
        .map((u) => toLocation(u.file, u.line, u.column));
    if (params.context.includeDeclaration) {
        const sym = allSymbols().find((s) => s.name === name);
        if (sym)
            locations.push(toLocation(sym.file, sym.line, sym.column));
    }
    return locations;
});
connection.onCompletion((params) => {
    const doc = documents.get(params.textDocument.uri);
    const items = [];
    // If completion was triggered right after `Ns.Sub.`, only offer symbols
    // mangled under that prefix (e.g. "Console.Color." -> "Console_Color_*").
    // See the module comment for why this doesn't extend to instance
    // variables like `screen.`.
    let dotPrefix = null;
    if (doc) {
        const line = doc.getText({
            start: { line: params.position.line, character: 0 },
            end: params.position,
        });
        const m = /([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\.\s*$/.exec(line);
        if (m)
            dotPrefix = m[1].replace(/\./g, '_');
    }
    if (dotPrefix) {
        const realPath = (0, url_1.fileURLToPath)(params.textDocument.uri);
        const local = allLocals().find((l) => l.file === realPath && l.name === dotPrefix);
        if (local) {
            const typePrefix = local.type.replace(/\*/g, '').replace(/\[\]$/, '');
            for (const s of allSymbols()) {
                if (!s.name.startsWith(typePrefix + '.'))
                    continue;
                items.push({
                    label: s.name.slice(typePrefix.length + 1),
                    kind: kindToCompletionKind(s.kind),
                    detail: s.signature,
                });
            }
            return items;
        }
    }
    for (const s of allSymbols()) {
        let label = s.name.includes('.') ? s.name.split('.').pop() : s.name;
        if (dotPrefix) {
            // Strip the typed prefix (plus its joining "_" or ".") so the
            // inserted text is just what's left to type, e.g. "RED" after
            // "Console.Color." rather than the full mangled "Console_Color_RED".
            if (s.name.startsWith(dotPrefix + '_') || s.name.startsWith(dotPrefix + '.')) {
                label = s.name.slice(dotPrefix.length + 1);
            }
            else {
                continue;
            }
        }
        items.push({
            label,
            kind: kindToCompletionKind(s.kind),
            detail: s.signature,
        });
    }
    if (!dotPrefix) {
        for (const kw of KEYWORDS) {
            items.push({ label: kw, kind: node_1.CompletionItemKind.Keyword });
        }
        for (const widget of UI_WIDGETS) {
            items.push({
                label: widget,
                kind: node_1.CompletionItemKind.Class,
                detail: `std.ui ${widget} widget`,
            });
        }
        for (const prop of UI_PROPERTIES) {
            items.push({
                label: prop,
                kind: node_1.CompletionItemKind.Property,
                detail: 'std.ui widget property',
            });
        }
        for (const method of UI_METHODS) {
            items.push({
                label: method,
                kind: node_1.CompletionItemKind.Method,
                detail: 'std.ui helper method',
            });
        }
        const realPath = (0, url_1.fileURLToPath)(params.textDocument.uri);
        for (const local of allLocals().filter((l) => l.file === realPath)) {
            items.push({
                label: local.name,
                kind: node_1.CompletionItemKind.Variable,
                detail: `${local.kind}: ${local.type}`,
            });
        }
    }
    return items;
});
documents.listen(connection);
connection.listen();
//# sourceMappingURL=server.js.map