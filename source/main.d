module main;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.getopt;
import std.process : execute, environment;
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
    bool binaryMode = false;
    string ccOverride;
    bool keepC = false;
    string lspSymbolsFile;
    bool safeMode = false;
    bool enableDCE = true;

    auto helpInfo = getopt(
        args,
        "o|output", "Output file path (a .c source file, or - with -b/--binary - a native binary)",
            &outputFile,
        "b|binary", "Compile directly to a native binary instead of emitting C source " ~
            "(invokes a system C compiler - see --cc)", &binaryMode,
        "cc", "C compiler to invoke in --binary mode (default: $CC, falling back to \"cc\")",
            &ccOverride,
        "keep-c", "Keep the intermediate .c file in --binary mode even on a successful build",
            &keepC,
        "v|verbose", "Verbose output", &verbose,
        "safe", "Enable runtime safety checks (currently: bounds-check fixed-size array indexing)",
            &safeMode,
        "dce", "Enable dead-code elimination (default: true)", &enableDCE,
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
        outputFile = binaryMode ? stripExtension(inputFile) : setExtension(inputFile, "c");
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
        auto codegen = new CodeGenerator(safeMode, enableDCE);
        string cCode = codegen.generateMultiple(programs);

        if (verbose) {
            writefln("Code generation complete");
        }

        if (binaryMode) {
            compileToBinary(cCode, outputFile, ccOverride, keepC, verbose,
                codegen.linkLibraries, codegen.compilerFlags);
        } else {
            std.file.write(outputFile, cCode);
            writefln("Successfully compiled to %s", outputFile);
            if (codegen.linkLibraries.length > 0 || codegen.compilerFlags.length > 0) {
                string linkFlags = codegen.linkLibraries.map!(lib => "-l" ~ lib).join(" ");
                string extraFlags = codegen.compilerFlags.join(" ");
                string allFlags = [extraFlags, linkFlags].filter!(s => s.length > 0).join(" ");
                writefln("Note: this program requires: %s (e.g. `cc %s runtime/runtime.c %s -o <output>`)",
                    allFlags, outputFile, allFlags);
            }
        }

    } catch (MultiCompileError e) {
        foreach (i, err; e.errors) {
            if (i > 0) stderr.writeln();
            stderr.write(formatCompileError(err));
        }
        exit(1);
    } catch (CompileError e) {
        stderr.write(formatCompileError(e));
        exit(1);
    } catch (Exception e) {
        stderr.writefln("error: %s", e.msg);
        exit(1);
    }
}

// Compiles generated C `cCode` straight down to a native binary at
// `outputFile`, by writing it to `<outputFile>.c` and invoking a system C
// compiler against it plus runtime/runtime.c - the same two-step workflow
// (`llpl foo.llpl -o foo.c` then `cc foo.c runtime/runtime.c -o foo`)
// every hosted example in this repo already uses by hand, just automated
// into one step. Scoped to ordinary hosted programs: a freestanding/kernel
// target (see examples/baremetal_demo) needs its own linker script, boot
// assembly, and `-ffreestanding`-style flags this has no way to know
// about, so --binary isn't meant for those - use the Makefile-based
// two-step build there instead.
private void compileToBinary(string cCode, string outputFile, string ccOverride, bool keepC, bool verbose,
        string[] linkLibraries, string[] compilerFlags) {
    string runtimeDir = buildNormalizedPath(dirName(thisExePath()), "runtime");
    string runtimeC = buildNormalizedPath(runtimeDir, "runtime.c");
    string runtimeH = buildNormalizedPath(runtimeDir, "runtime.h");
    if (!exists(runtimeC) || !exists(runtimeH)) {
        stderr.writefln("error: --binary needs runtime/runtime.c and runtime/runtime.h next to " ~
            "the llpl binary (looked in %s) - found neither there", runtimeDir);
        exit(1);
    }

    string cFile = outputFile ~ ".c";
    std.file.write(cFile, cCode);

    string cc = ccOverride.length > 0 ? ccOverride : environment.get("CC", "cc");
    // Plain C `char` signedness is implementation-defined (signed by
    // default on most x86 targets); this compiler's own type-checking
    // (isSignedIntegerType in codegen.d) treats `char` as unsigned, so the
    // generated C needs to match that at the actual C-compiler level too,
    // not just at the LLPL level - otherwise e.g. a `char` byte value above
    // 127 round-trips as negative in the compiled binary despite LLPL's own
    // rules saying it shouldn't.
    string[] cmd = [cc, cFile, runtimeC, "-I", runtimeDir, "-funsigned-char"];
    // `#flags "..."` directives (see ast.d's FlagsDecl) - split on
    // whitespace since execute() takes an argv array, not a shell string;
    // a single "-O2 -Wall" entry passed through whole would otherwise be
    // handed to the C compiler as one literal argument containing a space.
    foreach (flagsStr; compilerFlags) {
        foreach (flag; flagsStr.split()) {
            cmd ~= flag;
        }
    }
    // `#link "NAME"` directives (see ast.d's LinkDecl) - collected by the
    // code generator, surfaced here so `--binary` doesn't need every
    // caller to already know a program like the SDL bindings needs -lSDL3.
    foreach (lib; linkLibraries) {
        cmd ~= "-l" ~ lib;
    }
    cmd ~= ["-o", outputFile];

    if (verbose) {
        writefln("Running: %s", cmd.join(" "));
    }

    auto result = execute(cmd);
    if (result.status != 0) {
        stderr.writefln("error: %s failed to compile the generated C code (exit %d):", cc, result.status);
        stderr.writeln(result.output);
        stderr.writefln("(kept the intermediate C file at %s for inspection)", cFile);
        exit(1);
    }

    if (keepC || verbose) {
        writefln("(kept intermediate C file at %s)", cFile);
    } else {
        std.file.remove(cFile);
    }

    writefln("Successfully compiled to %s", outputFile);
}
