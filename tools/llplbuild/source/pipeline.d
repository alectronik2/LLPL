module pipeline;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;
import std.string;
import core.thread;
import core.sync.condition;
import core.sync.mutex;
import buildconfig;
import terminal;

struct RunOptions {
    int jobs = 4;
}

final class BuildError : Exception {
    this(string msg) { super(msg); }
}

private SysTime mtimeOrMin(string path) {
    if (!exists(path)) return SysTime.min;
    return timeLastModified(path);
}

// A step is up to date (skippable) when every declared output already
// exists and is newer than every declared input *and* newer than the
// config file itself - editing build.yaml invalidates everything
// downstream, the same "the declaration is the source of truth" stance
// checkArrayLiteralInit takes for a const array alias elsewhere in this
// project (see codegen.d).
private bool isUpToDate(const string[] outputs, const string[] inputs, string configPath) {
    if (outputs.length == 0) return false;
    foreach (o; outputs) if (!exists(o)) return false;
    SysTime oldestOutput = outputs.map!(o => mtimeOrMin(o)).reduce!min;
    foreach (i; inputs) {
        if (mtimeOrMin(i) > oldestOutput) return false;
    }
    if (mtimeOrMin(configPath) > oldestOutput) return false;
    return true;
}

// One thing to do. Steps sharing the same positive `parallelGroup` are
// independent of each other and may be launched together (see
// runPlan) - `0` means "run alone, in plan order".
private enum StepKind { compileLlpl, assemble, compileC, link, action, persistentCreate, packageGate }

private struct PlanStep {
    StepKind kind;
    string description;
    string[] inputs;
    string[] outputs;
    string[] cmd;          // for compileLlpl/assemble/compileC/link
    PackageAction pkgAction; // for kind == action
    string persistentPath;  // for kind == persistentCreate
    string persistentCreateCmd;
    bool allowFailure;
    int parallelGroup;
}

private string objPathFor(string srcPath, string defaultOutput = "") {
    if (defaultOutput.length > 0) return defaultOutput;
    return stripExtension(baseName(srcPath)) ~ ".o";
}

// Every `.llpl` file under the project directory, plus prelude.llpl next
// to the llpl compiler binary - a conservative over-approximation of
// kernel.llpl's real transitive `import` graph (which would need this
// tool to either re-parse imports itself or ask the compiler for them).
// Erring toward "rebuild when in doubt" rather than reimplementing
// module resolution here is the right trade-off for a build tool whose
// actual correctness-critical logic lives in the compiler, not in this
// dependency estimate.
private string[] allLlplSources(string projectDir, string llplCompiler) {
    string[] result;
    foreach (entry; dirEntries(projectDir, "*.llpl", SpanMode.depth)) {
        result ~= entry.name;
    }
    string preludePath = buildNormalizedPath(dirName(llplCompiler), "prelude.llpl");
    if (exists(preludePath)) result ~= preludePath;
    return result;
}

