module modules;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.format;
import std.json;
import std.process : environment, execute;
import ast;
import lexer;
import parser;
import errors;

class ProjectConfig {
    string path;
    string rootDir;
    string[] importPaths;
    string[] sourceRoots;
    string[] linkLibraries;
    string[] compilerFlags;
    string target;

    string[] moduleSearchPaths() {
        string[] result;
        foreach (p; sourceRoots) result ~= buildNormalizedPath(rootDir, p);
        foreach (p; importPaths) result ~= buildNormalizedPath(rootDir, p);
        return result;
    }
}

class ModuleInfo {
    string path;
    string absolutePath;
    Program ast;
    bool isBeingParsed;  // For circular dependency detection
    bool isParsed;
    ImportStmt[] imports;

    this(string path, string absolutePath) {
        this.path = path;
        this.absolutePath = absolutePath;
        this.isBeingParsed = false;
        this.isParsed = false;
    }
}

class ModuleResolver {
    private ModuleInfo[string] modules;  // Map absolute path -> module info
    private string[] searchPaths;
    private string[] importOrder;  // Order in which modules were fully processed
    private bool recoverParseErrors;
    private CompileError[] collectedDiagnostics;
    private string[string] headerImportCache;

    this(string[] searchPaths = [], bool recoverParseErrors = false) {
        this.searchPaths = searchPaths ~ [".", "lib", "modules"];
        this.recoverParseErrors = recoverParseErrors;
    }

    // Resolve a module and all its dependencies
    Program[] resolveAll(string entryPath) {
        string absPath = absolutePath(entryPath);

        if (!exists(absPath)) {
            throw new Exception(format("Entry file not found: %s", entryPath));
        }

        // Parse entry module and all dependencies
        resolveModule(absPath);

        // Return modules in dependency order
        Program[] programs;
        foreach (modPath; importOrder) {
            programs ~= modules[modPath].ast;
        }

        return programs;
    }

    private void resolveModule(string absPath) {
        // Check if already parsed
        if (absPath in modules && modules[absPath].isParsed) {
            return;
        }

        // Check for circular dependency
        if (absPath in modules && modules[absPath].isBeingParsed) {
            // Circular import detected - this is OK, we'll handle it
            writefln("Info: Circular import detected: %s", absPath);
            return;
        }

        // Create module info
        if (absPath !in modules) {
            modules[absPath] = new ModuleInfo(absPath, absPath);
        }

        auto modInfo = modules[absPath];
        modInfo.isBeingParsed = true;

        // Read and parse the file
        string source = readText(absPath);
        auto lexer = new Lexer(source);
        auto tokens = lexer.tokenize();
        auto parser = new Parser(tokens, absPath);
        modInfo.ast = recoverParseErrors ? parser.parseRecovering() : parser.parse();
        if (recoverParseErrors) {
            collectedDiagnostics ~= parser.diagnostics();
        }
        modInfo.ast.modulePath = absPath;

        // Extract imports
        foreach (decl; modInfo.ast.declarations) {
            if (auto importStmt = cast(ImportStmt)decl) {
                modInfo.imports ~= importStmt;

                // Resolve the imported module
                string importPath = resolveImportPath(importStmt.modulePath, absPath);
                importStmt.resolvedPath = importPath;
                if (importPath.length > 0) {
                    resolveModule(importPath);
                }
            }
        }

        modInfo.isBeingParsed = false;
        modInfo.isParsed = true;

        // Add to import order
        importOrder ~= absPath;
    }

    private string resolveImportPath(string modulePath, string fromFile) {
        // If it's a relative path, resolve from the importing file's directory
        string baseDir = dirName(fromFile);

        bool isHeaderImport = modulePath.length >= 2 && modulePath[$ - 2 .. $] == ".h";
        string testPath = modulePath;
        if (!isHeaderImport && !testPath.endsWith(".llpl")) {
            testPath ~= ".llpl";
        }

        // Try relative to importing file
        string candidatePath = buildNormalizedPath(baseDir, testPath);
        if (exists(candidatePath)) {
            return isHeaderImport ? materializeHeaderImport(absolutePath(candidatePath)) : absolutePath(candidatePath);
        }

        // Try each search path
        foreach (searchPath; searchPaths) {
            candidatePath = buildNormalizedPath(searchPath, testPath);
            if (exists(candidatePath)) {
                return isHeaderImport ? materializeHeaderImport(absolutePath(candidatePath)) : absolutePath(candidatePath);
            }
        }

        if (isHeaderImport) {
            throw new Exception(format("Could not resolve C header import: %s (from %s)", modulePath, fromFile));
        }

        stderr.writefln("Warning: Could not resolve import: %s (from %s)", modulePath, fromFile);
        return "";
    }

