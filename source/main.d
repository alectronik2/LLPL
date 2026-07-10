module main;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.getopt;
import core.stdc.stdlib : exit;
import lexer;
import parser;
import codegen;
import modules;
import errors;
import lspquery;

void main(string[] args) {
    string inputFile;
    string outputFile;
    bool verbose = false;
    string lspSymbolsFile;

    auto helpInfo = getopt(
        args,
        "o|output", "Output C file path", &outputFile,
        "v|verbose", "Verbose output", &verbose,
        "lsp-symbols", "Analyze <file> and dump diagnostics/symbols/usages as JSON (for editor tooling)",
            &lspSymbolsFile
    );

    if (lspSymbolsFile.length > 0) {
        runLspSymbols(lspSymbolsFile);
        return;
    }

    if (helpInfo.helpWanted || args.length < 2) {
        defaultGetoptPrinter("LLPL Compiler - Low Level Programming Language\n" ~
                           "Usage: llpl [options] <input.llpl>\n" ~
                           "Options:",
                           helpInfo.options);
        return;
    }

    inputFile = args[1];

    if (!exists(inputFile)) {
        stderr.writefln("Error: Input file '%s' not found", inputFile);
        return;
    }

    if (outputFile.length == 0) {
        outputFile = setExtension(inputFile, "c");
    }

    try {
        if (verbose) {
            writefln("Compiling %s...", inputFile);
        }

        // Resolve modules and dependencies (prelude.llpl first, if present)
        auto programs = resolveWithPrelude(inputFile);

        if (verbose) {
            writefln("Resolved %d modules", programs.length);
            foreach (prog; programs) {
                if (prog.modulePath.length > 0) {
                    writefln("  - %s", prog.modulePath);
                }
            }
        }

        // Code generation for all modules
        auto codegen = new CodeGenerator();
        string cCode = codegen.generateMultiple(programs);

        if (verbose) {
            writefln("Code generation complete");
        }

        // Write output
        std.file.write(outputFile, cCode);
        writefln("Successfully compiled to %s", outputFile);

    } catch (CompileError e) {
        stderr.write(formatCompileError(e));
        exit(1);
    } catch (Exception e) {
        stderr.writefln("error: %s", e.msg);
        exit(1);
    }
}