private PlanStep[] buildPlan(const BuildConfig cfg, const Configuration* config) {
    PlanStep[] plan;

    string[] cflags = cfg.commonCflags.dup;
    if (config !is null) cflags ~= config.cflags;

    string generatedC = stripExtension(cfg.entry) ~ ".c";
    string[] llplDeps = allLlplSources(".", cfg.llplCompiler);

    plan ~= PlanStep(StepKind.compileLlpl,
        format("Compiling %s", cfg.entry),
        llplDeps,
        [generatedC],
        [cfg.llplCompiler, cfg.entry, "-o", generatedC],
        PackageAction.init, "", "", false, 0);

    foreach (a; cfg.asmSources) {
        plan ~= PlanStep(StepKind.assemble,
            format("Assembling %s", a.src),
            [a.src],
            [a.output],
            [cfg.nasm, "-f", "elf64", a.src, "-o", a.output],
            PackageAction.init, "", "", false, 1);
    }

    foreach (src; cfg.cSources) {
        string obj = objPathFor(src.path, src.objOutput);
        string[] cmd = [cfg.cc] ~ cflags ~ src.cflags;
        foreach (dir; src.includeDirs) cmd ~= ["-I", dir];
        cmd ~= ["-c", src.path, "-o", obj];
        string[] inputs = [src.path, configStampPath];
        // Generated C may keep a stale/unchanged mtime when the LLPL
        // compiler rewrites it quickly. Make the object depend directly
        // on the LLPL source set too, so imported modules always
        // invalidate the C compilation stage.
        if (src.path == generatedC) inputs ~= llplDeps;
        plan ~= PlanStep(StepKind.compileC,
            format("Compiling %s", src.path),
            inputs,
            [obj],
            cmd,
            PackageAction.init, "", "", false, 1);
    }

    if (cfg.hasLink) {
        string[] cmd = [cfg.ld] ~ cfg.link.ldflags.dup;
        if (cfg.link.script.length > 0) cmd ~= ["-T", cfg.link.script];
        cmd ~= cfg.link.objects;
        cmd ~= ["-o", cfg.link.output];
        string[] inputs = cfg.link.objects.dup;
        if (cfg.link.script.length > 0) inputs ~= cfg.link.script;
        plan ~= PlanStep(StepKind.link,
            format("Linking %s", cfg.link.output),
            inputs,
            [cfg.link.output],
            cmd,
            PackageAction.init, "", "", false, 0);
    }

    foreach (i, el; cfg.extraLinks) {
        int group = 100 + cast(int)i; // its own asm sources run together, independent of everything else in this group id
        foreach (src; el.llplSources) {
            plan ~= PlanStep(StepKind.compileLlpl,
                format("Compiling %s (%s)", src.src, el.name),
                llplDeps,
                [src.cOutput],
                [cfg.llplCompiler, src.src, "-o", src.cOutput],
                PackageAction.init, "", "", false, 0);

            string[] cmd = [cfg.cc] ~ cflags ~ src.cflags;
            foreach (dir; src.includeDirs) cmd ~= ["-I", dir];
            cmd ~= ["-c", src.cOutput, "-o", src.objOutput];
            plan ~= PlanStep(StepKind.compileC,
                format("Compiling %s (%s)", src.cOutput, el.name),
                [src.cOutput, configStampPath] ~ llplDeps,
                [src.objOutput],
                cmd,
                PackageAction.init, "", "", false, group);
        }
        foreach (a; el.asmSources) {
            plan ~= PlanStep(StepKind.assemble,
                format("Assembling %s (%s)", a.src, el.name),
                [a.src],
                [a.output],
                [cfg.nasm, "-f", "elf64", a.src, "-o", a.output],
                PackageAction.init, "", "", false, group);
        }
        foreach (src; el.cSources) {
            string obj = objPathFor(src.path, src.objOutput);
            string[] ccmd = [cfg.cc] ~ cflags ~ src.cflags;
            foreach (dir; src.includeDirs) ccmd ~= ["-I", dir];
            ccmd ~= ["-c", src.path, "-o", obj];
            plan ~= PlanStep(StepKind.compileC,
                format("Compiling %s (%s)", src.path, el.name),
                [src.path, configStampPath],
                [obj],
                ccmd,
                PackageAction.init, "", "", false, group);
        }
        string[] cmd = [cfg.ld] ~ el.link.ldflags.dup;
        if (el.link.script.length > 0) cmd ~= ["-T", el.link.script];
        cmd ~= el.link.objects;
        cmd ~= ["-o", el.link.output];
        string[] inputs = el.link.objects.dup;
        if (el.link.script.length > 0) inputs ~= el.link.script;
        plan ~= PlanStep(StepKind.link,
            format("Linking %s (%s)", el.link.output, el.name),
            inputs,
            [el.link.output],
            cmd,
            PackageAction.init, "", "", false, 0);
    }

    if (cfg.hasPackage) {
        // The whole package (ISO/etc.) is one incremental unit, same
        // granularity Make gave it - its inputs are every binary this
        // config just linked, not each individual copy/write/run action.
        //
        // Whether it's stale can only be judged once every one of those
        // inputs has actually been (re)built - not here, since buildPlan
        // runs entirely before runPlan executes a single compile/link step,
        // so checking mtimes now would compare against each input's
        // *pre-build* state. A link step earlier in this very plan can
        // regenerate one of these inputs; deciding staleness this early
        // would miss that and silently skip re-packaging a binary that
        // just changed. So this only plants a gate - runPlan re-evaluates
        // it live, right before the actions below would run, once
        // everything ahead of it in the plan has already executed.
        string[] pkgInputs;
        if (cfg.hasLink) pkgInputs ~= cfg.link.output;
        foreach (el; cfg.extraLinks) pkgInputs ~= el.link.output;

        plan ~= PlanStep(StepKind.packageGate, format("Packaging %s", cfg.pkg.output),
            pkgInputs, [cfg.pkg.output], [], PackageAction.init, "", "", false, 0);

        foreach (action; cfg.pkg.actions) {
            string desc;
            final switch (action.kind) {
                case ActionKind.mkdir: desc = format("mkdir %s", action.mkdirPath); break;
                case ActionKind.copy: desc = format("copy %s -> %s", action.copyFrom, action.copyTo); break;
                case ActionKind.write: desc = format("write %s", action.writeTo); break;
                case ActionKind.run: desc = format("run: %s", action.runCmd); break;
                case ActionKind.requireFile: desc = format("check %s", action.requireFilePath); break;
            }
            // No incremental inputs/outputs on the individual action - the
            // gate above is what decides whether this whole batch runs.
            plan ~= PlanStep(StepKind.action, desc, [], [], [],
                action, "", "", action.allowFailure, 0);
        }
    }

    foreach (pf; cfg.persistentFiles) {
        plan ~= PlanStep(StepKind.persistentCreate,
            format("Creating %s", pf.path),
            [], [pf.path], [], PackageAction.init, pf.path, pf.create, false, 0);
    }

    return plan;
}

