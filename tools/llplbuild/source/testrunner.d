module testrunner;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.format;
import std.parallelism : totalCPUs;
import std.path;
import std.process;
import std.stdio;
import std.string;
import core.thread;
import core.sync.condition;
import core.sync.mutex;
import core.time : MonoTime;
import pipeline : formatElapsed;
import terminal;

struct TestOptions {
    string dir = "test";
    string[] paths;
    string compiler = "./llpl";
    string[] skip = ["macro_quote"]; // no main() - see run_tests.sh's own history
    int jobs = 4;
}

private struct TestResult {
    string name;
    bool passed;
    string detail;  // one-line suffix, e.g. "(expected failure)" - "" if none
    string failure; // full diff/reason, only set when !passed
}

private string readFlags(string path) {
    if (!exists(path)) return "";
    return readText(path).strip();
}

private TestResult compareExpectedPrefix(string base, string label, string expectedPath, string actual) {
    string expected = readText(expectedPath);
    string prefix = actual.length >= expected.length ? actual[0 .. expected.length] : actual;
    if (prefix == expected) {
        return TestResult(base, true, label, "");
    }
    return TestResult(base, false, "", format(
        "expected output prefix differs from %s\n--- expected\n%s\n--- actual (first %d bytes)\n%s",
        expectedPath, expected, expected.length, prefix));
}

// Runs one test end to end: compile via `-b` (already applies
// -funsigned-char - see source/main.d - so unlike run_tests.sh's old
// two-step compile+gcc, this is a single command), run the resulting
// binary, and compare against `<name>.expected`/`.expected_fail` using
// the exact same rules run_tests.sh has always used.
private TestResult runOne(string srcPath, TestOptions opts) {
    string base = stripExtension(baseName(srcPath));
    string testDir = dirName(srcPath);
    string expectedPath = buildPath(testDir, base ~ ".expected");
    string expectedFailPath = buildPath(testDir, base ~ ".expected_fail");
    string compileFailExpectedPath = buildPath(testDir, base ~ ".compile_fail.expected");
    string astExpectedPath = buildPath(testDir, base ~ ".ast.expected");
    string asyncLayoutExpectedPath = buildPath(testDir, base ~ ".async-layout.expected");
    string flagsPath = buildPath(testDir, base ~ ".flags");
    string tmpBin = buildPath(tempDir(), "llplbuild-test-" ~ base);
    string tmpC = buildPath(tempDir(), "llplbuild-test-" ~ base ~ ".c");
    string tmpAst = buildPath(tempDir(), "llplbuild-test-" ~ base ~ ".ast");

    scope (exit) if (exists(tmpBin)) remove(tmpBin);
    scope (exit) if (exists(tmpC)) remove(tmpC);
    scope (exit) if (exists(tmpAst)) remove(tmpAst);

    string[] flags = readFlags(flagsPath).split();

    if (exists(astExpectedPath)) {
        string[] astCmd = [opts.compiler] ~ flags ~ ["--emit-ast", srcPath, "-o", tmpAst];
        auto astResult = execute(astCmd);
        if (astResult.status != 0) {
            return TestResult(base, false, "", format("AST emit failed\n%s", astResult.output));
        }
        string actual = readText(tmpAst);
        string expected = readText(astExpectedPath);
        if (actual == expected) {
            return TestResult(base, true, "(AST golden)", "");
        }
        return TestResult(base, false, "", format(
            "AST output differs from %s\n--- expected\n%s\n--- actual\n%s",
            astExpectedPath, expected, actual));
    }

    if (exists(asyncLayoutExpectedPath)) {
        string[] layoutCmd = [opts.compiler] ~ flags ~ [srcPath, "-o", tmpAst];
        auto layoutResult = execute(layoutCmd);
        if (layoutResult.status != 0) {
            return TestResult(base, false, "", format("async layout emit failed\n%s", layoutResult.output));
        }
        string actual = readText(tmpAst);
        string expected = readText(asyncLayoutExpectedPath);
        if (actual == expected) {
            return TestResult(base, true, "(async layout golden)", "");
        }
        return TestResult(base, false, "", format(
            "async layout output differs from %s\n--- expected\n%s\n--- actual\n%s",
            asyncLayoutExpectedPath, expected, actual));
    }

    if (exists(compileFailExpectedPath)) {
        string[] compileCmd = [opts.compiler] ~ flags ~ [srcPath, "-o", tmpC];
        auto compileResult = execute(compileCmd);
        if (compileResult.status == 0) {
            return TestResult(base, false, "", "expected compile failure but compilation succeeded");
        }
        return compareExpectedPrefix(base, "(expected compile failure)",
            compileFailExpectedPath, compileResult.output);
    }

    string[] compileCmd = [opts.compiler] ~ flags ~ [srcPath, "-b", "-o", tmpBin];
    bool compilerRanTest = flags.canFind("--unittest");
    auto compileResult = execute(compileCmd);
    if (compileResult.status != 0 && !compilerRanTest) {
        return TestResult(base, false, "", format("compiler error\n%s", compileResult.output));
    }

    string actual;
    int rc;
    if (compilerRanTest) {
        actual = compileResult.output;
        rc = compileResult.status;
    } else {
        auto runResult = execute([tmpBin]);
        actual = runResult.output;
        rc = runResult.status;
    }

    if (exists(expectedFailPath)) {
        if (rc == 0) {
            return TestResult(base, false, "", "expected runtime failure but exited 0");
        }
        if (exists(expectedPath)) {
            return compareExpectedPrefix(base, "(expected failure)", expectedPath, actual);
        }
        return TestResult(base, true, "(expected failure, no output check)", "");
    }

    if (rc != 0) {
        return TestResult(base, false, "", format("runtime exit code %d\n%s", rc, actual));
    }

    if (exists(expectedPath)) {
        string expected = readText(expectedPath);
        if (actual == expected) {
            return TestResult(base, true, "", "");
        }
        return TestResult(base, false, "", format(
            "output differs from %s\n--- expected\n%s\n--- actual\n%s", expectedPath, expected, actual));
    }

    return TestResult(base, true, "(no expected output)", "");
}

