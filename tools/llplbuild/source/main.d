module main;

import std.stdio;
import std.getopt;
import std.process : environment;
import std.string;
import std.algorithm;
import std.parallelism : totalCPUs;
import std.file;
import std.path;
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
            "Usage: llplbuild [options] [build|check|run|clean|configs|test] [test-file-or-dir ...]\n" ~
            "  build/check/run/clean/configs: run from a target directory with its own build.yaml\n" ~
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
                    "error: unknown command '%s' (expected new, build, check, run, clean, configs, or test)", command);
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
    string sourcePath = buildPath(dir, "main.llpl");
    if (exists(configPath) || exists(sourcePath)) {
        stderr.writefln("error: refusing to overwrite an existing build.yaml or main.llpl in '%s'", target);
        exit(1);
    }

    mkdirRecurse(buildPath(dir, "build"));
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

    string yaml =
        "project: " ~ name ~ "\n" ~
        "entry: main.llpl\n" ~
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