private void runCommand(string[] cmd, bool allowFailure, string description) {
    Pid pid;
    try {
        pid = spawnProcess(cmd);
    } catch (ProcessException e) {
        if (allowFailure) {
            logWarn(format("%s: '%s' not found, skipping (allow_failure)", description, cmd[0]));
            return;
        }
        throw new BuildError(format("%s: couldn't run '%s': %s", description, cmd[0], e.msg));
    }
    int code = wait(pid);
    if (code != 0 && !allowFailure) {
        throw new BuildError(format("%s failed (exit %d): %s", description, code, cmd.join(" ")));
    }
    if (code != 0) {
        logWarn(format("%s failed (exit %d) - continuing (allow_failure)", description, code));
    }
}

private void runAction(PackageAction action) {
    final switch (action.kind) {
        case ActionKind.mkdir:
            mkdirRecurse(action.mkdirPath);
            break;
        case ActionKind.copy:
            std.file.copy(action.copyFrom, action.copyTo);
            break;
        case ActionKind.write:
            std.file.write(action.writeTo, action.writeContent);
            break;
        case ActionKind.run:
            runCommand(["/bin/sh", "-c", action.runCmd], action.allowFailure, action.runCmd);
            break;
        case ActionKind.requireFile:
            if (!exists(action.requireFilePath)) {
                string msg = action.requireFileMessage.length > 0
                    ? action.requireFileMessage
                    : format("required file '%s' not found", action.requireFilePath);
                throw new BuildError(msg);
            }
            break;
    }
}

private void executeStep(PlanStep step) {
    final switch (step.kind) {
        case StepKind.compileLlpl:
        case StepKind.assemble:
        case StepKind.compileC:
        case StepKind.link:
            runCommand(step.cmd, false, step.description);
            break;
        case StepKind.action:
            try {
                runAction(step.pkgAction);
            } catch (BuildError e) {
                throw e;
            } catch (Exception e) {
                if (!step.allowFailure) {
                    throw new BuildError(format("%s: %s", step.description, e.msg));
                }
                logWarn(format("%s: %s - continuing (allow_failure)", step.description, e.msg));
            }
            break;
        case StepKind.persistentCreate:
            if (!exists(step.persistentPath)) {
                runCommand(["/bin/sh", "-c", step.persistentCreateCmd], false, step.description);
            }
            break;
        case StepKind.packageGate:
            break; // never actually executed - runPlan checks and consumes it directly (see below)
    }
}