    private string sanitizeForTempName(string text) {
        string result;
        foreach (ch; text) {
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
                result ~= ch;
            } else {
                result ~= '_';
            }
        }
        return result;
    }

    private string bindgenCommand() {
        string envCmd = environment.get("LLPL_BINDGEN", "");
        if (envCmd.length > 0) {
            return envCmd;
        }

        string localCmd = buildNormalizedPath(".", "tools/llpl-bindgen");
        if (exists(localCmd)) {
            return localCmd;
        }

        string exeCmd = buildNormalizedPath(dirName(thisExePath()), "../tools/llpl-bindgen");
        if (exists(exeCmd)) {
            return exeCmd;
        }

        return "tools/llpl-bindgen";
    }

    private string headerImportTempPath(string headerPath) {
        string baseName = sanitizeForTempName(headerPath);
        return buildNormalizedPath(tempDir(), "llpl-bindgen-" ~ baseName ~ ".llpl");
    }

    private string materializeHeaderImport(string headerPath) {
        if (headerPath in headerImportCache) {
            return headerImportCache[headerPath];
        }

        string binder = bindgenCommand();
        auto result = execute([binder, headerPath]);
        if (result.status != 0) {
            throw new Exception(format("llpl-bindgen failed for %s (exit %d)", headerPath, result.status));
        }

        string tempPath = headerImportTempPath(headerPath);
        std.file.write(tempPath, result.output);
        headerImportCache[headerPath] = tempPath;
        return tempPath;
    }

    // Get all modules in dependency order
    ModuleInfo[] getModules() {
        ModuleInfo[] result;
        foreach (path; importOrder) {
            result ~= modules[path];
        }
        return result;
    }

    CompileError[] diagnostics() {
        return collectedDiagnostics;
    }
}

// `prelude.llpl` ships as a sibling of the compiler binary itself (not
// relative to the current working directory, so `llpl foo.llpl` behaves
// the same no matter where it's run from) - see prelude.llpl for what it
// contains and why. Returns "" if there isn't one there, so building
// without a prelude present is a silent no-op rather than an error: it's
// an optional convenience, not a required part of every LLPL toolchain.
string findPreludePath() {
    string candidate = buildNormalizedPath(dirName(thisExePath()), "prelude.llpl");
    return exists(candidate) ? candidate : "";
}

private string[] jsonStringArray(JSONValue root, string key) {
    string[] result;
    if (key !in root.object) return result;
    foreach (item; root[key].array) {
        result ~= item.str;
    }
    return result;
}

ProjectConfig findProjectConfig(string entryPath) {
    string start = exists(entryPath) && isDir(entryPath) ? absolutePath(entryPath) : dirName(absolutePath(entryPath));
    string dir = start;
    while (dir.length > 0) {
        string candidate = buildNormalizedPath(dir, "llpl.json");
        if (exists(candidate)) {
            auto config = new ProjectConfig();
            config.path = candidate;
            config.rootDir = dir;
            JSONValue root = parseJSON(readText(candidate));
            config.importPaths = jsonStringArray(root, "import_paths");
            config.sourceRoots = jsonStringArray(root, "source_roots");
            config.linkLibraries = jsonStringArray(root, "link");
            config.compilerFlags = jsonStringArray(root, "flags");
            if ("target" in root.object) config.target = root["target"].str;
            return config;
        }
        string parent = dirName(dir);
        if (parent == dir) break;
        dir = parent;
    }
    return null;
}

// Resolves `entryPath` and everything it imports, exactly like
// `ModuleResolver.resolveAll`, except prelude.llpl (if present) is
// resolved first and unconditionally, so its declarations are visible
// everywhere without needing an explicit `import` - regardless of whether
// the entry file, or anything it imports, ever mentions it.
//
// Also adds $LLPL_HOME (if set) as a module search path, so a stdlib
// import like `import "stdlib/yaml/yaml_parser.llpl"` resolves the same
// way from any file, at any depth, instead of needing a "../../stdlib/..."
// relative path that depends on how deeply nested the importing file
// happens to be. Read here (not threaded in from main.d/lspquery.d
// separately) so both the CLI compiler and editor-tooling entry points
// (lspquery.d) automatically get identical resolution behavior.
Program[] resolveWithPrelude(string entryPath) {
    string[] extraSearchPaths;
    string llplHome = environment.get("LLPL_HOME", "");
    if (llplHome.length > 0) {
        extraSearchPaths ~= llplHome;
    }
    auto project = findProjectConfig(entryPath);
    if (project !is null) {
        extraSearchPaths ~= project.moduleSearchPaths();
    }
    auto resolver = new ModuleResolver(extraSearchPaths);
    string preludePath = findPreludePath();
    if (preludePath.length > 0) {
        resolver.resolveAll(preludePath);
    }
    return resolver.resolveAll(entryPath);
}

Program[] resolveWithPreludeRecovering(string entryPath, out CompileError[] diagnostics, out ProjectConfig project) {
    string[] extraSearchPaths;
    string llplHome = environment.get("LLPL_HOME", "");
    if (llplHome.length > 0) {
        extraSearchPaths ~= llplHome;
    }
    project = findProjectConfig(entryPath);
    if (project !is null) {
        extraSearchPaths ~= project.moduleSearchPaths();
    }
    auto resolver = new ModuleResolver(extraSearchPaths, true);
    string preludePath = findPreludePath();
    if (preludePath.length > 0) {
        resolver.resolveAll(preludePath);
    }
    auto programs = resolver.resolveAll(entryPath);
    diagnostics = resolver.diagnostics();
    return programs;
}
