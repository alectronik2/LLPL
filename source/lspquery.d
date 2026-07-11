module lspquery;

import std.json;
import std.stdio;
import lexer;
import parser;
import codegen;
import modules;
import errors;

// Backs `llpl --lsp-symbols <entry.llpl>`: runs the normal module-resolve +
// codegen pipeline (discarding the generated C - only its side effects
// matter here), then dumps everything an editor needs for diagnostics,
// completion, hover, go-to-definition and find-references as one JSON
// object on stdout:
//
//   { "diagnostics": [ {message, file, line, column} ],
//     "symbols":     [ {name, kind, file, line, column, signature} ],
//     "usages":      [ {name, file, line, column} ] }
//
// `symbols` is declaration sites (one per top-level function/class/struct/
// macro/global, plus one per class method/field with a dotted name like
// "Console_Screen.write"). `usages` is resolved reference sites - see
// CodeGenerator.recordUsage. An editor turns a cursor position into a
// symbol by finding the usage (or declaration) at that exact location,
// then looks that resolved name up in `symbols`.
//
// On a compile error, `diagnostics` gets one entry and `symbols`/`usages`
// are empty - there's no error-recovering parse here, so a currently-broken
// file temporarily has no completion/hover data, just the diagnostic
// explaining why (matching every other LLPL tool in this project, which
// also stop at the first CompileError rather than trying to recover).
void runLspSymbols(string entryFile) {
    JSONValue[] diagnostics;
    JSONValue[] symbolsJson;
    JSONValue[] usagesJson;

    try {
        auto programs = resolveWithPrelude(entryFile);

        auto gen = new CodeGenerator();
        gen.generateMultiple(programs);

        foreach (sym; gen.symbols()) {
            JSONValue j;
            j["name"] = sym.name;
            j["kind"] = sym.kind;
            j["file"] = sym.file;
            j["line"] = sym.line;
            j["column"] = sym.column;
            j["signature"] = sym.signature;
            symbolsJson ~= j;
        }

        foreach (u; gen.usages()) {
            JSONValue j;
            j["name"] = u.name;
            j["file"] = u.file;
            j["line"] = u.line;
            j["column"] = u.column;
            usagesJson ~= j;
        }
    } catch (CompileError e) {
        JSONValue j;
        j["message"] = e.msg;
        j["file"] = e.filePath;
        j["line"] = e.line;
        j["column"] = e.column;
        diagnostics ~= j;
    } catch (Exception e) {
        JSONValue j;
        j["message"] = e.msg;
        j["file"] = entryFile;
        j["line"] = 1;
        j["column"] = 1;
        diagnostics ~= j;
    }

    JSONValue result;
    result["diagnostics"] = diagnostics;
    result["symbols"] = symbolsJson;
    result["usages"] = usagesJson;

    writeln(result.toString());
}
