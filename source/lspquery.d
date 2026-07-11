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
// `diagnostics` can carry more than one entry now - codegen.d collects a
// CompileError per top-level declaration that failed (see its
// collectedErrors/MultiCompileError) instead of stopping at the first one,
// so an editor can show every independent error in the file at once, not
// just the first. `symbols`/`usages` are still populated from whatever
// *did* generate cleanly even when there are errors elsewhere (`gen` is
// constructed outside the try block specifically so it's still reachable
// after a caught exception) - there's still no statement-level error
// recovery within a single declaration, so a badly-broken one still
// contributes nothing beyond its own diagnostic.
void runLspSymbols(string entryFile) {
    JSONValue[] diagnostics;
    JSONValue[] symbolsJson;
    JSONValue[] usagesJson;

    auto gen = new CodeGenerator();
    try {
        auto programs = resolveWithPrelude(entryFile);
        gen.generateMultiple(programs);
    } catch (MultiCompileError e) {
        foreach (err; e.errors) {
            JSONValue j;
            j["message"] = err.msg;
            j["file"] = err.filePath;
            j["line"] = err.line;
            j["column"] = err.column;
            diagnostics ~= j;
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

    JSONValue result;
    result["diagnostics"] = diagnostics;
    result["symbols"] = symbolsJson;
    result["usages"] = usagesJson;

    writeln(result.toString());
}
