module buildconfig;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.string;
import dyaml;

// One `c_sources`/`extra_links[].asm_sources` entry, plus a runtime-only
// `objOutput` this module fills in (either given explicitly in YAML or
// derived from the source's own basename - see resolveObjectOutputs).
struct CSource {
    string path;
    string[] includeDirs;
    string objOutput;
}

struct AsmSource {
    string src;
    string output;
}

struct LinkSpec {
    string output;
    string script; // "" means no -T
    string[] ldflags;
    string[] objects;
}

struct ExtraLink {
    string name;
    AsmSource[] asmSources;
    LinkSpec link;
}

enum ActionKind { mkdir, copy, write, run, requireFile }

struct PackageAction {
    ActionKind kind;
    string mkdirPath;
    string copyFrom;
    string copyTo;
    string writeTo;
    string writeContent;
    string runCmd;
    string requireFilePath;
    string requireFileMessage;
    bool allowFailure;
}

struct PackageSpec {
    string output;
    PackageAction[] actions;
}

struct PersistentFile {
    string path;
    string create;
}

struct Configuration {
    string name;
    string[] cflags;
}

// A fully-parsed `build.yaml` - one instance covers one target directory.
// String fields may still contain unexpanded `${VAR}` references until
// `substituteVariables` runs (see main.d, which resolves `variables:`
// against the environment and `--var` overrides first).
struct BuildConfig {
    string project;
    string entry;
    string llplCompiler = "../../llpl";
    string[string] variables;

    string nasm = "nasm";
    string cc = "gcc";
    string ld = "ld";
    string qemu = "qemu-system-x86_64";

    string[] commonCflags;
    string defaultConfig;
    Configuration[string] configurations;

    CSource[] cSources;
    AsmSource[] asmSources;

    bool hasLink;
    LinkSpec link;

    ExtraLink[] extraLinks;

    bool hasPackage;
    PackageSpec pkg;

    PersistentFile[] persistentFiles;

    bool hasRun;
    string[] runArgs;

    string configPath; // absolute path to the build.yaml itself
    string configDir;  // its containing directory - every relative path in
                        // this struct is relative to it, matching how `make`
                        // is always invoked from within the target directory
}

private string ctx(string path, string field) {
    return format("%s: '%s'", path, field);
}

private string requireStr(Node node, string key, string errCtx) {
    if (auto v = key in node) return (*v).as!string;
    throw new Exception(format("%s: missing required field '%s'", errCtx, key));
}

private string getStr(Node node, string key, string def = "") {
    if (auto v = key in node) return (*v).as!string;
    return def;
}

private string[] getStrList(Node node, string key) {
    string[] result;
    if (auto v = key in node) {
        foreach (string s; *v) result ~= s;
    }
    return result;
}

private bool getBool(Node node, string key, bool def = false) {
    if (auto v = key in node) return (*v).as!bool;
    return def;
}

private AsmSource[] parseAsmSources(Node node, string errCtx) {
    AsmSource[] result;
    if (auto v = "asm_sources" in node) {
        foreach (Node entry; *v) {
            string src = requireStr(entry, "src", errCtx ~ ".asm_sources[]");
            string output = getStr(entry, "output", stripExtension(baseName(src)) ~ ".o");
            result ~= AsmSource(src, output);
        }
    }
    return result;
}

private LinkSpec parseLink(Node node, string errCtx) {
    LinkSpec link;
    link.output = requireStr(node, "output", errCtx);
    link.script = getStr(node, "script");
    link.ldflags = getStrList(node, "ldflags");
    link.objects = getStrList(node, "objects");
    return link;
}

