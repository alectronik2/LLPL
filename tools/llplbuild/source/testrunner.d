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

// Runs one test end to end: compile via `-b` (already applies
// -funsigned-char - see source/main.d - so unlike run_tests.sh's old
// two-step compile+gcc, this is a single command), run the resulting
// binary, and compare against `<name>.expected`/`.expected_fail` using
// the exact same rules run_tests.sh has always used.
private TestResult runOne(string srcPath, TestOptions opts) {
    string base = stripExtension(baseName(srcPath));
    string expectedPath = buildPath(opts.dir, base ~ ".expected");
    string expectedFailPath = buildPath(opts.dir, base ~ ".expected_fail");
    string flagsPath = buildPath(opts.dir, base ~ ".flags");
    string tmpBin = buildPath(tempDir(), "llplbuild-test-" ~ base);

    scope (exit) if (exists(tmpBin)) remove(tmpBin);

    string[] flags = readFlags(flagsPath).split();
    string[] compileCmd = [opts.compiler] ~ flags ~ [srcPath, "-b", "-o", tmpBin];
    auto compileResult = execute(compileCmd);
    if (compileResult.status != 0) {
        return TestResult(base, false, "", format("compiler error\n%s", compileResult.output));
    }

    auto runResult = execute([tmpBin]);
    string actual = runResult.output;
    int rc = runResult.status;

    if (exists(expectedFailPath)) {
        if (rc == 0) {
            return TestResult(base, false, "", "expected runtime failure but exited 0");
        }
        if (exists(expectedPath)) {
            string expected = readText(expectedPath);
            string prefix = actual.length >= expected.length ? actual[0 .. expected.length] : actual;
            if (prefix == expected) {
                return TestResult(base, true, "(expected failure)", "");
            }
            return TestResult(base, false, "", format(
                "expected failure output prefix differs\n--- expected\n%s\n--- actual (first %d bytes)\n%s",
                expected, expected.length, prefix));
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
    foreach (entry; dirEntries(opts.dir, "*.llpl", SpanMode.shallow)) {
        string base = stripExtension(baseName(entry.name));
        if (opts.skip.canFind(base)) continue;
        sources ~= entry.name;
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
