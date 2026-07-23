module main;

import std.stdio;
import std.getopt;
import std.process : environment;
import std.string;
import std.algorithm;
import std.parallelism : totalCPUs;
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
            "Usage: llplbuild [options] [build|check|run|clean|configs|test]\n" ~
            "  build/check/run/clean/configs: run from a target directory with its own build.yaml\n" ~
            "  test: run from the repo root - no build.yaml needed\n" ~
            "Options:",
            helpInfo.options);
        return;
    }

    string command = args.length > 1 ? args[1] : "build";

    if (command == "test") {
        TestOptions topts;
        topts.dir = testDir;
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
                    "error: unknown command '%s' (expected build, check, run, clean, configs, or test)", command);
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