private PackageAction parseAction(Node node, string errCtx) {
    PackageAction action;
    action.allowFailure = getBool(node, "allow_failure");
    if (auto v = "mkdir" in node) {
        action.kind = ActionKind.mkdir;
        action.mkdirPath = (*v).as!string;
    } else if (auto v = "copy" in node) {
        action.kind = ActionKind.copy;
        action.copyFrom = requireStr(*v, "from", errCtx ~ ".copy");
        action.copyTo = requireStr(*v, "to", errCtx ~ ".copy");
    } else if (auto v = "write" in node) {
        action.kind = ActionKind.write;
        action.writeTo = requireStr(*v, "to", errCtx ~ ".write");
        action.writeContent = requireStr(*v, "content", errCtx ~ ".write");
    } else if (auto v = "run" in node) {
        action.kind = ActionKind.run;
        action.runCmd = (*v).as!string;
    } else if (auto v = "require_file" in node) {
        action.kind = ActionKind.requireFile;
        action.requireFilePath = requireStr(*v, "path", errCtx ~ ".require_file");
        action.requireFileMessage = getStr(*v, "message");
    } else {
        throw new Exception(format(
            "%s: expected one of mkdir/copy/write/run/require_file", errCtx));
    }
    return action;
}

BuildConfig loadConfig(string path) {
    string absPath = absolutePath(path).buildNormalizedPath();
    Node root = Loader.fromFile(absPath).load();

    BuildConfig cfg;
    cfg.configPath = absPath;
    cfg.configDir = dirName(absPath);

    cfg.project = requireStr(root, "project", absPath);
    cfg.entry = requireStr(root, "entry", absPath);
    cfg.llplCompiler = getStr(root, "llpl_compiler", "../../llpl");

    if (auto v = "variables" in root) {
        foreach (string name, string value; *v) {
            cfg.variables[name] = value;
        }
    }

    if (auto v = "toolchain" in root) {
        cfg.nasm = getStr(*v, "nasm", "nasm");
        cfg.cc = getStr(*v, "cc", "gcc");
        cfg.ld = getStr(*v, "ld", "ld");
        cfg.qemu = getStr(*v, "qemu", "qemu-system-x86_64");
    }

    cfg.commonCflags = getStrList(root, "common_cflags");
    cfg.defaultConfig = getStr(root, "default_config");

    if (auto v = "configurations" in root) {
        foreach (string name, Node entry; *v) {
            Configuration c;
            c.name = name;
            c.cflags = getStrList(entry, "cflags");
            cfg.configurations[name] = c;
        }
    }
    if (cfg.defaultConfig.length == 0 && cfg.configurations.length > 0) {
        throw new Exception(format(
            "%s: 'configurations' is set but 'default_config' is missing", absPath));
    }
    if (cfg.defaultConfig.length > 0 && cfg.defaultConfig !in cfg.configurations) {
        throw new Exception(format(
            "%s: default_config '%s' isn't one of the declared configurations",
            absPath, cfg.defaultConfig));
    }

    if (auto v = "c_sources" in root) {
        foreach (Node entry; *v) {
            CSource src;
            src.path = requireStr(entry, "path", absPath ~ ".c_sources[]");
            src.includeDirs = getStrList(entry, "include_dirs");
            cfg.cSources ~= src;
        }
    }

    cfg.asmSources = parseAsmSources(root, absPath);

    if (auto v = "link" in root) {
        cfg.hasLink = true;
        cfg.link = parseLink(*v, absPath ~ ".link");
    }

    if (auto v = "extra_links" in root) {
        foreach (Node entry; *v) {
            ExtraLink el;
            el.name = requireStr(entry, "name", absPath ~ ".extra_links[]");
            el.asmSources = parseAsmSources(entry, absPath ~ ".extra_links." ~ el.name);
            el.link = parseLink(entry["link"], absPath ~ ".extra_links." ~ el.name ~ ".link");
            cfg.extraLinks ~= el;
        }
    }

    if (auto v = "package" in root) {
        cfg.hasPackage = true;
        cfg.pkg.output = requireStr(*v, "output", absPath ~ ".package");
        if (auto actions = "actions" in *v) {
            foreach (Node entry; *actions) {
                cfg.pkg.actions ~= parseAction(entry, absPath ~ ".package.actions[]");
            }
        }
    }

    if (auto v = "persistent_files" in root) {
        foreach (Node entry; *v) {
            PersistentFile pf;
            pf.path = requireStr(entry, "path", absPath ~ ".persistent_files[]");
            pf.create = requireStr(entry, "create", absPath ~ ".persistent_files[]");
            cfg.persistentFiles ~= pf;
        }
    }

    if (auto v = "run" in root) {
        cfg.hasRun = true;
        cfg.runArgs = getStrList(*v, "args");
    }

    return cfg;
}

