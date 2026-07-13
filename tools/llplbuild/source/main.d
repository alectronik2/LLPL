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
import terminal;

void main(string[] args) {
    string file = "build.yaml";
    string configName;
    string[] varFlags;
    int jobs = totalCPUs;

    auto helpInfo = getopt(
        args,
        "f|file", "Path to the build config (default: build.yaml)", &file,
        "c|config", "Build configuration to use (default: the YAML's default_config)", &configName,
        "var", "Override a 'variables:' entry, e.g. --var LIMINE_DIR=/path (repeatable)", &varFlags,
        "j|jobs", "Max concurrent compile/assemble jobs (default: CPU count)", &jobs,
    );

    if (helpInfo.helpWanted) {
        defaultGetoptPrinter(
            "llplbuild - YAML-configured build tool for LLPL bare-metal targets\n" ~
            "Usage: llplbuild [options] [build|run|clean|configs]\n" ~
            "Options:",
            helpInfo.options);
        return;
    }

    string command = args.length > 1 ? args[1] : "build";

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
                stderr.writefln("error: unknown command '%s' (expected build, run, clean, or configs)", command);
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