private void runPlan(PlanStep[] plan, string configPath, RunOptions opts) {
    StepCounter counter;
    counter.total = cast(int)plan.length;

    void runBuildChunk(size_t start, size_t end) {
        if (start >= end) return;

        PlanStep[] steps = plan[start .. end];
        size_t n = steps.length;
        bool[] done = new bool[](n);
        bool[] running = new bool[](n);
        bool[] willRun = new bool[](n);
        int[] remainingDeps = new int[](n);
        size_t[][string] consumersByOutput;
        size_t[string] producerByOutput;
        size_t doneCount = 0;
        size_t runningCount = 0;

        foreach (idx, s; steps) {
            foreach (o; s.outputs) {
                if (o.length > 0) producerByOutput[o] = idx;
            }
            willRun[idx] = !isUpToDate(s.outputs, s.inputs, configPath);
        }

        bool changed = true;
        while (changed) {
            changed = false;
            foreach (idx, s; steps) {
                if (willRun[idx]) continue;
                foreach (input; s.inputs) {
                    if (auto producer = input in producerByOutput) {
                        if (willRun[*producer]) {
                            willRun[idx] = true;
                            changed = true;
                            break;
                        }
                    }
                }
            }
        }

        foreach (idx, s; steps) {
            if (!willRun[idx]) {
                counter.skipped(s.description);
                done[idx] = true;
                doneCount++;
            } else {
                counter.step(s.description);
            }
        }

        foreach (idx, s; steps) {
            if (done[idx]) continue;
            foreach (input; s.inputs) {
                if (auto producer = input in producerByOutput) {
                    if (!done[*producer]) {
                        remainingDeps[idx]++;
                        consumersByOutput[input] ~= idx;
                    }
                }
            }
        }

        Thread[] threads = new Thread[](n);
        string[] errors = new string[](n);
        size_t[] completed;
        auto completeMutex = new Mutex();
        auto completeCond = new Condition(completeMutex);
        int maxJobs = opts.jobs > 0 ? opts.jobs : 1;

        void launch(size_t idx) {
            running[idx] = true;
            runningCount++;
            auto worker = new Thread({
                string error;
                try {
                    executeStep(steps[idx]);
                } catch (BuildError e) {
                    error = e.msg;
                } catch (Exception e) {
                    error = format("%s: %s", steps[idx].description, e.msg);
                }
                synchronized (completeMutex) {
                    errors[idx] = error;
                    completed ~= idx;
                    completeCond.notify();
                }
            });
            worker.start();
            threads[idx] = worker;
        }

        size_t waitForFinishedWorker() {
            synchronized (completeMutex) {
                while (completed.length == 0) {
                    completeCond.wait();
                }
                size_t idx = completed[$ - 1];
                completed.length = completed.length - 1;
                return idx;
            }
        }

        void finishWorker(size_t finishedIdx) {
            threads[finishedIdx].join();
            if (errors[finishedIdx].length > 0) {
                throw new BuildError(errors[finishedIdx]);
            }

            running[finishedIdx] = false;
            done[finishedIdx] = true;
            doneCount++;
            runningCount--;

            foreach (output; steps[finishedIdx].outputs) {
                if (auto consumers = output in consumersByOutput) {
                    foreach (consumer; *consumers) {
                        if (remainingDeps[consumer] > 0) remainingDeps[consumer]--;
                    }
                }
            }
        }

        while (doneCount < n) {
            bool launchedAny = false;
            while (runningCount < cast(size_t)maxJobs) {
                size_t readyIdx = n;
                foreach (idx; 0 .. n) {
                    if (!done[idx] && !running[idx] && remainingDeps[idx] == 0) {
                        readyIdx = idx;
                        break;
                    }
                }
                if (readyIdx == n) break;
                launch(readyIdx);
                launchedAny = true;
            }

            if (runningCount == 0) {
                throw new BuildError("internal build scheduler error: no runnable steps; check for circular or missing dependencies");
            }

            if (!launchedAny && runningCount >= cast(size_t)maxJobs) {
                // Fall through and wait for a worker below.
            }

            finishWorker(waitForFinishedWorker());
        }
    }

    size_t i = 0;
    while (i < plan.length) {
        size_t chunkStart = i;
        while (i < plan.length && plan[i].kind != StepKind.packageGate && plan[i].kind != StepKind.action) {
            i++;
        }
        runBuildChunk(chunkStart, i);
        if (i >= plan.length) break;

        // The whole package (ISO/etc.) is judged up to date or stale here,
        // live - every step ahead of it in the plan has already executed
        // (or been skipped) by this point, so its inputs' mtimes now
        // reflect reality instead of pre-build state (see buildPlan).
        if (plan[i].kind == StepKind.packageGate) {
            if (isUpToDate(plan[i].outputs, plan[i].inputs, configPath)) {
                counter.skipped(plan[i].description);
                i++;
                // The actions covered by this gate carry no incremental
                // inputs/outputs of their own (see buildPlan) - without
                // this, they'd run unconditionally despite the package
                // itself being up to date.
                while (i < plan.length && plan[i].kind == StepKind.action) {
                    counter.skipped(plan[i].description);
                    i++;
                }
            } else {
                i++;
            }
            continue;
        }

        if (plan[i].kind == StepKind.action) {
            counter.step(plan[i].description);
            executeStep(plan[i]);
            i++;
            continue;
        }
    }
}

