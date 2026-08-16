module main;

import std.stdio;
import std.getopt;
import std.process : environment;
import std.string;
import std.algorithm;
import std.array : array;
import std.parallelism : totalCPUs;
import std.file;
import std.path;
import std.regex;
import core.stdc.stdlib : exit;
import buildconfig;
import pipeline;
import testrunner;
import terminal;

void main(string[] args) {
    string file = "build.yaml";
    string configName;
    string[] varFlags;
    int jobs = totalCPUs;
    string testDir = "test";
    string testCompiler = "./llpl";

    auto helpInfo = getopt(
        args,
        "f|file", "Path to the build config (default: build.yaml)", &file,
        "c|config", "Build configuration to use (default: the YAML's default_config)", &configName,
        "var", "Override a 'variables:' entry, e.g. --var LIMINE_DIR=/path (repeatable)", &varFlags,
        "j|jobs", "Max concurrent compile/assemble/test jobs (default: CPU count)", &jobs,
        "dir", "Test directory ('test' command only, default: test)", &testDir,
        "compiler", "Path to the llpl compiler ('test' command only, default: ./llpl)", &testCompiler,
    );

    if (helpInfo.helpWanted) {
        defaultGetoptPrinter(
            "llplbuild - a cargo-like build tool for LLPL\n" ~
            "Usage: llplbuild [options] [new|build|check|run|clean|configs|fmt|doc|test] [args...]\n" ~
            "  build/check/run/clean/configs: run from a target directory with its own build.yaml\n" ~
            "  fmt/doc: run from a package root with llpl.toml or pass file/dir paths\n" ~
            "  test: run from the repo root - no build.yaml needed; optional paths run focused tests\n" ~
            "Options:",
            helpInfo.options);
        return;
    }

    string command = args.length > 1 ? args[1] : "build";

    if (command == "new") {
        createProject(args.length > 2 ? args[2] : "");
        return;
    }

    if (command == "fmt") {
        exit(runFmt(args.length > 2 ? args[2 .. $] : [], false));
    }

    if (command == "fmt-check") {
        exit(runFmt(args.length > 2 ? args[2 .. $] : [], true));
    }

    if (command == "doc") {
        runDoc(args.length > 2 ? args[2] : ".");
        return;
    }

    if (command == "test") {
        TestOptions topts;
        topts.dir = testDir;
        if (args.length > 2) {
            topts.paths = args[2 .. $];
        }
        topts.compiler = testCompiler;
        topts.jobs = jobs > 0 ? jobs : 1;
        exit(runTests(topts));
    }

    string[string] cliOverrides;
    foreach (v; varFlags) {
        auto idx = v.indexOf('=');
        if (idx < 0) {
            stderr.writefln("error: --var expects NAME=value, got '%s'", v);
            exit(1);
        }
        cliOverrides[v[0 .. idx]] = v[idx + 1 .. $];
    }

    try {
        auto cfg = loadConfig(file);
        auto vars = resolveVariables(cfg, environment.toAA(), cliOverrides);
        substituteVariables(cfg, vars);

        RunOptions opts;
        opts.jobs = jobs > 0 ? jobs : 1;

        switch (command) {
            case "build":
                build(cfg, configName, opts);
                break;
            case "check":
                check(cfg, configName, opts);
                break;
            case "run":
                run(cfg, configName, opts);
                break;
            case "clean":
                clean(cfg);
                break;
            case "configs":
                listConfigs(cfg);
                break;
            default:
                stderr.writefln(
                    "error: unknown command '%s' (expected new, build, check, run, clean, configs, fmt, fmt-check, doc, or test)", command);
                exit(1);
        }
    } catch (BuildError e) {
        logFail(e.msg);
        exit(1);
    } catch (Exception e) {
        logFail(e.msg);
        exit(1);
    }
}