// Runs every `<dir>/*.llpl` test (skipping configured names) in a thread
// pool capped at `opts.jobs` - tests are fully independent of each other,
// unlike a real build's dependency graph, so this is a plain worker pool
// rather than pipeline.d's dependency-aware scheduler. Returns the
// process exit code (0 all passed, 1 otherwise), matching run_tests.sh.
int runTests(TestOptions opts) {
    auto start = MonoTime.currTime;

    string[] sources;
    if (opts.paths.length > 0) {
        foreach (path; opts.paths) {
            if (isDir(path)) {
                foreach (entry; dirEntries(path, "*.llpl", SpanMode.shallow)) {
                    string base = stripExtension(baseName(entry.name));
                    if (opts.skip.canFind(base)) continue;
                    sources ~= entry.name;
                }
            } else {
                sources ~= path;
            }
        }
    } else {
        foreach (entry; dirEntries(opts.dir, "*.llpl", SpanMode.shallow)) {
            string base = stripExtension(baseName(entry.name));
            if (opts.skip.canFind(base)) continue;
            sources ~= entry.name;
        }
    }
    sources.sort();

    if (sources.length == 0) {
        writeln("running 0 tests");
        writeln();
        writeln("test result: ok. 0 passed; 0 failed");
        return 0;
    }

    writefln("running %d test%s", sources.length, sources.length == 1 ? "" : "s");

    TestResult[] results = new TestResult[](sources.length);
    auto mutex = new Mutex();
    auto cond = new Condition(mutex);
    size_t nextIdx = 0;
    size_t runningCount = 0;
    int maxJobs = opts.jobs > 0 ? opts.jobs : 1;
    bool[] launched = new bool[](sources.length);

    void worker() {
        while (true) {
            size_t idx;
            synchronized (mutex) {
                if (nextIdx >= sources.length) return;
                idx = nextIdx++;
            }
            results[idx] = runOne(sources[idx], opts);
        }
    }

    Thread[] threads;
    foreach (i; 0 .. min(maxJobs, cast(int)sources.length)) {
        auto t = new Thread(&worker);
        t.start();
        threads ~= t;
    }
    foreach (t; threads) t.join();

    // Cargo prints results in source order, not completion order (which
    // parallel execution makes nondeterministic) - already guaranteed
    // here since each worker writes into its own fixed `idx` slot.
    int passed = 0, failed = 0;
    foreach (r; results) {
        if (r.passed) {
            passed++;
            writefln("test %s ... %s", r.name, paintOk("ok") ~ (r.detail.length > 0 ? " " ~ r.detail : ""));
        } else {
            failed++;
            writefln("test %s ... %s", r.name, paintFail("FAILED"));
        }
    }

    if (failed > 0) {
        writeln();
        writeln("failures:");
        foreach (r; results) {
            if (r.passed) continue;
            writeln();
            writefln("---- %s ----", r.name);
            writeln(r.failure);
        }
        writeln();
        writeln("failures:");
        foreach (r; results) {
            if (!r.passed) writefln("    %s", r.name);
        }
    }

    writeln();
    writefln("test result: %s. %d passed; %d failed; finished in %s",
        failed == 0 ? "ok" : "FAILED", passed, failed, formatElapsed(MonoTime.currTime - start));

    return failed == 0 ? 0 : 1;
}
