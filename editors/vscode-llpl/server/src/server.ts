// LLPL language server.
//
// This doesn't reimplement any part of the LLPL compiler - it shells out to
// the real `llpl` binary's `--lsp-symbols <file>` query mode (see
// source/lspquery.d), which runs the normal module-resolve + codegen
// pipeline and dumps everything as JSON:
//
//   { diagnostics: [{message, file, line, column}],
//     symbols:     [{name, kind, file, line, column, signature}],
//     usages:      [{name, file, line, column}] }
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
//  - Member completion after `x.` only works when `x` is itself a
//    namespace/enum path (e.g. `Console.Color.`) - it can't yet filter to
//    an instance variable's own type's methods/fields (e.g. `screen.`),
//    since local variable types aren't part of the JSON the compiler
//    currently exposes.
//  - Go-to-definition/find-references highlight a short marker at the
//    target position rather than the full identifier: the compiler
//    reports where a name starts, not how long the source token was
//    (mangled names like "Console_Screen.write" don't map 1:1 back onto
//    what's actually written in the source).

import {
    createConnection,
    TextDocuments,
    ProposedFeatures,
    InitializeParams,
    TextDocumentSyncKind,
    InitializeResult,
    Diagnostic,
    DiagnosticSeverity,
    CompletionItem,
    CompletionItemKind,
    Hover,
    Location,
    MarkupKind,
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';
import { execFile } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

interface SymbolInfo {
    name: string;
    kind: string;
    file: string;
    line: number;
    column: number;
    signature: string;
}

interface UsageInfo {
    name: string;
    file: string;
    line: number;
    column: number;
}

interface DiagnosticInfo {
    message: string;
    file: string;
    line: number;
    column: number;
}

interface AnalysisResult {
    diagnostics: DiagnosticInfo[];
    symbols: SymbolInfo[];
    usages: UsageInfo[];
}

const EMPTY_RESULT: AnalysisResult = { diagnostics: [], symbols: [], usages: [] };

const KEYWORDS = [
    'import', 'from', 'namespace', 'class', 'struct', 'packed', 'enum', 'macro',
    'constructor', 'destructor', 'func', 'let', 'const', 'volatile', 'private', 'if',
    'else', 'while', 'for', 'foreach', 'in', 'return', 'defer', 'unless',
    'try', 'catch', 'finally', 'throw', 'delete', 'asm', 'new', 'true', 'false', 'null',
    'extern', 'as', 'match', 'case', 'default', 'alias', 'operator', 'trait',
    'impl', 'quote', 'unquote', 'interrupt',
    'sizeof', 'self', 'int', 'uint', 'int16', 'uint16', 'int32', 'uint32',
    'char', 'bool', 'void',
];

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

let compilerPath = 'llpl';

// entryPath (the real, on-disk path used as the analysis entry point) -> its
// most recent analysis. Completion/hover/definition/references search the
// union of every cached result, so a project stays fully navigable as long
// as at least one of its files has been analyzed this session - and since
// each analysis already includes everything that file transitively
// imports, opening just the entry point of a program is usually enough.
const cache = new Map<string, AnalysisResult>();
const debounceTimers = new Map<string, ReturnType<typeof setTimeout>>();

// Walks up from `startDir` looking for an executable file literally named
// `llpl` (`llpl.exe` on Windows, tried first since that's what `dub build`
// actually produces there) - the layout this extension ships in:
// editors/vscode-llpl/server under a checkout that builds the compiler to
// its repo root. Falls back to bare "llpl"/"llpl.exe", relying on PATH, if
// that search comes up empty.
function findCompiler(startDir: string): string {
    const names = process.platform === 'win32' ? ['llpl.exe', 'llpl'] : ['llpl'];
    let dir = startDir;
    for (let i = 0; i < 12; i++) {
        for (const name of names) {
            const candidate = path.join(dir, name);
            if (fs.existsSync(candidate)) {
                try {
                    fs.accessSync(candidate, fs.constants.X_OK);
                    return candidate;
                } catch {
                    // Exists but isn't executable - keep looking upward.
                }
            }
        }
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
    }
    return process.platform === 'win32' ? 'llpl.exe' : 'llpl';
}

function runQuery(entryPath: string): Promise<AnalysisResult> {
    return new Promise((resolve) => {
        execFile(compilerPath, ['--lsp-symbols', entryPath], { maxBuffer: 64 * 1024 * 1024 },
            (err, stdout) => {
                if (err && !stdout) {
                    connection.console.error(`llpl --lsp-symbols failed: ${err.message}`);
                    resolve(EMPTY_RESULT);
                    return;
                }
                try {
                    resolve(JSON.parse(stdout) as AnalysisResult);
                } catch {
                    resolve(EMPTY_RESULT);
                }
            });
    });
}

function toDiagnostic(d: DiagnosticInfo): Diagnostic {
    const line = Math.max(0, d.line - 1);
    const col = Math.max(0, d.column - 1);
    return {
        severity: DiagnosticSeverity.Error,
        range: { start: { line, character: col }, end: { line, character: col + 1 } },
        message: d.message,
        source: 'llpl',
    };
}

// realPath -> the document version its analysis was started for, so a
// slower-to-resolve analyze() from an older edit can't clobber the cache
// after a newer one has already landed - see the version check below.
const latestRequested = new Map<string, number>();

// Analyzes `document` by writing its *live editor buffer* (not what's on
// disk) to a sibling temp file and running the compiler on that, so
// diagnostics/completion reflect what you're currently typing rather than
// lagging behind your last save. The temp file lives next to the real one
// so relative `import`s from it still resolve. Every reference to the temp
// file's path in the result is rewritten back to the real document's path
// afterward; everything else (its imports) is analyzed as last saved.
async function analyze(document: TextDocument): Promise<void> {
    const realPath = fileURLToPath(document.uri);
    const myVersion = document.version;
    latestRequested.set(realPath, myVersion);

    const dir = path.dirname(realPath);
    const tmpPath = path.join(dir, `.llpl-lsp-${process.pid}-${Date.now()}.llpl`);

    fs.writeFileSync(tmpPath, document.getText());
    let result: AnalysisResult;
    try {
        result = await runQuery(tmpPath);
    } finally {
        fs.unlink(tmpPath, () => { /* best-effort cleanup */ });
    }

    // A newer edit was analyzed (and possibly already finished) while this
    // request for an older snapshot was still in flight - drop it rather
    // than let it overwrite the cache with stale data.
    if (latestRequested.get(realPath) !== myVersion) return;

    const patch = (file: string) => (file === tmpPath ? realPath : file);
    result.diagnostics.forEach((d) => { d.file = patch(d.file); });
    result.symbols.forEach((s) => { s.file = patch(s.file); });
    result.usages.forEach((u) => { u.file = patch(u.file); });

    cache.set(realPath, result);

    const diagnostics = result.diagnostics
        .filter((d) => d.file === realPath)
        .map(toDiagnostic);
    connection.sendDiagnostics({ uri: document.uri, diagnostics });
}

function allSymbols(): SymbolInfo[] {
    const seen = new Map<string, SymbolInfo>();
    for (const result of cache.values()) {
        for (const s of result.symbols) {
            seen.set(`${s.name}\0${s.file}\0${s.line}\0${s.column}`, s);
        }
    }
    return [...seen.values()];
}

function allUsages(): UsageInfo[] {
    const usages: UsageInfo[] = [];
    for (const result of cache.values()) usages.push(...result.usages);
    return usages;
}

// Finds the resolved symbol name under (file, 1-based line/column): first
// checks whether the position falls at-or-after a recorded usage on that
// line (covering namespace-qualified/sibling-resolved references, where
// the mangled name differs from the raw source text - see the module
// comment), then falls back to a declaration site on that line. The `<=64`
// slack bounds how far right of a usage's start column still counts as
// "on" it, since the compiler doesn't report token lengths.
function resolveAt(file: string, line: number, column: number): string | null {
    let best: UsageInfo | null = null;
    for (const u of allUsages()) {
        if (u.file !== file || u.line !== line || u.column > column) continue;
        if (!best || u.column > best.column) best = u;
    }
    if (best && column - best.column <= 64) return best.name;

    for (const s of allSymbols()) {
        if (s.file === file && s.line === line && Math.abs(s.column - column) <= 64) {
            return s.name;
        }
    }
    return null;
}

function toLocation(file: string, line: number, column: number): Location {
    const start = { line: Math.max(0, line - 1), character: Math.max(0, column - 1) };
    return {
        uri: pathToFileURL(file).toString(),
        range: { start, end: { line: start.line, character: start.character + 1 } },
    };
}

function kindToCompletionKind(kind: string): CompletionItemKind {
    switch (kind) {
        case 'function': return CompletionItemKind.Function;
        case 'method': return CompletionItemKind.Method;
        case 'class': return CompletionItemKind.Class;
        case 'struct': return CompletionItemKind.Struct;
        case 'macro': return CompletionItemKind.Snippet;
        case 'field': return CompletionItemKind.Field;
        case 'variable': return CompletionItemKind.Variable;
        case 'trait': return CompletionItemKind.Interface;
        default: return CompletionItemKind.Text;
    }
}

connection.onInitialize((params: InitializeParams): InitializeResult => {
    const configured = (params.initializationOptions as { compilerPath?: string } | undefined)?.compilerPath;
    if (configured) {
        compilerPath = configured;
    } else {
        const folders = params.workspaceFolders;
        const startDir = folders && folders.length > 0
            ? fileURLToPath(folders[0].uri)
            : (params.rootUri ? fileURLToPath(params.rootUri) : process.cwd());
        compilerPath = findCompiler(startDir);
    }
    connection.console.log(`llpl compiler: ${compilerPath}`);

    return {
        capabilities: {
            textDocumentSync: TextDocumentSyncKind.Incremental,
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
    if (existing) clearTimeout(existing);
    debounceTimers.set(uri, setTimeout(() => {
        debounceTimers.delete(uri);
        void analyze(change.document);
    }, 400));
});

documents.onDidClose((change) => {
    const uri = change.document.uri;
    const existing = debounceTimers.get(uri);
    if (existing) clearTimeout(existing);
    debounceTimers.delete(uri);
});

connection.onHover((params): Hover | null => {
    const realPath = fileURLToPath(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name) return null;
    const sym = allSymbols().find((s) => s.name === name);
    if (!sym) return null;
    return {
        contents: {
            kind: MarkupKind.Markdown,
            value: `\`\`\`llpl\n${sym.signature}\n\`\`\`\n\n*${sym.kind}* - ${path.basename(sym.file)}:${sym.line}`,
        },
    };
});

connection.onDefinition((params): Location | null => {
    const realPath = fileURLToPath(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name) return null;
    const sym = allSymbols().find((s) => s.name === name);
    return sym ? toLocation(sym.file, sym.line, sym.column) : null;
});

connection.onReferences((params): Location[] => {
    const realPath = fileURLToPath(params.textDocument.uri);
    const name = resolveAt(realPath, params.position.line + 1, params.position.character + 1);
    if (!name) return [];

    const locations = allUsages()
        .filter((u) => u.name === name)
        .map((u) => toLocation(u.file, u.line, u.column));

    if (params.context.includeDeclaration) {
        const sym = allSymbols().find((s) => s.name === name);
        if (sym) locations.push(toLocation(sym.file, sym.line, sym.column));
    }

    return locations;
});

connection.onCompletion((params): CompletionItem[] => {
    const doc = documents.get(params.textDocument.uri);
    const items: CompletionItem[] = [];

    // If completion was triggered right after `Ns.Sub.`, only offer symbols
    // mangled under that prefix (e.g. "Console.Color." -> "Console_Color_*").
    // See the module comment for why this doesn't extend to instance
    // variables like `screen.`.
    let dotPrefix: string | null = null;
    if (doc) {
        const line = doc.getText({
            start: { line: params.position.line, character: 0 },
            end: params.position,
        });
        const m = /([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\.\s*$/.exec(line);
        if (m) dotPrefix = m[1].replace(/\./g, '_');
    }

    for (const s of allSymbols()) {
        let label = s.name.includes('.') ? s.name.split('.').pop()! : s.name;
        if (dotPrefix) {
            // Strip the typed prefix (plus its joining "_" or ".") so the
            // inserted text is just what's left to type, e.g. "RED" after
            // "Console.Color." rather than the full mangled "Console_Color_RED".
            if (s.name.startsWith(dotPrefix + '_') || s.name.startsWith(dotPrefix + '.')) {
                label = s.name.slice(dotPrefix.length + 1);
            } else {
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
            items.push({ label: kw, kind: CompletionItemKind.Keyword });
        }
    }

    return items;
});

documents.listen(connection);
connection.listen();