private void createProject(string target) {
    if (target.length == 0) {
        stderr.writefln("error: llplbuild new expects a target directory");
        exit(1);
    }

    string dir = absolutePath(target).buildNormalizedPath();
    string name = baseName(dir);
    if (name.length == 0 || name == "." || name == "..") {
        stderr.writefln("error: invalid project directory '%s'", target);
        exit(1);
    }

    string configPath = buildPath(dir, "build.yaml");
    string tomlPath = buildPath(dir, "llpl.toml");
    string srcDir = buildPath(dir, "src");
    string sourcePath = buildPath(srcDir, "main.llpl");
    if (exists(configPath) || exists(tomlPath) || exists(sourcePath)) {
        stderr.writefln("error: refusing to overwrite an existing build.yaml, llpl.toml, or src/main.llpl in '%s'", target);
        exit(1);
    }

    mkdirRecurse(srcDir);
    mkdirRecurse(buildPath(dir, "build"));
    mkdirRecurse(buildPath(dir, "vendor"));
    string invocationDir = absolutePath(".").buildNormalizedPath();
    string repositoryRoot = invocationDir;
    while (true) {
        if (exists(buildPath(repositoryRoot, "llpl")) &&
                exists(buildPath(repositoryRoot, "runtime", "runtime.c"))) break;
        string parent = dirName(repositoryRoot).buildNormalizedPath();
        if (parent == repositoryRoot) break;
        repositoryRoot = parent;
    }
    string compilerPath = buildPath(repositoryRoot, "llpl");
    string runtimePath = buildPath(repositoryRoot, "runtime");
    if (!exists(compilerPath)) compilerPath = "llpl";
    if (!exists(buildPath(runtimePath, "runtime.c"))) runtimePath = "runtime";
    std.file.write(sourcePath, "extern func puts(s: char*) -> i64\n\n" ~
        "func main() -> int {\n" ~
        "    puts(\"Hello from LLPL\\n\")\n" ~
        "    return 0\n" ~
        "}\n");
    std.file.write(tomlPath,
        "[package]\n" ~
        "name = \"" ~ name ~ "\"\n" ~
        "version = \"0.1.0\"\n" ~
        "entry = \"src/main.llpl\"\n" ~
        "target = \"hosted\"\n" ~
        "source_roots = [\"src\"]\n" ~
        "import_paths = [\"lib\", \"modules\"]\n\n" ~
        "[dependencies]\n" ~
        "# name = \"vendor/name\"\n");

    string yaml =
        "project: " ~ name ~ "\n" ~
        "entry: src/main.llpl\n" ~
        "generated_c: build/main.c\n" ~
        "llpl_compiler: \"" ~ compilerPath ~ "\"\n\n" ~
        "toolchain:\n" ~
        "  cc: cc\n" ~
        "  ld: cc\n\n" ~
        "common_cflags:\n" ~
        "  - -I" ~ runtimePath ~ "\n\n" ~
        "c_sources:\n" ~
        "  - path: build/main.c\n" ~
        "    output: build/main.o\n" ~
        "    include_dirs: [\"" ~ runtimePath ~ "\"]\n" ~
        "  - path: \"" ~ buildPath(runtimePath, "runtime.c") ~ "\"\n" ~
        "    output: build/runtime.o\n" ~
        "    include_dirs: [\"" ~ runtimePath ~ "\"]\n\n" ~
        "link:\n" ~
        "  output: build/" ~ name ~ "\n" ~
        "  objects: [build/main.o, build/runtime.o]\n";
    std.file.write(configPath, yaml);
    writefln("Created LLPL project '%s'", target);
    writefln("  cd %s && llplbuild build", target);
}

private string findPackageRoot(string startPath) {
    string dir = exists(startPath) && isDir(startPath)
        ? absolutePath(startPath).buildNormalizedPath()
        : dirName(absolutePath(startPath)).buildNormalizedPath();
    while (dir.length > 0) {
        if (exists(buildPath(dir, "llpl.toml")) || exists(buildPath(dir, "build.yaml"))) return dir;
        string parent = dirName(dir).buildNormalizedPath();
        if (parent == dir) break;
        dir = parent;
    }
    return absolutePath(startPath).buildNormalizedPath();
}