// Resolves the final `variables:` map for one build: YAML's own defaults,
// overridden by same-named environment variables (matching Make's `?=`
// convention the old Makefiles used for LIMINE_DIR), overridden last by
// explicit `--var NAME=value` CLI flags - the same three-tier precedence
// Make gave for free, made explicit since this format has no built-in
// notion of "environment" the way Make does.
string[string] resolveVariables(const BuildConfig cfg, string[string] env,
        string[string] cliOverrides) {
    string[string] result = cfg.variables.dup;
    foreach (name, def; cfg.variables) {
        if (auto envVal = name in env) {
            result[name] = *envVal;
        }
    }
    foreach (name, val; cliOverrides) {
        result[name] = val;
    }
    return result;
}

private string substitute(string s, const string[string] vars) {
    if (s.indexOf("${") < 0) return s;
    string result = s;
    foreach (name, val; vars) {
        result = result.replace("${" ~ name ~ "}", val);
    }
    return result;
}

private string[] substituteList(string[] list, const string[string] vars) {
    return list.map!(s => substitute(s, vars)).array;
}

// Expands every `${VAR}` reference across the config's string fields in
// place - applied once, right after `resolveVariables`, so every later
// pipeline stage only ever sees already-substituted, real paths/commands.
void substituteVariables(ref BuildConfig cfg, const string[string] vars) {
    cfg.commonCflags = substituteList(cfg.commonCflags, vars);
    foreach (name, ref c; cfg.configurations) {
        c.cflags = substituteList(c.cflags, vars);
    }
    foreach (ref src; cfg.cSources) {
        src.path = substitute(src.path, vars);
        src.includeDirs = substituteList(src.includeDirs, vars);
    }
    foreach (ref a; cfg.asmSources) {
        a.src = substitute(a.src, vars);
        a.output = substitute(a.output, vars);
    }
    void substLink(ref LinkSpec link) {
        link.output = substitute(link.output, vars);
        link.script = substitute(link.script, vars);
        link.ldflags = substituteList(link.ldflags, vars);
        link.objects = substituteList(link.objects, vars);
    }
    if (cfg.hasLink) substLink(cfg.link);
    foreach (ref el; cfg.extraLinks) {
        foreach (ref a; el.asmSources) {
            a.src = substitute(a.src, vars);
            a.output = substitute(a.output, vars);
        }
        substLink(el.link);
    }
    if (cfg.hasPackage) {
        cfg.pkg.output = substitute(cfg.pkg.output, vars);
        foreach (ref action; cfg.pkg.actions) {
            final switch (action.kind) {
                case ActionKind.mkdir:
                    action.mkdirPath = substitute(action.mkdirPath, vars);
                    break;
                case ActionKind.copy:
                    action.copyFrom = substitute(action.copyFrom, vars);
                    action.copyTo = substitute(action.copyTo, vars);
                    break;
                case ActionKind.write:
                    action.writeTo = substitute(action.writeTo, vars);
                    action.writeContent = substitute(action.writeContent, vars);
                    break;
                case ActionKind.run:
                    action.runCmd = substitute(action.runCmd, vars);
                    break;
                case ActionKind.requireFile:
                    action.requireFilePath = substitute(action.requireFilePath, vars);
                    action.requireFileMessage = substitute(action.requireFileMessage, vars);
                    break;
            }
        }
    }
    foreach (ref pf; cfg.persistentFiles) {
        pf.path = substitute(pf.path, vars);
        pf.create = substitute(pf.create, vars);
    }
    cfg.runArgs = substituteList(cfg.runArgs, vars);
}
