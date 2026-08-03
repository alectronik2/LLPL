module main;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.conv;
import std.format;
import std.string : splitLines, startsWith, indexOf, lastIndexOf, replace, strip;
import std.getopt;
import std.process : execute, environment;
import std.datetime.stopwatch;
import std.datetime.systime : Clock;
import core.stdc.stdlib : exit;
import lexer;
import parser;
import codegen;
import modules;
import errors;
import lspquery;
import astprint;
import comptime;

void main(string[] args) {
    bool auditMode = false;
    bool runMode = false;
    string[] runArgs;
    bool outputWasExplicit = false;
    if (args.length >= 2 && args[1] == "run") {
        runMode = true;
        size_t separator = args.length;
        foreach (i, arg; args) {
            if (i > 1 && arg == "--") {
                separator = i;
                break;
            }
        }
        if (separator < args.length) {
            runArgs = args[separator + 1 .. $];
            args = args[0 .. 1] ~ args[2 .. separator];
        } else {
            args = args[0 .. 1] ~ args[2 .. $];
        }
    }
    if (args.length >= 2 && args[1] == "audit") {
        auditMode = true;
        args = args[0 .. 1] ~ args[2 .. $];
    }

    string inputFile;
    string outputFile;
    bool verbose = false;
    bool binaryMode = false;
    string ccOverride;
    bool keepC = false;
    string lspSymbolsFile;
    bool safeMode = true;
    bool noSafeMode = false;
    bool enableDCE = true;
    bool enableUnitTests = false;
    string unitTestExpectedFile;
    string targetProfile;
    string provenanceFile;
    string effectsFile;
    string debugBundleDir;
    string auditDir;
    string diagnosticsJsonFile;
    bool emitAst = false;

    auto helpInfo = getopt(
        args,
        "o|output", "Output file path (a .c source file, or - with -b/--binary - a native binary)",
            &outputFile,
        "b|binary", "Compile directly to a native binary instead of emitting C source " ~
            "(invokes a system C compiler - see --cc)", &binaryMode,
        "cc", "C compiler to invoke in --binary mode (default: $CC, falling back to \"tcc\")",
            &ccOverride,
        "keep-c", "Keep the intermediate .c file in --binary mode even on a successful build",
            &keepC,
        "v|verbose", "Verbose output", &verbose,
        "safe", "Enable runtime safety checks (default: on; accepted for compatibility)",
            &safeMode,
        "no-safe", "Disable default runtime safety checks",
            &noSafeMode,
        "target", "Target profile: hosted, freestanding, or kernel (default: hosted)",
            &targetProfile,
        "dce", "Enable dead-code elimination (default: true)", &enableDCE,
        "unittest", "Compile unittest { ... } blocks and generate a test main",
            &enableUnitTests,
        "unittest-expected", "Compare --unittest stdout against this file (default: <input>.unittest.expected if present)",
            &unitTestExpectedFile,
        "lsp-symbols", "Analyze <file> and dump diagnostics/symbols/usages as JSON (for editor tooling)",
            &lspSymbolsFile,
        "diagnostics-json", "Write machine-readable diagnostics JSON to <file> on compiler errors",
            &diagnosticsJsonFile,
        "emit-ast", "Parse <input.llpl> and emit a canonical AST golden-test dump",
            &emitAst,
        "emit-provenance", "Write generated-C to LLPL source provenance JSON to <file>",
            &provenanceFile,
        "emit-effects", "Write conservative per-function capability/effect JSON to <file>",
            &effectsFile,
        "debug-bundle", "Write generated C, provenance, symbols/usages, and manifest artifacts to <dir>",
            &debugBundleDir,
        "audit-dir", "Directory for `llpl audit` artifacts (default: <input>.llpl-audit)",
            &auditDir
    );

    if (lspSymbolsFile.length > 0) {
        runLspSymbols(lspSymbolsFile);
        return;
    }

    if (noSafeMode) {
        safeMode = false;
    }

    if (helpInfo.helpWanted || args.length < 2) {
        defaultGetoptPrinter("LLPL Compiler - Low Level Programming Language\n" ~
                           "Usage: llpl [options] <input.llpl>\n" ~
                           "       llpl run [options] <input.llpl> [-- args...]\n" ~
                           "       llpl audit [options] <input.llpl>\n" ~
                           "Options:",
                           helpInfo.options);
        return;
    }

    inputFile = args[1];
    outputWasExplicit = outputFile.length > 0;

    if (!exists(inputFile)) {
        if (diagnosticsJsonFile.length > 0) {
            auto err = new CompileError(format("Input file '%s' not found", inputFile), inputFile, 1, 1);
            std.file.write(diagnosticsJsonFile, buildDiagnosticsJson([err]));
        }
        stderr.writefln("Error: Input file '%s' not found", inputFile);
        return;
    }

    auto projectConfig = findProjectConfig(inputFile);
    if (targetProfile.length == 0) {
        targetProfile = projectConfig !is null && projectConfig.target.length > 0
            ? projectConfig.target
            : "hosted";
    }

    if (enableUnitTests) {
        binaryMode = true;
    }
    if (runMode) {
        binaryMode = true;
    }

    if (outputFile.length == 0 && !emitAst) {
        outputFile = runMode ? temporaryRunOutputPath(inputFile)
            : (binaryMode ? stripExtension(inputFile) : setExtension(inputFile, "c"));
    }

    try {
        if (emitAst) {
            string expandedSource = expandComptimeFor(readText(inputFile), inputFile);
            registerExpandedSource(inputFile, expandedSource);
            auto lexer = new Lexer(expandedSource);
            auto parser = new Parser(lexer.tokenize(), inputFile);
            string astDump = printAst(parser.parse());
            if (outputFile.length > 0) {
                std.file.write(outputFile, astDump);
                if (verbose) writefln("Wrote AST to %s", outputFile);
            } else {
                write(astDump);
            }
            return;
        }

        StopWatch totalTime;
        StopWatch phaseTime;
        totalTime.start();

        if (verbose) {
            writefln("Compiling %s...", inputFile);
        }

        // Resolve modules and dependencies (prelude.llpl first, if present)
        phaseTime.start();
        auto programs = resolveWithPrelude(inputFile, verbose);
        phaseTime.stop();

        if (verbose) {
            writefln("Resolved %d modules (%.2f ms)", programs.length, phaseTime.peek().total!"msecs");
            foreach (prog; programs) {
                if (prog.modulePath.length > 0) {
                    writefln("  - %s", prog.modulePath);
                }
            }
        }

        // Code generation for all modules
        phaseTime.reset();
        phaseTime.start();
        auto codegen = new CodeGenerator(safeMode, enableDCE, targetProfile, enableUnitTests);
        string cCode = codegen.generateMultiple(programs);
        phaseTime.stop();

        if (projectConfig !is null) {
            codegen.linkLibraries ~= projectConfig.linkLibraries;
            codegen.compilerFlags ~= projectConfig.compilerFlags;
        }

        if (verbose) {
            writefln("Code generation complete (%.2f ms)", phaseTime.peek().total!"msecs");
            codegen.reportTiming();
        }

        totalTime.stop();
        if (verbose) {
            writefln("Total compilation time: %.2f ms", totalTime.peek().total!"msecs");
        }

        if (provenanceFile.length > 0) {
            std.file.write(provenanceFile, buildProvenanceJson(cCode));
            if (verbose) writefln("Wrote provenance map to %s", provenanceFile);
        }

        if (effectsFile.length > 0) {
            std.file.write(effectsFile, buildEffectsJson(codegen));
            if (verbose) writefln("Wrote effect report to %s", effectsFile);
        }

        if (debugBundleDir.length > 0) {
            writeDebugBundle(debugBundleDir, inputFile, outputFile, targetProfile, cCode, codegen);
            if (verbose) writefln("Wrote debug bundle to %s", debugBundleDir);
        }

        if (auditMode) {
            if (auditDir.length == 0) auditDir = stripExtension(inputFile) ~ ".llpl-audit";
            writeDebugBundle(auditDir, inputFile, outputFile, targetProfile, cCode, codegen);
            writeAuditVerdict(auditDir, inputFile, outputFile, targetProfile, cCode, codegen);
            writefln("Audit passed: %s", auditDir);
            return;
        }

        if (binaryMode) {
            compileToBinary(cCode, outputFile, ccOverride, keepC, verbose,
                codegen.linkLibraries, codegen.compilerFlags, !enableUnitTests && !runMode);
            if (runMode) {
                int status = runBinary(outputFile, runArgs);
                if (!outputWasExplicit) {
                    if (exists(outputFile)) std.file.remove(outputFile);
                }
                exit(status);
            }
            if (enableUnitTests) {
                string actual = runUnitTestBinary(outputFile);
                checkUnitTestExpectedOutput(inputFile, unitTestExpectedFile, actual);
                write(actual);
            }
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
        if (diagnosticsJsonFile.length > 0) {
            std.file.write(diagnosticsJsonFile, buildDiagnosticsJson(e.errors));
        }
        foreach (i, err; e.errors) {
            if (i > 0) stderr.writeln();
            stderr.write(formatCompileError(err));
        }
        exit(1);
    } catch (CompileError e) {
        if (diagnosticsJsonFile.length > 0) {
            std.file.write(diagnosticsJsonFile, buildDiagnosticsJson([e]));
        }
        stderr.write(formatCompileError(e));
        exit(1);
    } catch (Exception e) {
        if (diagnosticsJsonFile.length > 0) {
            auto err = new CompileError(e.msg, inputFile, 1, 1);
            std.file.write(diagnosticsJsonFile, buildDiagnosticsJson([err]));
        }
        stderr.writefln("error: %s", e.msg);
        exit(1);
    }
}

private string jsonEscape(string s) {
    string out_;
    foreach (ch; s) {
        switch (ch) {
            case '\\': out_ ~= "\\\\"; break;
            case '"': out_ ~= "\\\""; break;
            case '\n': out_ ~= "\\n"; break;
            case '\r': out_ ~= "\\r"; break;
            case '\t': out_ ~= "\\t"; break;
            default: out_ ~= ch; break;
        }
    }
    return out_;
}

private ulong fnv1a64(const(ubyte)[] bytes) {
    ulong hash = 14695981039346656037UL;
    foreach (b; bytes) {
        hash ^= b;
        hash *= 1099511628211UL;
    }
    return hash;
}

private string buildProvenanceJson(string cCode) {
    string json = "[\n";
    bool first = true;
    string currentFile;
    int currentSourceLine = 0;
    int generatedLine = 0;

    foreach (line; cCode.splitLines()) {
        generatedLine++;
        if (line.startsWith("#line ")) {
            ptrdiff_t firstQuote = line.indexOf('"');
            ptrdiff_t lastQuote = line.lastIndexOf('"');
            if (firstQuote > 6 && lastQuote > firstQuote) {
                try {
                    currentSourceLine = to!int(line[6 .. firstQuote].strip());
                    currentFile = line[firstQuote + 1 .. lastQuote].replace("\\\"", "\"").replace("\\\\", "\\");
                } catch (Exception) {
                    currentFile = "";
                    currentSourceLine = 0;
                }
            }
            continue;
        }
        if (currentFile.length == 0 || currentSourceLine <= 0) continue;
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("  { \"generated_line\": %d, \"source_file\": \"%s\", \"source_line\": %d }",
            generatedLine, jsonEscape(currentFile), currentSourceLine);
        currentSourceLine++;
    }
    json ~= "\n]\n";
    return json;
}

private string buildSymbolsJson(CodeGenerator gen) {
    string json = "{\n  \"symbols\": [\n";
    bool first = true;
    foreach (sym; gen.symbols()) {
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("    { \"name\": \"%s\", \"kind\": \"%s\", \"file\": \"%s\", " ~
            "\"line\": %d, \"column\": %d, \"signature\": \"%s\" }",
            jsonEscape(sym.name), jsonEscape(sym.kind), jsonEscape(sym.file),
            sym.line, sym.column, jsonEscape(sym.signature));
    }
    json ~= "\n  ],\n  \"usages\": [\n";
    first = true;
    foreach (u; gen.usages()) {
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("    { \"name\": \"%s\", \"file\": \"%s\", \"line\": %d, \"column\": %d }",
            jsonEscape(u.name), jsonEscape(u.file), u.line, u.column);
    }
    json ~= "\n  ],\n  \"locals\": [\n";
    first = true;
    foreach (local; gen.locals()) {
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("    { \"name\": \"%s\", \"type\": \"%s\", \"file\": \"%s\", " ~
            "\"line\": %d, \"column\": %d, \"scopeName\": \"%s\", \"kind\": \"%s\" }",
            jsonEscape(local.name), jsonEscape(local.type), jsonEscape(local.file),
            local.line, local.column, jsonEscape(local.scopeName), jsonEscape(local.kind));
    }
    json ~= "\n  ]\n}\n";
    return json;
}

private string buildDiagnosticsJson(CompileError[] errors) {
    string json = "[\n";
    foreach (i, err; errors) {
        if (i > 0) json ~= ",\n";
        json ~= format("  { \"severity\": \"error\", \"message\": \"%s\", \"file\": \"%s\", " ~
            "\"line\": %d, \"column\": %d }",
            jsonEscape(err.msg), jsonEscape(err.filePath), err.line, err.column);
    }
    json ~= "\n]\n";
    return json;
}

private string buildEffectsJson(CodeGenerator gen) {
    string json = "[\n";
    bool first = true;
    foreach (effect; gen.effects()) {
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("  { \"name\": \"%s\", \"kind\": \"%s\", \"file\": \"%s\", " ~
            "\"line\": %d, \"column\": %d, \"effects\": [",
            jsonEscape(effect.name), jsonEscape(effect.kind), jsonEscape(effect.file),
            effect.line, effect.column);
        foreach (i, label; effect.effects) {
            if (i > 0) json ~= ", ";
            json ~= "\"" ~ jsonEscape(label) ~ "\"";
        }
        json ~= "] }";
    }
    json ~= "\n]\n";
    return json;
}

private string buildAbiReportJson(string cCode) {
    string json = "{\n  \"static_asserts\": [\n";
    bool first = true;
    foreach (line; cCode.splitLines()) {
        if (line.indexOf("_Static_assert(") < 0) continue;
        if (!first) json ~= ",\n";
        first = false;
        json ~= format("    { \"c\": \"%s\" }", jsonEscape(line.strip()));
    }
    json ~= "\n  ]\n}\n";
    return json;
}

private void writeDebugBundle(string dir, string inputFile, string outputFile, string targetProfile,
        string cCode, CodeGenerator gen) {
    mkdirRecurse(dir);
    string generatedCPath = buildNormalizedPath(dir, "generated.c");
    string provenancePath = buildNormalizedPath(dir, "provenance.json");
    string symbolsPath = buildNormalizedPath(dir, "symbols.json");
    string effectsPath = buildNormalizedPath(dir, "effects.json");
    string abiPath = buildNormalizedPath(dir, "abi.json");
    string manifestPath = buildNormalizedPath(dir, "manifest.json");

    std.file.write(generatedCPath, cCode);
    std.file.write(provenancePath, buildProvenanceJson(cCode));
    std.file.write(symbolsPath, buildSymbolsJson(gen));
    std.file.write(effectsPath, buildEffectsJson(gen));
    std.file.write(abiPath, buildAbiReportJson(cCode));

    ulong sourceHash = exists(inputFile) ? fnv1a64(cast(const(ubyte)[])read(inputFile)) : 0;
    string manifest = format(
        "{\n" ~
        "  \"input\": \"%s\",\n" ~
        "  \"output\": \"%s\",\n" ~
        "  \"target\": \"%s\",\n" ~
        "  \"source_hash_fnv1a64\": \"%016x\",\n" ~
        "  \"generated_c\": \"%s\",\n" ~
        "  \"provenance\": \"%s\",\n" ~
        "  \"symbols\": \"%s\",\n" ~
        "  \"effects\": \"%s\",\n" ~
        "  \"abi_report\": \"%s\",\n" ~
        "  \"artifact_schema\": \"llpl.build-artifact.v1\"\n" ~
        "}\n",
        jsonEscape(inputFile), jsonEscape(outputFile), jsonEscape(targetProfile),
        sourceHash, jsonEscape(generatedCPath), jsonEscape(provenancePath),
        jsonEscape(symbolsPath), jsonEscape(effectsPath), jsonEscape(abiPath));
    std.file.write(manifestPath, manifest);
}

private void writeAuditVerdict(string dir, string inputFile, string outputFile, string targetProfile,
        string cCode, CodeGenerator gen) {
    size_t unsafeFunctions = 0;
    size_t ffiFunctions = 0;
    foreach (effect; gen.effects()) {
        if (effect.effects.canFind("unsafe")) unsafeFunctions++;
        if (effect.effects.canFind("ffi")) ffiFunctions++;
    }

    string auditPath = buildNormalizedPath(dir, "audit.json");
    string audit = format(
        "{\n" ~
        "  \"verdict\": \"pass\",\n" ~
        "  \"input\": \"%s\",\n" ~
        "  \"output\": \"%s\",\n" ~
        "  \"target\": \"%s\",\n" ~
        "  \"generated_lines\": %d,\n" ~
        "  \"functions_with_effects\": %d,\n" ~
        "  \"unsafe_functions\": %d,\n" ~
        "  \"ffi_functions\": %d,\n" ~
        "  \"debug_bundle\": \"%s\"\n" ~
        "}\n",
        jsonEscape(inputFile), jsonEscape(outputFile), jsonEscape(targetProfile),
        cCode.splitLines().length, gen.effects().length, unsafeFunctions, ffiFunctions,
        jsonEscape(dir));
    std.file.write(auditPath, audit);
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
private string defaultCCompiler() {
    return environment.get("CC", "tcc");
}

private string sanitizePathComponent(string text) {
    string result;
    foreach (ch; text) {
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
            result ~= ch;
        } else {
            result ~= '_';
        }
    }
    return result.length > 0 ? result : "program";
}

private string temporaryRunOutputPath(string inputFile) {
    string base = sanitizePathComponent(stripExtension(baseName(inputFile)));
    return buildPath(tempDir(), format("llpl-run-%s-%s", base, Clock.currTime().stdTime));
}

private void compileToBinary(string cCode, string outputFile, string ccOverride, bool keepC, bool verbose,
        string[] linkLibraries, string[] compilerFlags, bool announceSuccess = true) {
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

    string cc = ccOverride.length > 0 ? ccOverride : defaultCCompiler();
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

    if (announceSuccess) {
        writefln("Successfully compiled to %s", outputFile);
    }
}

private int runBinary(string outputFile, string[] args) {
    string executable = outputFile;
    if (!isAbsolute(outputFile) && outputFile.indexOf(dirSeparator) < 0) {
        executable = buildPath(".", outputFile);
    }

    auto result = execute([executable] ~ args);
    write(result.output);
    return result.status;
}

private string runUnitTestBinary(string outputFile) {
    string executable = outputFile;
    if (!isAbsolute(outputFile) && outputFile.indexOf(dirSeparator) < 0) {
        executable = buildPath(".", outputFile);
    }

    auto result = execute([executable]);
    if (result.status != 0) {
        stderr.writefln("error: unittest executable '%s' failed (exit %d)", outputFile, result.status);
        exit(result.status);
    }
    return result.output;
}

private string defaultUnitTestExpectedPath(string inputFile) {
    return stripExtension(inputFile) ~ ".unittest.expected";
}

private void checkUnitTestExpectedOutput(string inputFile, string expectedOverride, string actual) {
    string expectedPath = expectedOverride.length > 0 ? expectedOverride : defaultUnitTestExpectedPath(inputFile);
    if (!exists(expectedPath)) {
        if (expectedOverride.length > 0) {
            stderr.writefln("error: unittest expected output file '%s' not found", expectedPath);
            exit(1);
        }
        return;
    }

    string expected = readText(expectedPath);
    if (actual == expected) return;

    stderr.writefln("error: unittest output differs from %s", expectedPath);
    stderr.writeln("--- expected");
    stderr.write(expected);
    if (expected.length == 0 || expected[$ - 1] != '\n') stderr.writeln();
    stderr.writeln("--- actual");
    stderr.write(actual);
    if (actual.length == 0 || actual[$ - 1] != '\n') stderr.writeln();
    exit(1);
}
