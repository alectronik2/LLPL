module modules;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import std.format;
import std.json;
import std.string : endsWith, indexOf, join, replace, split, splitLines, startsWith, strip;
import std.process : environment, execute;
import std.datetime.stopwatch;
import std.datetime.systime : SysTime, Clock;
import core.stdc.time : time_t;
import ast;
import lexer;
import parser;
import errors;
import comptime;

class ProjectConfig {
    string path;
    string rootDir;
    string packageName;
    string version_;
    string entry;
    string[] importPaths;
    string[] sourceRoots;
    string[string] dependencies;
    string[] linkLibraries;
    string[] compilerFlags;
    string target;

    string[] moduleSearchPaths() {
        string[] result;
        foreach (p; sourceRoots) result ~= buildNormalizedPath(rootDir, p);
        foreach (p; importPaths) result ~= buildNormalizedPath(rootDir, p);
        foreach (name, p; dependencies) {
            string depRoot = buildNormalizedPath(rootDir, p);
            result ~= depRoot;
            result ~= buildNormalizedPath(depRoot, "src");
            result ~= buildNormalizedPath(depRoot, "lib");
        }
        string vendorDir = buildNormalizedPath(rootDir, "vendor");
        if (exists(vendorDir) && isDir(vendorDir)) {
            foreach (entry; dirEntries(vendorDir, SpanMode.shallow)) {
                if (!entry.isDir) continue;
                result ~= entry.name;
                result ~= buildNormalizedPath(entry.name, "src");
                result ~= buildNormalizedPath(entry.name, "lib");
            }
        }
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
    private bool[string] pathExistsCache;  // Cache filesystem exists() results
    private string[string] modulePathCache;  // Map module name -> resolved path
    private SysTime[string] fileMtimeCache;  // Track file modification times for incremental compilation
    private bool enableIncrementalCache = false;
    private int incrementalHits = 0;
    private int incrementalMisses = 0;
    private bool enableTiming = false;
    private double readFileTime = 0;
    private double lexTime = 0;
    private double parseTime = 0;
    private double importResolvTime = 0;
    private double headerBindgenTime = 0;
    private int resolvePathCalls = 0;
    private int cachedExistsCalls = 0;
    private int cacheHits = 0;
    private int headerCacheHits = 0;
    private int headerCacheMisses = 0;

    this(string[] searchPaths = [], bool recoverParseErrors = false, bool forceTiming = false) {
        this.searchPaths = searchPaths ~ [".", "lib", "modules"];
        this.recoverParseErrors = recoverParseErrors;
        this.enableTiming = forceTiming || (environment.get("LLPL_TIMING", "").length > 0);
        this.enableIncrementalCache = (environment.get("LLPL_INCREMENTAL", "").length > 0);
    }

    private bool canUseIncrementalCache(string absPath) {
        if (!enableIncrementalCache) return false;
        if (absPath !in modules) return false;

        ModuleInfo info = modules[absPath];
        if (!info.isParsed || info.ast is null) return false;

        // TODO: check file mtime for actual incremental benefit
        // For now, rely on isParsed flag within single run
        return true;
    }

    void reportTiming() {
        if (enableTiming) {
            writefln("  File I/O: %.2f ms", readFileTime);
            writefln("  Lexing: %.2f ms", lexTime);
            writefln("  Parsing: %.2f ms", parseTime);
            writefln("  Import resolution: %.2f ms", importResolvTime);
            writefln("  Header bindgen: %.2f ms (%d cache hits, %d misses)",
                headerBindgenTime, headerCacheHits, headerCacheMisses);
            writefln("  resolveImportPath calls: %d (cache hits: %d)", resolvePathCalls, cacheHits);
            writefln("  cachedExists calls: %d", cachedExistsCalls);
        }
        if (enableIncrementalCache) {
            writefln("  Incremental cache: %d hits, %d misses", incrementalHits, incrementalMisses);
        }
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

        // Check incremental cache
        if (canUseIncrementalCache(absPath)) {
            incrementalHits++;
            return;
        }
        if (enableIncrementalCache) {
            incrementalMisses++;
        }

        // Check for circular dependency
        if (absPath in modules && modules[absPath].isBeingParsed) {
            // Circular import detected - this is OK, we'll handle it
            //writefln("Info: Circular import detected: %s", absPath);
            return;
        }

        // Create module info
        if (absPath !in modules) {
            modules[absPath] = new ModuleInfo(absPath, absPath);
        }

        auto modInfo = modules[absPath];
        modInfo.isBeingParsed = true;

        // Read and parse the file
        StopWatch timer;
        timer.start();
        string source = expandComptimeFor(readText(absPath), absPath);
        registerExpandedSource(absPath, source);
        timer.stop();
        if (enableTiming) readFileTime += timer.peek().total!"msecs";

        timer.reset();
        timer.start();
        auto lexer = new Lexer(source);
        auto tokens = lexer.tokenize();
        timer.stop();
        if (enableTiming) lexTime += timer.peek().total!"msecs";

        timer.reset();
        timer.start();
        auto parser = new Parser(tokens, absPath);
        modInfo.ast = recoverParseErrors ? parser.parseRecovering() : parser.parse();
        if (recoverParseErrors) {
            collectedDiagnostics ~= parser.diagnostics();
        }
        modInfo.ast.modulePath = absPath;
        timer.stop();
        if (enableTiming) parseTime += timer.peek().total!"msecs";

        // Extract imports
        foreach (decl; modInfo.ast.declarations) {
            if (auto importStmt = cast(ImportStmt)decl) {
                modInfo.imports ~= importStmt;

                // Resolve the imported module
                timer.reset();
                timer.start();
                string[] importPaths = resolveImportPaths(importStmt.modulePath, absPath);
                timer.stop();
                if (enableTiming) importResolvTime += timer.peek().total!"msecs";

                importStmt.resolvedPaths = importPaths;
                importStmt.resolvedPath = importPaths.length > 0 ? importPaths[0] : "";
                foreach (importPath; importPaths) {
                    resolveModule(importPath);
                }
            }
        }

        modInfo.isBeingParsed = false;
        modInfo.isParsed = true;

        // Add to import order
        importOrder ~= absPath;
    }

    private bool cachedExists(string path) {
        if (enableTiming) cachedExistsCalls++;
        if (path !in pathExistsCache) {
            pathExistsCache[path] = exists(path);
        }
        return pathExistsCache[path];
    }

    private string resolveImportPath(string modulePath, string fromFile) {
        auto paths = resolveImportPaths(modulePath, fromFile);
        return paths.length > 0 ? paths[0] : "";
    }

    private string[] resolveImportPaths(string modulePath, string fromFile) {
        if (enableTiming) resolvePathCalls++;

        string cacheKey = fromFile ~ "\n" ~ modulePath;

        // Check module path cache first
        if (cacheKey in modulePathCache) {
            if (enableTiming) cacheHits++;
            string cached = modulePathCache[cacheKey];
            return cached.length > 0 ? cached.split("\n") : [];
        }

        string[] result = resolveImportPathsImpl(modulePath, fromFile);

        // Cache result (even empty string to avoid repeated searches)
        modulePathCache[cacheKey] = result.join("\n");
        return result;
    }

    private string[] resolveImportPathsImpl(string modulePath, string fromFile) {
        // If it's a relative path, resolve from the importing file's directory
        string baseDir = dirName(fromFile);

        bool isHeaderImport = modulePath.length >= 2 && modulePath[$ - 2 .. $] == ".h";
        string testPath = modulePath;
        if (!isHeaderImport && !testPath.endsWith(".llpl")) {
            testPath ~= ".llpl";
        }

        string[] testPaths;
        if (!isHeaderImport && testPath.startsWith("std/")) {
            testPaths ~= "stdlib/" ~ testPath[4 .. $];
        }
        testPaths ~= testPath;

        // Try relative to importing file
        foreach (path; testPaths) {
            string candidatePath = buildNormalizedPath(baseDir, path);
            if (cachedExists(candidatePath)) {
                auto absPath = absolutePath(candidatePath);
                return [isHeaderImport ? materializeHeaderImport(absPath) : absPath];
            }
        }

        // Try each search path
        foreach (searchPath; searchPaths) {
            foreach (path; testPaths) {
                string candidatePath = buildNormalizedPath(searchPath, path);
                if (cachedExists(candidatePath)) {
                    auto absPath = absolutePath(candidatePath);
                    return [isHeaderImport ? materializeHeaderImport(absPath) : absPath];
                }
            }
        }

        if (!isHeaderImport) {
            string[] dirTestPaths;
            if (modulePath.startsWith("std/")) {
                dirTestPaths ~= "stdlib/" ~ modulePath[4 .. $];
            }
            dirTestPaths ~= modulePath;

            string[] resolveDir(string dirPath) {
                if (!cachedExists(dirPath) || !isDir(dirPath)) return [];
                string[] paths;
                foreach (entry; dirEntries(dirPath, SpanMode.shallow)) {
                    if (!entry.isFile || extension(entry.name) != ".llpl") continue;
                    paths ~= absolutePath(entry.name);
                }
                sort(paths);
                return paths;
            }

            foreach (path; dirTestPaths) {
                auto paths = resolveDir(buildNormalizedPath(baseDir, path));
                if (paths.length > 0) return paths;
            }
            foreach (searchPath; searchPaths) {
                foreach (path; dirTestPaths) {
                    auto paths = resolveDir(buildNormalizedPath(searchPath, path));
                    if (paths.length > 0) return paths;
                }
            }
        }

        if (isHeaderImport) {
            throw new Exception(format("Could not resolve C header import: %s (from %s)",
                                     modulePath, fromFile));
        }

        stderr.writefln("Warning: Could not resolve import: %s (from %s)", modulePath, fromFile);
        return [];
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

    private string bindgenSourcePath(string binder) {
        string dir = dirName(absolutePath(binder));
        string candidate = buildNormalizedPath(dir, "llpl-bindgen.llpl");
        return exists(candidate) ? candidate : "";
    }

    private string headerImportTempPath(string headerPath) {
        string baseName = sanitizeForTempName(headerPath);
        return buildNormalizedPath(tempDir(), "llpl-bindgen-" ~ baseName ~ ".llpl");
    }

    private bool generatedHeaderImportIsFresh(string tempPath, string headerPath, string binder) {
        if (!exists(tempPath)) return false;
        SysTime outputTime = timeLastModified(tempPath);
        if (timeLastModified(headerPath) > outputTime) return false;
        if (exists(binder) && timeLastModified(binder) > outputTime) return false;
        string sourcePath = bindgenSourcePath(binder);
        if (sourcePath.length > 0 && timeLastModified(sourcePath) > outputTime) return false;
        return true;
    }

    private string materializeHeaderImport(string headerPath) {
        if (headerPath in headerImportCache) {
            return headerImportCache[headerPath];
        }

        string binder = bindgenCommand();
        string tempPath = headerImportTempPath(headerPath);
        if (generatedHeaderImportIsFresh(tempPath, headerPath, binder)) {
            if (enableTiming) headerCacheHits++;
            headerImportCache[headerPath] = tempPath;
            return tempPath;
        }
        if (enableTiming) headerCacheMisses++;

        StopWatch timer;
        timer.start();
        auto result = execute([binder, headerPath]);
        timer.stop();
        if (enableTiming) headerBindgenTime += timer.peek().total!"msecs";
        if (result.status != 0) {
            throw new Exception(format("llpl-bindgen failed for %s (exit %d)", headerPath, result.status));
        }

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

private string stripTomlComment(string line) {
    bool inString = false;
    string out_;
    for (size_t i = 0; i < line.length; i++) {
        char ch = line[i];
        if (ch == '"' && (i == 0 || line[i - 1] != '\\')) {
            inString = !inString;
        }
        if (ch == '#' && !inString) break;
        out_ ~= ch;
    }
    return out_.strip();
}

private string unquoteToml(string value) {
    value = value.strip();
    if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"') {
        return value[1 .. $ - 1];
    }
    return value;
}

private string[] tomlArray(string value) {
    string[] result;
    value = value.strip();
    if (value.length < 2 || value[0] != '[' || value[$ - 1] != ']') return result;
    string inner = value[1 .. $ - 1];
    bool inString = false;
    string current;
    for (size_t i = 0; i < inner.length; i++) {
        char ch = inner[i];
        if (ch == '"' && (i == 0 || inner[i - 1] != '\\')) {
            inString = !inString;
            current ~= ch;
            continue;
        }
        if (ch == ',' && !inString) {
            string item = unquoteToml(current.strip());
            if (item.length > 0) result ~= item;
            current = "";
            continue;
        }
        current ~= ch;
    }
    string item = unquoteToml(current.strip());
    if (item.length > 0) result ~= item;
    return result;
}

private ProjectConfig loadTomlProjectConfig(string candidate, string rootDir) {
    auto config = new ProjectConfig();
    config.path = candidate;
    config.rootDir = rootDir;
    string section;
    foreach (rawLine; readText(candidate).splitLines()) {
        string line = stripTomlComment(rawLine);
        if (line.length == 0) continue;
        if (line.startsWith("[") && line.endsWith("]")) {
            section = line[1 .. $ - 1].strip();
            continue;
        }
        auto idx = line.indexOf('=');
        if (idx < 0) continue;
        string key = line[0 .. idx].strip();
        string value = line[idx + 1 .. $].strip();
        if (section == "package" || section.length == 0) {
            if (key == "name") config.packageName = unquoteToml(value);
            else if (key == "version") config.version_ = unquoteToml(value);
            else if (key == "entry") config.entry = unquoteToml(value);
            else if (key == "target") config.target = unquoteToml(value);
            else if (key == "source_roots") config.sourceRoots = tomlArray(value);
            else if (key == "import_paths") config.importPaths = tomlArray(value);
            else if (key == "link") config.linkLibraries = tomlArray(value);
            else if (key == "flags") config.compilerFlags = tomlArray(value);
        } else if (section == "dependencies") {
            config.dependencies[key] = unquoteToml(value);
        }
    }
    if (config.sourceRoots.length == 0) config.sourceRoots = ["src"];
    config.importPaths ~= ["lib", "modules"];
    return config;
}

ProjectConfig findProjectConfig(string entryPath) {
    string start = exists(entryPath) && isDir(entryPath) ? absolutePath(entryPath) : dirName(absolutePath(entryPath));
    string dir = start;
    while (dir.length > 0) {
        string tomlCandidate = buildNormalizedPath(dir, "llpl.toml");
        if (exists(tomlCandidate)) {
            return loadTomlProjectConfig(tomlCandidate, dir);
        }
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
// import like `import std.yaml.yaml_parser` resolves the same
// way from any file, at any depth, instead of needing a "../../stdlib/..."
// relative path that depends on how deeply nested the importing file
// happens to be. Read here (not threaded in from main.d/lspquery.d
// separately) so both the CLI compiler and editor-tooling entry points
// (lspquery.d) automatically get identical resolution behavior.
Program[] resolveWithPrelude(string entryPath, bool enableTiming = false) {
    string[] extraSearchPaths;
    extraSearchPaths ~= dirName(absolutePath(entryPath));
    string llplHome = environment.get("LLPL_HOME", "");
    if (llplHome.length > 0) {
        extraSearchPaths ~= llplHome;
    }
    auto project = findProjectConfig(entryPath);
    if (project !is null) {
        extraSearchPaths ~= project.moduleSearchPaths();
    }
    auto resolver = new ModuleResolver(extraSearchPaths, false, enableTiming);
    string preludePath = findPreludePath();
    if (preludePath.length > 0) {
        resolver.resolveAll(preludePath);
    }
    auto result = resolver.resolveAll(entryPath);
    resolver.reportTiming();
    return result;
}

Program[] resolveWithPreludeRecovering(string entryPath, out CompileError[] diagnostics, out ProjectConfig project) {
    string[] extraSearchPaths;
    extraSearchPaths ~= dirName(absolutePath(entryPath));
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