private string[] llplFilesForArgs(string[] paths) {
    string[] result;
    if (paths.length == 0) {
        string root = findPackageRoot(".");
        string src = buildPath(root, "src");
        if (exists(src) && isDir(src)) paths = [src];
        else paths = [root];
    }
    foreach (path; paths) {
        if (!exists(path)) continue;
        if (isDir(path)) {
            foreach (entry; dirEntries(path, "*.llpl", SpanMode.depth)) {
                result ~= entry.name;
            }
        } else if (extension(path) == ".llpl") {
            result ~= path;
        }
    }
    sort(result);
    return result.uniq.array;
}

private string indentString(int indent) {
    string s;
    foreach (_; 0 .. indent) s ~= "    ";
    return s;
}

private string formatLlplSource(string source) {
    string out_;
    int indent = 0;
    bool previousBlank = false;
    foreach (rawLine; source.splitLines()) {
        string line = rawLine.strip();
        if (line.length == 0) {
            if (!previousBlank && out_.length > 0) {
                out_ ~= "\n";
                previousBlank = true;
            }
            continue;
        }
        if (line.startsWith("}")) {
            indent = indent > 0 ? indent - 1 : 0;
        }
        out_ ~= indentString(indent) ~ line ~ "\n";
        previousBlank = false;
        if (line.endsWith("{")) {
            indent++;
        }
    }
    return out_;
}

private int runFmt(string[] paths, bool checkOnly) {
    int changed = 0;
    foreach (file; llplFilesForArgs(paths)) {
        string before = readText(file);
        string after = formatLlplSource(before);
        if (before != after) {
            changed++;
            if (checkOnly) {
                writeln(file);
            } else {
                std.file.write(file, after);
                cargoLine("Formatted", file);
            }
        }
    }
    if (checkOnly && changed > 0) {
        stderr.writefln("error: %d file(s) need formatting", changed);
        return 1;
    }
    return 0;
}

private string docLineFor(string file, string line) {
    auto m = matchFirst(line, regex(`^\s*(public\s+)?(async\s+)?(func|class|struct|trait|enum|alias)\s+([A-Za-z_][A-Za-z0-9_]*)`));
    if (m.empty) return "";
    string visibility = m.captures[1].length > 0 ? "public " : "";
    string asyncPart = m.captures[2];
    string kind = m.captures[3];
    string name = m.captures[4];
    return "- `" ~ visibility ~ asyncPart ~ kind ~ " " ~ name ~ "` (" ~ file ~ ")";
}

private void runDoc(string target) {
    string root = findPackageRoot(target);
    string outDir = buildPath(root, "build", "docs");
    mkdirRecurse(outDir);
    string outPath = buildPath(outDir, "api.md");
    string title = baseName(root);
    if (exists(buildPath(root, "llpl.toml"))) {
        foreach (line; readText(buildPath(root, "llpl.toml")).splitLines()) {
            auto m = matchFirst(line, regex(`^\s*name\s*=\s*"([^"]+)"`));
            if (!m.empty) {
                title = m.captures[1];
                break;
            }
        }
    }
    string doc = "# " ~ title ~ " API\n\n";
    foreach (file; llplFilesForArgs([root])) {
        string[] lines;
        foreach (line; readText(file).splitLines()) {
            string item = docLineFor(relativePath(file, root), line);
            if (item.length > 0) lines ~= item;
        }
        if (lines.length == 0) continue;
        doc ~= "## " ~ relativePath(file, root) ~ "\n\n";
        foreach (line; lines) doc ~= line ~ "\n";
        doc ~= "\n";
    }
    std.file.write(outPath, doc);
    cargoLine("Documented", outPath);
}