// Plain mtime comparison alone can't tell "the config changed" from "the
// config is unchanged" - a C-compile step's inputs/outputs on disk look
// identical either way, since cflags never appear in a file. This one-
// line stamp file closes that gap: whenever the resolved configuration
// name differs from what's recorded here, the stamp's mtime is bumped,
// and every compile step lists it as an extra input (see buildPlan) - so
// switching from `final` to `debug` (or back) correctly invalidates and
// recompiles every C source, exactly like any other changed input would.
private enum configStampPath = ".llplbuild-config";

private void touchConfigStamp(string resolvedName) {
    string previous = exists(configStampPath) ? readText(configStampPath) : "";
    if (previous != resolvedName) {
        std.file.write(configStampPath, resolvedName);
    }
}

void build(BuildConfig cfg, string configName, RunOptions opts) {
    chdir(cfg.configDir);

    const(Configuration)* config = null;
    if (configName.length > 0) {
        if (auto c = configName in cfg.configurations) config = c;
        else throw new BuildError(format("unknown configuration '%s' (see 'llplbuild configs')", configName));
    } else if (cfg.defaultConfig.length > 0) {
        config = cfg.defaultConfig in cfg.configurations;
    }

    touchConfigStamp(config !is null ? config.name : "");

    auto plan = buildPlan(cfg, config);
    runPlan(plan, cfg.configPath, opts);
    logOk(format("Build complete (%s)", config !is null ? config.name : "no configuration"));
}

void run(BuildConfig cfg, string configName, RunOptions opts) {
    build(cfg, configName, opts);
    if (!cfg.hasRun) {
        throw new BuildError("this build.yaml has no 'run:' section");
    }
    string[] cmd = [cfg.qemu] ~ cfg.runArgs;
    logInfo(format("Running: %s", cmd.join(" ")));
    auto pid = spawnProcess(cmd);
    wait(pid);
}

// Every path this config could ever produce, across every configuration
// (cflags don't change *which* files exist, only their contents) -
// `clean` removes exactly this set, matching the old Makefile's explicit
// `rm -f`/`rm -rf` lists (including persisted files like disk.img, which
// the Makefile's own `clean:` target wiped too).
void clean(BuildConfig cfg) {
    chdir(cfg.configDir);

    string[] files;
    string[] dirs;

    files ~= configStampPath;
    files ~= stripExtension(cfg.entry) ~ ".c";
    foreach (src; cfg.cSources) files ~= objPathFor(src.path, src.objOutput);
    foreach (a; cfg.asmSources) files ~= a.output;
    if (cfg.hasLink) files ~= cfg.link.output;
    foreach (el; cfg.extraLinks) {
        foreach (src; el.llplSources) {
            files ~= src.cOutput;
            files ~= src.objOutput;
        }
        foreach (a; el.asmSources) files ~= a.output;
        foreach (src; el.cSources) files ~= objPathFor(src.path, src.objOutput);
        files ~= el.link.output;
    }
    if (cfg.hasPackage) {
        files ~= cfg.pkg.output;
        foreach (action; cfg.pkg.actions) {
            if (action.kind == ActionKind.mkdir) {
                dirs ~= pathSplitter(action.mkdirPath).front.to!string;
            }
        }
    }
    foreach (pf; cfg.persistentFiles) files ~= pf.path;

    foreach (f; files.sort().uniq()) {
        if (exists(f) && isFile(f)) {
            remove(f);
            logInfo(format("removed %s", f));
        }
    }
    foreach (d; dirs.sort().uniq()) {
        if (exists(d) && isDir(d)) {
            rmdirRecurse(d);
            logInfo(format("removed %s/", d));
        }
    }
    logOk("Clean complete");
}

void listConfigs(BuildConfig cfg) {
    if (cfg.configurations.length == 0) {
        writeln("(no configurations declared - build always uses common_cflags only)");
        return;
    }
    foreach (name, config; cfg.configurations) {
        string marker = name == cfg.defaultConfig ? " (default)" : "";
        writefln("%s%s: %s", name, marker, config.cflags.join(" "));
    }
}
