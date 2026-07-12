module modules;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.format;
import ast;
import lexer;
import parser;

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

    this(string[] searchPaths = []) {
        this.searchPaths = searchPaths ~ [".", "lib", "modules"];
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
        modInfo.ast = parser.parse();
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

        // Add .llpl extension if not present
        string testPath = modulePath;
        if (!testPath.endsWith(".llpl")) {
            testPath ~= ".llpl";
        }

        // Try relative to importing file
        string candidatePath = buildNormalizedPath(baseDir, testPath);
        if (exists(candidatePath)) {
            return absolutePath(candidatePath);
        }

        // Try each search path
        foreach (searchPath; searchPaths) {
            candidatePath = buildNormalizedPath(searchPath, testPath);
            if (exists(candidatePath)) {
                return absolutePath(candidatePath);
            }
        }

        stderr.writefln("Warning: Could not resolve import: %s (from %s)", modulePath, fromFile);
        return "";
    }

    // Get all modules in dependency order
    ModuleInfo[] getModules() {
        ModuleInfo[] result;
        foreach (path; importOrder) {
            result ~= modules[path];
        }
        return result;
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

// Resolves `entryPath` and everything it imports, exactly like
// `ModuleResolver.resolveAll`, except prelude.llpl (if present) is
// resolved first and unconditionally, so its declarations are visible
// everywhere without needing an explicit `import` - regardless of whether
// the entry file, or anything it imports, ever mentions it.
Program[] resolveWithPrelude(string entryPath) {
    auto resolver = new ModuleResolver();
    string preludePath = findPreludePath();
    if (preludePath.length > 0) {
        resolver.resolveAll(preludePath);
    }
    return resolver.resolveAll(entryPath);
}
