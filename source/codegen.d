module codegen;

import std.stdio;
import std.string;
import std.format;
import std.conv;
import std.array;
import std.algorithm;
import std.range;
import std.path;
import std.file;
import ast;
import errors;

// Declaration-site info for one top-level symbol (function, class, struct,
// macro, global var/const/enum-member) or one class method/field (`name`
// is dotted, e.g. "Console_Screen.write", for the latter). Built by
// CodeGenerator.generateMultiple as a side effect of normal codegen, for
// LSP-style tooling (see lspquery.d) - hover text, go-to-definition, and
// completion all come from this list.
struct SymbolInfo {
    string name;
    string kind; // "function", "class", "struct", "macro", "variable", "field", "method"
    string file;
    int line;
    int column;
    string signature;
}

// One resolved reference to a symbol at a source location - e.g. a call,
// a bare variable read, a `new Foo(...)`, a qualified `Ns.CONST` access.
// `name` matches a SymbolInfo.name. Also built as a side effect of normal
// codegen (see the various generateExpression branches and
// generateMacroExpansion). Powers go-to-definition (map cursor position ->
// usage -> resolved name -> SymbolInfo) and find-references (collect every
// usage with a given name).
struct UsageInfo {
    string name;
    string file;
    int line;
    int column;
}

// One active `try` block's redirect/replay state - see generateTryStmt,
// generateThrowStmt, and generatePropagateExpr's use of tryFrameStack below.
private struct TryFrame {
    string catchLabel;    // "" disables throw/? redirection (no catch clause, or
                           // we're generating *this* try's own catch block)
    string errorVarName;  // C variable a redirecting throw/? assigns into
    Type errorType;       // set by the first redirected throw/? seen in this
                           // try's tryBlock; every later one in the same try
                           // must match
    string[] finallyCode; // this try's finally block, pre-generated once
                           // (empty if there's no finally clause)
    string frameVarName;
}

private struct DeferInfo {
    string code;
    string frameVarName;
    string activeVarName;
}

// resolveGenericFunctionCall's result - the monomorphized function's
// mangled name plus the call's arguments already resolved to plain
// positional form (named args placed, defaults substituted) - see
// CodeGenerator.resolveCallArguments. Every caller needs mangledName;
// only the one that actually generates the call's C argument list needs
// resolvedArgs too.
private struct GenericCallResolution {
    string mangledName;
    ASTNode[] resolvedArgs;
}

class CodeGenerator {
    private int indentLevel;
    private DeferInfo[] deferredStatements;
    // Stack of TryFrames, innermost last - what throw/`?` inside a try block
    // redirects to (see generatePropagateExpr) instead of returning from
    // the enclosing function, and what a `return` anywhere inside a try or
    // its catch block needs to replay (that try's finally) before actually
    // returning - see generateStatement's ReturnStmt case, which replays
    // this (innermost-to-outermost) *before* deferredStatements, so a
    // try's own cleanup runs before any function-level defer.
    private TryFrame[] tryFrameStack;
    private int tryCounter; // numbers each try block's labels/temp uniquely
    private int tempVarCounter;
    private string currentClassName;
    private Type currentReturnType; // Enclosing function/method/lambda's declared return type, for ReturnStmt's nullable-sugar auto-wrap (see generateNullableWrap)
    private Type currentReturnTypeAsWritten; // Same, but a clone captured *before* resolveType mutated it - see resolveStructLiteralTarget
    private string currentModulePath; // Module whose code is currently being generated, for error citations
    private string[] currentNamespaceSegments; // Enclosing namespace path of the declaration being generated
    private Type[string] variableTypes; // Maps variable names to their types
    private bool[string] constVariables; // Names (mangled) of `const`-declared variables
    private FunctionDecl[string] functionRegistry; // Functions, by mangled (namespace-prefixed) name
    private ClassDecl[string] classRegistry; // Classes, by mangled (namespace-prefixed) name
    private StructDecl[string] structRegistry; // Structs, by mangled (namespace-prefixed) name
    private MacroDecl[string] macroRegistry; // Macros, by mangled (namespace-prefixed) name
    private VarDecl[string] globalVarRegistry; // Global lets/consts (incl. enum members), by mangled name
    private VariantInfo[string] variantRegistry; // Tagged-enum variant constructors, by mangled function name
    private Type[string] typeAliases; // Type aliases (`alias string = char*`), by mangled alias name
    // Named array literals (`alias NAME = [ ... ]`, see ArrayAliasDecl), by
    // mangled alias name - never emitted as their own C symbol, only
    // expanded back into these element expressions at each use site (see
    // expandArrayAliasesShallow).
    private ASTNode[][string] arrayLiteralAliases;

    // Per-symbol origin module path, so alias-qualified and selective imports
    // can look up which module a given mangled name came from.
    private string[string] functionModulePath;
    private string[string] classModulePath;
    private string[string] structModulePath;
    private string[string] macroModulePath;
    private string[string] globalVarModulePath;
    private string[string] typeAliasModulePath;
    private int macroExpansionDepth; // Guards against (possibly indirect) macro self-recursion
    private SymbolInfo[] collectedSymbols; // Declaration-site symbol table, built by generateMultiple; see symbols()
    private UsageInfo[] usageRecords; // Resolved reference sites, recorded via recordUsage; see usages()
    // Every CompileError caught instead of letting it abort the whole
    // compile - see errors.MultiCompileError, thrown with this list once
    // generateMultiple finishes (or returned normally if it's still
    // empty). Populated at two levels: generateMultiple's main declCode
    // loop catches per top-level declaration, and generateBodyStatement
    // catches per top-level statement within one function/method/
    // constructor/destructor/lambda body - so both "two independent
    // functions each have a bug" and "one function has several unrelated
    // bad statements" get every error reported in the same run.
    private CompileError[] collectedErrors;
    private int interpStringCounter; // Numbers each `\(...)` call site's scratch buffer uniquely
    private string[] interpBufferDecls; // `static char __llpl_interpN[SIZE];` decls, emitted up front
    private enum interpBufferSize = 256; // Scratch buffer size for one interpolated string's result
    private int lambdaCounter; // Numbers each lambda literal's env struct/trampoline function uniquely
    private string[] lambdaDecls; // Per-lambda `struct __LambdaEnvN {...};` + trampoline function decls, emitted up front
    private int embeddedFileCounter; // Numbers each embed("path") static blob uniquely
    private string[] embeddedFileDecls; // Static byte arrays emitted before function bodies

    // Per-capture context while generating a lambda body: how to read the
    // capture's value (useExpr), how to refer to its storage location
    // (lvalueExpr), and whether it is itself a reference capture. Nested
    // lambdas need all three to build their own environments correctly.
    private struct LambdaCaptureCtx {
        string useExpr;
        string lvalueExpr;
        bool byRef;
    }
    private LambdaCaptureCtx[string] currentLambdaCaptures;

    // Per-module import metadata for aliases and selective imports.
    private struct ImportedNameInfo {
        string original;
        string alias_;
    }
    private struct ModuleImportInfo {
        string targetModulePath;
        string alias_;                // module alias, if any
        ImportedNameInfo[] names;     // empty = import all
        bool isSelective;
    }
    private ModuleImportInfo[][string] moduleImports;       // importer -> imports
    private string[string][string] moduleAliases;           // importer -> alias -> target module path
    private string[string][string] selectiveLocalAliases;   // importer -> local name -> target mangled name
    private bool[string][string] exportsByModule;           // module -> set of mangled names it declares
    private string preludeModulePath;                       // treated as implicitly imported everywhere

    // Monomorphization engine (see resolveType's typeArgs branch and
    // resolveGenericFunctionCall): a generic class/struct/function is
    // never generated directly, only registered here as a template; each
    // concrete type combination it's used with gets a real, fully-typed
    // clone generated on demand the first time that combination is seen,
    // the same "discover lazily during ordinary codegen, splice the extra
    // C code in before declCode" trick generateLambdaExpr already uses.
    private ClassDecl[string] genericClassTemplates; // by mangled (namespace-prefixed) template name
    private StructDecl[string] genericStructTemplates;
    private FunctionDecl[string] genericFunctionTemplates;
    // Which module a generic template/trait was declared in - templates are
    // pulled out of prog.declarations entirely (see the comment on that pass),
    // so collectSymbolTable can't recover this by walking prog.declarations
    // like it does for everything else; recorded at pull-out time instead.
    private string[string] genericTemplateModulePath; // by the same mangled key as the *Templates maps above
    private string[string] traitModulePath; // by mangled trait name
    private string[] pendingImplModulePaths; // parallel to pendingImpls
    private bool[string] monomorphizedInstances; // mangled instantiation name -> reserved/emitted, dedupes + guards recursion
    // Reverse of the substitution instantiateGenericTypeArgs just made -
    // mangled instantiation name (e.g. "Slice_int") -> the concrete type
    // args it was built from (e.g. [int]). Needed so a generic *function*
    // parameter shaped like `s: Slice<T>` (T nested inside another generic
    // type, not itself the parameter's bare type) can still have T
    // inferred at a call site - see resolveGenericFunctionCall, which by
    // call time only ever sees the argument's already-mangled flat type
    // name and needs this to recover what T actually was.
    private Type[][string] monomorphizedTypeArgs;
    private string[] genericForwardDecls; // opaque struct tags / function prototypes, spliced before genericInstanceDecls
    private string[] genericInstanceDecls; // full monomorphized class/struct/function bodies, emitted up front

    // Which monomorphized instantiations came specifically from prelude.llpl's
    // `Optional<T>`/`Result<T, E>` templates, by mangled name (e.g.
    // "Optional_int") - used by generatePropagateExpr (`expr?`) to know
    // which of the two unwrap/early-return shapes applies, and by
    // generateNullableWrap's callers to recognize a `T?`-sugared Optional.
    private bool[string] optionalInstantiations;
    private bool[string] resultInstantiations;
    private int propagateCounter; // numbers each `expr?`'s scratch temp var uniquely

    // Traits/interfaces (see processImplBlock): static, monomorphization-time
    // only - a trait bound never participates in any runtime dispatch, so
    // there's no vtable/fat-pointer representation anywhere in this list.
    private TraitDecl[string] traitRegistry; // by (namespace-qualified) name
    private bool[string] traitImplemented; // "TraitName:MangledTargetTypeName" -> true (key uses mangleTypeArg, so char vs char* don't collide)
    private ImplDecl[] pendingImpls; // parked during the early pull-out pass, processed once classRegistry/structRegistry exist
    // Function *bodies* (impl methods, and generic-function instantiations)
    // that take a *plain* class/struct type by value - unlike a generic
    // class/struct's own instantiated body (genericInstanceDecls), which is
    // fully self-contained, a function body accessing `self.x`/`v.field` on
    // a plain type needs that type's complete C definition already visible,
    // which for a plain (non-generic) class/struct only exists once declCode
    // has emitted it - i.e. after declCode, not before it like
    // genericForwardDecls/genericInstanceDecls. Forward declarations
    // (prototypes) don't have this problem (C allows an incomplete-type
    // parameter in a declaration, just not in a definition), so those still
    // go in genericForwardDecls as usual - see processImplBlock and
    // resolveGenericFunctionCall.
    private string[] deferredFunctionBodies;

    this() {
        indentLevel = 0;
        tempVarCounter = 0;
    }

    private string indent() {
        string result = "";
        for (int i = 0; i < indentLevel; i++) {
            result ~= "    ";
        }
        return result;
    }

    // Builds the compiler-internal tuple type `__LLPL_TupleN<T1, ..., Tn>`.
    // Arities outside 2..8 are rejected here; the parser already enforces the
    // same limit for user-written tuple syntax.
    private Type makeTupleType(Type[] elems, int line, int column) {
        if (elems.length < 2 || elems.length > 8) {
            throw new CompileError(format("Tuple arity %d is not supported (use 2..8)", elems.length),
                currentModulePath, line, column);
        }
        string name = format("__LLPL_Tuple%d", elems.length);
        Type t = new Type(name);
        t.typeArgs = elems;
        return t;
    }

    private string tupleFieldName(size_t i) {
        return format("_%d", i);
    }

    // Escapes a decoded LLPL string (already past lexer escape processing,
    // e.g. \x1b is a real ESC byte by this point) back into a C string
    // literal body: named escapes for the common control characters, and
    // \ooo (octal) for any other non-printable byte, so the generated C
    // source never contains raw control characters. Octal, not \xHH: C's
    // hex escapes are unbounded-width and would greedily swallow a
    // following character that happens to look like a hex digit (e.g.
    // "\x1bA" is one escape, not ESC followed by 'A'); \ooo is always
    // exactly 3 digits, so nothing after it can be misread as part of it.
    private string escapeCString(string s) {
        string result = "";
        foreach (c; s) {
            switch (c) {
                case '\\': result ~= "\\\\"; break;
                case '"': result ~= "\\\""; break;
                case '\n': result ~= "\\n"; break;
                case '\t': result ~= "\\t"; break;
                case '\r': result ~= "\\r"; break;
                default:
                    if (c < 0x20 || c == 0x7f) {
                        result ~= format("\\%03o", cast(int)cast(ubyte)c);
                    } else {
                        result ~= c;
                    }
                    break;
            }
        }
        return result;
    }

    // Picks the ksnprintf format specifier for one `\(expr[:width][:radix])`'s
    // inferred type. Only scalar/pointer types that ksnprintf actually
    // knows how to format are allowed - a bare struct or class value (not
    // a pointer) has no sensible textual form, so that's a compile error
    // rather than silently printing raw bytes or an address.
    //
    // `spec.radix` is "" (plain decimal - the default), "hex", "oct", or
    // "bin" from a trailing `\(n:hex)`-style suffix; a radix's 0x/0o/0b
    // prefix is literal text outside the width (so `\(n:016:hex)` pads the
    // hex *digits* to 16, then still shows "0x" in front - the natural
    // reading for e.g. a zero-padded 64-bit address). `spec.width`/
    // `zeroPad` come from a `:016`-style suffix (see
    // Parser.splitInterpolationFormat); only integers accept either.
    private string interpFormatSpecifier(ASTNode expr, InterpFormat spec) {
        Type t = inferType(expr);
        resolveType(t);

        bool isPlainInt = !t.isPointer && !t.isArray &&
            (t.name == "int" || t.name == "uint" ||
             t.name == "int16" || t.name == "uint16" ||
             t.name == "int32" || t.name == "uint32");
        bool isUnsigned = t.name == "uint" || t.name == "uint16" || t.name == "uint32";

        if (spec.radix.length > 0 || spec.width > 0) {
            if (!isPlainInt) {
                string what = spec.radix.length > 0 ? format("':%s'", spec.radix) : "width";
                throw new CompileError(
                    format("Cannot use %s formatting on a value of type '%s' - only integers support it",
                        what, t.toString()),
                    currentModulePath, expr.line, expr.column);
            }

            string widthPrefix = spec.width > 0 ? format("%s%d", spec.zeroPad ? "0" : "", spec.width) : "";
            switch (spec.radix) {
                case "hex": return "0x%" ~ widthPrefix ~ "x";
                case "oct": return "0o%" ~ widthPrefix ~ "o";
                case "bin": return "0b%" ~ widthPrefix ~ "b";
                case "":    return "%" ~ widthPrefix ~ (isUnsigned ? "u" : "d");
                default: assert(0, "splitInterpolationFormat only ever produces hex/oct/bin/\"\"");
            }
        }

        if (t.isPointer && t.name == "char") return "%s";
        if (!t.isPointer && !t.isArray && t.name == "char") return "%c";
        if (!t.isPointer && !t.isArray && t.name == "bool") return "%d";
        if (t.isPointer) return "%p";

        switch (t.name) {
            case "int": case "int16": case "int32": return "%d";
            case "uint": case "uint16": case "uint32": return "%u";
            default:
                throw new CompileError(
                    format("Cannot interpolate a value of type '%s' inside a string - only " ~
                        "integers, char, bool, char* and other pointers are supported", t.toString()),
                    currentModulePath, expr.line, expr.column);
        }
    }

    // Builds a printf-style format string out of the literal segments (with
    // any literal '%' escaped to '%%', so user text is never misread as a
    // format specifier) and one specifier per embedded expression, then
    // formats it into a scratch buffer unique to this call site and yields
    // that buffer as a `char*` - all as a single GCC statement-expression,
    // so it can be used anywhere an expression can (a `let` initializer, a
    // call argument, ...). The buffer is `static`, not stack-local: a
    // statement-expression's own locals go out of scope when it ends, so a
    // stack buffer would leave the result pointing at a dead stack slot
    // (real UB, worse under -O2). `static` costs reentrancy - two
    // evaluations of the same call site (e.g. across loop iterations)
    // overwrite the same memory - but that's already exactly how this
    // codebase's other sprintf-into-shared-buffer helper (HAL.Log.buffer)
    // behaves, and there's no allocator to do better in a freestanding build.
    private string generateInterpolatedString(InterpolatedStringLiteral interp) {
        string fmt = "";
        string args = "";

        foreach (i, part; interp.literalParts) {
            fmt ~= escapeCString(part).replace("%", "%%");
            if (i < interp.expressions.length) {
                ASTNode expr = interp.expressions[i];
                InterpFormat spec = interp.specs[i];
                // A class/struct value has no sensible textual form on its
                // own (interpFormatSpecifier would otherwise reject it) -
                // implicitly resolve it the same way `.stringof`/`as
                // string` do (a custom stringof() method, or the type's
                // own name) instead of requiring `"\(f.stringof)"` to be
                // spelled out every time. Not offered alongside an
                // explicit width/radix modifier (`\(f:016)`) - that's
                // still a plain-integer-only error, unchanged.
                bool useStringof = false;
                Type stringofType;
                if (spec.radix.length == 0 && spec.width == 0) {
                    try {
                        stringofType = inferType(expr);
                        resolveType(stringofType);
                        useStringof = (stringofType.name in classRegistry) !is null ||
                            (stringofType.name in structRegistry) !is null;
                    } catch (Exception e) {
                        // fall through to the ordinary path below
                    }
                }
                if (useStringof) {
                    fmt ~= "%s";
                    args ~= ", " ~ generateStringofValue(stringofType, expr, expr.line, expr.column);
                } else {
                    fmt ~= interpFormatSpecifier(expr, spec);
                    args ~= ", " ~ variadicPromote(expr, generateExpression(expr));
                }
            }
        }

        string bufName = format("__llpl_interp%d", interpStringCounter++);
        interpBufferDecls ~= format("static char %s[%d];\n", bufName, interpBufferSize);

        return format("({ ksnprintf(%s, %d, \"%s\"%s); (char*)%s; })",
            bufName, interpBufferSize, fmt, args, bufName);
    }

    string generate(Program program) {
        return generateMultiple([program]);
    }

    // Populated as a side effect of generateMultiple(); only meaningful
    // after it's been called. See SymbolInfo/UsageInfo above and lspquery.d.
    SymbolInfo[] symbols() { return collectedSymbols; }
    UsageInfo[] usages() { return usageRecords; }

    private void recordUsage(string name, int line, int column) {
        usageRecords ~= UsageInfo(name, currentModulePath, line, column);
    }

    private string functionSignature(FunctionDecl fn, string displayName) {
        string sig = "";
        if (fn.isExtern) sig ~= "extern ";
        if (fn.isInterrupt) sig ~= "interrupt ";
        sig ~= "func " ~ displayName ~ "(";
        foreach (i, p; fn.params) {
            if (i > 0) sig ~= ", ";
            sig ~= p.name ~ ": " ~ p.type.toString();
        }
        if (fn.isVariadic) {
            if (fn.params.length > 0) sig ~= ", ";
            sig ~= "...";
        }
        sig ~= ")";
        if (fn.returnType.name != "void" || fn.returnType.isPointer) {
            sig ~= " -> " ~ fn.returnType.toString();
        }
        return sig;
    }

    private string classSignature(ClassDecl cls, string displayName) {
        return format("class %s (%d field(s), %d method(s))", displayName, cls.fields.length, cls.methods.length);
    }

    private string structSignature(StructDecl st, string displayName) {
        return format("%sstruct %s (%d field(s))", st.packed ? "packed " : "", displayName, st.fields.length);
    }

    private string macroSignature(MacroDecl m, string displayName) {
        return format("macro %s(%s)", displayName, m.params.join(", "));
    }

    private string varSignature(VarDecl v, string displayName) {
        return format("%s%s%s: %s", v.isVolatile ? "volatile " : "", v.isConst ? "const " : "let ", displayName,
            v.type !is null ? v.type.toString() : "?");
    }

    private string fieldSignature(VarDecl f, string ownerName) {
        return format("%s.%s: %s", ownerName, f.name, f.type !is null ? f.type.toString() : "?");
    }

    private string methodSignature(FunctionDecl m, string ownerName) {
        return functionSignature(m, ownerName ~ "." ~ m.name);
    }

    // Renders a template's type-parameter list for display, e.g.
    // genericSuffix(["T", "U"], ["Comparable", ""]) -> "<T: Comparable, U>".
    private string genericSuffix(string[] typeParams, string[] bounds) {
        if (typeParams.length == 0) return "";
        string[] parts;
        foreach (i, tp; typeParams) {
            string bound = i < bounds.length ? bounds[i] : "";
            parts ~= bound.length > 0 ? format("%s: %s", tp, bound) : tp;
        }
        return "<" ~ parts.join(", ") ~ ">";
    }

    private string traitSignature(TraitDecl t, string displayName) {
        string[] methodSigs;
        foreach (m; t.methods) methodSigs ~= functionSignature(m, m.name);
        string[] noBounds = new string[](t.typeParams.length);
        return format("trait %s%s { %s }", displayName, genericSuffix(t.typeParams, noBounds), methodSigs.join("; "));
    }

    // Builds the flat, declaration-only symbol table (see SymbolInfo) from
    // every module's top-level declarations. Called at the end of
    // generateMultiple, after the main generation pass, so every field/
    // global-var type that started out null (inferred from an initializer)
    // has already been resolved in place - see generateGlobalVar and the
    // class/struct field-inference pass earlier in generateMultiple.
    private void collectSymbolTable(Program[] programs) {
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    string dname = mangledFunc(funcDecl);
                    collectedSymbols ~= SymbolInfo(dname, "function", prog.modulePath,
                        funcDecl.line, funcDecl.column, functionSignature(funcDecl, dname));
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    string dname = mangledClass(classDecl);
                    collectedSymbols ~= SymbolInfo(dname, "class", prog.modulePath,
                        classDecl.line, classDecl.column, classSignature(classDecl, dname));
                    foreach (field; classDecl.fields) {
                        collectedSymbols ~= SymbolInfo(dname ~ "." ~ field.name, "field", prog.modulePath,
                            field.line, field.column, fieldSignature(field, dname));
                    }
                    foreach (method; classDecl.methods) {
                        collectedSymbols ~= SymbolInfo(dname ~ "." ~ method.name, "method", prog.modulePath,
                            method.line, method.column, methodSignature(method, dname));
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string dname = mangledStruct(structDecl);
                    collectedSymbols ~= SymbolInfo(dname, "struct", prog.modulePath,
                        structDecl.line, structDecl.column, structSignature(structDecl, dname));
                    foreach (field; structDecl.fields) {
                        collectedSymbols ~= SymbolInfo(dname ~ "." ~ field.name, "field", prog.modulePath,
                            field.line, field.column, fieldSignature(field, dname));
                    }
                } else if (auto macroDecl = cast(MacroDecl)decl) {
                    string dname = mangled(macroDecl.namespaceSegments, macroDecl.name);
                    collectedSymbols ~= SymbolInfo(dname, "macro", prog.modulePath,
                        macroDecl.line, macroDecl.column, macroSignature(macroDecl, dname));
                } else if (auto varDecl = cast(VarDecl)decl) {
                    string dname = mangled(varDecl.namespaceSegments, varDecl.name);
                    collectedSymbols ~= SymbolInfo(dname, "variable", prog.modulePath,
                        varDecl.line, varDecl.column, varSignature(varDecl, dname));
                }
            }
        }

        // Generic templates, traits, and impl blocks were all pulled out of
        // prog.declarations entirely before this point (see that pass's own
        // comment), so they need their own pass here, using the module paths
        // recorded at pull-out time instead of prog.modulePath.
        foreach (key, fn; genericFunctionTemplates) {
            string dname = key ~ genericSuffix(fn.typeParams, fn.typeParamBounds);
            collectedSymbols ~= SymbolInfo(key, "function", genericTemplateModulePath[key],
                fn.line, fn.column, functionSignature(fn, dname));
        }
        foreach (key, cls; genericClassTemplates) {
            string dname = key ~ genericSuffix(cls.typeParams, cls.typeParamBounds);
            string modulePath = genericTemplateModulePath[key];
            collectedSymbols ~= SymbolInfo(key, "class", modulePath,
                cls.line, cls.column, classSignature(cls, dname));
            foreach (field; cls.fields) {
                collectedSymbols ~= SymbolInfo(key ~ "." ~ field.name, "field", modulePath,
                    field.line, field.column, fieldSignature(field, key));
            }
            foreach (method; cls.methods) {
                collectedSymbols ~= SymbolInfo(key ~ "." ~ method.name, "method", modulePath,
                    method.line, method.column, methodSignature(method, key));
            }
        }
        foreach (key, st; genericStructTemplates) {
            string dname = key ~ genericSuffix(st.typeParams, st.typeParamBounds);
            string modulePath = genericTemplateModulePath[key];
            collectedSymbols ~= SymbolInfo(key, "struct", modulePath,
                st.line, st.column, structSignature(st, dname));
            foreach (field; st.fields) {
                collectedSymbols ~= SymbolInfo(key ~ "." ~ field.name, "field", modulePath,
                    field.line, field.column, fieldSignature(field, key));
            }
        }
        foreach (key, trait; traitRegistry) {
            collectedSymbols ~= SymbolInfo(key, "trait", traitModulePath[key],
                trait.line, trait.column, traitSignature(trait, key));
        }
        // Impl methods are keyed the same way method-call codegen resolves a
        // dispatch target (mangleTypeArg(targetType) ~ "." ~ methodName - see
        // the CallExpr method-dispatch branch), so a hover/go-to-definition
        // on a call site like `p.greet()` or `key.hash()` resolves here.
        // impl.targetType is already resolved in place by processImplBlock
        // by this point in generateMultiple.
        foreach (i, impl; pendingImpls) {
            string targetKey = mangleTypeArg(impl.targetType);
            foreach (method; impl.methods) {
                collectedSymbols ~= SymbolInfo(targetKey ~ "." ~ method.name, "method", pendingImplModulePaths[i],
                    method.line, method.column, methodSignature(method, targetKey));
            }
        }
    }

    // Joins namespace path segments into a declaration's mangled C identifier,
    // e.g. mangled(["Graphics"], "Point") -> "Graphics_Point".
    private string mangled(string[] segments, string name) {
        return segments.length > 0 ? segments.join("_") ~ "_" ~ name : name;
    }

    private string mangledFunc(FunctionDecl fn) {
        // extern functions bind to a real external C symbol by that exact
        // name, regardless of namespace nesting - never mangle those.
        if (fn.isExtern) return fn.name;
        return mangled(fn.namespaceSegments, fn.name);
    }

    private string mangledClass(ClassDecl cls) {
        return mangled(cls.namespaceSegments, cls.name);
    }

    private string mangledStruct(StructDecl st) {
        return mangled(st.namespaceSegments, st.name);
    }

    // Recorded per tagged-enum variant, keyed by its constructor's mangled
    // function name (e.g. "Shape_Circle") - the same name a `case`
    // pattern's callee resolves to (see tryResolveQualifiedPath), so
    // generateMatch can recognize `case Shape.Circle(r)` as a destructuring
    // pattern rather than a plain equality comparison against a call's
    // result (which wouldn't even compile - see desugarTaggedEnum).
    private struct VariantInfo {
        string enumName; // mangled enum/struct name, e.g. "Shape"
        string variantName; // e.g. "Circle"
        int tag;
        Parameter[] fields;
    }

    // Turns one tagged `enum Name { Variant(field: type, ...), ... }` into
    // the plain declarations it actually compiles to: a struct (the union
    // layout) plus one constructor function per variant. Returns them as a
    // drop-in replacement for the EnumDecl in `prog.declarations` - see the
    // call site in generateMultiple, which runs this before anything else
    // (registries, forward declarations, ...) looks at the declaration
    // list, so every later pass sees only StructDecl/FunctionDecl, exactly
    // as if this had been hand-written.
    //
    // The struct is "flat", not a real C union: every variant's fields all
    // live in the same struct, each prefixed with its variant's name
    // (`Circle_radius`, `Rect_width`, `Rect_height`, ...) to keep two
    // variants that happen to share a field name (`Circle(x: uint)` vs
    // `Rect(x: uint)`) from colliding. This wastes some space compared to a
    // real tagged union (every instance carries every variant's fields,
    // not just the active one's), traded for not needing C's anonymous-
    // union syntax at all - simpler to generate correctly, and consistent
    // with this compiler's general preference for straightforward codegen
    // over maximally compact output (see e.g. KHeap's arena design).
    private ASTNode[] desugarTaggedEnum(EnumDecl enumDecl) {
        VarDecl[] structFields;
        structFields ~= new VarDecl("tag", new Type("int"), null, false, enumDecl.line, enumDecl.column);
        foreach (variant; enumDecl.variants) {
            foreach (field; variant.fields) {
                structFields ~= new VarDecl(format("%s_%s", variant.name, field.name), field.type,
                    null, false, variant.line, variant.column);
            }
        }
        auto structDecl = new StructDecl(enumDecl.name, structFields, false, enumDecl.line, enumDecl.column);
        structDecl.namespaceSegments = enumDecl.namespaceSegments;

        ASTNode[] result = [structDecl];
        string mangledEnumName = mangled(enumDecl.namespaceSegments, enumDecl.name);

        foreach (i, variant; enumDecl.variants) {
            auto resultType = new Type(enumDecl.name);

            ASTNode[] bodyStmts;
            bodyStmts ~= new VarDecl("__enum_result", resultType, null, false, variant.line, variant.column);
            bodyStmts ~= new ExprStmt(new BinaryExpr("=",
                new MemberExpr(new Identifier("__enum_result", variant.line, variant.column), "tag",
                    variant.line, variant.column),
                new IntLiteral(cast(int)i, variant.line, variant.column), variant.line, variant.column));
            foreach (field; variant.fields) {
                bodyStmts ~= new ExprStmt(new BinaryExpr("=",
                    new MemberExpr(new Identifier("__enum_result", variant.line, variant.column),
                        format("%s_%s", variant.name, field.name), variant.line, variant.column),
                    new Identifier(field.name, variant.line, variant.column), variant.line, variant.column));
            }
            bodyStmts ~= new ReturnStmt(new Identifier("__enum_result", variant.line, variant.column));

            auto ctor = new FunctionDecl(variant.name, variant.fields, resultType, new Block(bodyStmts),
                false, false, false, variant.line, variant.column);
            // Namespaced as if declared inside `namespace EnumName { ... }`,
            // so it mangles to e.g. "Shape_Circle" and `Shape.Circle(...)`
            // resolves to it via the same qualified-call machinery any
            // other `Namespace.function(...)` call already uses.
            ctor.namespaceSegments = enumDecl.namespaceSegments ~ enumDecl.name;
            result ~= ctor;

            string mangledCtorName = mangledEnumName ~ "_" ~ variant.name;
            variantRegistry[mangledCtorName] =
                VariantInfo(mangledEnumName, variant.name, cast(int)i, variant.fields);
        }

        return result;
    }

    // Recursively hoists the contents of `namespace` blocks to the top level,
    // stamping each contained function/class/struct/global with the full
    // chain of enclosing namespace names (innermost last).
    private ASTNode[] flattenNamespaces(ASTNode[] decls, string[] segments) {
        ASTNode[] result;
        foreach (decl; decls) {
            if (auto ns = cast(NamespaceDecl)decl) {
                result ~= flattenNamespaces(ns.declarations, segments ~ ns.name);
            } else if (auto funcDecl = cast(FunctionDecl)decl) {
                funcDecl.namespaceSegments = segments;
                result ~= funcDecl;
            } else if (auto classDecl = cast(ClassDecl)decl) {
                classDecl.namespaceSegments = segments;
                result ~= classDecl;
            } else if (auto structDecl = cast(StructDecl)decl) {
                structDecl.namespaceSegments = segments;
                result ~= structDecl;
            } else if (auto enumDecl = cast(EnumDecl)decl) {
                enumDecl.namespaceSegments = segments;
                result ~= enumDecl;
            } else if (auto varDecl = cast(VarDecl)decl) {
                varDecl.namespaceSegments = segments;
                result ~= varDecl;
            } else if (auto aliasDecl = cast(AliasDecl)decl) {
                aliasDecl.namespaceSegments = segments;
                result ~= aliasDecl;
            } else if (auto arrayAliasDecl = cast(ArrayAliasDecl)decl) {
                arrayAliasDecl.namespaceSegments = segments;
                result ~= arrayAliasDecl;
            } else if (auto macroDecl = cast(MacroDecl)decl) {
                macroDecl.namespaceSegments = segments;
                result ~= macroDecl;
            } else if (auto traitDecl = cast(TraitDecl)decl) {
                traitDecl.namespaceSegments = segments;
                result ~= traitDecl;
            } else if (auto implDecl = cast(ImplDecl)decl) {
                implDecl.namespaceSegments = segments;
                result ~= implDecl;
            } else {
                result ~= decl;
            }
        }
        return result;
    }

    string generateMultiple(Program[] programs) {
        string code = "";

        // Register the closure runtime representation as a known struct
        // type name (see runtime.h's __LLPL_Closure and parser.d's closure
        // type syntax), so resolveType/isStructTypeName/typeToC treat
        // `__LLPL_Closure` as an ordinary value-type struct name - without
        // this it would fail resolveType's "known type" check. Registered
        // directly into the dict rather than via prog.declarations, since
        // the real definition already exists (hand-written) in runtime.h -
        // emitting another `typedef struct {...} __LLPL_Closure;` here
        // would be a duplicate-definition error.
        structRegistry["__LLPL_Closure"] = new StructDecl("__LLPL_Closure", [], false);

        // Resolve namespace blocks into flat, mangled top-level declarations
        // before anything else looks at prog.declarations.
        foreach (prog; programs) {
            prog.declarations = flattenNamespaces(prog.declarations, []);
        }

        // Desugar tagged enums into the struct + constructor functions they
        // actually compile to (see desugarTaggedEnum) - also before anything
        // else looks at prog.declarations, so every later pass (registries,
        // forward declarations, ...) sees only StructDecl/FunctionDecl and
        // needs no EnumDecl-specific handling of its own. Plain (non-tagged)
        // enums never produce an EnumDecl in the first place - the parser
        // desugars those directly into a namespace of int consts.
        foreach (prog; programs) {
            ASTNode[] withEnumsDesugared;
            foreach (decl; prog.declarations) {
                if (auto enumDecl = cast(EnumDecl)decl) {
                    withEnumsDesugared ~= desugarTaggedEnum(enumDecl);
                } else {
                    withEnumsDesugared ~= decl;
                }
            }
            prog.declarations = withEnumsDesugared;
        }

        // Pull every generic declaration (typeParams non-empty) out of
        // prog.declarations entirely, before any other pass - field-type
        // inference, forward declarations, the registry-population loop
        // below - looks at it. A generic declaration is a template, not
        // real code: its param/field/return types can mention a bare type
        // parameter name ("T") that doesn't resolve to anything, so it
        // must never reach a pass that assumes every declaration it sees
        // is concrete. Real code is produced later, on demand, by cloning
        // the template with its type parameters substituted (see
        // resolveType's typeArgs branch and resolveGenericFunctionCall).
        foreach (prog; programs) {
            ASTNode[] withGenericsPulledOut;
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    if (funcDecl.typeParams.length > 0) {
                        string key = mangledFunc(funcDecl);
                        genericFunctionTemplates[key] = funcDecl;
                        genericTemplateModulePath[key] = prog.modulePath;
                        exportsByModule[prog.modulePath][key] = true;
                        continue;
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.typeParams.length > 0) {
                        string key = mangledClass(classDecl);
                        genericClassTemplates[key] = classDecl;
                        genericTemplateModulePath[key] = prog.modulePath;
                        exportsByModule[prog.modulePath][key] = true;
                        continue;
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    if (structDecl.typeParams.length > 0) {
                        string key = mangledStruct(structDecl);
                        genericStructTemplates[key] = structDecl;
                        genericTemplateModulePath[key] = prog.modulePath;
                        exportsByModule[prog.modulePath][key] = true;
                        continue;
                    }
                } else if (auto traitDecl = cast(TraitDecl)decl) {
                    // A trait is purely a compile-time contract - it never
                    // produces any C code itself (same treatment as
                    // MacroDecl), so registering it is all that's needed.
                    string key = mangled(traitDecl.namespaceSegments, traitDecl.name);
                    traitRegistry[key] = traitDecl;
                    traitModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                    continue;
                } else if (auto implDecl = cast(ImplDecl)decl) {
                    // Parked, not processed yet - its methods have a
                    // `Self`-typed (or otherwise unresolved) target type
                    // that isn't safe for any pass to see as if it were
                    // concrete until processImplBlock below resolves it,
                    // the same reasoning that already applies to generic
                    // templates. Also needs classRegistry/structRegistry
                    // to already be populated (for a user-defined target
                    // type) before it can resolve its own target, so it's
                    // processed further down, after the main registries.
                    pendingImpls ~= implDecl;
                    pendingImplModulePaths ~= prog.modulePath;
                    continue;
                }
                withGenericsPulledOut ~= decl;
            }
            prog.declarations = withGenericsPulledOut;
        }

        // Register functions, classes and structs from all modules up front so
        // type inference can resolve calls/fields regardless of declaration order.
        // Type aliases (see generateAlias) are registered here too, and before
        // anything else in this loop touches types, since resolveType() needs
        // to see them no matter where `alias string = char*` sits relative to
        // its uses - unlike a symbol alias, which can only ever point at
        // something already in one of these same registries anyway.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto aliasDecl = cast(AliasDecl)decl) {
                    bool isTypeAlias = aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
                        (aliasDecl.targetPath.length == 1 && isPrimitiveTypeName(aliasDecl.targetPath[0]));
                    if (isTypeAlias) {
                        string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);
                        string baseName = aliasDecl.targetPath.join("_");
                        typeAliases[mangledName] = new Type(baseName, aliasDecl.targetPointerDepth,
                            aliasDecl.targetIsArray, aliasDecl.targetArraySize);
                        typeAliasModulePath[mangledName] = prog.modulePath;
                        exportsByModule[prog.modulePath][mangledName] = true;
                    }
                } else if (auto arrayAliasDecl = cast(ArrayAliasDecl)decl) {
                    string mangledName = mangled(arrayAliasDecl.namespaceSegments, arrayAliasDecl.name);
                    arrayLiteralAliases[mangledName] = arrayAliasDecl.elements;
                }
            }
        }
        // Group every non-extern top-level function by its plain
        // (pre-overload-suffix) mangled name first, so mangleFreeFunctionName
        // (called below, per declaration) already knows whether each name
        // is actually overloaded (2+ candidates) before any of them are
        // registered. Extern functions are excluded - their C symbol is a
        // real, fixed external name that can't be arbitrarily suffixed
        // (see mangleFreeFunctionName's own comment).
        string[string] candidateModulePath;
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    if (!funcDecl.isExtern) {
                        string key = mangledFunc(funcDecl);
                        functionCandidates[key] ~= funcDecl;
                        if (key !in candidateModulePath) candidateModulePath[key] = prog.modulePath;
                    }
                }
            }
        }
        foreach (key, candidates; functionCandidates) {
            if (candidates.length > 1) {
                currentModulePath = candidateModulePath[key];
                checkNoDuplicateSignatures(candidates, format("function '%s'", key),
                    candidates[0].line, candidates[0].column);
            }
        }
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    string key = mangleFreeFunctionName(funcDecl);
                    functionRegistry[key] = funcDecl;
                    functionModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    string key = mangledClass(classDecl);
                    classRegistry[key] = classDecl;
                    classModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string key = mangledStruct(structDecl);
                    structRegistry[key] = structDecl;
                    structModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                } else if (auto macroDecl = cast(MacroDecl)decl) {
                    string key = mangled(macroDecl.namespaceSegments, macroDecl.name);
                    macroRegistry[key] = macroDecl;
                    macroModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                } else if (auto varDecl = cast(VarDecl)decl) {
                    string key = mangled(varDecl.namespaceSegments, varDecl.name);
                    globalVarRegistry[key] = varDecl;
                    globalVarModulePath[key] = prog.modulePath;
                    exportsByModule[prog.modulePath][key] = true;
                }
            }
        }

        // Build per-module import metadata (aliases, selective imports) now
        // that every module's exports are known.
        collectImports(programs);

        // Process every parked `impl Trait for Type { ... }` block now
        // that classRegistry/structRegistry are populated (so a
        // user-defined target type resolves correctly) but before the
        // field-resolution pass just below - the earliest point a generic
        // instantiation's trait-bound check could otherwise fire, which
        // needs traitImplemented already populated (see processImplBlock).
        foreach (impl; pendingImpls) {
            currentNamespaceSegments = impl.namespaceSegments;
            processImplBlock(impl);
        }

        // Resolve any inferred class/struct field types before they can be
        // looked up. currentModulePath/currentNamespacePath are set per-decl
        // so inference errors cite the right file and unqualified sibling
        // lookups (if the initializer ever needs one) resolve correctly.
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    foreach (field; classDecl.fields) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        resolveType(field.type);
                        if (field.bitWidth >= 0) {
                            checkBitfield(field);
                        }
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    currentNamespaceSegments = structDecl.namespaceSegments;
                    foreach (field; structDecl.fields) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        resolveType(field.type);
                        if (field.bitWidth >= 0) {
                            checkBitfield(field);
                        }
                    }
                }
            }
        }

        // Resolve global variable types up front too, for the same reason
        // as class/struct fields just above: with multiple modules merged
        // into one compile, a global can easily be *used* (e.g. a method
        // call, which needs to know its class name) by a file that's
        // processed before the file declaring it - generateGlobalVar
        // alone, which only runs later per-declaration, would leave
        // variableTypes empty for it until too late. Harmless to redo the
        // inference/resolution there afterward; varDecl.type is simply
        // already set by then.
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto varDecl = cast(VarDecl)decl) {
                    currentNamespaceSegments = varDecl.namespaceSegments;
                    if (varDecl.type is null) {
                        varDecl.type = inferType(varDecl.initializer);
                    }
                    resolveType(varDecl.type);
                    checkArrayLiteralInit(varDecl);
                    variableTypes[mangled(varDecl.namespaceSegments, varDecl.name)] = varDecl.type;
                }
            }
        }

        // Include runtime header
        code ~= "#include <stdint.h>\n";
        code ~= "#include <stddef.h>\n";
        code ~= "#include \"runtime.h\"\n\n";

        // Everything below through the alias #defines used to be appended
        // straight into `code`, but any of these passes can - via
        // resolveType - trigger a *new* generic instantiation (e.g. an
        // ordinary function's return type being `int?`/Optional<int>) whose
        // own forward tag/body only gets flushed into `code` once, right
        // before declCode (see genericForwardDecls/genericInstanceDecls
        // below). Writing straight to `code` meant that flush could land
        // *after* text that already referenced the newly-triggered generic
        // type's mangled name - a real "unknown type name" bug. Buffering
        // all of it into earlyDeclCode instead, and only appending it after
        // that one flush, fixes this the same way declCode already avoids
        // it (declCode was always buffered, for the analogous reason with
        // interpBufferDecls/lambdaDecls).
        string earlyDeclCode = "";

        // Forward declarations for classes and structs from all modules
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    string cName = mangledClass(classDecl);
                    earlyDeclCode ~= format("typedef struct %s %s;\n", cName, cName);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string sName = mangledStruct(structDecl);
                    earlyDeclCode ~= format("typedef struct %s %s;\n", sName, sName);
                }
            }
        }
        earlyDeclCode ~= "\n";

        // Forward declarations for functions and methods from all modules.
        // currentNamespaceSegments is set per-declaration so resolveType
        // resolves unqualified namespaced types exactly the way the real
        // definition will, keeping each forward declaration's signature
        // consistent with the definition that follows it later.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    currentNamespaceSegments = funcDecl.namespaceSegments;
                    if (funcDecl.isExtern) {
                        string params = "";
                        foreach (i, param; funcDecl.params) {
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        earlyDeclCode ~= format("extern %s %s(%s);\n",
                            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                    } else if (funcDecl.isInterrupt) {
                        string params = "void* __frame";
                        if (funcDecl.params.length >= 1) {
                            resolveType(funcDecl.params[0].type);
                            params ~= format(", %s %s",
                                typeToC(funcDecl.params[0].type), funcDecl.params[0].name);
                        }
                        earlyDeclCode ~= format("__attribute__((interrupt)) void %s(%s);\n",
                            mangledFunc(funcDecl), params);
                    } else {
                        // Resolve a *clone*, not funcDecl.returnType itself -
                        // generateFunction later needs the pristine
                        // as-written return type (e.g. `Pair<int, int>`,
                        // typeArgs intact) to resolve a bare `return Pair {
                        // ... }` struct literal's target; resolving the
                        // real node here first would already have mangled
                        // it (typeArgs cleared) by the time that runs.
                        Type returnTypeForFwd = cloneType(funcDecl.returnType);
                        resolveType(returnTypeForFwd);
                        string params = "";
                        foreach (i, param; funcDecl.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        earlyDeclCode ~= format("%s %s(%s);\n",
                            typeToC(returnTypeForFwd), mangleFreeFunctionName(funcDecl), params);
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    string cName = mangledClass(classDecl);
                    // Constructor forward declaration(s)
                    checkNoDuplicateSignatures(classDecl.constructors, format("constructor of '%s'", cName),
                        classDecl.line, classDecl.column);
                    foreach (ctor; classDecl.constructors) {
                        string params = "";
                        foreach (i, param; ctor.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        earlyDeclCode ~= format("%s* %s(%s);\n", cName, mangleConstructorName(classDecl, cName, ctor), params);
                    }

                    // Destructor forward declaration
                    if (classDecl.destructor) {
                        earlyDeclCode ~= format("void %s_destroy(void* ptr);\n", cName);
                    }

                    // Method forward declarations
                    bool[string] checkedMethodNames;
                    foreach (method; classDecl.methods) {
                        if (method.name !in checkedMethodNames) {
                            checkedMethodNames[method.name] = true;
                            checkNoDuplicateSignatures(methodCandidatesNamed(classDecl, method.name),
                                format("method '%s.%s'", cName, method.name), method.line, method.column);
                        }
                        // Same "resolve a clone, not the real node" reasoning
                        // as the plain-function forward-decl loop above -
                        // generateMethod needs method.returnType still
                        // as-written when it later runs.
                        Type returnTypeForFwd = cloneType(method.returnType);
                        resolveType(returnTypeForFwd);
                        string params = format("%s* self", cName);
                        foreach (param; method.params) {
                            resolveType(param.type);
                            params ~= format(", %s %s", typeToC(param.type), param.name);
                        }
                        earlyDeclCode ~= format("%s %s(%s);\n",
                            typeToC(returnTypeForFwd), mangleMethodName(classDecl, cName, method), params);
                    }
                }
            }
        }
        earlyDeclCode ~= "\n";

        // Forward declarations for global variables from all modules: even
        // though the registries above already make a global resolvable by
        // *name* regardless of which file declares it, C itself still needs
        // an `extern` declaration textually before a function body in some
        // other (earlier-processed) file can reference it - the same
        // problem forward-declaring functions/classes above already solves
        // for those. The real definition (with its initializer) is emitted
        // later, in each variable's normal position; a prior `extern`
        // declaration doesn't conflict with that.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto varDecl = cast(VarDecl)decl) {
                    currentNamespaceSegments = varDecl.namespaceSegments;
                    string cName = mangled(varDecl.namespaceSegments, varDecl.name);
                    // Must match the real definition's const/volatile
                    // qualifiers exactly - GCC treats an extern declaration
                    // and its later definition disagreeing on a type
                    // qualifier as a conflicting redeclaration, not just a
                    // style nit.
                    string constPrefix = (varDecl.isVolatile ? "volatile " : "") ~ (varDecl.isConst ? "const " : "");
                    bool isStructOrClassElement = !varDecl.type.isPointer &&
                        (isStructTypeName(varDecl.type.name) || isClassTypeName(varDecl.type.name));
                    if (varDecl.type.isArray && varDecl.type.arraySize > 0 && isStructOrClassElement) {
                        // An array of struct/class values (not pointers) needs
                        // its element type *complete* even just to declare the
                        // array's size - but struct/class bodies aren't defined
                        // until later in the file (after all these forward
                        // declarations). Skip it: this only matters for a
                        // global that's used by a file processed earlier than
                        // the one declaring it, which none of these are (e.g.
                        // GDT.entries/IDT.entries are only ever used from
                        // within their own file).
                    } else if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
                        string baseType = primitiveToC(varDecl.type.name);
                        baseType ~= pointerStars(varDecl.type);
                        earlyDeclCode ~= format("extern %s%s %s[%d];\n", constPrefix, baseType, cName, varDecl.type.arraySize);
                    } else {
                        earlyDeclCode ~= format("extern %s%s %s;\n", constPrefix, typeToC(varDecl.type), cName);
                    }
                }
            }
        }
        earlyDeclCode ~= "\n";

        // Alias `#define`s are emitted early too, for the same reason as
        // the forward declarations above: the C preprocessor is purely
        // positional, so a #define must appear before any C code that
        // uses the alias name - which, once multiple files' declarations
        // are merged into one compile, could easily be in a file
        // processed earlier than the one declaring the alias.
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto aliasDecl = cast(AliasDecl)decl) {
                    earlyDeclCode ~= generateAlias(aliasDecl);
                }
            }
        }
        earlyDeclCode ~= "\n";

        // Generate declarations from all modules (skip import statements).
        // Collected into declCode, not appended to code directly, because
        // generating these bodies is what discovers this module's `\(...)`
        // string interpolations (interpBufferDecls) - and those scratch
        // buffers need to land *before* any code that might reference them.
        string declCode = "";
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            if (prog.modulePath.length > 0) {
                declCode ~= format("// Module: %s\n", prog.modulePath);
            }
            foreach (decl; prog.declarations) {
                if (cast(ImportStmt)decl) {
                    continue;  // Skip import statements in code generation
                }
                if (cast(MacroDecl)decl) {
                    continue;  // A macro is a compile-time template, not real C - it only
                               // ever appears inline at its NAME!(...) call sites.
                }
                if (cast(AliasDecl)decl) {
                    continue;  // Already emitted above, ahead of everything that might use it.
                }
                // Caught and collected, not left to abort the whole
                // compile - see collectedErrors's own comment. Safe to
                // just skip this one declaration's contribution to
                // declCode and move on: every registry/field/generic-
                // template resolution any *other* declaration could
                // depend on already happened in the passes above, so
                // this declaration's own failure can't cascade into a
                // false error anywhere else. None of declCode ends up
                // used anyway once collectedErrors is non-empty (see the
                // very end of this function).
                try {
                    declCode ~= generateDeclaration(decl);
                    declCode ~= "\n";
                } catch (CompileError e) {
                    collectedErrors ~= e;
                }
            }
        }

        // genericForwardDecls/genericInstanceDecls may have been populated
        // as a side effect of *any* pass above (the early forward-decl
        // passes buffered into earlyDeclCode, or declCode generation just
        // above) - flushed here, before earlyDeclCode/declCode are
        // actually appended, so a generic type's own mangled name is
        // always defined before any earlier-computed text that references
        // it (see the comment on earlyDeclCode's declaration for the bug
        // this fixes).
        if (genericForwardDecls.length > 0) {
            code ~= "// Monomorphized generic instantiations - forward declarations\n";
            foreach (fwd; genericForwardDecls) {
                code ~= fwd;
            }
            code ~= "\n";
        }

        if (genericInstanceDecls.length > 0) {
            code ~= "// Monomorphized generic instantiations - full bodies\n";
            foreach (instDecl; genericInstanceDecls) {
                code ~= instDecl;
            }
            code ~= "\n";
        }

        code ~= earlyDeclCode;

        if (interpBufferDecls.length > 0) {
            code ~= "// String-interpolation scratch buffers (one per `\\(...)` call site)\n";
            foreach (bufDecl; interpBufferDecls) {
                code ~= bufDecl;
            }
            code ~= "\n";
        }

        if (lambdaDecls.length > 0) {
            code ~= "// Lambda literal environment structs + trampoline functions\n";
            foreach (lambdaDecl; lambdaDecls) {
                code ~= lambdaDecl;
            }
            code ~= "\n";
        }

        if (embeddedFileDecls.length > 0) {
            code ~= "// Embedded file blobs from embed(\"path\")\n";
            foreach (embedDecl; embeddedFileDecls) {
                code ~= embedDecl;
            }
            code ~= "\n";
        }

        code ~= declCode;

        if (deferredFunctionBodies.length > 0) {
            code ~= "// Function bodies deferred until after plain class/struct definitions exist\n";
            foreach (b; deferredFunctionBodies) {
                code ~= b;
            }
            code ~= "\n";
        }

        string reflectionMetadata = generateReflectionMetadata(programs);
        if (reflectionMetadata.length > 0) {
            code ~= "// Runtime reflection metadata for @reflect types\n";
            code ~= reflectionMetadata;
        }

        string backtraceSymbolTable = generateBacktraceSymbolTable();
        if (backtraceSymbolTable.length > 0) {
            code ~= "// Symbol table for symbolized panic backtraces\n";
            code ~= backtraceSymbolTable;
        }

        collectSymbolTable(programs);

        // Collected symbols/usages above are still valid (if partial) even
        // when this throws - an editor tool (lspquery.d) can still offer
        // hover/go-to-def for whatever *did* generate cleanly, alongside
        // every collected diagnostic, rather than losing all of it just
        // because something else in the file has a bug.
        if (collectedErrors.length > 0) {
            throw new MultiCompileError(collectedErrors);
        }

        return code;
    }

    private string generateDeclaration(ASTNode node) {
        if (auto funcDecl = cast(FunctionDecl)node) {
            return generateFunction(funcDecl);
        } else if (auto classDecl = cast(ClassDecl)node) {
            return generateClass(classDecl);
        } else if (auto structDecl = cast(StructDecl)node) {
            return generateStruct(structDecl);
        } else if (auto varDecl = cast(VarDecl)node) {
            return generateGlobalVar(varDecl);
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            return generateAlias(aliasDecl);
        }
        return "";
    }

    private bool isKnownSymbol(string name) {
        return (name in functionRegistry) !is null || (name in classRegistry) !is null ||
               (name in structRegistry) !is null || (name in variableTypes) !is null;
    }

    // Resolves `alias name = a.b.c`'s target path to the mangled C
    // identifier it refers to, using the same resolution order as every
    // other namespace-qualified reference: exact mangled match, then each
    // enclosing namespace scope, then (for extern functions specifically,
    // which are never mangled) the bare rightmost segment.
    private string resolveAliasTarget(string[] path, int line, int column) {
        string flat = path.join("_");
        if (isKnownSymbol(flat)) return flat;

        foreach (candidate; enclosingQualifications(flat)) {
            if (isKnownSymbol(candidate)) return candidate;
        }

        string rightmost = path[$ - 1];
        if (auto fd = rightmost in functionRegistry) {
            if (fd.isExtern) return rightmost;
        }

        throw new CompileError(format("Cannot resolve alias target '%s'", path.join(".")),
            currentModulePath, line, column);
    }

    private string generateAlias(AliasDecl aliasDecl) {
        currentNamespaceSegments = aliasDecl.namespaceSegments;
        string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);

        if (isKnownSymbol(mangledName)) {
            throw new CompileError(
                format("Cannot declare alias '%s': a symbol with that name already exists",
                    aliasDecl.name),
                currentModulePath, aliasDecl.line, aliasDecl.column);
        }

        // A `*`/`[...]` suffix, or a bare primitive name (which isn't a
        // registered symbol at all), means there's no symbol to #define
        // against - this is a *type* alias instead (`alias string =
        // char*`, `alias Bytes = char[256]`, `alias Cell = int`). Already
        // registered into typeAliases up front (see generateMultiple), so
        // resolveType() substitutes it correctly regardless of where this
        // declaration sits relative to its uses - nothing left to do here.
        bool isTypeAlias = aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
            (aliasDecl.targetPath.length == 1 && isPrimitiveTypeName(aliasDecl.targetPath[0]));
        if (isTypeAlias) {
            return "";
        }

        string target = resolveAliasTarget(aliasDecl.targetPath, aliasDecl.line, aliasDecl.column);

        // Register the alias so later references to it resolve exactly like
        // the thing it points to (correct arity/variadic-ness for calls,
        // correct field/method lookup for types, etc.) - generateExpression
        // will emit the alias name literally, and the #define below is what
        // actually makes that resolve to the real symbol in the C output.
        if (auto fd = target in functionRegistry) functionRegistry[mangledName] = *fd;
        if (auto cd = target in classRegistry) classRegistry[mangledName] = *cd;
        if (auto sd = target in structRegistry) structRegistry[mangledName] = *sd;
        if (auto vt = target in variableTypes) variableTypes[mangledName] = *vt;

        return format("#define %s %s\n", mangledName, target);
    }

    private bool hasAttribute(VarAttribute[] attrs, string name) {
        foreach (attr; attrs) {
            if (attr.name == name) return true;
        }
        return false;
    }

    private string reflectionTypeName(Type t) {
        Type copy = cloneType(t);
        resolveType(copy);
        return copy.toString();
    }

    private void validateReflectAttributes(VarAttribute[] attrs) {
        foreach (attr; attrs) {
            if (attr.name != "reflect") {
                throw new CompileError(format("Unknown type attribute '@%s'", attr.name),
                    currentModulePath, attr.line, attr.column);
            }
            if (attr.hasStringValue || attr.hasIntValue) {
                throw new CompileError("@reflect does not take an argument",
                    currentModulePath, attr.line, attr.column);
            }
        }
    }

    private string generateReflectionMetadata(Program[] programs) {
        string code = "";
        string[] typeEntries;
        int typeIndex = 0;

        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    validateReflectAttributes(classDecl.attributes);
                    if (!hasAttribute(classDecl.attributes, "reflect")) continue;
                    if (classDecl.typeParams.length > 0) continue;

                    currentNamespaceSegments = classDecl.namespaceSegments;
                    string cName = mangledClass(classDecl);
                    string fieldsName = format("__llpl_reflect_fields_%d", typeIndex);
                    code ~= format("static LLPL_FieldInfo %s[%d] = {\n", fieldsName,
                        classDecl.fields.length == 0 ? 1 : classDecl.fields.length);
                    foreach (field; classDecl.fields) {
                        code ~= format("    { %s, %s, offsetof(%s, %s), sizeof(((%s*)0)->%s) },\n",
                            cStringLiteral(field.name), cStringLiteral(reflectionTypeName(field.type)),
                            cName, field.name, cName, field.name);
                    }
                    if (classDecl.fields.length == 0) {
                        code ~= "    { 0, 0, 0, 0 },\n";
                    }
                    code ~= "};\n";
                    typeEntries ~= format("    { %s, \"class\", sizeof(%s), %s, %d },\n",
                        cStringLiteral(cName), cName, fieldsName, classDecl.fields.length);
                    typeIndex++;
                } else if (auto structDecl = cast(StructDecl)decl) {
                    validateReflectAttributes(structDecl.attributes);
                    if (!hasAttribute(structDecl.attributes, "reflect")) continue;
                    if (structDecl.typeParams.length > 0) continue;

                    currentNamespaceSegments = structDecl.namespaceSegments;
                    string sName = mangledStruct(structDecl);
                    string fieldsName = format("__llpl_reflect_fields_%d", typeIndex);
                    code ~= format("static LLPL_FieldInfo %s[%d] = {\n", fieldsName,
                        structDecl.fields.length == 0 ? 1 : structDecl.fields.length);
                    foreach (field; structDecl.fields) {
                        code ~= format("    { %s, %s, offsetof(%s, %s), sizeof(((%s*)0)->%s) },\n",
                            cStringLiteral(field.name), cStringLiteral(reflectionTypeName(field.type)),
                            sName, field.name, sName, field.name);
                    }
                    if (structDecl.fields.length == 0) {
                        code ~= "    { 0, 0, 0, 0 },\n";
                    }
                    code ~= "};\n";
                    typeEntries ~= format("    { %s, \"struct\", sizeof(%s), %s, %d },\n",
                        cStringLiteral(sName), sName, fieldsName, structDecl.fields.length);
                    typeIndex++;
                }
            }
        }

        if (typeEntries.length == 0) return "";

        code ~= "LLPL_TypeInfo __llpl_reflect_types[] = {\n";
        foreach (entry; typeEntries) code ~= entry;
        code ~= "};\n";
        code ~= format("uint64_t __llpl_reflect_type_count = %d;\n\n", typeEntries.length);
        return code;
    }

    // One entry per user-defined function/method/constructor actually
    // compiled - drives symbolized panic backtraces (see
    // examples/baremetal_demo/backtrace.llpl and runtime.c's
    // llpl_resolve_symbol). Reads functionRegistry/classRegistry directly
    // (rather than re-walking `programs`, the way generateReflectionMetadata
    // does) specifically so generic instantiations and impl-block-desugared
    // functions - synthesized during codegen, never present in the original
    // parsed declarations at all - are automatically included too: by the
    // time this runs (the very end of generateMultiple), every instantiation
    // that was ever going to happen already has an entry in one of these
    // two registries. Extern functions are skipped (no LLPL-side body/line
    // to report). functionModulePath/classModulePath don't have entries for
    // generic instantiations or impl methods (only ordinary top-level
    // registrations do) - "?" is an acceptable fallback there, not a
    // hard requirement of this being a debugging aid, not the compiler's
    // main correctness surface.
    private string generateBacktraceSymbolTable() {
        string[] entries;

        foreach (name, funcDecl; functionRegistry) {
            if (funcDecl.isExtern) continue;
            string file = name in functionModulePath ? baseName(functionModulePath[name]) : "?";
            entries ~= format("    { %s, (void*)%s, %s, %d },\n",
                cStringLiteral(name), name, cStringLiteral(file), funcDecl.line);
        }

        foreach (cName, classDecl; classRegistry) {
            string file = cName in classModulePath ? baseName(classModulePath[cName]) : "?";
            foreach (ctor; classDecl.constructors) {
                string mangledName = mangleConstructorName(classDecl, cName, ctor);
                entries ~= format("    { %s, (void*)%s, %s, %d },\n",
                    cStringLiteral(mangledName), mangledName, cStringLiteral(file), ctor.line);
            }
            foreach (method; classDecl.methods) {
                string mangledName = mangleMethodName(classDecl, cName, method);
                entries ~= format("    { %s, (void*)%s, %s, %d },\n",
                    cStringLiteral(mangledName), mangledName, cStringLiteral(file), method.line);
            }
        }

        if (entries.length == 0) return "";

        string code = "LLPL_Symbol llpl_symbol_table[] = {\n";
        foreach (entry; entries) code ~= entry;
        code ~= "};\n";
        code ~= format("uint64_t llpl_symbol_table_count = %d;\n\n", entries.length);
        return code;
    }

    // A struct/class field's C declaration - `type name;`, `type name[N];`
    // for a fixed-size array field, or `type name : N;` for a bit-field
    // (checked first - bit-fields and arrays don't overlap in this
    // language's grammar). Mirrors generateGlobalVar's identical
    // array-vs-scalar handling for a global variable's own declaration;
    // used by both generateStruct and generateClass so an array field
    // (e.g. `let name: char[32]`) isn't silently collapsed to a bare
    // scalar C declaration, losing its array entirely.
    private string fieldDeclaration(Type type, string name, int bitWidth) {
        if (bitWidth >= 0) {
            return format("    %s %s : %d;\n", typeToC(type), name, bitWidth);
        }
        if (type.isArray && type.arraySize > 0) {
            string baseType = primitiveToC(type.name);
            baseType ~= pointerStars(type);
            return format("    %s %s[%d];\n", baseType, name, type.arraySize);
        }
        return format("    %s %s;\n", typeToC(type), name);
    }

    private string generateStruct(StructDecl structDecl) {
        string sName = mangledStruct(structDecl);
        currentNamespaceSegments = structDecl.namespaceSegments;

        string attr = structDecl.packed ? " __attribute__((packed))" : "";
        string code = format("struct%s %s {\n", attr, sName);
        foreach (field; structDecl.fields) {
            code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
        }
        code ~= "};\n";
        return code;
    }

    private string generateGlobalVar(VarDecl varDecl) {
        currentNamespaceSegments = varDecl.namespaceSegments;
        if (varDecl.bitWidth >= 0) {
            throw new CompileError("Bit-fields are only allowed on class fields, not global variables",
                currentModulePath, varDecl.line, varDecl.column);
        }
        if (varDecl.type is null) {
            varDecl.type = inferType(varDecl.initializer);
        }
        Type declaredTypeAsWritten = cloneType(varDecl.type);
        resolveType(varDecl.type);
        checkArrayLiteralInit(varDecl);
        if (varDecl.type.isNullableSugar) {
            // A `T?` global's initializer needs a real Optional_T_new()/
            // _set() call (see generateNullableWrap) - not a compile-time
            // constant, so it can't be a plain C static initializer the
            // way every other global here is. Local `T?` variables and
            // assignments don't have this restriction (see generateStatement's
            // VarDecl case), only globals.
            throw new CompileError(
                "A nullable ('T?') type isn't supported for a global variable - " ~
                "declare it as a local inside a function instead",
                currentModulePath, varDecl.line, varDecl.column);
        }
        string cName = mangled(varDecl.namespaceSegments, varDecl.name);
        variableTypes[cName] = varDecl.type;
        if (varDecl.isConst) {
            constVariables[cName] = true;
        }

        string attrPrefix = globalVarAttributes(varDecl);

        // Handle array declarations specially
        string constPrefix = (varDecl.isVolatile ? "volatile " : "") ~ (varDecl.isConst ? "const " : "");
        string code;
        if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
            string baseType = primitiveToC(varDecl.type.name);
            baseType ~= pointerStars(varDecl.type);
            code = format("%s%s%s %s[%d]", attrPrefix, constPrefix, baseType, cName, varDecl.type.arraySize);
        } else {
            code = format("%s%s%s %s", attrPrefix, constPrefix, typeToC(varDecl.type), cName);
        }

        if (varDecl.initializer) {
            if (auto structLit = cast(StructLiteral)varDecl.initializer) {
                code ~= " = " ~ generateStructLiteralValue(structLit, declaredTypeAsWritten);
            } else {
                code ~= " = " ~ generateExpression(varDecl.initializer);
            }
        }
        code ~= ";\n";
        return code;
    }

    private string escapeCAttrString(string s) {
        string out_;
        foreach (ch; s) {
            if (ch == '\\') out_ ~= "\\\\";
            else if (ch == '"') out_ ~= "\\\"";
            else out_ ~= ch;
        }
        return out_;
    }

    private string globalVarAttributes(VarDecl varDecl) {
        string[] attrs;
        foreach (attr; varDecl.attributes) {
            switch (attr.name) {
                case "used":
                    attrs ~= "used";
                    break;
                case "section":
                    if (!attr.hasStringValue) {
                        throw new CompileError("@section requires a string argument",
                            currentModulePath, attr.line, attr.column);
                    }
                    attrs ~= format("section(\"%s\")", escapeCAttrString(attr.stringValue));
                    break;
                case "align":
                    if (!attr.hasIntValue) {
                        throw new CompileError("@align requires an integer argument",
                            currentModulePath, attr.line, attr.column);
                    }
                    attrs ~= format("aligned(%d)", attr.intValue);
                    break;
                default:
                    throw new CompileError(format("Unknown global variable attribute '@%s'", attr.name),
                        currentModulePath, attr.line, attr.column);
            }
        }
        if (attrs.length == 0) {
            return "";
        }
        return "__attribute__((" ~ attrs.join(", ") ~ ")) ";
    }

    private string generateClass(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";

        // Generate struct definition
        code ~= format("struct %s {\n", cName);
        code ~= "    RefCount ref_count;\n";
        foreach (field; classDecl.fields) {
            code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
        }
        code ~= "};\n\n";

        // Generate constructor(s)
        foreach (ctor; classDecl.constructors) {
            code ~= generateConstructor(classDecl, ctor);
        }

        // Generate destructor
        if (classDecl.destructor) {
            code ~= generateDestructor(classDecl, classDecl.destructor);
        }

        // Generate methods
        foreach (method; classDecl.methods) {
            code ~= generateMethod(classDecl, method);
        }

        currentClassName = "";
        return code;
    }

    // Generates one *top-level* statement of a function/method/constructor/
    // destructor/lambda body, catching (not letting propagate) a
    // CompileError so a sibling statement's own, independent bug still
    // gets found in the same compile, instead of the first bad statement
    // aborting the rest of the body - see collectedErrors's own comment
    // (this is the same mechanism, just one level deeper: per-declaration
    // there, per-top-level-statement here). Deliberately scoped to this
    // level only, not recursively into every nested if/while/match/foreach
    // body too - a bug inside one of those still aborts its *whole*
    // enclosing top-level statement, an acceptable, predictable boundary
    // matching generateMultiple's own "declaration-level, not universal"
    // reasoning. Safe to just skip a failed statement's contribution to
    // `code`: local variable *types* are already registered in
    // variableTypes before their initializer expression is ever generated
    // (see generateStatement's VarDecl case), so a broken initializer
    // doesn't cascade into spurious "unknown variable" errors for whatever
    // sibling statement references that name next.
    private string generateBodyStatement(ASTNode stmt, bool isDeferred) {
        try {
            return generateStatement(stmt, isDeferred);
        } catch (CompileError e) {
            collectedErrors ~= e;
            return "";
        }
    }

    // If a function/method/lambda body's last statement is a bare
    // expression (not already a `return`) and its return type isn't
    // `void`, treats that trailing expression as an implicit return value -
    // `func foo() -> int { 128 }` behaves exactly like
    // `func foo() -> int { return 128 }`. Only the true last statement
    // qualifies (the same "only the last statement supplies a value" rule
    // ast.IfExpr's branches use) - an expression anywhere else in the body
    // is still just evaluated for its side effects and discarded, unchanged
    // from today. Reusing ReturnStmt's own codegen (rather than
    // duplicating its logic here) means the implicit return gets exactly
    // the same defer/try-finally replay and nullable/tuple/struct-literal
    // return-value handling an explicit `return` already gets.
    private ASTNode[] withImplicitReturn(ASTNode[] statements, Type returnType) {
        if (returnType is null || returnType.name == "void") return statements;
        if (statements.length == 0) return statements;
        auto exprStmt = cast(ExprStmt)statements[$ - 1];
        if (exprStmt is null) return statements;
        auto result = statements.dup;
        result[$ - 1] = new ReturnStmt(exprStmt.expression);
        return result;
    }

    private string generateConstructor(ClassDecl classDecl, FunctionDecl constructor) {
        string cName = mangledClass(classDecl);
        string code = "";
        string params = "";

        // Set current class/namespace context
        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);

        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= format("%s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        code ~= format("%s* %s(%s) {\n", cName, mangleConstructorName(classDecl, cName, constructor), params);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n",
            cName, cName, cName);
        code ~= indent() ~ "if (!self) return NULL;\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n\n";

        deferredStatements = [];

        // Generate constructor body
        string bodyCode = "";
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;

        // Un-bind the constructor's own params (and self) from
        // variableTypes now that its body is done - otherwise their bare,
        // unqualified names would keep resolving here for every
        // subsequently-generated function/method, permanently shadowing
        // any later global/field that happens to share one of those names
        // (resolveName checks a bare name before any namespace-qualified
        // candidate - see enclosingQualifications).
        foreach (param; constructor.params) {
            variableTypes.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    private string generateDestructor(ClassDecl classDecl, FunctionDecl destructor) {
        string cName = mangledClass(classDecl);
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";

        // Unlike generateConstructor/generateMethod, this was previously
        // never setting variableTypes["self"] - harmless for a destructor
        // that only ever accesses fields directly off `self` (memberAccessor
        // silently falls back to "->" when it can't infer a type, which
        // happens to be the right answer for a bare `self.field`, since
        // self is always a pointer), but wrong as soon as a destructor
        // indexes through a field to reach a *value* (struct-typed, not
        // pointer) element - e.g. `self.buckets[i].head` - where the
        // fallback's "->" guess is incorrect (it should be "."). Real bug,
        // not generics-specific; just never previously exercised by any
        // hand-written destructor.
        variableTypes["self"] = new Type(cName);

        code ~= format("void %s_destroy(void* ptr) {\n", cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)ptr;\n", cName, cName);

        deferredStatements = [];

        // Generate destructor body
        string bodyCode = "";
        if (destructor.body_) {
            foreach (stmt; destructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();

        // Release reference-counted fields. Struct-typed fields (including
        // __LLPL_Closure - see runtime.h/generateLambdaExpr) are plain
        // value types, not heap-allocated class instances, so they're
        // never reference-counted and must be excluded here the same way
        // typeToC/isStructTypeName already exclude them from auto-pointering.
        foreach (field; classDecl.fields) {
            if (!isPrimitiveTypeName(field.type.name) && !field.type.isPointer && !isStructTypeName(field.type.name)) {
                code ~= indent() ~ format("if (self->%s) rc_release(self->%s, %s_destroy);\n",
                    field.name, field.name, field.type.name);
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        variableTypes.remove("self");

        return code;
    }

    private string generateMethod(ClassDecl classDecl, FunctionDecl method) {
        string cName = mangledClass(classDecl);
        string code = "";
        string params = format("%s* self", cName);

        // Set current class/namespace context
        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);

        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(method.returnType);
        resolveType(method.returnType);
        Type prevReturnType = currentReturnType;
        currentReturnType = method.returnType;
        foreach (param; method.params) {
            resolveType(param.type);
            params ~= format(", %s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        code ~= format("%s %s(%s) {\n",
            typeToC(method.returnType), mangleMethodName(classDecl, cName, method), params);
        indentLevel++;

        deferredStatements = [];

        string bodyCode = "";
        if (method.body_) {
            foreach (stmt; withImplicitReturn(method.body_.statements, method.returnType)) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();

        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;

        // See generateConstructor's matching comment: params (and self)
        // are only valid names inside this method's own body.
        foreach (param; method.params) {
            variableTypes.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    private string generateFunction(FunctionDecl funcDecl) {
        if (funcDecl.isExtern) {
            // Just a forward declaration
            string params = "";
            foreach (i, param; funcDecl.params) {
                if (i > 0) params ~= ", ";
                params ~= format("%s %s", typeToC(param.type), param.name);
            }
            if (funcDecl.isVariadic) params ~= ", ...";
            return format("extern %s %s(%s);\n",
                typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
        }

        if (funcDecl.isInterrupt) {
            return generateInterruptFunction(funcDecl);
        }

        string code = "";
        string params = "";
        currentNamespaceSegments = funcDecl.namespaceSegments;
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(funcDecl.returnType);
        resolveType(funcDecl.returnType);
        Type prevReturnType = currentReturnType;
        currentReturnType = funcDecl.returnType;

        foreach (i, param; funcDecl.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= format("%s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }
        if (funcDecl.isVariadic) params ~= ", ...";

        // An `impl Trait for TheClass { ... }` method is desugared
        // (processImplBlock) into exactly this kind of ordinary top-level
        // function, with a `self: TheClass` parameter prepended - not
        // routed through generateClass/generateMethod at all, so
        // currentClassName (which checkMemberAccess relies on to allow
        // access to the class's own `private` members) would otherwise
        // never get set while generating its body, wrongly treating an
        // impl block as "outside" the very class it's implementing for.
        string prevClassNameForSelf = currentClassName;
        if (funcDecl.params.length > 0 && funcDecl.params[0].name == "self" &&
                funcDecl.params[0].type.name in classRegistry) {
            currentClassName = mangledClass(classRegistry[funcDecl.params[0].type.name]);
        }

        code ~= format("%s %s(%s) {\n",
            typeToC(funcDecl.returnType), mangleFreeFunctionName(funcDecl), params);
        indentLevel++;

        deferredStatements = [];

        string bodyCode = "";
        if (funcDecl.body_) {
            foreach (stmt; withImplicitReturn(funcDecl.body_.statements, funcDecl.returnType)) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        // Replay deferred statements for a fall-off-the-end return (every
        // *explicit* `return` already replays them inline - see
        // generateStatement's ReturnStmt case - but a void function that
        // never writes one needs this too, the same as generateMethod
        // already does).
        code ~= deferredCleanupCode();

        indentLevel--;
        code ~= "}\n";

        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentClassName = prevClassNameForSelf;

        // See generateConstructor's matching comment: params are only
        // valid names inside this function's own body.
        foreach (param; funcDecl.params) {
            variableTypes.remove(param.name);
        }

        return code;
    }

    // `interrupt func handler(...)` compiles to a GCC hardware-interrupt
    // handler: __attribute__((interrupt)) with the mandatory leading frame
    // pointer, and (for exceptions that push one) a trailing error-code
    // parameter driven by whether the LLPL declaration has a parameter.
    private string generateInterruptFunction(FunctionDecl funcDecl) {
        if (funcDecl.returnType.name != "void") {
            throw new CompileError("Interrupt functions must return void",
                currentModulePath, funcDecl.line, funcDecl.column);
        }
        if (funcDecl.params.length > 1) {
            throw new CompileError(
                "Interrupt functions take at most one parameter (the hardware error code)",
                currentModulePath, funcDecl.line, funcDecl.column);
        }

        currentNamespaceSegments = funcDecl.namespaceSegments;

        string params = "void* __frame";
        if (funcDecl.params.length == 1) {
            Parameter param = funcDecl.params[0];
            resolveType(param.type);
            params ~= format(", %s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        string code = format("__attribute__((interrupt)) void %s(%s) {\n", mangledFunc(funcDecl), params);
        indentLevel++;

        deferredStatements = [];

        string bodyCode = "";
        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();

        indentLevel--;
        code ~= "}\n";

        return code;
    }

    // Auto-wraps a plain value (or `null`) into a real Optional<T> instance
    // - what makes `T?` "sugar" for Optional<T> (see ast.Type.isNullableSugar)
    // rather than just a shorter way to spell the same explicit
    // `new`+`set()` dance. `optionalType.name` is already the resolved,
    // mangled instantiation name (e.g. "Optional_int") by the time this
    // runs, the same as any other generic instantiation - isNullableSugar
    // only marks the coercion itself, not a separate resolution path.
    private string generateNullableWrap(Type optionalType, ASTNode value) {
        string mangledName = optionalType.name;
        if (cast(NullLiteral)value !is null) {
            return format("%s_new()", mangledName);
        }
        try {
            // Assigning one already-Optional value to another (e.g. one
            // nullable variable to another, or a function returning
            // Optional<T> into a `T?`) - just copy the reference, don't
            // wrap it a second time.
            if (inferType(value).name == mangledName) {
                return generateExpression(value);
            }
        } catch (Exception e) {
            // Not a typed value inferType can see through (e.g. a bare
            // array literal) - fall through and treat it as a plain value
            // to wrap, same as the common case below.
        }
        string valueCode = generateExpression(value);
        return format("({ %s* __opt = %s_new(); %s_set(__opt, %s); __opt; })",
            mangledName, mangledName, mangledName, valueCode);
    }

    // Escape a string so it can be emitted as a C string literal.
    private string cStringLiteral(string s) {
        string result = "\"";
        foreach (char c; s) {
            switch (c) {
                case '\\': result ~= "\\\\"; break;
                case '"': result ~= "\\\""; break;
                case '\n': result ~= "\\n"; break;
                case '\r': result ~= "\\r"; break;
                case '\t': result ~= "\\t"; break;
                default:
                    if (c < 0x20 || c > 0x7E) {
                        result ~= format("\\x%02x", cast(ubyte)c);
                    } else {
                        result ~= c;
                    }
                    break;
            }
        }
        result ~= "\"";
        return result;
    }

    // `expr?` - unwraps an Optional<T>/Result<T, E>, or returns early out
    // of the *enclosing* function with an equivalent empty/error value.
    // Needs currentReturnType (see generateFunction/generateMethod/
    // generateLambdaExpr) to already be an Optional/Result of the same
    // kind - an empty Optional<T> carries no payload, so any T works for
    // that one, but propagating a Result's error needs its own E to match
    // (or at least be assignment-compatible in the generated C - a
    // mismatch surfaces as an ordinary C type error, same as everywhere
    // else this compiler leans on the C backend to catch a deeper type
    // mismatch rather than checking it itself).
    private bool sameErrorType(Type a, Type b) {
        if (a is null || b is null) return a is b;
        return a.name == b.name && a.pointerDepth == b.pointerDepth &&
            a.isArray == b.isArray && a.arraySize == b.arraySize;
    }

    private int nearestCatchFrameIndex() {
        int i = cast(int)tryFrameStack.length - 1;
        while (i >= 0) {
            if (tryFrameStack[i].catchLabel.length > 0) {
                return i;
            }
            i--;
        }
        return -1;
    }

    private void recordTryFrameErrorType(int frameIndex, Type errorType, int line, int column, string origin) {
        Type existing = tryFrameStack[frameIndex].errorType;
        if (existing is null) {
            tryFrameStack[frameIndex].errorType = errorType;
        } else if (!sameErrorType(existing, errorType)) {
            throw new CompileError(format(
                "All throws/'?' propagations caught by one 'try' block must use the same error type - " ~
                "this %s has '%s', but an earlier one was '%s'",
                origin, errorType.toString(), existing.toString()),
                currentModulePath, line, column);
        }
    }

    private string finallyCodeAboveFrame(int frameIndex) {
        string code = "";
        int i = cast(int)tryFrameStack.length - 1;
        while (i > frameIndex) {
            foreach (finallyStmt; tryFrameStack[i].finallyCode) {
                code ~= finallyStmt;
            }
            i--;
        }
        return code;
    }

    private string allActiveFinallyCode() {
        string code = "";
        if (tryFrameStack.length > 0) {
            foreach_reverse (frame; tryFrameStack) {
                foreach (finallyStmt; frame.finallyCode) {
                    code ~= finallyStmt;
                }
            }
        }
        return code;
    }

    private string cleanupCodeForFunctionExit() {
        string code = allActiveFinallyCode();
        if (tryFrameStack.length > 0) {
            foreach_reverse (frame; tryFrameStack) {
                if (frame.frameVarName.length > 0) {
                    code ~= indent() ~ format("llpl_eh_pop(&%s);\n", frame.frameVarName);
                }
            }
        }
        code ~= deferredCleanupCode();
        return code;
    }

    private string deferredCleanupCode() {
        string code = "";
        if (deferredStatements.length > 0) {
            foreach_reverse (deferInfo; deferredStatements) {
                code ~= indent() ~ format("if (%s) {\n", deferInfo.activeVarName);
                indentLevel++;
                code ~= indent() ~ format("%s = 0;\n", deferInfo.activeVarName);
                code ~= indent() ~ format("llpl_eh_pop(&%s);\n", deferInfo.frameVarName);
                code ~= deferInfo.code;
                indentLevel--;
                code ~= indent() ~ "}\n";
            }
        }
        return code;
    }

    private string deferFrameDeclarations() {
        string code = "";
        foreach (deferInfo; deferredStatements) {
            code ~= indent() ~ format("__LLPL_EH_Frame %s;\n", deferInfo.frameVarName);
            code ~= indent() ~ format("int %s = 0;\n", deferInfo.activeVarName);
        }
        return code;
    }

    private string generateDeferStmt(DeferStmt deferStmt) {
        string frameVar = format("__llpl_defer_frame%d", tryCounter++);
        string activeVar = format("__llpl_defer_active%d", tryCounter++);
        string deferCode = generateStatement(deferStmt.statement, true);
        deferredStatements ~= DeferInfo(deferCode, frameVar, activeVar);

        string code = "";
        code ~= indent() ~ format("%s.kind = LLPL_EH_FRAME_CLEANUP;\n", frameVar);
        code ~= indent() ~ format("%s.type_id = NULL;\n", frameVar);
        code ~= indent() ~ format("%s.error_slot = NULL;\n", frameVar);
        code ~= indent() ~ format("%s.error_size = 0;\n", frameVar);
        code ~= indent() ~ format("llpl_eh_push(&%s);\n", frameVar);
        code ~= indent() ~ format("%s = 1;\n", activeVar);
        code ~= indent() ~ format("if (llpl_eh_setjmp(&%s.env) != 0) {\n", frameVar);
        indentLevel++;
        code ~= indent() ~ format("%s = 0;\n", activeVar);
        code ~= deferCode;
        code ~= indent() ~ "llpl_eh_resume();\n";
        code ~= indent() ~ "__builtin_unreachable();\n";
        indentLevel--;
        code ~= indent() ~ "}\n";
        return code;
    }

    private string typeId(Type t) {
        return cStringLiteral(t.toString());
    }

    // Desugars `try { ... } [catch (e) { ... }] [finally { ... }]` into plain
    // C blocks/goto/labels - see ast.TryStmt's doc comment for the overall
    // design and TryFrame's own comment for the per-try state this pushes
    // onto tryFrameStack while generating the try/catch bodies (consulted
    // by generateThrowStmt/generatePropagateExpr to redirect here instead of
    // returning, and by generateStatement's ReturnStmt case to replay
    // finallyCode before any actual return).
    private string generateTryStmt(TryStmt stmt, bool isDeferred) {
        string[] finallyCode;
        if (stmt.finallyBlock !is null) {
            foreach (finStmt; stmt.finallyBlock.statements) {
                finallyCode ~= generateBodyStatement(finStmt, isDeferred);
            }
        }

        tryCounter++;
        int myId = tryCounter;
        string catchLabel = stmt.catchBlock !is null ? format("__catch_%d", myId) : "";
        string errorVarName = format("__llpl_try_err%d", myId);
        string frameVarName = format("__llpl_eh_frame%d", myId);

        Type explicitCatchType = null;
        if (stmt.catchType !is null) {
            explicitCatchType = cloneType(stmt.catchType);
            resolveType(explicitCatchType);
        }

        // Generate the try block's own statements first (at the indent depth
        // they'll actually be spliced back in at, below) so myFrame.errorType
        // is known before we have to emit errorVarName's declaration - a `?`
        // inside tryBodyCode already refers to errorVarName by name, so the
        // declaration has to exist somewhere that both it and the __catch_N
        // label below can see, i.e. the wrapping `{ }` this function emits.
        tryFrameStack ~= TryFrame(catchLabel, errorVarName, explicitCatchType, finallyCode, frameVarName);
        indentLevel++;
        string tryBodyCode = "";
        foreach (tstmt; stmt.tryBlock.statements) {
            tryBodyCode ~= generateBodyStatement(tstmt, isDeferred);
        }
        indentLevel--;
        TryFrame myFrame = tryFrameStack[$ - 1];
        tryFrameStack = tryFrameStack[0 .. $ - 1];

        if (stmt.catchBlock !is null && myFrame.errorType is null) {
            throw new CompileError(
                "'try' has a 'catch' clause but no throw/'?' inside the try block to determine " ~
                "the caught error's type; use 'catch (e: Type)' for cross-function throws",
                currentModulePath, stmt.line, stmt.column);
        }

        string code = "";
        code ~= indent() ~ "{\n";
        indentLevel++;
        if (stmt.catchBlock !is null) {
            code ~= indent() ~ format("%s %s;\n", typeToC(myFrame.errorType), errorVarName);
            code ~= indent() ~ format("__LLPL_EH_Frame %s;\n", frameVarName);
            code ~= indent() ~ format("%s.kind = LLPL_EH_FRAME_CATCH;\n", frameVarName);
            code ~= indent() ~ format("%s.type_id = %s;\n", frameVarName, typeId(myFrame.errorType));
            code ~= indent() ~ format("%s.error_slot = &%s;\n", frameVarName, errorVarName);
            code ~= indent() ~ format("%s.error_size = sizeof(%s);\n", frameVarName, typeToC(myFrame.errorType));
            code ~= indent() ~ format("llpl_eh_push(&%s);\n", frameVarName);
            code ~= indent() ~ format("if (llpl_eh_setjmp(&%s.env) == 0) {\n", frameVarName);
            indentLevel++;
            code ~= tryBodyCode;
            code ~= indent() ~ format("llpl_eh_pop(&%s);\n", frameVarName);
            code ~= indent() ~ format("goto __try_done_%d;\n", myId);
            indentLevel--;
            code ~= indent() ~ "} else {\n";
            indentLevel++;
            code ~= format("%s: ;\n", catchLabel);
            code ~= indent() ~ "{\n";
            indentLevel++;
            code ~= indent() ~ format("%s %s = %s;\n",
                typeToC(myFrame.errorType), stmt.catchVar, errorVarName);
            variableTypes[stmt.catchVar] = myFrame.errorType;
            tryFrameStack ~= TryFrame("", errorVarName, myFrame.errorType, finallyCode, "");
            foreach (cstmt; stmt.catchBlock.statements) {
                code ~= generateBodyStatement(cstmt, isDeferred);
            }
            tryFrameStack = tryFrameStack[0 .. $ - 1];
            indentLevel--;
            code ~= indent() ~ "}\n";
            indentLevel--;
            code ~= indent() ~ "}\n";
            code ~= format("__try_done_%d: ;\n", myId);
        } else if (stmt.finallyBlock !is null) {
            code ~= indent() ~ format("__LLPL_EH_Frame %s;\n", frameVarName);
            code ~= indent() ~ format("%s.kind = LLPL_EH_FRAME_CLEANUP;\n", frameVarName);
            code ~= indent() ~ format("%s.type_id = NULL;\n", frameVarName);
            code ~= indent() ~ format("%s.error_slot = NULL;\n", frameVarName);
            code ~= indent() ~ format("%s.error_size = 0;\n", frameVarName);
            code ~= indent() ~ format("llpl_eh_push(&%s);\n", frameVarName);
            code ~= indent() ~ format("if (llpl_eh_setjmp(&%s.env) == 0) {\n", frameVarName);
            indentLevel++;
            code ~= tryBodyCode;
            code ~= indent() ~ format("llpl_eh_pop(&%s);\n", frameVarName);
            indentLevel--;
            code ~= indent() ~ "} else {\n";
            indentLevel++;
            foreach (finStmt; finallyCode) {
                code ~= finStmt;
            }
            code ~= indent() ~ "llpl_eh_resume();\n";
            code ~= indent() ~ "__builtin_unreachable();\n";
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else {
            code ~= tryBodyCode;
        }

        indentLevel--;
        code ~= indent() ~ "}\n";

        foreach (finStmt; finallyCode) {
            code ~= finStmt;
        }

        return code;
    }

    private Type currentResultErrorType(int line, int column, string diagnostic) {
        if (currentReturnType is null || (currentReturnType.name !in resultInstantiations)) {
            throw new CompileError(diagnostic, currentModulePath, line, column);
        }
        auto recorded = currentReturnType.name in monomorphizedTypeArgs;
        if (recorded is null || recorded.length != 2) {
            throw new CompileError("Cannot determine the current function's Result error type",
                currentModulePath, line, column);
        }
        return (*recorded)[1];
    }

    private string generateThrowStmt(ThrowStmt stmt, bool isDeferred) {
        if (isDeferred) {
            throw new CompileError("'throw' is not supported inside a deferred statement",
                currentModulePath, stmt.line, stmt.column);
        }

        Type thrownType;
        try {
            thrownType = inferType(stmt.value);
        } catch (Exception e) {
            throw new CompileError("Cannot infer the type of thrown value",
                currentModulePath, stmt.line, stmt.column);
        }
        string valueCode = generateExpression(stmt.value);

        int catchIndex = nearestCatchFrameIndex();
        if (catchIndex >= 0) {
            recordTryFrameErrorType(catchIndex, thrownType, stmt.line, stmt.column, "'throw'");
        }
        string code = "";
        string tmp = format("__llpl_throw_value%d", tryCounter++);
        code ~= indent() ~ format("%s %s = %s;\n", typeToC(thrownType), tmp, valueCode);
        code ~= indent() ~ format("llpl_eh_throw(%s, &%s, sizeof(%s));\n",
            typeId(thrownType), tmp, typeToC(thrownType));
        code ~= indent() ~ "__builtin_unreachable();\n";
        return code;
    }

    // `delete expr` - see ast.DeleteStmt's own comment for why this is
    // exactly rc_release(ptr, ClassName_destroy), the same call
    // generateDestructor already emits to release a reference-counted
    // field. Only classes are reference-counted/heap-allocated at all -
    // structs are plain values, so "delete"-ing one is a compile error
    // (the same kind of "clear error over silently generating nonsense
    // C" this compiler prefers elsewhere).
    private string generateDeleteStmt(DeleteStmt stmt) {
        Type t;
        try {
            t = inferType(stmt.value);
        } catch (Exception e) {
            throw new CompileError("Cannot infer the type of 'delete's operand",
                currentModulePath, stmt.line, stmt.column);
        }
        resolveType(t);
        if ((t.name in classRegistry) is null) {
            throw new CompileError(format(
                "'delete' can only be used on a class instance, not '%s' - structs and " ~
                "primitives aren't reference-counted", t.toString()),
                currentModulePath, stmt.line, stmt.column);
        }
        return indent() ~ format("rc_release(%s, %s_destroy);\n",
            generateExpression(stmt.value), t.name);
    }

    private string generatePropagateExpr(PropagateExpr propExpr) {
        Type operandType;
        try {
            operandType = inferType(propExpr.operand);
        } catch (Exception e) {
            throw new CompileError("Cannot infer the type of '?''s operand",
                currentModulePath, propExpr.line, propExpr.column);
        }
        string operandMangled = operandType.name;
        string operandCode = generateExpression(propExpr.operand);
        string tmp = format("__propagate%d", propagateCounter++);

        if (operandMangled in optionalInstantiations) {
            if (currentReturnType is null || (currentReturnType.name !in optionalInstantiations)) {
                throw new CompileError(
                    "'?' on an Optional value needs the enclosing function to also return " ~
                    "an Optional<T> (or 'T?')", currentModulePath, propExpr.line, propExpr.column);
            }
            return format("({ %s* %s = %s; if (!%s->has_value) { %s return %s_new(); } %s->value; })",
                operandMangled, tmp, operandCode, tmp, cleanupCodeForFunctionExit(),
                currentReturnType.name, tmp);
        }

        if (operandMangled in resultInstantiations) {
            // Inside a `try` block with a catch clause - redirect to that
            // try's catch label instead of returning from the enclosing
            // function (see ast.TryStmt/generateTryStmt's own comments).
            // No new Result/trace to build here, unlike the plain
            // early-return path below - we're not returning a Result to
            // anyone, just capturing the raw error value locally.
            int catchIndex = nearestCatchFrameIndex();
            if (catchIndex >= 0) {
                auto recorded = operandMangled in monomorphizedTypeArgs;
                if (recorded is null || recorded.length != 2) {
                    throw new CompileError("Cannot determine the error type of '?' inside a try block",
                        currentModulePath, propExpr.line, propExpr.column);
                }
                Type errorType = (*recorded)[1];
                recordTryFrameErrorType(catchIndex, errorType, propExpr.line, propExpr.column, "'?'");
                auto frame = tryFrameStack[catchIndex];
                string popFrame = frame.frameVarName.length > 0
                    ? format("llpl_eh_pop(&%s); ", frame.frameVarName)
                    : "";
                return format("({ %s* %s = %s; if (!%s->ok) { %s%s = %s->error; %sgoto %s; } %s->value; })",
                    operandMangled, tmp, operandCode, tmp, finallyCodeAboveFrame(catchIndex),
                    frame.errorVarName, tmp, popFrame, frame.catchLabel, tmp);
            }

            if (currentReturnType is null || (currentReturnType.name !in resultInstantiations)) {
                throw new CompileError(
                    "'?' on a Result value needs the enclosing function to also return a Result<T, E>",
                    currentModulePath, propExpr.line, propExpr.column);
            }
            string loc = format("%s:%d", baseName(currentModulePath), propExpr.line);
            string locVar = format("__llpl_loc%d", propagateCounter);
            string traceVar = format("__llpl_trace%d", propagateCounter);
            return format(
                "({ static char %s[] = %s; static char %s[512]; %s* %s = %s; " ~
                "if (!%s->ok) { %s* __e = %s_new(); " ~
                "if (%s->trace) { ksnprintf(%s, 512, \"%%s -> %%s\", %s->trace, %s); %s_set_err_with_trace(__e, %s->error, %s); } " ~
                "else { %s_set_err_with_trace(__e, %s->error, %s); } %s return __e; } %s->value; })",
                locVar, cStringLiteral(loc), traceVar,
                operandMangled, tmp, operandCode, tmp,
                currentReturnType.name, currentReturnType.name,
                tmp, traceVar, tmp, locVar, currentReturnType.name, tmp, traceVar,
                currentReturnType.name, tmp, locVar,
                cleanupCodeForFunctionExit(), tmp);
        }

        throw new CompileError(format("'?' can only be used on an Optional<T> or Result<T, E> value, not '%s'",
            operandMangled), currentModulePath, propExpr.line, propExpr.column);
    }

    // Returns `block`'s trailing expression - see ast.IfExpr's doc comment
    // for why only the *last* statement can supply a branch's value.
    // Shared by generateIfExpr (which also emits every earlier statement
    // first, for their side effects) and inferIfExprType (which only needs
    // the value's type).
    private ASTNode ifExprBranchValue(Block block, string branchName, IfExpr ifExpr) {
        if (block.statements.length == 0) {
            throw new CompileError(format(
                "if-expression's '%s' branch is empty - it needs a trailing expression to supply a value",
                branchName), currentModulePath, ifExpr.line, ifExpr.column);
        }
        auto exprStmt = cast(ExprStmt)block.statements[$ - 1];
        if (exprStmt is null) {
            throw new CompileError(format(
                "if-expression's '%s' branch must end with an expression to supply its value",
                branchName), currentModulePath, ifExpr.line, ifExpr.column);
        }
        return exprStmt.expression;
    }

    // Both branches' trailing expressions must produce the same type - no
    // implicit widening/coercion here, matching this compiler's existing
    // "nominal, single-type" simplifications elsewhere (tagged enums,
    // try/catch's one-error-type-per-block, ...).
    private Type checkIfExprBranchTypesMatch(Type thenType, Type elseType, IfExpr ifExpr) {
        if (thenType.name != elseType.name || thenType.pointerDepth != elseType.pointerDepth) {
            throw new CompileError(format(
                "if-expression's branches have different types - 'then' is '%s', 'else' is '%s'",
                thenType.toString(), elseType.toString()),
                currentModulePath, ifExpr.line, ifExpr.column);
        }
        return thenType;
    }

    // Resolves an if-expression's result type when it's needed *without*
    // also generating its code (e.g. VarDecl inferring `let y = if ... `'s
    // type with no explicit annotation, before it ever calls
    // generateExpression on the initializer) - see generateIfExpr's own
    // comment for why a branch's preceding statements have to be generated
    // (here, generated and thrown away) before the trailing value can be
    // typed at all: a trailing expression referencing a variable the same
    // branch just declared (`if c { let a = 1; a } else { 0 }`) can't be
    // typed otherwise. Harmless duplicate work, not a correctness issue -
    // generateIfExpr repeats this generation for real afterward; nothing
    // from this throwaway pass is ever emitted.
    private Type inferIfExprType(IfExpr ifExpr) {
        // ifExprBranchValue validates non-emptiness first - checked before
        // ever slicing off "everything but the last statement" below,
        // since that slice underflows (`$ - 1` on a length-0 array) if the
        // block turns out to be empty.
        ASTNode thenValue = ifExprBranchValue(ifExpr.thenBlock, "then", ifExpr);
        foreach (stmt; ifExpr.thenBlock.statements[0 .. $ - 1]) generateBodyStatement(stmt, false);
        Type thenType = inferType(thenValue);
        ASTNode elseValue = ifExprBranchValue(ifExpr.elseBlock, "else", ifExpr);
        foreach (stmt; ifExpr.elseBlock.statements[0 .. $ - 1]) generateBodyStatement(stmt, false);
        Type elseType = inferType(elseValue);
        return checkIfExprBranchTypesMatch(thenType, elseType, ifExpr);
    }

    // Desugars an if-expression (e.g. `let x = if cond { 128 } else { 256 }`)
    // into a GCC statement expression - the same `({ ... })` trick
    // generatePropagateExpr already relies on for `?`, so this needs
    // nothing beyond what this compiler already emits for freestanding
    // targets. Each branch's preceding statements are generated first (so
    // they're available to type/generate that branch's trailing value,
    // same reasoning as inferIfExprType above), then spliced together once
    // both branches are fully known.
    private string generateIfExpr(IfExpr ifExpr) {
        // ifExprBranchValue validates non-emptiness before the `[0 .. $ - 1]`
        // prefix slice below, which would otherwise underflow on an empty
        // block (see inferIfExprType's matching comment).
        ASTNode thenValue = ifExprBranchValue(ifExpr.thenBlock, "then", ifExpr);
        string thenPrefix = "";
        foreach (stmt; ifExpr.thenBlock.statements[0 .. $ - 1]) thenPrefix ~= generateBodyStatement(stmt, false);
        Type thenType = inferType(thenValue);
        string thenValueCode = generateExpression(thenValue);

        ASTNode elseValue = ifExprBranchValue(ifExpr.elseBlock, "else", ifExpr);
        string elsePrefix = "";
        foreach (stmt; ifExpr.elseBlock.statements[0 .. $ - 1]) elsePrefix ~= generateBodyStatement(stmt, false);
        Type elseType = inferType(elseValue);
        string elseValueCode = generateExpression(elseValue);

        Type resultType = checkIfExprBranchTypesMatch(thenType, elseType, ifExpr);
        resolveType(resultType);

        string tmp = format("__llpl_ifexpr%d", tempVarCounter++);
        string conditionCode = generateExpression(ifExpr.condition);

        return format("({ %s %s; if (%s) { %s%s = %s; } else { %s%s = %s; } %s; })",
            typeToC(resultType), tmp, conditionCode,
            thenPrefix, tmp, thenValueCode,
            elsePrefix, tmp, elseValueCode,
            tmp);
    }

    private string generateStatement(ASTNode node, bool isDeferred) {
        string code = "";

        if (auto varDecl = cast(VarDecl)node) {
            if (varDecl.bitWidth >= 0) {
                throw new CompileError("Bit-fields are only allowed on class fields, not local variables",
                    currentModulePath, varDecl.line, varDecl.column);
            }

            // Infer the type from the initializer if none was declared
            if (varDecl.type is null) {
                varDecl.type = inferType(varDecl.initializer);
            }
            // Captured *before* resolveType mutates varDecl.type in place -
            // a generic struct literal initializer (Pair { ... }) needs the
            // declared type's original, unmangled name/typeArgs to supply
            // its own type arguments (see resolveStructLiteralTarget).
            Type declaredTypeAsWritten = cloneType(varDecl.type);
            resolveType(varDecl.type);
            checkArrayLiteralInit(varDecl);

            // Track the variable type
            variableTypes[varDecl.name] = varDecl.type;
            if (varDecl.isConst) {
                constVariables[varDecl.name] = true;
            }

            // Handle array declarations specially
            string constPrefix = (varDecl.isVolatile ? "volatile " : "") ~ (varDecl.isConst ? "const " : "");
            if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
                string baseType = primitiveToC(varDecl.type.name);
                baseType ~= pointerStars(varDecl.type);
                code ~= indent() ~ format("%s%s %s[%d]", constPrefix, baseType, varDecl.name, varDecl.type.arraySize);
            } else {
                code ~= indent() ~ format("%s%s %s", constPrefix, typeToC(varDecl.type), varDecl.name);
            }

            if (varDecl.initializer) {
                if (varDecl.type.isNullableSugar) {
                    code ~= " = " ~ generateNullableWrap(varDecl.type, varDecl.initializer);
                } else if (auto tupleLit = cast(TupleLiteral)varDecl.initializer) {
                    code ~= " = " ~ generateTupleLiteral(tupleLit, declaredTypeAsWritten);
                } else if (auto structLit = cast(StructLiteral)varDecl.initializer) {
                    code ~= " = " ~ generateStructLiteralValue(structLit, declaredTypeAsWritten);
                } else {
                    code ~= " = " ~ generateExpression(varDecl.initializer);
                }
            } else if (varDecl.type.isNullableSugar) {
                // No initializer at all (`let x: int?`) - default to an
                // empty Optional rather than an uninitialized pointer,
                // which would crash the moment any method (is_some(), ...)
                // ran on it.
                code ~= " = " ~ format("%s_new()", varDecl.type.name);
            }
            code ~= ";\n";
        } else if (auto destructStmt = cast(DestructuringStmt)node) {
            code ~= generateDestructuringStmt(destructStmt);
        } else if (auto ifStmt = cast(IfStmt)node) {
            code ~= indent() ~ "if (" ~ generateExpression(ifStmt.condition) ~ ") {\n";
            indentLevel++;
            foreach (stmt; ifStmt.thenBlock.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            if (ifStmt.elseBlock) {
                code ~= indent() ~ "} else {\n";
                indentLevel++;
                foreach (stmt; ifStmt.elseBlock.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }
                indentLevel--;
            }
            code ~= indent() ~ "}\n";
        } else if (auto whileStmt = cast(WhileStmt)node) {
            code ~= indent() ~ "while (" ~ generateExpression(whileStmt.condition) ~ ") {\n";
            indentLevel++;
            foreach (stmt; whileStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto forStmt = cast(ForStmt)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            if (forStmt.initializer) {
                code ~= generateStatement(forStmt.initializer, isDeferred);
            }
            code ~= indent() ~ "while (";
            if (forStmt.condition) {
                code ~= generateExpression(forStmt.condition);
            } else {
                code ~= "1";
            }
            code ~= ") {\n";
            indentLevel++;
            foreach (stmt; forStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            if (forStmt.update) {
                code ~= indent() ~ generateExpression(forStmt.update) ~ ";\n";
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            code ~= generateForeachStmt(foreachStmt, isDeferred);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            // Replay any enclosing try block(s)' finally code first
            // (innermost-to-outermost), then function-level defers - see
            // TryFrame's own comment for why finally must run before defer.
            if (returnStmt.value) {
                string valueCode;
                if (currentReturnType !is null && currentReturnType.isNullableSugar) {
                    valueCode = generateNullableWrap(currentReturnType, returnStmt.value);
                } else if (auto tupleLit = cast(TupleLiteral)returnStmt.value) {
                    valueCode = generateTupleLiteral(tupleLit, currentReturnTypeAsWritten);
                } else if (auto structLit = cast(StructLiteral)returnStmt.value) {
                    valueCode = generateStructLiteralValue(structLit, currentReturnTypeAsWritten);
                } else {
                    valueCode = generateExpression(returnStmt.value);
                }
                tempVarCounter++;
                string retName = format("__llpl_ret%d", tempVarCounter);
                code ~= indent() ~ format("%s %s = %s;\n", typeToC(currentReturnType), retName, valueCode);
                if (!isDeferred) {
                    code ~= cleanupCodeForFunctionExit();
                }
                code ~= indent() ~ format("return %s;\n", retName);
            } else {
                if (!isDeferred) {
                    code ~= cleanupCodeForFunctionExit();
                }
                code ~= indent() ~ "return;\n";
            }
        } else if (auto deferStmt = cast(DeferStmt)node) {
            code ~= generateDeferStmt(deferStmt);
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            code ~= generateThrowStmt(throwStmt, isDeferred);
        } else if (auto tryStmt = cast(TryStmt)node) {
            code ~= generateTryStmt(tryStmt, isDeferred);
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            code ~= generateDeleteStmt(deleteStmt);
        } else if (auto block = cast(Block)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (stmt; block.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto exprStmt = cast(ExprStmt)node) {
            code ~= indent() ~ generateExpression(exprStmt.expression) ~ ";\n";
        } else if (auto asmStmt = cast(AsmStmt)node) {
            code ~= generateAsm(asmStmt);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            code ~= generateMatch(matchStmt, isDeferred);
        } else if (auto macroInvocation = cast(MacroInvocation)node) {
            code ~= generateMacroExpansion(macroInvocation, isDeferred);
        } else if (cast(QuoteExpr)node || cast(UnquoteExpr)node) {
            throw new CompileError("'quote'/'unquote' can only be used to build macro expansions",
                currentModulePath, node.line, node.column);
        }

        return code;
    }

    // `typeSubs`, when non-null, additionally substitutes a generic type
    // parameter's name (e.g. "T") with its bound concrete Type wherever
    // this clones a Type - used by the monomorphization engine (see
    // instantiateGenericClassOrStruct/instantiateGenericFunction) to stamp
    // out a concrete copy of a generic declaration's body. `null` (the
    // default, used by every existing macro-expansion call site) means
    // "just deep-copy, no substitution" - macros are unaffected.
    private Type cloneType(Type t, Type[string] typeSubs = null) {
        if (t is null) return null;
        if (typeSubs !is null) {
            if (auto sub = t.name in typeSubs) {
                // Merge, same as resolveType's alias substitution: a use
                // site that also wrote its own `*` on top of an
                // already-pointer type parameter binding (`T*` where `T`
                // is bound to `int*`) stacks depth (`int**`) rather than
                // collapsing back to a single `*`.
                auto merged = new Type(sub.name, t.pointerDepth + sub.pointerDepth, t.isArray || sub.isArray,
                    t.arraySize > 0 ? t.arraySize : sub.arraySize);
                merged.typeArgs = sub.typeArgs.map!(a => cloneType(a, typeSubs)).array;
                merged.closureParams = sub.closureParams;
                merged.closureReturnType = sub.closureReturnType;
                return merged;
            }
        }
        auto copy = new Type(t.name, t.pointerDepth, t.isArray, t.arraySize);
        copy.typeArgs = t.typeArgs.map!(a => cloneType(a, typeSubs)).array;
        if (t.closureReturnType !is null) {
            Parameter[] cps;
            foreach (p; t.closureParams) cps ~= new Parameter(p.name, cloneType(p.type, typeSubs));
            copy.closureParams = cps;
            copy.closureReturnType = cloneType(t.closureReturnType, typeSubs);
        }
        return copy;
    }

    private ASTNode[] cloneNodes(ASTNode[] nodes, ASTNode[string] subs, Type[string] typeSubs = null) {
        ASTNode[] result;
        foreach (n; nodes) {
            result ~= cloneNode(n, subs, typeSubs);
        }
        return result;
    }

    private Block cloneBlock(Block b, ASTNode[string] subs, Type[string] typeSubs = null) {
        if (b is null) return null;
        return new Block(cloneNodes(b.statements, subs, typeSubs));
    }

    // Deep-copies an AST subtree, replacing any Identifier whose name is a
    // macro parameter with a fresh clone of the argument it was called
    // with. Everything else (locals the macro body declares itself,
    // references to outer/global names) is copied unchanged and left to
    // resolve normally at the call site - macros are deliberately
    // unhygienic about names they didn't introduce, same as C's #define.
    // Also reused (with `subs` empty and `typeSubs` set) by the
    // monomorphization engine to stamp out a generic declaration's body
    // with its type parameters substituted - see cloneType above.
    private Pattern clonePattern(Pattern pattern, ASTNode[string] subs, Type[string] typeSubs = null) {
        if (cast(WildcardPattern)pattern) {
            return new WildcardPattern(pattern.line, pattern.column);
        } else if (auto bind = cast(BindingPattern)pattern) {
            return new BindingPattern(bind.name, bind.line, bind.column);
        } else if (auto tuplePat = cast(TuplePattern)pattern) {
            Pattern[] cloned;
            foreach (p; tuplePat.elements) cloned ~= clonePattern(p, subs, typeSubs);
            return new TuplePattern(cloned, tuplePat.line, tuplePat.column);
        } else if (auto structPat = cast(StructPattern)pattern) {
            return new StructPattern(cloneType(structPat.type, typeSubs),
                structPat.fieldNames.dup, structPat.line, structPat.column);
        }
        return null;
    }

    private ASTNode cloneNode(ASTNode node, ASTNode[string] subs, Type[string] typeSubs = null) {
        if (node is null) return null;

        if (auto ident = cast(Identifier)node) {
            if (auto sub = ident.name in subs) {
                return cloneNode(*sub, null, typeSubs); // substitution itself is never re-substituted
            }
            return new Identifier(ident.name, ident.line, ident.column);
        } else if (auto intLit = cast(IntLiteral)node) {
            return new IntLiteral(intLit.value, intLit.line, intLit.column);
        } else if (auto strLit = cast(StringLiteral)node) {
            return new StringLiteral(strLit.value, strLit.line, strLit.column);
        } else if (auto regexLit = cast(RegexLiteral)node) {
            return new RegexLiteral(regexLit.pattern, regexLit.line, regexLit.column);
        } else if (auto interp = cast(InterpolatedStringLiteral)node) {
            return new InterpolatedStringLiteral(interp.literalParts.dup, cloneNodes(interp.expressions, subs, typeSubs),
                interp.specs.dup, interp.line, interp.column);
        } else if (auto arrLit = cast(ArrayLiteral)node) {
            return new ArrayLiteral(cloneNodes(arrLit.elements, subs, typeSubs), arrLit.line, arrLit.column);
        } else if (auto boolLit = cast(BoolLiteral)node) {
            return new BoolLiteral(boolLit.value, boolLit.line, boolLit.column);
        } else if (cast(NullLiteral)node) {
            return new NullLiteral(node.line, node.column);
        } else if (auto binExpr = cast(BinaryExpr)node) {
            return new BinaryExpr(binExpr.op, cloneNode(binExpr.left, subs, typeSubs),
                cloneNode(binExpr.right, subs, typeSubs), binExpr.line, binExpr.column);
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            return new UnaryExpr(unaryExpr.op, cloneNode(unaryExpr.operand, subs, typeSubs),
                unaryExpr.line, unaryExpr.column);
        } else if (auto callExpr = cast(CallExpr)node) {
            return new CallExpr(cloneNode(callExpr.callee, subs, typeSubs), cloneNodes(callExpr.args, subs, typeSubs),
                callExpr.line, callExpr.column, callExpr.argNames.dup);
        } else if (auto memberExpr = cast(MemberExpr)node) {
            return new MemberExpr(cloneNode(memberExpr.object, subs, typeSubs), memberExpr.member,
                memberExpr.line, memberExpr.column);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            return new IndexExpr(cloneNode(indexExpr.array, subs, typeSubs), cloneNode(indexExpr.index, subs, typeSubs),
                indexExpr.line, indexExpr.column);
        } else if (auto newExpr = cast(NewExpr)node) {
            return new NewExpr(cloneType(newExpr.type, typeSubs), cloneNodes(newExpr.args, subs, typeSubs),
                newExpr.line, newExpr.column, newExpr.argNames.dup);
        } else if (auto castExpr = cast(CastExpr)node) {
            return new CastExpr(cloneType(castExpr.type, typeSubs), cloneNode(castExpr.expression, subs, typeSubs),
                castExpr.line, castExpr.column);
        } else if (auto sizeofExpr = cast(SizeofExpr)node) {
            return new SizeofExpr(cloneType(sizeofExpr.type, typeSubs), sizeofExpr.line, sizeofExpr.column);
        } else if (auto structLit = cast(StructLiteral)node) {
            return new StructLiteral(structLit.typeName, structLit.fieldNames.dup,
                cloneNodes(structLit.fieldValues, subs, typeSubs), structLit.line, structLit.column);
        } else if (auto tupleLit = cast(TupleLiteral)node) {
            return new TupleLiteral(cloneNodes(tupleLit.elements, subs, typeSubs),
                tupleLit.line, tupleLit.column);
        } else if (auto propExpr = cast(PropagateExpr)node) {
            return new PropagateExpr(cloneNode(propExpr.operand, subs, typeSubs), propExpr.line, propExpr.column);
        } else if (auto ifExpr = cast(IfExpr)node) {
            return new IfExpr(cloneNode(ifExpr.condition, subs, typeSubs), cloneBlock(ifExpr.thenBlock, subs, typeSubs),
                cloneBlock(ifExpr.elseBlock, subs, typeSubs), ifExpr.line, ifExpr.column);
        } else if (auto lambdaExpr = cast(LambdaExpr)node) {
            Parameter[] lps;
            foreach (p; lambdaExpr.params) lps ~= new Parameter(p.name, cloneType(p.type, typeSubs));
            Capture[] caps;
            foreach (c; lambdaExpr.captures) caps ~= new Capture(c.name, c.byRef);
            return new LambdaExpr(caps, lps, cloneType(lambdaExpr.returnType, typeSubs),
                cloneBlock(lambdaExpr.body_, subs, typeSubs), lambdaExpr.line, lambdaExpr.column);
        } else if (auto varDecl = cast(VarDecl)node) {
            return new VarDecl(varDecl.name, cloneType(varDecl.type, typeSubs), cloneNode(varDecl.initializer, subs, typeSubs),
                varDecl.isConst, varDecl.line, varDecl.column, varDecl.bitWidth, varDecl.isVolatile,
                varDecl.attributes.dup);
        } else if (auto destructStmt = cast(DestructuringStmt)node) {
            return new DestructuringStmt(clonePattern(destructStmt.pattern, subs, typeSubs),
                cloneType(destructStmt.type, typeSubs), cloneNode(destructStmt.initializer, subs, typeSubs),
                destructStmt.isConst, destructStmt.isVolatile, destructStmt.line, destructStmt.column);
        } else if (auto patternExpr = cast(PatternExpr)node) {
            return new PatternExpr(clonePattern(patternExpr.pattern, subs, typeSubs),
                patternExpr.line, patternExpr.column);
        } else if (auto ifStmt = cast(IfStmt)node) {
            return new IfStmt(cloneNode(ifStmt.condition, subs, typeSubs), cloneBlock(ifStmt.thenBlock, subs, typeSubs),
                cloneBlock(ifStmt.elseBlock, subs, typeSubs));
        } else if (auto whileStmt = cast(WhileStmt)node) {
            return new WhileStmt(cloneNode(whileStmt.condition, subs, typeSubs), cloneBlock(whileStmt.body_, subs, typeSubs));
        } else if (auto forStmt = cast(ForStmt)node) {
            return new ForStmt(cloneNode(forStmt.initializer, subs, typeSubs), cloneNode(forStmt.condition, subs, typeSubs),
                cloneNode(forStmt.update, subs, typeSubs), cloneBlock(forStmt.body_, subs, typeSubs));
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            return new ForeachStmt(foreachStmt.varName, cloneNode(foreachStmt.iterable, subs, typeSubs),
                cloneBlock(foreachStmt.body_, subs, typeSubs), foreachStmt.line, foreachStmt.column);
        } else if (auto rangeExpr = cast(RangeExpr)node) {
            return new RangeExpr(cloneNode(rangeExpr.start, subs, typeSubs), cloneNode(rangeExpr.end, subs, typeSubs),
                rangeExpr.line, rangeExpr.column);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(cloneNode(returnStmt.value, subs, typeSubs));
        } else if (auto deferStmt = cast(DeferStmt)node) {
            return new DeferStmt(cloneNode(deferStmt.statement, subs, typeSubs));
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            return new ThrowStmt(cloneNode(throwStmt.value, subs, typeSubs),
                throwStmt.line, throwStmt.column);
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            return new DeleteStmt(cloneNode(deleteStmt.value, subs, typeSubs),
                deleteStmt.line, deleteStmt.column);
        } else if (auto tryStmt = cast(TryStmt)node) {
            return new TryStmt(cloneBlock(tryStmt.tryBlock, subs, typeSubs), tryStmt.catchVar,
                cloneType(tryStmt.catchType, typeSubs), cloneBlock(tryStmt.catchBlock, subs, typeSubs),
                cloneBlock(tryStmt.finallyBlock, subs, typeSubs), tryStmt.line, tryStmt.column);
        } else if (auto block = cast(Block)node) {
            return cloneBlock(block, subs, typeSubs);
        } else if (auto exprStmt = cast(ExprStmt)node) {
            return new ExprStmt(cloneNode(exprStmt.expression, subs, typeSubs));
        } else if (auto asmStmt = cast(AsmStmt)node) {
            AsmOperand[] cloneOperands(AsmOperand[] ops) {
                AsmOperand[] result;
                foreach (op; ops) {
                    result ~= new AsmOperand(op.constraint, cloneNode(op.expr, subs, typeSubs));
                }
                return result;
            }
            return new AsmStmt(asmStmt.templateLines.dup, cloneOperands(asmStmt.outputs),
                cloneOperands(asmStmt.inputs), asmStmt.clobbers.dup, asmStmt.line, asmStmt.column);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            MatchCase[] cases;
            foreach (c; matchStmt.cases) {
                cases ~= new MatchCase(cloneNodes(c.patterns, subs, typeSubs), cloneBlock(c.body_, subs, typeSubs));
            }
            return new MatchStmt(cloneNode(matchStmt.subject, subs, typeSubs), cases, matchStmt.line, matchStmt.column);
        } else if (auto macroInvocation = cast(MacroInvocation)node) {
            return new MacroInvocation(macroInvocation.name, cloneNodes(macroInvocation.args, subs, typeSubs),
                macroInvocation.line, macroInvocation.column);
        } else if (auto quoteExpr = cast(QuoteExpr)node) {
            return new QuoteExpr(cloneNode(quoteExpr.body, subs, typeSubs), quoteExpr.isBlock,
                quoteExpr.line, quoteExpr.column);
        } else if (auto unquoteExpr = cast(UnquoteExpr)node) {
            return new UnquoteExpr(cloneNode(unquoteExpr.expression, subs, typeSubs),
                unquoteExpr.line, unquoteExpr.column);
        }

        throw new CompileError("Internal error: this construct can't appear inside a macro body",
            currentModulePath, node.line, node.column);
    }

    // Stamps out one concrete copy of a generic function template with its
    // type parameters bound (`typeSubs`) - used for both a `func foo<T>`
    // free function and a generic class's methods/constructor/destructor
    // (all of which share this same "params + return type + body" shape).
    // `namespaceSegments` is always cleared on the clone: for a top-level
    // function `newName` is passed in as the already-fully-mangled
    // instantiation name (e.g. "max_of_int"), so mangledFunc(clone) must
    // return it unchanged rather than re-prefixing a namespace; for a
    // method/constructor/destructor `newName`/namespaceSegments aren't used
    // for naming at all (generateMethod/generateConstructor/
    // generateDestructor derive the emitted C symbol from the *class's*
    // mangled name instead), so clearing it here is harmless either way.
    private FunctionDecl cloneFunctionDeclWithTypeSubs(FunctionDecl fn, Type[string] typeSubs, string newName) {
        Parameter[] params;
        foreach (p; fn.params) {
            ASTNode defaultValue = p.defaultValue is null ? null : cloneNode(p.defaultValue, null, typeSubs);
            params ~= new Parameter(p.name, cloneType(p.type, typeSubs), defaultValue);
        }
        auto clone = new FunctionDecl(newName, params, cloneType(fn.returnType, typeSubs),
            cloneBlock(fn.body_, null, typeSubs), fn.isExtern, fn.isInterrupt, fn.isVariadic,
            fn.line, fn.column);
        clone.namespaceSegments = [];
        return clone;
    }

    private ClassDecl cloneClassDeclWithTypeSubs(ClassDecl cls, Type[string] typeSubs, string newName) {
        VarDecl[] fields;
        foreach (f; cls.fields) {
            auto field = new VarDecl(f.name, cloneType(f.type, typeSubs), null, f.isConst,
                f.line, f.column, f.bitWidth, f.isVolatile);
            fields ~= field;
        }
        FunctionDecl[] ctors;
        foreach (c; cls.constructors) ctors ~= cloneFunctionDeclWithTypeSubs(c, typeSubs, c.name);
        FunctionDecl dtor = cls.destructor is null ? null :
            cloneFunctionDeclWithTypeSubs(cls.destructor, typeSubs, cls.destructor.name);
        FunctionDecl[] methods;
        foreach (m; cls.methods) methods ~= cloneFunctionDeclWithTypeSubs(m, typeSubs, m.name);
        auto clone = new ClassDecl(newName, fields, ctors, dtor, methods, cls.line, cls.column);
        clone.namespaceSegments = [];
        return clone;
    }

    private StructDecl cloneStructDeclWithTypeSubs(StructDecl st, Type[string] typeSubs, string newName) {
        VarDecl[] fields;
        foreach (f; st.fields) {
            fields ~= new VarDecl(f.name, cloneType(f.type, typeSubs), null, f.isConst,
                f.line, f.column, f.bitWidth, f.isVolatile);
        }
        auto clone = new StructDecl(newName, fields, st.packed, st.line, st.column);
        clone.namespaceSegments = [];
        return clone;
    }

    private ASTNode unquoteValue(UnquoteExpr unquoteExpr, ASTNode[string] subs) {
        ASTNode value = cloneNode(unquoteExpr.expression, subs);
        if (auto quoteExpr = cast(QuoteExpr)value) {
            return cloneNode(quoteExpr.body, null);
        }
        return value;
    }

    private ASTNode[] expandQuotedNodes(ASTNode[] nodes, ASTNode[string] subs) {
        ASTNode[] result;
        foreach (n; nodes) {
            result ~= expandQuotedNode(n, subs);
        }
        return result;
    }

    private Block expandQuotedBlock(Block b, ASTNode[string] subs) {
        if (b is null) return null;
        return new Block(expandQuotedNodes(b.statements, subs));
    }

    // Deep-copies quoted syntax. Unlike cloneNode(), plain identifiers are
    // copied literally; only explicit unquote(...) nodes substitute macro
    // arguments. This is the key difference between old template-style LLPL
    // macros and Elixir-style quoted macros.
    private ASTNode expandQuotedNode(ASTNode node, ASTNode[string] subs) {
        if (node is null) return null;

        if (auto unquoteExpr = cast(UnquoteExpr)node) {
            return unquoteValue(unquoteExpr, subs);
        } else if (auto ident = cast(Identifier)node) {
            return new Identifier(ident.name, ident.line, ident.column);
        } else if (auto intLit = cast(IntLiteral)node) {
            return new IntLiteral(intLit.value, intLit.line, intLit.column);
        } else if (auto strLit = cast(StringLiteral)node) {
            return new StringLiteral(strLit.value, strLit.line, strLit.column);
        } else if (auto regexLit = cast(RegexLiteral)node) {
            return new RegexLiteral(regexLit.pattern, regexLit.line, regexLit.column);
        } else if (auto interp = cast(InterpolatedStringLiteral)node) {
            return new InterpolatedStringLiteral(interp.literalParts.dup,
                expandQuotedNodes(interp.expressions, subs), interp.specs.dup,
                interp.line, interp.column);
        } else if (auto arrLit = cast(ArrayLiteral)node) {
            return new ArrayLiteral(expandQuotedNodes(arrLit.elements, subs), arrLit.line, arrLit.column);
        } else if (auto boolLit = cast(BoolLiteral)node) {
            return new BoolLiteral(boolLit.value, boolLit.line, boolLit.column);
        } else if (cast(NullLiteral)node) {
            return new NullLiteral(node.line, node.column);
        } else if (auto binExpr = cast(BinaryExpr)node) {
            return new BinaryExpr(binExpr.op, expandQuotedNode(binExpr.left, subs),
                expandQuotedNode(binExpr.right, subs), binExpr.line, binExpr.column);
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            return new UnaryExpr(unaryExpr.op, expandQuotedNode(unaryExpr.operand, subs),
                unaryExpr.line, unaryExpr.column);
        } else if (auto callExpr = cast(CallExpr)node) {
            return new CallExpr(expandQuotedNode(callExpr.callee, subs),
                expandQuotedNodes(callExpr.args, subs), callExpr.line, callExpr.column, callExpr.argNames.dup);
        } else if (auto memberExpr = cast(MemberExpr)node) {
            return new MemberExpr(expandQuotedNode(memberExpr.object, subs), memberExpr.member,
                memberExpr.line, memberExpr.column);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            return new IndexExpr(expandQuotedNode(indexExpr.array, subs),
                expandQuotedNode(indexExpr.index, subs), indexExpr.line, indexExpr.column);
        } else if (auto newExpr = cast(NewExpr)node) {
            return new NewExpr(cloneType(newExpr.type), expandQuotedNodes(newExpr.args, subs),
                newExpr.line, newExpr.column, newExpr.argNames.dup);
        } else if (auto castExpr = cast(CastExpr)node) {
            return new CastExpr(cloneType(castExpr.type), expandQuotedNode(castExpr.expression, subs),
                castExpr.line, castExpr.column);
        } else if (auto varDecl = cast(VarDecl)node) {
            return new VarDecl(varDecl.name, cloneType(varDecl.type),
                expandQuotedNode(varDecl.initializer, subs), varDecl.isConst,
                varDecl.line, varDecl.column, varDecl.bitWidth, varDecl.isVolatile,
                varDecl.attributes.dup);
        } else if (auto ifStmt = cast(IfStmt)node) {
            return new IfStmt(expandQuotedNode(ifStmt.condition, subs),
                expandQuotedBlock(ifStmt.thenBlock, subs), expandQuotedBlock(ifStmt.elseBlock, subs));
        } else if (auto whileStmt = cast(WhileStmt)node) {
            return new WhileStmt(expandQuotedNode(whileStmt.condition, subs),
                expandQuotedBlock(whileStmt.body_, subs));
        } else if (auto forStmt = cast(ForStmt)node) {
            return new ForStmt(expandQuotedNode(forStmt.initializer, subs),
                expandQuotedNode(forStmt.condition, subs), expandQuotedNode(forStmt.update, subs),
                expandQuotedBlock(forStmt.body_, subs));
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            return new ForeachStmt(foreachStmt.varName, expandQuotedNode(foreachStmt.iterable, subs),
                expandQuotedBlock(foreachStmt.body_, subs), foreachStmt.line, foreachStmt.column);
        } else if (auto rangeExpr = cast(RangeExpr)node) {
            return new RangeExpr(expandQuotedNode(rangeExpr.start, subs), expandQuotedNode(rangeExpr.end, subs),
                rangeExpr.line, rangeExpr.column);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(expandQuotedNode(returnStmt.value, subs));
        } else if (auto deferStmt = cast(DeferStmt)node) {
            return new DeferStmt(expandQuotedNode(deferStmt.statement, subs));
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            return new ThrowStmt(expandQuotedNode(throwStmt.value, subs),
                throwStmt.line, throwStmt.column);
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            return new DeleteStmt(expandQuotedNode(deleteStmt.value, subs),
                deleteStmt.line, deleteStmt.column);
        } else if (auto tryStmt = cast(TryStmt)node) {
            return new TryStmt(expandQuotedBlock(tryStmt.tryBlock, subs), tryStmt.catchVar,
                cloneType(tryStmt.catchType), expandQuotedBlock(tryStmt.catchBlock, subs),
                expandQuotedBlock(tryStmt.finallyBlock, subs), tryStmt.line, tryStmt.column);
        } else if (auto block = cast(Block)node) {
            return expandQuotedBlock(block, subs);
        } else if (auto exprStmt = cast(ExprStmt)node) {
            return new ExprStmt(expandQuotedNode(exprStmt.expression, subs));
        } else if (auto asmStmt = cast(AsmStmt)node) {
            AsmOperand[] cloneOperands(AsmOperand[] ops) {
                AsmOperand[] result;
                foreach (op; ops) {
                    result ~= new AsmOperand(op.constraint, expandQuotedNode(op.expr, subs));
                }
                return result;
            }
            return new AsmStmt(asmStmt.templateLines.dup, cloneOperands(asmStmt.outputs),
                cloneOperands(asmStmt.inputs), asmStmt.clobbers.dup, asmStmt.line, asmStmt.column);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            MatchCase[] cases;
            foreach (c; matchStmt.cases) {
                cases ~= new MatchCase(expandQuotedNodes(c.patterns, subs), expandQuotedBlock(c.body_, subs));
            }
            return new MatchStmt(expandQuotedNode(matchStmt.subject, subs), cases,
                matchStmt.line, matchStmt.column);
        } else if (auto patternExpr = cast(PatternExpr)node) {
            return new PatternExpr(clonePattern(patternExpr.pattern, subs),
                patternExpr.line, patternExpr.column);
        } else if (auto macroInvocation = cast(MacroInvocation)node) {
            return new MacroInvocation(macroInvocation.name, expandQuotedNodes(macroInvocation.args, subs),
                macroInvocation.line, macroInvocation.column);
        } else if (auto quoteExpr = cast(QuoteExpr)node) {
            return new QuoteExpr(cloneNode(quoteExpr.body, null), quoteExpr.isBlock,
                quoteExpr.line, quoteExpr.column);
        }

        throw new CompileError("Internal error: this construct can't appear inside quoted macro syntax",
            currentModulePath, node.line, node.column);
    }

    private enum maxMacroExpansionDepth = 64;

    private MacroDecl resolveMacroInvocation(MacroInvocation inv) {
        string mangledName = resolveName(inv.name, (n) => (n in macroRegistry) !is null);
        auto declPtr = mangledName in macroRegistry;
        if (declPtr is null) {
            throw new CompileError(format("Unknown macro '%s'", inv.name),
                currentModulePath, inv.line, inv.column);
        }
        MacroDecl decl = *declPtr;
        recordUsage(mangledName, inv.line, inv.column);

        if (inv.args.length != decl.params.length) {
            throw new CompileError(
                format("Macro '%s' expects %d argument(s), got %d",
                    decl.name, decl.params.length, inv.args.length),
                currentModulePath, inv.line, inv.column);
        }

        if (macroExpansionDepth >= maxMacroExpansionDepth) {
            throw new CompileError(
                format("Macro '%s' exceeded the maximum expansion depth (%d) - " ~
                    "check for (possibly indirect) self-recursion", decl.name, maxMacroExpansionDepth),
                currentModulePath, inv.line, inv.column);
        }

        return decl;
    }

    private ASTNode[string] macroSubstitutions(MacroDecl decl, MacroInvocation inv) {
        ASTNode[string] subs;
        foreach (i, param; decl.params) {
            subs[param] = inv.args[i];
        }
        return subs;
    }

    private QuoteExpr macroQuoteBody(MacroDecl decl) {
        if (decl.body_.statements.length != 1) return null;
        ASTNode stmt = decl.body_.statements[0];
        if (auto quoteExpr = cast(QuoteExpr)stmt) return quoteExpr;
        if (auto exprStmt = cast(ExprStmt)stmt) {
            return cast(QuoteExpr)exprStmt.expression;
        }
        if (auto returnStmt = cast(ReturnStmt)stmt) {
            return cast(QuoteExpr)returnStmt.value;
        }
        return null;
    }

    // Expands `inv` inline: substitutes each parameter with the argument it
    // was called with, splices the resulting statements into a fresh `{ }`
    // block (so repeated/nested expansions never collide over locals the
    // macro body declares), and generates code for them in place.
    private string generateMacroExpansion(MacroInvocation inv, bool isDeferred) {
        MacroDecl decl = resolveMacroInvocation(inv);
        ASTNode[string] subs = macroSubstitutions(decl, inv);
        QuoteExpr quoteExpr = macroQuoteBody(decl);

        Block expanded;
        if (quoteExpr !is null) {
            if (!quoteExpr.isBlock) {
                throw new CompileError(
                    format("Macro '%s' expands to an expression, but was used as a statement", decl.name),
                    currentModulePath, inv.line, inv.column);
            }
            expanded = cast(Block)expandQuotedNode(quoteExpr.body, subs);
        } else {
            expanded = cloneBlock(decl.body_, subs);
        }

        macroExpansionDepth++;
        string code = indent() ~ "{\n";
        indentLevel++;
        foreach (stmt; expanded.statements) {
            code ~= generateStatement(stmt, isDeferred);
        }
        indentLevel--;
        code ~= indent() ~ "}\n";
        macroExpansionDepth--;

        return code;
    }

    private string generateMacroExpression(MacroInvocation inv) {
        MacroDecl decl = resolveMacroInvocation(inv);
        QuoteExpr quoteExpr = macroQuoteBody(decl);
        if (quoteExpr is null || quoteExpr.isBlock) {
            throw new CompileError(
                format("Macro '%s' does not expand to an expression", decl.name),
                currentModulePath, inv.line, inv.column);
        }

        macroExpansionDepth++;
        ASTNode expanded = expandQuotedNode(quoteExpr.body, macroSubstitutions(decl, inv));
        string code = generateExpression(expanded);
        macroExpansionDepth--;
        return code;
    }

    private string generateAsm(AsmStmt asmStmt) {
        bool hasClobbers = asmStmt.clobbers.length > 0;
        bool hasInputs = asmStmt.inputs.length > 0 || hasClobbers;
        bool hasOutputs = asmStmt.outputs.length > 0 || hasInputs;

        string code = indent() ~ "__asm__ __volatile__ (\n";
        indentLevel++;

        foreach (line; asmStmt.templateLines) {
            code ~= indent() ~ format("\"%s\\n\\t\"\n", escapeCString(line));
        }

        string renderOperands(AsmOperand[] operands) {
            string result = "";
            foreach (i, op; operands) {
                if (i > 0) result ~= ", ";
                result ~= format("\"%s\"(%s)", op.constraint, generateExpression(op.expr));
            }
            return result;
        }

        if (hasOutputs) {
            code ~= indent() ~ ": " ~ renderOperands(asmStmt.outputs) ~ "\n";
        }
        if (hasInputs) {
            code ~= indent() ~ ": " ~ renderOperands(asmStmt.inputs) ~ "\n";
        }
        if (hasClobbers) {
            string clobberList = "";
            foreach (i, c; asmStmt.clobbers) {
                if (i > 0) clobberList ~= ", ";
                clobberList ~= format("\"%s\"", c);
            }
            code ~= indent() ~ ": " ~ clobberList ~ "\n";
        }

        indentLevel--;
        code ~= indent() ~ ");\n";
        return code;
    }

    // Desugars to an if/else-if chain over a temp holding the subject's
    // value, evaluated once. String subjects (char*) compare with strcmp;
    // everything else compares with ==. There's no fallthrough between arms,
    // unlike a C switch.
    private string generateMatch(MatchStmt matchStmt, bool isDeferred) {
        Type subjectType = inferType(matchStmt.subject);
        resolveType(subjectType);
        bool isString = subjectType.isPointer && subjectType.name == "char";

        tempVarCounter++;
        string tmpName = format("__match%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s;\n",
            typeToC(subjectType), tmpName, generateExpression(matchStmt.subject));
        variableTypes[tmpName] = subjectType;

        bool first = true;
        Block defaultBody = null;

        foreach (matchCase; matchStmt.cases) {
            if (matchCase.patterns.length == 0) {
                defaultBody = matchCase.body_;
                continue;
            }

            // A single pattern shaped like a call whose callee is a known
            // tagged-enum variant constructor - e.g. `case Shape.Circle(r)`
            // - destructures instead of comparing by equality (comparing a
            // constructed value by `==` wouldn't compile anyway; C has no
            // whole-struct `==`). Multiple comma-separated patterns never
            // trigger this - each variant can have different fields, so
            // there'd be no single set of bindings to give the shared body.
            VariantInfo* variant = null;
            CallExpr variantCall = null;
            if (matchCase.patterns.length == 1) {
                if (auto callExpr = cast(CallExpr)matchCase.patterns[0]) {
                    if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                        string qualifiedName =
                            tryResolveQualifiedPath(memberCallee, (n) => (n in functionRegistry) !is null);
                        if (qualifiedName.length > 0) {
                            if (auto found = qualifiedName in variantRegistry) {
                                variant = found;
                                variantCall = callExpr;
                            }
                        }
                    }
                }
            }

            if (variant !is null) {
                if (variant.enumName != subjectType.name) {
                    throw new CompileError(
                        format("This pattern is for enum '%s', but the match subject has type '%s'",
                            variant.enumName, subjectType.name),
                        currentModulePath, matchCase.patterns[0].line, matchCase.patterns[0].column);
                }
                if (variantCall.args.length != variant.fields.length) {
                    throw new CompileError(
                        format("'%s' has %d field(s), but this pattern binds %d",
                            variant.variantName, variant.fields.length, variantCall.args.length),
                        currentModulePath, matchCase.patterns[0].line, matchCase.patterns[0].column);
                }

                code ~= indent() ~ format("%s (%s.tag == %d) {\n", first ? "if" : "} else if",
                    tmpName, variant.tag);
                first = false;
                indentLevel++;

                string[] boundNames;
                foreach (i, arg; variantCall.args) {
                    auto bindIdent = cast(Identifier)arg;
                    if (bindIdent is null) {
                        throw new CompileError(
                            "Tagged-enum patterns can only bind a plain name per field - " ~
                            "no literals or nested expressions",
                            currentModulePath, arg.line, arg.column);
                    }
                    string fieldName = format("%s_%s", variant.variantName, variant.fields[i].name);
                    variableTypes[bindIdent.name] = variant.fields[i].type;
                    boundNames ~= bindIdent.name;
                    code ~= indent() ~ format("%s %s = %s.%s;\n",
                        typeToC(variant.fields[i].type), bindIdent.name, tmpName, fieldName);
                }

                foreach (stmt; matchCase.body_.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }

                // Bindings are only valid inside this arm's own body - see
                // generateConstructor's matching comment on why leaking a
                // bare name into variableTypes indefinitely is a real bug,
                // not just tidiness.
                foreach (boundName; boundNames) {
                    variableTypes.remove(boundName);
                }

                indentLevel--;
                continue;
            }

            PatternExpr destructurePattern = null;
            if (matchCase.patterns.length == 1) {
                destructurePattern = cast(PatternExpr)matchCase.patterns[0];
            }

            if (destructurePattern !is null) {
                if (matchCase.patterns.length > 1) {
                    throw new CompileError(
                        "Destructuring patterns cannot share an arm with other patterns",
                        currentModulePath, matchCase.patterns[0].line, matchCase.patterns[0].column);
                }

                code ~= indent() ~ format("%s (1) {\n", first ? "if" : "} else if");
                first = false;
                indentLevel++;

                Pattern pattern = destructurePattern.pattern;
                if (auto structPat = cast(StructPattern)pattern) {
                    inferPatternTypeFromSubject(structPat.type, subjectType);
                }

                string[] boundNames = patternBindingNames(pattern);
                Type[string] savedTypes;
                bool[string] savedConst;
                saveBindings(boundNames, savedTypes, savedConst);

                auto tmpIdent = new Identifier(tmpName, matchCase.patterns[0].line, matchCase.patterns[0].column);
                code ~= generatePatternBindings(pattern, tmpIdent, false, false);

                foreach (stmt; matchCase.body_.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }

                restoreBindings(boundNames, savedTypes, savedConst);

                indentLevel--;
                continue;
            }

            string cond = "";
            foreach (i, pattern; matchCase.patterns) {
                if (i > 0) cond ~= " || ";
                string patternExpr = generateExpression(pattern);
                cond ~= isString
                    ? format("(strcmp(%s, %s) == 0)", tmpName, patternExpr)
                    : format("(%s == %s)", tmpName, patternExpr);
            }

            code ~= indent() ~ format("%s (%s) {\n", first ? "if" : "} else if", cond);
            first = false;
            indentLevel++;
            foreach (stmt; matchCase.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
        }

        if (!first) {
            if (defaultBody) {
                code ~= indent() ~ "} else {\n";
                indentLevel++;
                foreach (stmt; defaultBody.statements) {
                    code ~= generateStatement(stmt, isDeferred);
                }
                indentLevel--;
            }
            code ~= indent() ~ "}\n";
        } else if (defaultBody) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (stmt; defaultBody.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        }

        indentLevel--;
        code ~= indent() ~ "}\n";
        variableTypes.remove(tmpName);
        return code;
    }

    // --- Namespace-qualified name resolution --------------------------------
    //
    // A reference like `Graphics.Utils.helper()` parses as nested MemberExprs
    // rooted at an Identifier, exactly like `obj.method()` instance access.
    // These helpers flatten such a chain into its mangled form so it can be
    // checked against the function/global registries and resolved as a plain
    // call/variable reference instead of instance member access, whenever the
    // root isn't a real local/instance variable.

    private string leftmostName(ASTNode expr) {
        if (auto ident = cast(Identifier)expr) return ident.name;
        if (auto member = cast(MemberExpr)expr) return leftmostName(member.object);
        return "";
    }

    private string flattenPath(ASTNode expr) {
        if (auto ident = cast(Identifier)expr) return ident.name;
        if (auto member = cast(MemberExpr)expr) {
            string base = flattenPath(member.object);
            if (base.length == 0) return "";
            return base ~ "_" ~ member.member;
        }
        return "";
    }

    // Tries each enclosing namespace scope, innermost first (Graphics.Utils,
    // then Graphics, then global), the way unqualified/partially-qualified
    // lookup works inside nested namespaces.
    private string[] enclosingQualifications(string suffix) {
        string[] candidates;
        for (size_t i = currentNamespaceSegments.length; i > 0; i--) {
            candidates ~= currentNamespaceSegments[0 .. i].join("_") ~ "_" ~ suffix;
        }
        return candidates;
    }

    private bool isPrimitiveTypeName(string name) {
        switch (name) {
            case "int": case "uint":
            case "int16": case "uint16":
            case "int32": case "uint32":
            case "char": case "bool": case "void": case "string":
                return true;
            default:
                return false;
        }
    }

    // Number of storage bits available for a bit-field of this base type, or
    // -1 if the type can't back a bit-field at all (classes, void, ...).
    private int primitiveBitSize(string name) {
        switch (name) {
            case "int": case "uint": return 64;
            case "int32": case "uint32": return 32;
            case "int16": case "uint16": return 16;
            case "char": return 8;
            case "bool": return 32; // backed by C `int`
            default: return -1;
        }
    }

    private void checkBitfield(VarDecl field) {
        auto err = (string message) =>
            new CompileError(message, currentModulePath, field.line, field.column);

        if (field.type.isPointer || field.type.isArray) {
            throw err(format("Bit-field '%s' cannot be a pointer or array type", field.name));
        }

        int maxBits = primitiveBitSize(field.type.name);
        if (maxBits < 0) {
            throw err(format("Bit-field '%s' must have an integer or bool type, not '%s'",
                field.name, field.type.name));
        }
        if (field.bitWidth == 0) {
            throw err(format("Bit-field '%s' must have a width of at least 1", field.name));
        }
        if (field.bitWidth > maxBits) {
            throw err(format("Bit-field '%s' width %d exceeds the %d bits available in '%s'",
                field.name, field.bitWidth, maxBits, field.type.name));
        }
    }

    // If `node` is a bare Identifier naming an `alias NAME = [ ... ]`
    // array literal (see ArrayAliasDecl), returns the equivalent
    // ArrayLiteral - recursively, so an alias can reference another alias.
    // Returns null for anything else (the ordinary case), including a
    // real variable that merely happens to hold an array value.
    private ArrayLiteral tryExpandArrayAlias(ASTNode node) {
        auto ident = cast(Identifier)node;
        if (ident is null) return null;
        auto elements = ident.name in arrayLiteralAliases;
        if (elements is null) return null;
        return new ArrayLiteral(expandArrayAliasElements(*elements), node.line, node.column);
    }

    // Splices any element that's itself a bare alias reference into the
    // result in place - `alias common = [a, b]` used inside `[common, c,
    // d]` yields `[a, b, c, d]`, not a nested array. Elements that aren't
    // alias references pass through unchanged.
    private ASTNode[] expandArrayAliasElements(ASTNode[] elements) {
        ASTNode[] result;
        foreach (elem; elements) {
            if (auto spliced = tryExpandArrayAlias(elem)) {
                result ~= spliced.elements;
            } else {
                result ~= elem;
            }
        }
        return result;
    }

    // Expands `node` if it's directly an alias reference (a whole
    // array-typed initializer that's just the alias's name), or splices
    // alias elements into it if it's already an ArrayLiteral containing
    // one or more as elements - one shallow pass, not a deep tree walk;
    // sufficient everywhere an alias is actually meant to be used (a
    // var/field's whole initializer, or one element of a literal array).
    private ASTNode expandArrayAliasesShallow(ASTNode node) {
        if (auto expanded = tryExpandArrayAlias(node)) return expanded;
        if (auto lit = cast(ArrayLiteral)node) {
            lit.elements = expandArrayAliasElements(lit.elements);
        }
        return node;
    }

    // Fills in `varDecl.type.arraySize` from an array-literal initializer
    // when none was given (`let arr: char[] = [1, 2, 3]`), or checks it
    // matches when one was (`let arr: char[8] = [...]` needs exactly 8
    // elements) - called for both local (generateStatement) and global
    // (generateGlobalVar) `let`/`const` declarations. A no-op unless the
    // initializer is actually an ArrayLiteral (including one just
    // expanded from a whole-array alias reference here).
    private void checkArrayLiteralInit(VarDecl varDecl) {
        if (varDecl.initializer !is null) {
            varDecl.initializer = expandArrayAliasesShallow(varDecl.initializer);
        }
        auto lit = cast(ArrayLiteral)varDecl.initializer;
        if (lit is null) return;

        if (!varDecl.type.isArray) {
            throw new CompileError(
                format("Cannot assign an array literal to '%s': declared type is '%s', not an array",
                    varDecl.name, varDecl.type.toString()),
                currentModulePath, varDecl.initializer.line, varDecl.initializer.column);
        }
        if (varDecl.type.arraySize == 0) {
            varDecl.type.arraySize = cast(int)lit.elements.length;
        } else if (varDecl.type.arraySize != lit.elements.length) {
            throw new CompileError(
                format("Array literal has %d element(s), but '%s' is declared as %s[%d]",
                    lit.elements.length, varDecl.name, varDecl.type.name, varDecl.type.arraySize),
                currentModulePath, varDecl.initializer.line, varDecl.initializer.column);
        }
    }

    // Structs are plain value types with no constructor/allocator; `new`
    // only makes sense for classes.
    private void checkNotStruct(NewExpr newExpr) {
        if (newExpr.type.name in structRegistry) {
            string message = format(
                "Cannot 'new' a struct: '%s' is a value type - declare a variable of that type " ~
                "and assign its fields directly",
                newExpr.type.name);
            throw new CompileError(message, currentModulePath, newExpr.line, newExpr.column);
        }
    }

    // Rejects `x = ...` when `x` (a plain or namespace-qualified variable
    // reference) was declared `const`. Only the variable being assigned is
    // checked - field/index assignment through it (x.field = ...) is fine,
    // since that mutates something the const variable merely points to.
    private void checkNotConstAssignment(ASTNode target) {
        string varName = "";
        if (auto ident = cast(Identifier)target) {
            varName = resolveName(ident.name, (n) => (n in variableTypes) !is null);
        } else if (auto member = cast(MemberExpr)target) {
            varName = tryResolveQualifiedPath(member, (n) => (n in variableTypes) !is null);
        }

        if (varName.length > 0 && (varName in constVariables)) {
            throw new CompileError(
                format("Cannot assign to '%s': it was declared 'const'", varName),
                currentModulePath, target.line, target.column);
        }
    }

    // Rejects a `private` field/method access from outside its declaring
    // class - `currentClassName` (set for the entire span of generateClass,
    // covering every constructor/destructor/method body belonging to that
    // class) is compared against the *member's own* declaring class, not
    // whether the receiver expression is literally `self`: `private`
    // is scoped to the class as a whole, so one of Foo's own methods
    // accessing `other.field` on a *different* Foo instance is exactly as
    // allowed as `self.field` is, matching every mainstream language's
    // access-control model (class-scoped, not instance-scoped).
    private void checkMemberAccess(bool isPrivate, string ownerClassName, string memberDescription,
            int line, int column) {
        if (isPrivate && currentClassName != ownerClassName) {
            throw new CompileError(
                format("%s is private - only accessible from within '%s'", memberDescription, ownerClassName),
                currentModulePath, line, column);
        }
    }

    // Resolves a struct literal's actual StructDecl + mangled name. `expectedType`
    // is the as-written (NOT YET resolveType-mutated) declared type at the
    // let/return site this literal is being used to initialize, if any -
    // see generateStatement's VarDecl case and the ReturnStmt handling for
    // where it's captured (a plain cloneType() *before* resolveType runs,
    // since resolveType mutates its argument in place and this needs the
    // original, unmangled name/typeArgs to compare against). It's the only
    // way a literal naming a *generic* struct template ever gets concrete
    // type arguments, since struct literals never write `<...>` themselves
    // (ast.StructLiteral's doc comment) - the same "context supplies T"
    // relationship generateNullableWrap's Optional<T> already relies on.
    private StructDecl resolveStructLiteralTarget(StructLiteral lit, Type expectedType, out string mangledName) {
        string aliased = resolveLocalImportAlias(lit.typeName);
        if (aliased.length > 0) {
            lit.typeName = aliased;
        }

        if (lit.typeName in structRegistry) {
            mangledName = lit.typeName;
            return structRegistry[mangledName];
        }
        if (lit.typeName in classRegistry) {
            throw new CompileError(format(
                "'%s' is a class, not a struct - use 'new %s(...)' instead of a struct literal",
                lit.typeName, lit.typeName), currentModulePath, lit.line, lit.column);
        }

        string templateKey = findGenericTemplateKey(lit.typeName, (k) => (k in genericStructTemplates) !is null);
        if (templateKey.length == 0) {
            if (findGenericTemplateKey(lit.typeName, (k) => (k in genericClassTemplates) !is null).length > 0) {
                throw new CompileError(format(
                    "'%s' is a generic class, not a struct - use 'new %s<...>(...)' instead of a struct literal",
                    lit.typeName, lit.typeName), currentModulePath, lit.line, lit.column);
            }
            throw new CompileError(format("Unknown struct type '%s'", lit.typeName),
                currentModulePath, lit.line, lit.column);
        }

        Type[] typeArgsToUse;
        bool haveTypeArgs = false;
        if (expectedType !is null && expectedType.name == lit.typeName && expectedType.typeArgs.length > 0) {
            // The common case: expectedType is still the pristine,
            // as-written form (e.g. `Slice<int>`), not yet mutated by
            // resolveType.
            typeArgsToUse = expectedType.typeArgs;
            haveTypeArgs = true;
        } else if (expectedType !is null) {
            // expectedType may already be a *resolved* instantiation of
            // this same template - e.g. a field's declared type
            // (`self.data: Slice<int>`), already mangled to "Slice_int" by
            // an ordinary field-type-resolution pass long before this
            // particular assignment/return/let ever runs (unlike a fresh
            // `let`, whose Type object is a brand new clone that hasn't
            // been resolved yet). Recover the original type args via the
            // reverse mapping instantiateGenericTypeArgs records, instead
            // of rejecting this as "no known concrete type" just because
            // .typeArgs is now empty - confirmed by re-deriving the same
            // mangled name from those recovered args and checking it
            // actually matches (not just some other generic type that
            // coincidentally shares this exact mangled name).
            StructDecl templ = genericStructTemplates[templateKey];
            if (auto recorded = expectedType.name in monomorphizedTypeArgs) {
                string reMangled = mangled(templ.namespaceSegments, instantiatedLeafName(templ.name, *recorded));
                if (reMangled == expectedType.name) {
                    typeArgsToUse = *recorded;
                    haveTypeArgs = true;
                }
            }
        }

        if (!haveTypeArgs) {
            throw new CompileError(format(
                "Cannot construct generic struct '%s' without a known concrete type - " ~
                "assign it to a 'let'/return with an explicit type annotation " ~
                "(e.g. 'let x: %s<...> = %s { ... }')", lit.typeName, lit.typeName, lit.typeName),
                currentModulePath, lit.line, lit.column);
        }

        Type instantiation = new Type(lit.typeName);
        instantiation.typeArgs = typeArgsToUse;
        resolveType(instantiation); // monomorphizes on demand, rewrites .name in place
        mangledName = instantiation.name;
        return structRegistry[mangledName];
    }

    private string generateStructLiteralValue(StructLiteral lit, Type expectedType) {
        string mangledName;
        StructDecl decl = resolveStructLiteralTarget(lit, expectedType, mangledName);

        if (lit.fieldNames.length != decl.fields.length) {
            throw new CompileError(format(
                "Struct literal for '%s' has %d field(s), but '%s' declares %d",
                lit.typeName, lit.fieldNames.length, mangledName, decl.fields.length),
                currentModulePath, lit.line, lit.column);
        }

        string result = format("(%s){ ", mangledName);
        bool[string] seen;
        foreach (i, fieldName; lit.fieldNames) {
            if (fieldName in seen) {
                throw new CompileError(format("Field '%s' given more than once in this '%s' literal",
                    fieldName, lit.typeName), currentModulePath, lit.line, lit.column);
            }
            seen[fieldName] = true;

            bool found = false;
            foreach (field; decl.fields) {
                if (field.name == fieldName) { found = true; break; }
            }
            if (!found) {
                throw new CompileError(format("'%s' has no field named '%s'", mangledName, fieldName),
                    currentModulePath, lit.line, lit.column);
            }

            if (i > 0) result ~= ", ";
            lit.fieldValues[i] = expandArrayAliasesShallow(lit.fieldValues[i]);
            result ~= format(".%s = %s", fieldName, generateExpression(lit.fieldValues[i]));
        }
        result ~= " }";
        return result;
    }

    private string generateTupleLiteral(TupleLiteral lit, Type expectedType) {
        Type tupleType;
        if (expectedType !is null) {
            tupleType = cloneType(expectedType);
        } else {
            Type[] elemTypes;
            foreach (e; lit.elements) {
                elemTypes ~= inferType(e);
            }
            tupleType = makeTupleType(elemTypes, lit.line, lit.column);
        }

        Type asWritten = cloneType(tupleType);
        resolveType(tupleType);

        if (tupleType.name !in structRegistry) {
            throw new CompileError(format("Unknown tuple type '%s'", asWritten.toString()),
                currentModulePath, lit.line, lit.column);
        }
        StructDecl decl = structRegistry[tupleType.name];
        if (lit.elements.length != decl.fields.length) {
            throw new CompileError(format(
                "Tuple literal has %d element(s), but %s has %d field(s)",
                lit.elements.length, asWritten.toString(), decl.fields.length),
                currentModulePath, lit.line, lit.column);
        }

        string result = format("(%s){ ", tupleType.name);
        foreach (i, e; lit.elements) {
            if (i > 0) result ~= ", ";
            result ~= format(".%s = %s", tupleFieldName(i), generateExpression(e));
        }
        result ~= " }";
        return result;
    }

    private string generateDestructuringStmt(DestructuringStmt stmt) {
        Type rhsType;
        if (stmt.type !is null) {
            rhsType = cloneType(stmt.type);
        } else {
            rhsType = inferType(stmt.initializer);
        }

        string tmp = format("__llpl_destruct_%d", tempVarCounter++);
        auto tmpDecl = new VarDecl(tmp, rhsType, stmt.initializer, false, stmt.line, stmt.column);
        string code = generateStatement(tmpDecl, false);

        auto tmpIdent = new Identifier(tmp, stmt.line, stmt.column);
        code ~= generatePatternBindings(stmt.pattern, tmpIdent, stmt.isConst, stmt.isVolatile);
        return code;
    }

    private string generatePatternBindings(Pattern pattern, ASTNode sourceExpr,
                                           bool isConst, bool isVolatile) {
        string code = "";
        if (cast(WildcardPattern)pattern) {
            // Nothing to bind.
        } else if (auto bind = cast(BindingPattern)pattern) {
            auto vd = new VarDecl(bind.name, null, sourceExpr, isConst, bind.line, bind.column);
            vd.isVolatile = isVolatile;
            code ~= generateStatement(vd, false);
        } else if (auto tuplePat = cast(TuplePattern)pattern) {
            Type sourceType = inferType(sourceExpr);
            Type resolved = cloneType(sourceType);
            resolveType(resolved);
            if (resolved.name !in structRegistry) {
                throw new CompileError(format("Cannot destructure a non-tuple value of type '%s'",
                    sourceType.toString()), currentModulePath, tuplePat.line, tuplePat.column);
            }
            StructDecl decl = structRegistry[resolved.name];
            if (tuplePat.elements.length != decl.fields.length) {
                throw new CompileError(format(
                    "Tuple pattern has %d element(s), but value of type '%s' has %d",
                    tuplePat.elements.length, sourceType.toString(), decl.fields.length),
                    currentModulePath, tuplePat.line, tuplePat.column);
            }
            foreach (i, elemPat; tuplePat.elements) {
                auto member = new MemberExpr(sourceExpr, tupleFieldName(i),
                    elemPat.line, elemPat.column);
                code ~= generatePatternBindings(elemPat, member, isConst, isVolatile);
            }
        } else if (auto structPat = cast(StructPattern)pattern) {
            Type sourceType = inferType(sourceExpr);
            Type resolvedSource = cloneType(sourceType);
            resolveType(resolvedSource);

            Type resolvedPattern = cloneType(structPat.type);
            if (structPat.type.typeArgs.length > 0) {
                resolveType(resolvedPattern);
            }

            // A plain struct pattern must name the same type as the source;
            // a generic pattern like `Result { ... }` matches any instantiation
            // of that generic class/struct.
            bool nameMatches = (resolvedSource.name == structPat.type.name) ||
                (resolvedSource.name.length > structPat.type.name.length + 1 &&
                 resolvedSource.name[0 .. structPat.type.name.length + 1] ==
                    structPat.type.name ~ "_");
            if (!nameMatches) {
                throw new CompileError(format(
                    "Struct pattern '%s' does not match value of type '%s'",
                    structPat.type.toString(), sourceType.toString()),
                    currentModulePath, structPat.line, structPat.column);
            }

            bool isClass = (resolvedSource.name in classRegistry) !is null;
            bool isStruct = (resolvedSource.name in structRegistry) !is null;
            if (!isClass && !isStruct) {
                throw new CompileError(format("Cannot destructure value of type '%s'",
                    sourceType.toString()), currentModulePath, structPat.line, structPat.column);
            }

            foreach (fieldName; structPat.fieldNames) {
                auto member = new MemberExpr(sourceExpr, fieldName,
                    structPat.line, structPat.column);
                // Validate the field exists by inferring its type.
                try {
                    inferType(member);
                } catch (Exception e) {
                    throw new CompileError(format("'%s' has no field named '%s'",
                        structPat.type.toString(), fieldName),
                        currentModulePath, structPat.line, structPat.column);
                }
                auto vd = new VarDecl(fieldName, null, member, isConst,
                    structPat.line, structPat.column);
                vd.isVolatile = isVolatile;
                code ~= generateStatement(vd, false);
            }
        }
        return code;
    }

    private string[] patternBindingNames(Pattern pattern) {
        string[] names;
        if (cast(WildcardPattern)pattern) {
            // no names
        } else if (auto bind = cast(BindingPattern)pattern) {
            names ~= bind.name;
        } else if (auto tuplePat = cast(TuplePattern)pattern) {
            foreach (p; tuplePat.elements) {
                names ~= patternBindingNames(p);
            }
        } else if (auto structPat = cast(StructPattern)pattern) {
            foreach (fieldName; structPat.fieldNames) {
                names ~= fieldName;
            }
        }
        return names;
    }

    private void saveBindings(string[] names, out Type[string] savedTypes,
                              out bool[string] savedConst) {
        foreach (name; names) {
            if (auto t = name in variableTypes) savedTypes[name] = *t;
            if (auto c = name in constVariables) savedConst[name] = *c;
        }
    }

    private void restoreBindings(string[] names, Type[string] savedTypes,
                                 bool[string] savedConst) {
        foreach (name; names) {
            if (auto t = name in savedTypes) variableTypes[name] = *t;
            else variableTypes.remove(name);
            if (auto c = name in savedConst) constVariables[name] = *c;
            else constVariables.remove(name);
        }
    }

    private void inferPatternTypeFromSubject(Type patternType, Type subjectType) {
        if (patternType.typeArgs.length > 0) return; // already explicit
        if (patternType.name != subjectType.name) return;
        patternType.typeArgs = subjectType.typeArgs.map!(a => cloneType(a)).array;
    }

    // Mirrors resolveName's shape but returns "" (not the original name) on
    // failure, since callers here need to distinguish "this is a generic
    // template" from "this name doesn't exist at all".
    private string findGenericTemplateKey(string name, bool delegate(string) exists) {
        if (exists(name)) return name;
        foreach (candidate; enclosingQualifications(name)) {
            if (exists(candidate)) return candidate;
        }
        return "";
    }

    // Validates one `impl TraitName for TargetType { ... }` block and, if
    // valid, desugars each of its methods into an ordinary top-level
    // function (`TargetType_methodName`, with an explicit `self` parameter
    // prepended) - see ast.ImplDecl's doc comment. Called once per
    // `pendingImpls` entry, after classRegistry/structRegistry are already
    // populated (so a user-defined target type resolves correctly) but
    // before anything that could trigger generic monomorphization (so a
    // trait bound check never runs before traitImplemented is populated).
    private void processImplBlock(ImplDecl impl) {
        // Captured *before* resolveType - resolveType monomorphizes a generic
        // instantiation in place and clears its typeArgs (see resolveType's
        // own comment), so checking .typeArgs after that call would always
        // see an empty array regardless of what the user actually wrote.
        bool targetWasGeneric = impl.targetType.typeArgs.length > 0;
        string targetDisplayName = impl.targetType.toString();
        resolveType(impl.targetType);
        if (targetWasGeneric) {
            throw new CompileError(
                format("'impl %s for %s' isn't supported - impl targets must be a concrete " ~
                    "primitive, class, or struct, not a generic type", impl.traitName, targetDisplayName),
                currentModulePath, impl.line, impl.column);
        }

        string traitKey = findGenericTemplateKey(impl.traitName, (k) => (k in traitRegistry) !is null);
        if (traitKey.length == 0) {
            throw new CompileError(format("Unknown trait '%s'", impl.traitName),
                currentModulePath, impl.line, impl.column);
        }
        TraitDecl trait = traitRegistry[traitKey];

        foreach (required; trait.methods) {
            bool found = false;
            foreach (m; impl.methods) {
                // Arity too, not just name - if this impl block ever wrote
                // more than one same-named method (overloading isn't
                // meant to extend to impls, but nothing else stops it
                // syntactically), a name-only match could wrongly "satisfy"
                // the trait via the wrong overload.
                if (m.name == required.name && m.params.length == required.params.length) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw new CompileError(
                    format("'impl %s for %s' is missing required method '%s'",
                        impl.traitName, impl.targetType.name, required.name),
                    currentModulePath, impl.line, impl.column);
            }
        }

        // Keyed by mangleTypeArg, not the bare .name - a pointer type (e.g.
        // char*) and its pointee (char) must not collide on the same key,
        // and mangleTypeArg already exists precisely to make that distinction
        // (see its own doc comment).
        string targetKey = mangleTypeArg(impl.targetType);
        traitImplemented[traitKey ~ ":" ~ targetKey] = true;

        // A plain (non-generic) class/struct target's own typedef is only
        // emitted later, in earlyDeclCode - which always lands *after*
        // genericForwardDecls in the final output (see generateMultiple's
        // splice-order comment). Since this method's forward declaration
        // goes into genericForwardDecls too, re-emit an idempotent duplicate
        // typedef right before it so `TargetType` already names a type by
        // then (identical repeated typedefs are legal in C11). Not needed
        // for primitives (already a built-in C type name) or generic
        // instantiations (their own typedef is already emitted the same way
        // by instantiateGenericTypeArgs).
        bool targetNeedsTypedef = (impl.targetType.name in classRegistry) !is null ||
            (impl.targetType.name in structRegistry) !is null;

        foreach (method; impl.methods) {
            Type[string] typeSubs;
            typeSubs["Self"] = impl.targetType;
            string mangledName = format("%s_%s", targetKey, method.name);
            auto substituted = cloneFunctionDeclWithTypeSubs(method, typeSubs, mangledName);

            Parameter[] paramsWithSelf = new Parameter("self", impl.targetType) ~ substituted.params;
            auto asFunction = new FunctionDecl(substituted.name, paramsWithSelf, substituted.returnType,
                substituted.body_, false, false, false, method.line, method.column);
            asFunction.namespaceSegments = [];

            // Forward-declare immediately (mirrors the ordinary function
            // forward-decl pass) so a call from code processed earlier
            // than this impl block still compiles. Safe even though the
            // target type's complete definition isn't visible yet here -
            // C allows an incomplete-type parameter in a declaration, just
            // not in a definition (see the body, below).
            //
            // Resolves a *clone* of the return type, not asFunction.returnType
            // itself - generateFunction (called below, via
            // deferredFunctionBodies) needs it still as-written to resolve a
            // bare `return SomeGenericStruct { ... }` in the method body;
            // resolving the real node here first would already have mangled
            // it by the time that runs.
            Type returnTypeForFwd = cloneType(asFunction.returnType);
            resolveType(returnTypeForFwd);
            string fwdParams = "";
            foreach (i, p; asFunction.params) {
                resolveType(p.type);
                if (i > 0) fwdParams ~= ", ";
                fwdParams ~= format("%s %s", typeToC(p.type), p.name);
            }
            if (targetNeedsTypedef) {
                genericForwardDecls ~= format("typedef struct %s %s;\n", impl.targetType.name, impl.targetType.name);
            }
            genericForwardDecls ~= format("%s %s(%s);\n", typeToC(returnTypeForFwd), asFunction.name, fwdParams);

            functionRegistry[asFunction.name] = asFunction;

            // The body (unlike the prototype above) needs the target type's
            // *complete* definition when it's a plain class/struct (e.g. a
            // `self.x` field access) - so it can't go in genericInstanceDecls
            // (spliced before declCode); see deferredFunctionBodies's doc comment.
            //
            // Snapshot/restore variableTypes around this - see the matching
            // comment in resolveGenericFunctionCall for why (this call isn't
            // known to be reentrant today, but the guard costs nothing and
            // keeps both eager-instantiation sites consistent).
            Type[string] savedVarTypes = variableTypes.dup;
            deferredFunctionBodies ~= generateFunction(asFunction);
            variableTypes = savedVarTypes;
        }
    }

    // The instantiation-suffix fragment for one concrete type argument,
    // e.g. Type("int") -> "int", Type("char", pointerDepth: 1) -> "char_ptr",
    // Type("char", pointerDepth: 2) -> "char_ptr_ptr". By the time this
    // runs, a nested generic argument (Vector<Vector<int>>) has already had
    // its own name rewritten to its mangled instantiation name by the
    // recursive resolveType call in instantiateGenericTypeArgs, so this
    // never needs to recurse into typeArgs itself.
    private string mangleTypeArg(Type t) {
        string s = t.name;
        foreach (i; 0 .. t.pointerDepth) s ~= "_ptr";
        if (t.isArray) s ~= format("_arr%d", t.arraySize);
        return s;
    }

    private string instantiatedLeafName(string templateLeafName, Type[] typeArgs) {
        string result = templateLeafName;
        foreach (arg; typeArgs) result ~= "_" ~ mangleTypeArg(arg);
        return result;
    }

    // Monomorphizes (on first use) or looks up the already-monomorphized
    // mangled name for one `TemplateName<typeArgs...>` instantiation. See
    // the module-level comment on genericClassTemplates for the overall
    // design. `typeArgs` must already be resolved (resolveType called on
    // each) by the caller.
    private string instantiateGenericTypeArgs(string name, Type[] typeArgs) {
        string classKey = findGenericTemplateKey(name, (k) => (k in genericClassTemplates) !is null);
        string structKey = findGenericTemplateKey(name, (k) => (k in genericStructTemplates) !is null);
        if (classKey.length == 0 && structKey.length == 0) {
            throw new CompileError(format("'%s' is not a generic type", name), currentModulePath, 0, 0);
        }
        bool isClass = classKey.length > 0;
        string templateKey = isClass ? classKey : structKey;
        string[] templateTypeParams = isClass ?
            genericClassTemplates[templateKey].typeParams : genericStructTemplates[templateKey].typeParams;
        string[] templateTypeParamBounds = isClass ?
            genericClassTemplates[templateKey].typeParamBounds : genericStructTemplates[templateKey].typeParamBounds;
        string templateLeafName = isClass ?
            genericClassTemplates[templateKey].name : genericStructTemplates[templateKey].name;
        string[] templateNamespaceSegments = isClass ?
            genericClassTemplates[templateKey].namespaceSegments : genericStructTemplates[templateKey].namespaceSegments;

        if (typeArgs.length != templateTypeParams.length) {
            throw new CompileError(format("Generic type '%s' expects %d type argument(s), got %d",
                templateKey, templateTypeParams.length, typeArgs.length), currentModulePath, 0, 0);
        }

        // Trait-bound check - runs on *every* call (cache hit or miss),
        // since a second use with the same bad type arg must still be
        // caught even once monomorphizedInstances already has an entry.
        foreach (i, bound; templateTypeParamBounds) {
            if (bound.length == 0) continue;
            if ((bound ~ ":" ~ mangleTypeArg(typeArgs[i])) !in traitImplemented) {
                throw new CompileError(
                    format("Type '%s' used for type parameter '%s' of '%s' must implement trait '%s'",
                        typeArgs[i].name, templateTypeParams[i], templateKey, bound),
                    currentModulePath, 0, 0);
            }
        }

        string mangledName = mangled(templateNamespaceSegments, instantiatedLeafName(templateLeafName, typeArgs));

        if (mangledName !in monomorphizedInstances) {
            monomorphizedInstances[mangledName] = true; // reserve before generating the body - guards
                                                          // self-referential fields from re-triggering
            monomorphizedTypeArgs[mangledName] = typeArgs;
            if (templateKey == "Optional") optionalInstantiations[mangledName] = true;
            else if (templateKey == "Result") resultInstantiations[mangledName] = true;
            Type[string] typeSubs;
            foreach (i, tp; templateTypeParams) typeSubs[tp] = typeArgs[i];

            // An opaque forward tag, emitted immediately (before the real
            // body is generated below) - lets a self-referential field
            // (e.g. LinkedListNode<T>'s `next: LinkedListNode<T>*`) resolve
            // even though the full struct/class body isn't known yet, the
            // same way every ordinary class/struct is already forward-
            // declared up front (see generateMultiple's own forward-decl
            // pass) - this is that same mechanism, just triggered lazily.
            genericForwardDecls ~= format("typedef struct %s %s;\n", mangledName, mangledName);

            if (isClass) {
                auto clone = cloneClassDeclWithTypeSubs(genericClassTemplates[templateKey], typeSubs, mangledName);
                classRegistry[mangledName] = clone;
                currentNamespaceSegments = [];

                // Ordinary (non-generic) class/struct fields get resolveType
                // called on them by a dedicated upfront pass in
                // generateMultiple, before generateClass/generateStruct ever
                // runs - generateClass/generateStruct don't do it
                // themselves. A generic clone never goes through that pass
                // (it doesn't exist until this exact moment), so it has to
                // happen here instead, or a field's type-argument suffix
                // (e.g. "Node<T>*") never gets collapsed into its mangled
                // name and leaks the raw, unmangled template name into the
                // emitted C.
                foreach (field; clone.fields) {
                    if (field.type is null) field.type = inferType(field.initializer);
                    resolveType(field.type);
                }

                // Forward-declare the constructor/destructor/methods too,
                // mirroring generateMultiple's own function/method forward-
                // decl pass - needed since one method can call another
                // declared later in the same class body (e.g. Vector<T>'s
                // push() calling its own grow()), and this class's methods
                // otherwise get no forward declaration at all before their
                // bodies are generated below.
                checkNoDuplicateSignatures(clone.constructors, format("constructor of '%s'", mangledName),
                    clone.line, clone.column);
                foreach (ctor; clone.constructors) {
                    string ctorParams = "";
                    foreach (i, param; ctor.params) {
                        resolveType(param.type);
                        if (i > 0) ctorParams ~= ", ";
                        ctorParams ~= format("%s %s", typeToC(param.type), param.name);
                    }
                    genericForwardDecls ~= format("%s* %s(%s);\n",
                        mangledName, mangleConstructorName(clone, mangledName, ctor), ctorParams);
                }
                if (clone.destructor) {
                    genericForwardDecls ~= format("void %s_destroy(void* ptr);\n", mangledName);
                }
                bool[string] checkedGenericMethodNames;
                foreach (method; clone.methods) {
                    if (method.name !in checkedGenericMethodNames) {
                        checkedGenericMethodNames[method.name] = true;
                        checkNoDuplicateSignatures(methodCandidatesNamed(clone, method.name),
                            format("method '%s.%s'", mangledName, method.name), method.line, method.column);
                    }
                    // Resolve a *clone*, not method.returnType itself -
                    // generateClass (below) -> generateMethod needs it
                    // still as-written to resolve a bare `return
                    // SomeGenericStruct { ... }` in the method body.
                    Type returnTypeForFwd = cloneType(method.returnType);
                    resolveType(returnTypeForFwd);
                    string methodParams = format("%s* self", mangledName);
                    foreach (param; method.params) {
                        resolveType(param.type);
                        methodParams ~= format(", %s %s", typeToC(param.type), param.name);
                    }
                    genericForwardDecls ~= format("%s %s(%s);\n",
                        typeToC(returnTypeForFwd), mangleMethodName(clone, mangledName, method), methodParams);
                }

                // Snapshot/restore variableTypes around this - see the
                // matching comment in resolveGenericFunctionCall for why:
                // resolveType (and therefore this whole instantiation) can
                // run reentrantly while a caller is mid-generation of its
                // own body, and generateClass -> generateConstructor/
                // generateMethod/generateDestructor's own "self"/param
                // cleanup would otherwise delete a same-named live binding
                // the caller still needs.
                Type[string] savedVarTypes = variableTypes.dup;
                genericInstanceDecls ~= generateClass(clone);
                variableTypes = savedVarTypes;
            } else {
                auto clone = cloneStructDeclWithTypeSubs(genericStructTemplates[templateKey], typeSubs, mangledName);
                structRegistry[mangledName] = clone;
                currentNamespaceSegments = [];
                foreach (field; clone.fields) {
                    if (field.type is null) field.type = inferType(field.initializer);
                    resolveType(field.type);
                }
                genericInstanceDecls ~= generateStruct(clone);
            }
        }

        return mangledName;
    }

    // Monomorphizes (on first use) or looks up the already-monomorphized
    // mangled name for a call to a generic function template. Generic
    // function calls never write explicit `<...>` type arguments (that
    // syntax only exists in type positions - see typeParamList's comment
    // on why generic operators/calls stay unambiguous), so every type
    // parameter is instead inferred from whichever parameter position(s)
    // mention it, using the argument expressions actually passed here.
    private GenericCallResolution resolveGenericFunctionCall(string templateKey, ASTNode[] args,
            string[] argNames) {
        FunctionDecl tmpl = genericFunctionTemplates[templateKey];
        args = resolveCallArguments(tmpl.params, false, args, argNames,
            format("generic function '%s'", templateKey), 0, 0);

        Type[string] bindings;
        foreach (i, param; tmpl.params) {
            if (i >= args.length) continue;
            if (tmpl.typeParams.canFind(param.type.name) && (param.type.name in bindings) is null) {
                bindings[param.type.name] = inferType(args[i]);
                continue;
            }
            // A param shaped like `Slice<T>` (T nested inside another
            // generic type, not the param's own bare type) - recover T
            // from the argument's own type via the reverse mapping
            // instantiateGenericTypeArgs records (see
            // monomorphizedTypeArgs's own comment for why this indirection
            // is needed at all: by the time we get here, the argument's
            // type has already been resolved down to a flat mangled name).
            if (param.type.typeArgs.length > 0) {
                Type argType = inferType(args[i]);
                resolveType(argType);
                if (auto recorded = argType.name in monomorphizedTypeArgs) {
                    foreach (j, ta; param.type.typeArgs) {
                        if (j < recorded.length && tmpl.typeParams.canFind(ta.name)
                                && (ta.name in bindings) is null) {
                            bindings[ta.name] = (*recorded)[j];
                        }
                    }
                }
            }
        }
        foreach (tp; tmpl.typeParams) {
            if ((tp in bindings) is null) {
                throw new CompileError(format(
                    "Cannot infer type parameter '%s' for generic function '%s' - " ~
                    "it must appear in at least one parameter's type", tp, templateKey),
                    currentModulePath, 0, 0);
            }
        }
        Type[] typeArgs;
        foreach (tp; tmpl.typeParams) {
            resolveType(bindings[tp]);
            typeArgs ~= bindings[tp];
        }

        // Trait-bound check - runs on every call (cache hit or miss), same
        // reasoning as instantiateGenericTypeArgs's identical check.
        foreach (i, bound; tmpl.typeParamBounds) {
            if (bound.length == 0) continue;
            if ((bound ~ ":" ~ mangleTypeArg(typeArgs[i])) !in traitImplemented) {
                throw new CompileError(
                    format("Type '%s' used for type parameter '%s' of '%s' must implement trait '%s'",
                        typeArgs[i].name, tmpl.typeParams[i], templateKey, bound),
                    currentModulePath, 0, 0);
            }
        }

        string mangledName = mangled(tmpl.namespaceSegments, instantiatedLeafName(tmpl.name, typeArgs));

        if (mangledName !in monomorphizedInstances) {
            monomorphizedInstances[mangledName] = true;

            Type[string] typeSubs;
            foreach (i, tp; tmpl.typeParams) typeSubs[tp] = typeArgs[i];
            auto clone = cloneFunctionDeclWithTypeSubs(tmpl, typeSubs, mangledName);

            // Forward-declare the concrete signature immediately (before
            // the body is generated) - resolves the common case of mutual
            // recursion between two different generic function
            // instantiations (see the module-level comment on
            // genericForwardDecls).
            string protoParams = "";
            foreach (i, p; clone.params) {
                resolveType(p.type);
                if (i > 0) protoParams ~= ", ";
                protoParams ~= format("%s %s", typeToC(p.type), p.name);
            }
            // Resolve a *clone*, not clone.returnType itself (yes, "clone"
            // here already means the monomorphized FunctionDecl - this is
            // a second, throwaway clone of just its return type) -
            // generateFunction (below, via deferredFunctionBodies) needs
            // it still as-written to resolve a bare `return
            // SomeGenericStruct { ... }` in the body.
            Type returnTypeForFwd = cloneType(clone.returnType);
            resolveType(returnTypeForFwd);
            genericForwardDecls ~= format("%s %s(%s);\n", typeToC(returnTypeForFwd), mangledName, protoParams);

            functionRegistry[mangledName] = clone;
            // Deferred, not genericInstanceDecls - a generic function's body
            // (unlike a generic class/struct's own definition) is never
            // needed by anything ahead of it, only its prototype above is
            // (already forward-declared) - and deferring avoids the same
            // incomplete-type problem processImplBlock hits when a plain
            // class/struct type argument is used by value (see
            // deferredFunctionBodies's doc comment).
            //
            // This call is reentrant: resolveGenericFunctionCall can itself
            // be invoked from generateExpression/inferType while a *caller*
            // is mid-generation of its own body (the first time a given
            // instantiation is seen). generateFunction ends by removing
            // just its own params from variableTypes, on the assumption
            // that's a clean, top-level entry/exit - but if a caller's own
            // local happens to share a name with one of *this* function's
            // params (very possible for common names like "n"/"self"),
            // that removal would delete the caller's still-live binding
            // too. Snapshotting/restoring the whole map around the call
            // isolates this instantiation's variable scope from whatever
            // the caller had before, regardless of name collisions.
            Type[string] savedVarTypes = variableTypes.dup;
            deferredFunctionBodies ~= generateFunction(clone);
            variableTypes = savedVarTypes;
        }

        return GenericCallResolution(mangledName, args);
    }

    // Resolves a possibly-unqualified class type name to its mangled form
    // in place, the same way resolveName does for functions/variables, so a
    // namespaced class can be referenced unqualified (or partially qualified)
    // from sibling code in that namespace. No-op for primitives or names that
    // are already fully qualified/unresolvable.
    private void resolveType(Type t) {
        if (t is null) return;

        // A name brought in by a selective import (possibly aliased) is
        // stored under its local spelling but refers to the target symbol.
        string localAliasTarget = resolveLocalImportAlias(t.name);
        if (localAliasTarget.length > 0) {
            t.name = localAliasTarget;
        }

        if (auto aliased = t.name in typeAliases) {
            // Substitute the alias's own type in place - a use site that
            // *also* wrote its own `*` on an already-pointer alias
            // (`string*` where `string` is `char*`) stacks depth (giving
            // `char**`) rather than collapsing back to a single `*`.
            t.name = aliased.name;
            t.pointerDepth = t.pointerDepth + aliased.pointerDepth;
            t.isArray = t.isArray || aliased.isArray;
            if (aliased.arraySize > 0) t.arraySize = aliased.arraySize;
        }

        // Built-in lowercase `string` is syntax sugar for `char*`, not a
        // distinct runtime type. Canonicalize it before generics, trait impl
        // keys, operator lookup and C type emission see it, so every existing
        // char* feature also applies to string.
        if (t.name == "string") {
            t.name = "char";
            t.pointerDepth += 1;
        }

        // Resolve module-alias prefixes in qualified type names (e.g.
        // `G.Point` flattened to `G_Point`) before generic instantiation
        // or class/struct lookup sees them.
        t.name = resolveAliasedTypeName(t.name);

        // Generic instantiation, e.g. Vector<int> - resolve nested type
        // arguments first (handles Vector<Vector<int>>), then monomorphize
        // (or reuse an existing instantiation) and rewrite this Type
        // in-place to the concrete mangled name, exactly as if it had been
        // hand-written - every other pass (typeToC, isStructTypeName, ...)
        // never needs to know generics exist at all.
        if (t.typeArgs.length > 0) {
            foreach (arg; t.typeArgs) resolveType(arg);
            t.name = instantiateGenericTypeArgs(t.name, t.typeArgs);
            t.typeArgs = [];
            return;
        }

        if (isPrimitiveTypeName(t.name)) return;
        if (t.name in classRegistry || t.name in structRegistry) return;
        foreach (candidate; enclosingQualifications(t.name)) {
            if (candidate in classRegistry || candidate in structRegistry) {
                t.name = candidate;
                return;
            }
        }

        // A bare generic name used with no type arguments at all, e.g.
        // `let v: Vector` instead of `Vector<int>`.
        if (findGenericTemplateKey(t.name, (k) => (k in genericClassTemplates) !is null).length > 0 ||
            findGenericTemplateKey(t.name, (k) => (k in genericStructTemplates) !is null).length > 0) {
            throw new CompileError(
                format("Generic type '%s' requires type arguments (e.g. %s<...>)", t.name, t.name),
                currentModulePath, 0, 0);
        }
    }

    private bool isStructTypeName(string name) {
        return (name in structRegistry) !is null;
    }

    private bool isClassTypeName(string name) {
        return (name in classRegistry) !is null;
    }

    // C's default variadic argument promotions only widen types smaller than
    // `int` up to `int` - a bare integer literal or an already-`int`-sized
    // value is passed exactly as-is. Our runtime's va_arg reads every
    // non-pointer vararg as a full 8-byte value (see runtime.c), so anything
    // not already pointer-width needs an explicit cast at the call site;
    // otherwise the callee reads garbage in the upper bits.
    private string variadicPromote(ASTNode arg, string argCode) {
        try {
            Type t = inferType(arg);
            if (t.isPointer || t.isArray || isStructTypeName(t.name) || isClassTypeName(t.name)) {
                return argCode;
            }
            return format("((long long)(%s))", argCode);
        } catch (Exception e) {
            return argCode;
        }
    }

    // Looks up the FunctionDecl a call's callee resolves to, if it's a
    // plain (possibly namespace-qualified) reference to a known function -
    // used to decide which trailing arguments are in a variadic tail.
    private FunctionDecl resolveCalledFunction(ASTNode callee) {
        if (auto ident = cast(Identifier)callee) {
            string resolved = resolveName(ident.name, (n) => (n in functionRegistry) !is null);
            if (auto fd = resolved in functionRegistry) {
                return *fd;
            }
        } else if (auto member = cast(MemberExpr)callee) {
            string qualified = tryResolveQualifiedPath(member, (n) => (n in functionRegistry) !is null);
            if (qualified.length > 0) {
                return functionRegistry[qualified];
            }
        }
        return null;
    }

    private bool hasNamedArgs(string[] argNames) {
        foreach (n; argNames) if (n.length > 0) return true;
        return false;
    }

    // Matches a call's raw (possibly named, possibly omitting trailing
    // defaulted) arguments against a callee's declared parameter list,
    // producing a plain positional ASTNode[] - one entry per `params[i]`
    // (defaults substituted for anything the call omitted), plus any extra
    // *variadic* tail arguments appended unchanged. This is the only place
    // named-argument/default-value resolution happens; every existing
    // call-generation path downstream already expects exactly this shape
    // (a positional ASTNode[] the same length as `params`, give or take a
    // variadic tail) and needs no further changes.
    private ASTNode[] resolveCallArguments(Parameter[] params, bool isVariadic, ASTNode[] args,
            string[] argNames, string calleeDescription, int line, int column) {
        // Fast path: every call before this feature existed, and the
        // overwhelming majority of calls after it - all positional, arity
        // matches exactly (or overflows into a variadic tail).
        if (!hasNamedArgs(argNames) && args.length == params.length) {
            return args;
        }
        if (!hasNamedArgs(argNames) && isVariadic && args.length >= params.length) {
            return args;
        }

        ASTNode[] resolved = new ASTNode[params.length];
        bool[] filled = new bool[params.length];
        ASTNode[] variadicTail;
        size_t nextPositional = 0;

        foreach (i, arg; args) {
            string name = i < argNames.length ? argNames[i] : "";
            if (name.length == 0) {
                if (nextPositional >= params.length) {
                    if (isVariadic) {
                        variadicTail ~= arg;
                        continue;
                    }
                    throw new CompileError(format("Too many arguments to %s - expected at most %d, got %d",
                        calleeDescription, params.length, args.length), currentModulePath, line, column);
                }
                resolved[nextPositional] = arg;
                filled[nextPositional] = true;
                nextPositional++;
            } else {
                long idx = -1;
                foreach (j, p; params) {
                    if (p.name == name) { idx = j; break; }
                }
                if (idx < 0) {
                    throw new CompileError(format("%s has no parameter named '%s'", calleeDescription, name),
                        currentModulePath, line, column);
                }
                if (filled[idx]) {
                    throw new CompileError(
                        format("Argument '%s' of %s was already supplied", name, calleeDescription),
                        currentModulePath, line, column);
                }
                resolved[idx] = arg;
                filled[idx] = true;
            }
        }

        foreach (i, p; params) {
            if (filled[i]) continue;
            if (p.defaultValue !is null) {
                resolved[i] = p.defaultValue;
                continue;
            }
            throw new CompileError(format("Missing required argument '%s' of %s", p.name, calleeDescription),
                currentModulePath, line, column);
        }

        return resolved ~ variadicTail;
    }

    // "(Type1, Type2)" - the parameter-types half of a human-readable
    // signature, for overload error messages (no matching overload,
    // ambiguous call, duplicate signature).
    private string paramTypesDescription(Parameter[] params) {
        string[] parts;
        foreach (p; params) parts ~= p.type.toString();
        return "(" ~ parts.join(", ") ~ ")";
    }

    // True if `a` and `b` declare the exact same parameter *types*, in the
    // same order (and so the same arity) - an accidental duplicate
    // overload, not a real one: nothing could ever distinguish them at a
    // call site. Reuses sameErrorType's existing exact (name +
    // pointerDepth + array-ness) comparison.
    private bool sameParameterTypes(Parameter[] a, Parameter[] b) {
        if (a.length != b.length) return false;
        foreach (i, p; a) {
            if (!sameErrorType(p.type, b[i].type)) return false;
        }
        return true;
    }

    // Run once per assembled candidate group (a class's methods sharing
    // one name, a class's whole `constructors` array, or a
    // `functionCandidates` group) - throws a clear compile error if two
    // candidates are indistinguishable duplicates, instead of letting it
    // surface later as a bewildering identically-mangled-C-symbol clash.
    private void checkNoDuplicateSignatures(FunctionDecl[] candidates, string calleeDescription,
            int line, int column) {
        foreach (i, a; candidates) {
            foreach (j; i + 1 .. candidates.length) {
                if (sameParameterTypes(a.params, candidates[j].params)) {
                    throw new CompileError(format(
                        "%s is declared more than once with the same parameter types %s",
                        calleeDescription, paramTypesDescription(a.params)),
                        currentModulePath, line, column);
                }
            }
        }
    }

    // Picks which of several same-named candidates (methods, constructors,
    // or free functions - see the "Method, constructor, and free-function
    // overloading" plan) a call's (args, argNames) actually mean, by
    // argument type. A single candidate is returned immediately with no
    // type inference at all, so the overwhelming non-overloaded case is
    // completely unaffected. Otherwise, each candidate is tried through
    // the existing named/default-argument resolver (resolveCallArguments)
    // - a candidate only "fits" if that succeeds *and* every resolved
    // argument's inferred type exactly matches (via sameErrorType - no
    // implicit numeric coercion, matching this compiler's existing
    // nominal-exact-type stance elsewhere, e.g. if-expression branch
    // matching) that parameter's declared type.
    private FunctionDecl resolveOverload(FunctionDecl[] candidates, ASTNode[] args, string[] argNames,
            string calleeDescription, int line, int column) {
        if (candidates.length == 1) return candidates[0];

        FunctionDecl[] fits;
        foreach (candidate; candidates) {
            ASTNode[] resolved;
            try {
                resolved = resolveCallArguments(candidate.params, candidate.isVariadic, args, argNames,
                    calleeDescription, line, column);
            } catch (CompileError e) {
                continue;
            }
            bool matches = true;
            foreach (i, param; candidate.params) {
                if (i >= resolved.length) { matches = false; break; }
                Type argType;
                try {
                    argType = inferType(resolved[i]);
                } catch (Exception e) {
                    matches = false;
                    break;
                }
                if (!sameErrorType(argType, param.type)) {
                    matches = false;
                    break;
                }
            }
            if (matches) fits ~= candidate;
        }

        if (fits.length == 1) return fits[0];

        string candidateList = candidates.map!(c => paramTypesDescription(c.params)).join(", ");
        if (fits.length == 0) {
            throw new CompileError(format("No matching overload for %s - %d candidate(s): %s",
                calleeDescription, candidates.length, candidateList),
                currentModulePath, line, column);
        }
        throw new CompileError(format("Ambiguous call to %s - matches %d overloads: %s",
            calleeDescription, fits.length, candidateList),
            currentModulePath, line, column);
    }

    // The "_int_int"-style suffix appended to an overloaded name's mangled
    // C symbol - one mangleTypeArg per parameter, joined by "_". Only ever
    // applied when a name has more than one candidate (checked by each
    // caller below), so a non-overloaded declaration's mangled name is
    // completely unaffected.
    private string overloadSuffix(Parameter[] params) {
        string suffix = "";
        foreach (p; params) suffix ~= "_" ~ mangleTypeArg(p.type);
        return suffix;
    }

    private FunctionDecl[] methodCandidatesNamed(ClassDecl cd, string name) {
        FunctionDecl[] result;
        foreach (m; cd.methods) if (m.name == name) result ~= m;
        return result;
    }

    // `ClassName_methodName` if `method` is the only one of its class
    // named that - the exact mangling this compiler has always used -
    // else suffixed with its own parameter types to stay unique among its
    // overloads.
    private string mangleMethodName(ClassDecl cd, string cName, FunctionDecl method) {
        auto candidates = methodCandidatesNamed(cd, method.name);
        if (candidates.length <= 1) return format("%s_%s", cName, method.name);
        return format("%s_%s%s", cName, method.name, overloadSuffix(method.params));
    }

    // `ClassName_new` if there's only one constructor (matches every
    // existing class), else suffixed per constructor the same way
    // mangleMethodName is.
    private string mangleConstructorName(ClassDecl cd, string cName, FunctionDecl ctor) {
        if (cd.constructors.length <= 1) return format("%s_new", cName);
        return format("%s_new%s", cName, overloadSuffix(ctor.params));
    }

    // Groups every top-level FunctionDecl by its plain (pre-overload-
    // suffix) mangled name - i.e. exactly what mangledFunc(fn) already
    // produces today. A key with more than one candidate is an overloaded
    // name; see mangleFreeFunctionName and every free-function call site.
    private FunctionDecl[][string] functionCandidates;

    // `mangledFunc(fn)` (today's plain namespace_name) if `fn` is the only
    // function registered under that name, else suffixed per its own
    // parameter types. Extern functions are never suffixed - their C
    // symbol is a real, fixed external name that can't be invented a
    // second spelling for.
    private string mangleFreeFunctionName(FunctionDecl fn) {
        string plain = mangledFunc(fn);
        if (fn.isExtern) return plain;
        auto candidates = plain in functionCandidates;
        if (candidates is null || candidates.length <= 1) return plain;
        return plain ~ overloadSuffix(fn.params);
    }

    // The iterator protocol a class opts into to support `foreach let x in
    // instance { ... }` - mirrors operatorMethodName's op_* naming (ast.d):
    // a fixed method name codegen looks up by string, not a language-level
    // interface/trait mechanism. ITER_HAS_NEXT/ITER_NEXT are mandatory (a
    // class needs both to be foreach-able at all); ITER_RESET is optional -
    // called automatically before the loop if present, letting an object
    // be foreach-ed more than once (e.g. two separate loops over the same
    // String) without the caller manually resetting iteration state, but
    // not required for a single-use iterator that's naturally exhausted.
    private static immutable string ITER_HAS_NEXT = "iter_has_next";
    private static immutable string ITER_NEXT = "iter_next";
    private static immutable string ITER_RESET = "iter_reset";

    private FunctionDecl findIterMethod(ClassDecl classDecl, string name) {
        foreach (method; classDecl.methods) {
            if (method.name == name) return method;
        }
        return null;
    }

    // Same lookup, but also falls back to a method an `impl Iterator<T> for
    // ThisClass { ... }` block provided instead of an inline one.
    // processImplBlock desugars impl methods into free functions named
    // "<targetKey>_<methodName>" in functionRegistry - never added to
    // classDecl.methods (see its own comment) - so findIterMethod alone
    // can't see them. mangledClass(classDecl) matches mangleTypeArg's output
    // for a plain (non-generic, non-pointer) class target, so this reuses
    // the exact same key processImplBlock registered the method under.
    private FunctionDecl findIterMethodOrImpl(ClassDecl classDecl, string name) {
        if (auto m = findIterMethod(classDecl, name)) return m;
        string key = mangledClass(classDecl) ~ "_" ~ name;
        if (auto f = key in functionRegistry) return *f;
        return null;
    }

    // `foreach let x in iterable { ... }` desugars to either a counted
    // index loop (iterable is a fixed-size array) or a has_next/next loop
    // (iterable is a class implementing the iterator protocol above) -
    // whichever matches is decided purely from iterable's inferred type,
    // the same way operator overloading is resolved from an operand's type.
    private string generateForeachStmt(ForeachStmt foreachStmt, bool isDeferred) {
        // `for i in start..end { ... }` - see ast.RangeExpr's own comment
        // for why this is checked before ever calling inferType: a range
        // isn't a typed value the way an array or iterator-protocol class
        // is, it's pure control-flow sugar.
        if (auto range = cast(RangeExpr)foreachStmt.iterable) {
            return generateRangeForeach(foreachStmt, range, isDeferred);
        }

        Type iterType;
        try {
            iterType = inferType(foreachStmt.iterable);
            resolveType(iterType);
        } catch (Exception e) {
            throw new CompileError(
                format("Cannot infer the type of this foreach expression: %s", e.msg),
                currentModulePath, foreachStmt.line, foreachStmt.column);
        }

        if (iterType.isArray) {
            if (iterType.arraySize <= 0) {
                throw new CompileError(
                    "foreach needs a fixed-size array (e.g. 'T[8]') - this array's size isn't known " ~
                    "at compile time (it's an unsized 'T[]', typically a function parameter)",
                    currentModulePath, foreachStmt.line, foreachStmt.column);
            }
            return generateArrayForeach(foreachStmt, iterType, isDeferred);
        }

        if (auto classDecl = iterType.name in classRegistry) {
            FunctionDecl hasNextMethod = findIterMethodOrImpl(*classDecl, ITER_HAS_NEXT);
            FunctionDecl nextMethod = findIterMethodOrImpl(*classDecl, ITER_NEXT);
            if (hasNextMethod !is null && nextMethod !is null) {
                return generateClassForeach(foreachStmt, *classDecl, nextMethod, isDeferred);
            }
        }

        throw new CompileError(
            format("'%s' can't be used with foreach: it's neither a fixed-size array nor a class " ~
                "implementing the iterator protocol (%s() -> bool and %s() -> T methods)",
                iterType.toString(), ITER_HAS_NEXT, ITER_NEXT),
            currentModulePath, foreachStmt.line, foreachStmt.column);
    }

    // `for i in start..end { ... }` desugars to a plain counting loop -
    // `end` is evaluated once, up front, into its own temporary (not
    // re-evaluated every iteration), matching this compiler's existing
    // "evaluate loop bounds once" stance elsewhere (e.g. array foreach's
    // fixed arraySize). The range is exclusive of `end`, like Rust's.
    private string generateRangeForeach(ForeachStmt foreachStmt, RangeExpr range, bool isDeferred) {
        tempVarCounter++;
        string endName = format("__range_end%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("int64_t %s = %s;\n", endName, generateExpression(range.end));
        code ~= indent() ~ format("int64_t %s = %s;\n", foreachStmt.varName, generateExpression(range.start));
        code ~= indent() ~ format("while (%s < %s) {\n", foreachStmt.varName, endName);
        indentLevel++;

        variableTypes[foreachStmt.varName] = new Type("int");
        foreach (stmt; foreachStmt.body_.statements) {
            code ~= generateStatement(stmt, isDeferred);
        }
        variableTypes.remove(foreachStmt.varName);

        code ~= indent() ~ format("%s = %s + 1;\n", foreachStmt.varName, foreachStmt.varName);
        indentLevel--;
        code ~= indent() ~ "}\n";
        indentLevel--;
        code ~= indent() ~ "}\n";
        return code;
    }

    private string generateArrayForeach(ForeachStmt foreachStmt, Type arrType, bool isDeferred) {
        Type elemType = new Type(arrType.name, false, false, 0);

        tempVarCounter++;
        string idxName = format("__foreach_i%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("int64_t %s = 0;\n", idxName);
        code ~= indent() ~ format("while (%s < %d) {\n", idxName, arrType.arraySize);
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s[%s];\n",
            typeToC(elemType), foreachStmt.varName, generateExpression(foreachStmt.iterable), idxName);

        variableTypes[foreachStmt.varName] = elemType;
        foreach (stmt; foreachStmt.body_.statements) {
            code ~= generateStatement(stmt, isDeferred);
        }
        variableTypes.remove(foreachStmt.varName);

        code ~= indent() ~ format("%s = %s + 1;\n", idxName, idxName);
        indentLevel--;
        code ~= indent() ~ "}\n";
        indentLevel--;
        code ~= indent() ~ "}\n";
        return code;
    }

    private string generateClassForeach(ForeachStmt foreachStmt, ClassDecl classDecl, FunctionDecl nextMethod,
            bool isDeferred) {
        string cName = mangledClass(classDecl);
        Type elemType = nextMethod.returnType;

        tempVarCounter++;
        // Evaluated into a local once, not re-evaluated for every has_next/
        // next/reset call - `foreachStmt.iterable` could be an arbitrary
        // (possibly side-effecting) expression, not just a bare variable.
        string objName = format("__foreach_obj%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s;\n",
            typeToC(new Type(cName)), objName, generateExpression(foreachStmt.iterable));

        if (findIterMethodOrImpl(classDecl, ITER_RESET) !is null) {
            code ~= indent() ~ format("%s_%s(%s);\n", cName, ITER_RESET, objName);
        }

        code ~= indent() ~ format("while (%s_%s(%s)) {\n", cName, ITER_HAS_NEXT, objName);
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s_%s(%s);\n",
            typeToC(elemType), foreachStmt.varName, cName, ITER_NEXT, objName);

        variableTypes[foreachStmt.varName] = elemType;
        foreach (stmt; foreachStmt.body_.statements) {
            code ~= generateStatement(stmt, isDeferred);
        }
        variableTypes.remove(foreachStmt.varName);

        indentLevel--;
        code ~= indent() ~ "}\n";
        indentLevel--;
        code ~= indent() ~ "}\n";
        return code;
    }

    // Shared by the `.stringof` property (see generateExpression's
    // MemberExpr case) and casting a class/struct value `as string`/`as
    // char*` (see its CastExpr case): a class defining a no-argument
    // `stringof()` method has it called; everything else (a struct, which
    // can't have methods at all, or a class that doesn't define one) falls
    // back to a compile-time string literal of the type's own name -
    // there's always *something* meaningful to produce either way.
    private string generateStringofValue(Type objType, ASTNode objectExpr, int line, int column) {
        if (auto classDecl = objType.name in classRegistry) {
            foreach (m; classDecl.methods) {
                if (m.name == "stringof" && m.params.length == 0) {
                    recordUsage(objType.name ~ ".stringof", line, column);
                    return format("%s_stringof(%s)", objType.name, generateExpression(objectExpr));
                }
            }
        }
        return format("\"%s\"", escapeCString(objType.toString()));
    }

    // Decides whether member access on `object` should use "." (a value
    // type: struct, array element, or dereferenced pointer) or "->" (a class
    // instance, always heap-allocated, or an explicit pointer type). Falls
    // back to "->" - the historical, only behavior before structs existed -
    // whenever the type can't be determined, so existing class-based code
    // is unaffected.
    private string memberAccessor(ASTNode object) {
        try {
            Type t = inferType(object);
            if (!t.isPointer && isStructTypeName(t.name)) {
                return ".";
            }
            return "->";
        } catch (Exception e) {
            return "->";
        }
    }

    // Finds the operator-overload method (see ast.operatorMethodName) `op`'s
    // self/left operand's type defines, or null if there isn't one - the
    // caller falls back to the plain C operator. Two independent sources,
    // since a class can define one inline (`func operator+(...)` as an
    // ordinary method, looked up via classRegistry like any other method)
    // while a struct or primitive has no inline method syntax at all and can
    // only ever gain one via `impl Add for TargetType { func operator+(...) }`
    // (desugared by processImplBlock into an ordinary function named
    // `<mangleTypeArg(target)>_op_add`, registered in functionRegistry) - a
    // class can use either form, so both are checked. Used both to generate
    // the overload call (see findOperatorMethodCallName) and, by inferType,
    // to get the overload's return type for `a + b`-shaped expressions.
    private FunctionDecl findOperatorMethodDecl(ASTNode selfOperand, string op, bool isUnary) {
        string methodName = operatorMethodName(op, isUnary);
        if (methodName.length == 0) return null;
        try {
            Type selfType = inferType(selfOperand);
            resolveType(selfType);
            if (auto classDecl = selfType.name in classRegistry) {
                foreach (method; classDecl.methods) {
                    if (method.name == methodName) return method;
                }
            }
            if (auto fn = format("%s_%s", mangleTypeArg(selfType), methodName) in functionRegistry) {
                return *fn;
            }
        } catch (Exception e) {
            // fall through - not an overload
        }
        return null;
    }

    // The mangled C call name for findOperatorMethodDecl's match - always
    // `<mangleTypeArg(selfType)>_<methodName>`. Built from the bare
    // operatorMethodName result, not the matched FunctionDecl's own .name -
    // a class's inline method's .name is bare ("op_add"), but an impl
    // block's desugared method is registered in functionRegistry under the
    // already-fully-mangled name ("Vec2_op_add" - see processImplBlock), so
    // using .name here would double the prefix for that second case.
    private string findOperatorMethodCallName(ASTNode selfOperand, string op, bool isUnary) {
        if (findOperatorMethodDecl(selfOperand, op, isUnary) is null) return "";
        string methodName = operatorMethodName(op, isUnary);
        try {
            Type selfType = inferType(selfOperand);
            resolveType(selfType);
            return format("%s_%s", mangleTypeArg(selfType), methodName);
        } catch (Exception e) {
            return "";
        }
    }

    private string tryBinaryOperatorOverloadCall(BinaryExpr binExpr) {
        string callName = findOperatorMethodCallName(binExpr.left, binExpr.op, false);
        if (callName.length == 0) return "";
        return format("%s(%s, %s)", callName,
            generateExpression(binExpr.left), generateExpression(binExpr.right));
    }

    private string tryUnaryOperatorOverloadCall(UnaryExpr unaryExpr) {
        string callName = findOperatorMethodCallName(unaryExpr.operand, unaryExpr.op, true);
        if (callName.length == 0) return "";
        return format("%s(%s)", callName, generateExpression(unaryExpr.operand));
    }

    // Same idea as tryBinaryOperatorOverloadCall, for `arr[index]` where
    // `arr` defines `operator[]` (op_index). Read-only: there's no
    // op_index= counterpart, so this never fires for the left side of an
    // assignment in a way that would need an lvalue - see
    // ast.operatorMethodName's doc comment.
    private string tryIndexOperatorOverloadCall(IndexExpr indexExpr) {
        string callName = findOperatorMethodCallName(indexExpr.array, "[]", false);
        if (callName.length == 0) return "";
        return format("%s(%s, %s)", callName,
            generateExpression(indexExpr.array), generateExpression(indexExpr.index));
    }

    // Tries to resolve a dotted chain as a namespace-qualified reference
    // Collect alias/selective-import metadata from every ImportStmt.
    private void collectImports(Program[] programs) {
        foreach (prog; programs) {
            if (baseName(prog.modulePath) == "prelude.llpl") {
                preludeModulePath = prog.modulePath;
            }
            foreach (decl; prog.declarations) {
                auto imp = cast(ImportStmt)decl;
                if (imp is null) continue;

                if (imp.resolvedPath.length == 0) {
                    if (imp.alias_.length > 0 || imp.isSelective) {
                        throw new CompileError(format("Could not resolve import '%s'", imp.modulePath),
                            prog.modulePath, imp.line, imp.column);
                    }
                    continue;
                }

                ModuleImportInfo info;
                info.targetModulePath = imp.resolvedPath;
                info.alias_ = imp.alias_;
                info.isSelective = imp.isSelective;
                foreach (n; imp.names) {
                    info.names ~= ImportedNameInfo(n.original, n.alias_);
                }
                moduleImports[prog.modulePath] ~= info;

                if (imp.alias_.length > 0) {
                    moduleAliases[prog.modulePath][imp.alias_] = imp.resolvedPath;
                }

                if (imp.isSelective) {
                    foreach (n; imp.names) {
                        string target = findSymbolInModule(imp.resolvedPath, n.original);
                        if (target.length == 0) {
                            throw new CompileError(
                                format("Selective import '%s' not found in module '%s'",
                                    n.original, imp.modulePath),
                                prog.modulePath, imp.line, imp.column);
                        }
                        string localName = n.alias_.length > 0 ? n.alias_ : n.original;
                        auto localAliases = prog.modulePath in selectiveLocalAliases;
                        if (localAliases !is null && (localName in *localAliases)) {
                            throw new CompileError(
                                format("Duplicate selective import name '%s'", localName),
                                prog.modulePath, imp.line, imp.column);
                        }
                        selectiveLocalAliases[prog.modulePath][localName] = target;
                    }
                }
            }
        }
    }

    // Find the mangled name exported by `targetModule` whose final segment
    // matches `name`. Returns "" if none, and throws if ambiguous.
    private string findSymbolInModule(string targetModule, string name) {
        if (targetModule !in exportsByModule) return "";
        string[] candidates;
        foreach (key; exportsByModule[targetModule].keys) {
            if (key == name || key.endsWith("_" ~ name)) {
                candidates ~= key;
            }
        }
        if (candidates.length == 0) return "";
        if (candidates.length == 1) return candidates[0];
        throw new CompileError(
            format("Selective import '%s' is ambiguous in module '%s'", name, targetModule),
            currentModulePath, 0, 0);
    }

    // If `name` was brought into the current module by a selective import
    // (possibly aliased), return the mangled name it refers to.
    private string resolveLocalImportAlias(string name) {
        auto aliases = currentModulePath in selectiveLocalAliases;
        if (aliases is null) return "";
        auto target = name in *aliases;
        return target ? *target : "";
    }

    // If `flatName` starts with a module alias, resolve it to the actual
    // mangled name exported by that module. The caller's `exists` predicate
    // then validates the kind (function, variable, generic template, ...).
    private string resolveAliasedQualifiedName(string flatName) {
        auto aliases = currentModulePath in moduleAliases;
        if (aliases is null) return "";

        foreach (alias_, targetModule; *aliases) {
            string prefix = alias_ ~ "_";
            if (!flatName.startsWith(prefix)) continue;
            string suffix = flatName[prefix.length .. $];
            if (suffix.length == 0) continue;

            string[] candidates;
            foreach (key; exportsByModule[targetModule].keys) {
                if (key == suffix || key.endsWith("_" ~ suffix)) {
                    candidates ~= key;
                }
            }
            if (candidates.length == 0) continue;
            if (candidates.length > 1) {
                throw new CompileError(
                    format("'%s' is ambiguous in module alias '%s'", suffix, alias_),
                    currentModulePath, 0, 0);
            }
            return candidates[0];
        }
        return "";
    }

    // Resolve a module-alias-prefixed type name (e.g. `G_Vector` for
    // `G.Vector`) to the actual mangled type name exported by the module.
    private string resolveAliasedTypeName(string name) {
        auto aliases = currentModulePath in moduleAliases;
        if (aliases is null) return name;

        foreach (alias_, targetModule; *aliases) {
            string prefix = alias_ ~ "_";
            if (!name.startsWith(prefix)) continue;
            string suffix = name[prefix.length .. $];
            if (suffix.length == 0) continue;

            string[] candidates;
            foreach (key; exportsByModule[targetModule].keys) {
                bool isType = (key in classRegistry) !is null ||
                              (key in structRegistry) !is null ||
                              (key in genericClassTemplates) !is null ||
                              (key in genericStructTemplates) !is null ||
                              (key in typeAliases) !is null;
                if (!isType) continue;
                if (key == suffix || key.endsWith("_" ~ suffix)) {
                    candidates ~= key;
                }
            }
            if (candidates.length == 0) continue;
            if (candidates.length > 1) {
                throw new CompileError(
                    format("Type '%s' is ambiguous in module alias '%s'", suffix, alias_),
                    currentModulePath, 0, 0);
            }
            return candidates[0];
        }
        return name;
    }

    // (checked via `exists`, e.g. against functionRegistry or variableTypes)
    // rather than instance member access. Returns "" if it isn't one.
    private string tryResolveQualifiedPath(ASTNode expr, bool delegate(string) exists) {
        string root = leftmostName(expr);
        if (root.length == 0 || (root in variableTypes)) {
            return ""; // root is a real local/instance variable; prefer normal member access
        }

        string flat = flattenPath(expr);
        if (flat.length == 0) return "";

        string aliased = resolveAliasedQualifiedName(flat);
        if (aliased.length > 0 && exists(aliased)) return aliased;

        if (exists(flat)) return flat;
        foreach (candidate; enclosingQualifications(flat)) {
            if (exists(candidate)) return candidate;
        }
        return "";
    }

    // Extern functions are always registered under their bare, unmangled
    // name (see mangledFunc) since they bind to a real external C symbol
    // regardless of how they're namespaced at the declaration site - so a
    // call like `HAL.Log.ksnprintf(...)` needs this narrow fallback after
    // tryResolveQualifiedPath's mangled-path lookup comes up empty. Scoped
    // to extern functions specifically (not a blanket bare-name fallback)
    // to avoid silently matching an unrelated same-named top-level symbol.
    private string tryResolveExternFunctionMember(ASTNode expr) {
        if (auto member = cast(MemberExpr)expr) {
            if (auto fd = member.member in functionRegistry) {
                if (fd.isExtern) return member.member;
            }
        }
        return "";
    }

    // Resolves a bare (unqualified) name, letting sibling code inside a
    // namespace refer to other members of that namespace (or an enclosing
    // one) without prefixing. A name brought in by a selective import (or
    // aliased selective import) takes priority over ordinary scope.
    private string resolveName(string name, bool delegate(string) exists) {
        string aliased = resolveLocalImportAlias(name);
        if (aliased.length > 0 && exists(aliased)) return aliased;

        if (exists(name)) return name;
        foreach (candidate; enclosingQualifications(name)) {
            if (exists(candidate)) return candidate;
        }
        return name;
    }

    // `func[cap1, &cap2](params) -> T { ... }` - see ast.d's LambdaExpr and
    // runtime.h's __LLPL_Closure for the overall design: every closure
    // shares the same two-word {fn, env} runtime representation regardless
    // of its signature, so this only needs to synthesize a per-lambda
    // environment struct (one field per capture) and a trampoline function
    // taking that environment (cast back from void*) as an extra leading
    // parameter, then return a single C expression building the closure
    // value.
    //
    // Captures are explicit: `func[x]` copies `x` by value at lambda-creation
    // time; `func[&x]` stores a pointer to `x` so the lambda sees live updates
    // and can write back. A reference capture of an outer lambda's by-value
    // capture takes the address of that outer environment slot; a reference
    // capture of an outer reference capture just copies the pointer, so all
    // closures involved alias the same original variable.
    private string generateLambdaExpr(LambdaExpr lambdaExpr) {
        int id = lambdaCounter++;
        string envType = format("__LambdaEnv%d", id);
        string trampolineName = format("__lambda%d", id);

        Type lambdaReturnTypeAsWritten = cloneType(lambdaExpr.returnType);
        resolveType(lambdaExpr.returnType);
        foreach (p; lambdaExpr.params) resolveType(p.type);

        struct CaptureGen {
            Type ty;
            bool byRef;
            string initExpr;
            string useExpr;
            string lvalueExpr;
        }
        CaptureGen[] caps;

        foreach (cap; lambdaExpr.captures) {
            bool outerByRef = false;
            string lvalueExpr;
            Type capType;
            if (auto outer = cap.name in currentLambdaCaptures) {
                outerByRef = outer.byRef;
                lvalueExpr = outer.lvalueExpr;
                capType = variableTypes[cap.name];
            } else {
                string resolved = resolveName(cap.name, (n) => (n in variableTypes) !is null);
                if ((resolved in variableTypes) is null) {
                    throw new CompileError(format("Unknown capture '%s'", cap.name),
                        currentModulePath, lambdaExpr.line, lambdaExpr.column);
                }
                lvalueExpr = resolved;
                capType = variableTypes[resolved];
            }

            string myLvalue = format("__env->%s", cap.name);
            string initExpr;
            string useExpr;
            if (cap.byRef) {
                useExpr = "(*" ~ myLvalue ~ ")";
                if (outerByRef) {
                    initExpr = lvalueExpr;
                } else {
                    initExpr = "&(" ~ lvalueExpr ~ ")";
                }
            } else {
                useExpr = myLvalue;
                if (outerByRef) {
                    initExpr = "(*" ~ lvalueExpr ~ ")";
                } else {
                    initExpr = lvalueExpr;
                }
            }

            caps ~= CaptureGen(capType, cap.byRef, initExpr, useExpr, myLvalue);
        }

        string envDecl = "typedef struct {\n";
        foreach (i, cap; lambdaExpr.captures) {
            string fieldType = caps[i].byRef ? (typeToC(caps[i].ty) ~ "*") : typeToC(caps[i].ty);
            envDecl ~= format("    %s %s;\n", fieldType, cap.name);
        }
        envDecl ~= format("} %s;\n\n", envType);

        string trampolineParams = "void* __env_raw";
        foreach (p; lambdaExpr.params) {
            trampolineParams ~= format(", %s %s", typeToC(p.type), p.name);
        }

        string trampolineCode = format("%s %s(%s) {\n", typeToC(lambdaExpr.returnType), trampolineName, trampolineParams);
        trampolineCode ~= format("    %s* __env = (%s*)__env_raw;\n", envType, envType);

        // Save/restore all per-function generation state around the body,
        // mirroring generateFunction/generateMethod: this trampoline is a
        // real top-level C function with its own fresh defer-stack, and
        // its own params/captures must not leak into the surrounding
        // function's variableTypes once it's done generating.
        DeferInfo[] savedDeferred = deferredStatements;
        deferredStatements = [];
        LambdaCaptureCtx[string] savedCaptures = currentLambdaCaptures.dup;
        Type prevReturnType = currentReturnType;
        currentReturnType = lambdaExpr.returnType;
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = lambdaReturnTypeAsWritten;

        Type[string] savedCaptureTypes;
        foreach (i, cap; lambdaExpr.captures) {
            if (auto prev = cap.name in variableTypes) {
                savedCaptureTypes[cap.name] = *prev;
            }
            LambdaCaptureCtx ctx;
            ctx.useExpr = caps[i].useExpr;
            ctx.lvalueExpr = caps[i].lvalueExpr;
            ctx.byRef = caps[i].byRef;
            currentLambdaCaptures[cap.name] = ctx;
            variableTypes[cap.name] = caps[i].ty;
        }
        foreach (p; lambdaExpr.params) {
            variableTypes[p.name] = p.type;
        }

        int savedIndent = indentLevel;
        indentLevel = 1;
        string bodyCode = "";
        foreach (stmt; withImplicitReturn(lambdaExpr.body_.statements, lambdaExpr.returnType)) {
            bodyCode ~= generateBodyStatement(stmt, false);
        }
        trampolineCode ~= deferFrameDeclarations();
        trampolineCode ~= bodyCode;
        trampolineCode ~= deferredCleanupCode();
        indentLevel = savedIndent;

        foreach (cap; lambdaExpr.captures) {
            if (auto prev = cap.name in savedCaptureTypes) {
                variableTypes[cap.name] = *prev;
            } else {
                variableTypes.remove(cap.name);
            }
        }
        foreach (p; lambdaExpr.params) {
            variableTypes.remove(p.name);
        }
        currentLambdaCaptures = savedCaptures;
        deferredStatements = savedDeferred;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;

        trampolineCode ~= "}\n";

        lambdaDecls ~= envDecl;
        lambdaDecls ~= trampolineCode;
        lambdaDecls ~= "\n";

        string envInit = format("({ %s* __e = (%s*)rc_alloc(sizeof(%s)); ", envType, envType, envType);
        foreach (i, cap; lambdaExpr.captures) {
            envInit ~= format("__e->%s = %s; ", cap.name, caps[i].initExpr);
        }
        envInit ~= "(void*)__e; })";

        return format("((__LLPL_Closure){ .fn = (void*)%s, .env = %s })", trampolineName, envInit);
    }

    private bool isEmbedCall(CallExpr callExpr) {
        auto calleeIdent = cast(Identifier)callExpr.callee;
        return calleeIdent !is null && calleeIdent.name == "embed";
    }

    private string embedPath(CallExpr callExpr) {
        if (callExpr.args.length != 1) {
            throw new CompileError("embed(path) expects exactly one string literal argument",
                currentModulePath, callExpr.line, callExpr.column);
        }
        auto lit = cast(StringLiteral)callExpr.args[0];
        if (lit is null) {
            throw new CompileError("embed(path) requires a string literal path",
                currentModulePath, callExpr.args[0].line, callExpr.args[0].column);
        }
        string baseDir = currentModulePath.length > 0 ? dirName(currentModulePath) : ".";
        return buildNormalizedPath(baseDir, lit.value);
    }

    private string generateEmbedCall(CallExpr callExpr) {
        string path = embedPath(callExpr);
        if (!exists(path)) {
            throw new CompileError(format("Embedded file not found: %s", path),
                currentModulePath, callExpr.line, callExpr.column);
        }

        ubyte[] bytes = cast(ubyte[])read(path);
        int id = embeddedFileCounter++;
        string dataName = format("__llpl_embed_%d", id);

        string decl = format("static unsigned char %s[%d] = {", dataName,
            bytes.length == 0 ? 1 : bytes.length);
        if (bytes.length == 0) {
            decl ~= "0";
        } else {
            foreach (i, b; bytes) {
                if (i > 0) decl ~= ", ";
                decl ~= to!string(b);
            }
        }
        decl ~= "};\n";
        embeddedFileDecls ~= decl;

        return format("((EmbeddedFile){ .data = (char*)%s, .len = %dULL })", dataName, bytes.length);
    }

    private string generateExpression(ASTNode node) {
        if (auto binExpr = cast(BinaryExpr)node) {
            if (binExpr.op == "=") {
                checkNotConstAssignment(binExpr.left);
                Type leftType = null;
                try {
                    leftType = inferType(binExpr.left);
                } catch (Exception e) {
                    // Not a typed value inferType can see through - fall
                    // through to a plain assignment below.
                }
                if (leftType !is null && leftType.isNullableSugar) {
                    return generateExpression(binExpr.left) ~ " = " ~
                        generateNullableWrap(leftType, binExpr.right);
                }
                // Same reasoning as ReturnStmt/VarDecl's own struct-literal/
                // tuple-literal handling - a plain assignment's RHS is just
                // as valid a place to write `self.field = Slice { ... }` as
                // a `let`/`return`, and needs the same expected-type context
                // (here, the already-inferred left-hand side's type) so a
                // *generic* struct/tuple literal can resolve its type args.
                if (leftType !is null) {
                    if (auto structLit = cast(StructLiteral)binExpr.right) {
                        return generateExpression(binExpr.left) ~ " = " ~
                            generateStructLiteralValue(structLit, leftType);
                    }
                    if (auto tupleLit = cast(TupleLiteral)binExpr.right) {
                        return generateExpression(binExpr.left) ~ " = " ~
                            generateTupleLiteral(tupleLit, leftType);
                    }
                }
                return generateExpression(binExpr.left) ~ " = " ~ generateExpression(binExpr.right);
            }
            string overloadCall = tryBinaryOperatorOverloadCall(binExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            return "(" ~ generateExpression(binExpr.left) ~ " " ~ binExpr.op ~ " " ~
                   generateExpression(binExpr.right) ~ ")";
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            string overloadCall = tryUnaryOperatorOverloadCall(unaryExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            return unaryExpr.op ~ generateExpression(unaryExpr.operand);
        } else if (auto lambdaExpr = cast(LambdaExpr)node) {
            return generateLambdaExpr(lambdaExpr);
        } else if (auto sizeofExpr = cast(SizeofExpr)node) {
            resolveType(sizeofExpr.type);
            return format("sizeof(%s)", typeToC(sizeofExpr.type));
        } else if (auto structLit = cast(StructLiteral)node) {
            // No expected-type context available here (this is the
            // standalone path, reached whenever a struct literal isn't
            // sitting directly in a let-initializer/return that already
            // handled it below with its own known type) - fine for a
            // plain (non-generic) struct, but resolveStructLiteralTarget
            // throws a clear error for a generic one used this way.
            return generateStructLiteralValue(structLit, null);
        } else if (auto tupleLit = cast(TupleLiteral)node) {
            return generateTupleLiteral(tupleLit, null);
        } else if (auto propExpr = cast(PropagateExpr)node) {
            return generatePropagateExpr(propExpr);
        } else if (auto ifExpr = cast(IfExpr)node) {
            return generateIfExpr(ifExpr);
        } else if (auto callExpr = cast(CallExpr)node) {
            if (isEmbedCall(callExpr)) {
                return generateEmbedCall(callExpr);
            }
            // Closure call: if the callee's own type resolves to a closure
            // type (a closure-typed variable, parameter, or field - never a
            // plain function/method name, which has no Type of its own),
            // generate an explicit function-pointer-cast call through the
            // closure's {fn, env} pair instead of any of the ordinary call
            // paths below. Checked first since a closure can be stored in a
            // field (self.callback(x)) and would otherwise match the
            // qualified-function-call/method-call branches' MemberExpr
            // callee below.
            Type closureType = null;
            try {
                closureType = inferType(callExpr.callee);
            } catch (Exception e) {
                // Not a typed value (a plain function/method name has no
                // Type) - fall through to the ordinary call paths below.
            }
            if (closureType !is null && closureType.closureReturnType !is null) {
                string calleeCode = generateExpression(callExpr.callee);
                string retC = typeToC(closureType.closureReturnType);
                string paramTypesC = "void*";
                foreach (p; closureType.closureParams) {
                    paramTypesC ~= ", " ~ typeToC(p.type);
                }
                // calleeCode is embedded twice (once to reach .fn, once for
                // .env) - a documented, accepted limitation: a closure
                // *expression* with side effects (rather than a plain
                // variable/field) would run those side effects twice. Every
                // realistic use calls through a closure-typed variable,
                // parameter or field, none of which have side effects to
                // duplicate.
                ASTNode[] resolvedArgs = resolveCallArguments(closureType.closureParams, false,
                    callExpr.args, callExpr.argNames, "this closure", callExpr.line, callExpr.column);
                string cargs = format("(%s).env", calleeCode);
                foreach (arg; resolvedArgs) {
                    cargs ~= ", " ~ generateExpression(arg);
                }
                return format("((%s (*)(%s))(%s).fn)(%s)", retC, paramTypesC, calleeCode, cargs);
            }
            // Generic function call: if the callee names a generic
            // function template (rather than an ordinary function),
            // monomorphize on demand (inferring its type parameters from
            // the argument expressions here) and generate the call as an
            // ordinary call to the concrete mangled function. Checked
            // before the method-call/qualified-call paths below for the
            // same reason as the closure check above.
            string genericTemplateKey = "";
            if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                genericTemplateKey = tryResolveQualifiedPath(memberCallee,
                    (n) => (n in genericFunctionTemplates) !is null);
            } else if (auto identCallee = cast(Identifier)callExpr.callee) {
                genericTemplateKey = findGenericTemplateKey(identCallee.name,
                    (n) => (n in genericFunctionTemplates) !is null);
            }
            if (genericTemplateKey.length > 0) {
                auto resolution = resolveGenericFunctionCall(genericTemplateKey, callExpr.args, callExpr.argNames);
                recordUsage(resolution.mangledName, callExpr.line, callExpr.column);
                string gargs = "";
                foreach (i, arg; resolution.resolvedArgs) {
                    if (i > 0) gargs ~= ", ";
                    gargs ~= generateExpression(arg);
                }
                return format("%s(%s)", resolution.mangledName, gargs);
            }
            // Check if this is a method call
            if (auto memberExpr = cast(MemberExpr)callExpr.callee) {
                // A namespace-qualified function call (e.g. Graphics.helper())
                // takes priority over instance-method-call syntax. Resolved
                // against functionCandidates (grouped by the same
                // pre-overload-suffix name tryResolveQualifiedPath already
                // produces), not functionRegistry directly - see the plain
                // (unqualified) call branch above for why an overloaded
                // name's *bare* qualified name is no longer a real
                // functionRegistry key on its own.
                string qualifiedName = tryResolveQualifiedPath(memberExpr,
                    (n) => (n in functionCandidates) !is null);
                if (qualifiedName.length > 0) {
                    auto candidates = functionCandidates[qualifiedName];
                    FunctionDecl qualifiedDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        format("function '%s'", qualifiedName), callExpr.line, callExpr.column);
                    string qualifiedFunc = mangleFreeFunctionName(qualifiedDecl);
                    recordUsage(qualifiedFunc, memberExpr.line, memberExpr.column);
                    ASTNode[] resolvedArgs = resolveCallArguments(qualifiedDecl.params, qualifiedDecl.isVariadic,
                        callExpr.args, callExpr.argNames, format("function '%s'", qualifiedName),
                        callExpr.line, callExpr.column);
                    string qargs = "";
                    foreach (i, arg; resolvedArgs) {
                        if (i > 0) qargs ~= ", ";
                        string argCode = generateExpression(arg);
                        if (qualifiedDecl.isVariadic && i >= qualifiedDecl.params.length) {
                            argCode = variadicPromote(arg, argCode);
                        }
                        qargs ~= argCode;
                    }
                    return format("%s(%s)", qualifiedFunc, qargs);
                }
                string externFunc = tryResolveExternFunctionMember(memberExpr);
                if (externFunc.length > 0) {
                    recordUsage(externFunc, memberExpr.line, memberExpr.column);
                    FunctionDecl qualifiedDecl = functionRegistry[externFunc];
                    ASTNode[] resolvedArgs = resolveCallArguments(qualifiedDecl.params, qualifiedDecl.isVariadic,
                        callExpr.args, callExpr.argNames, format("function '%s'", externFunc),
                        callExpr.line, callExpr.column);
                    string qargs = "";
                    foreach (i, arg; resolvedArgs) {
                        if (i > 0) qargs ~= ", ";
                        string argCode = generateExpression(arg);
                        if (qualifiedDecl.isVariadic && i >= qualifiedDecl.params.length) {
                            argCode = variadicPromote(arg, argCode);
                        }
                        qargs ~= argCode;
                    }
                    return format("%s(%s)", externFunc, qargs);
                }

                string objectExpr = generateExpression(memberExpr.object);
                string methodName = memberExpr.member;

                // Try to determine the class type - inferType handles far
                // more than a bare identifier (a `new Foo(...)` receiver, a
                // chained call like `a.trim().to_upper()`, an indexed or
                // field-accessed instance, ...), so a method call works on
                // any expression it can type, not just `x.method()`.
                string className = "";
                try {
                    // mangleTypeArg, not the bare .name - a raw pointer
                    // receiver (e.g. a `char*` calling an `impl Hashable for
                    // char*` method) must dispatch to its own
                    // pointer-suffixed mangled name, distinct from its
                    // pointee's (see processImplBlock, which mangles impl
                    // methods the same way). A no-op for every already-
                    // working case: ordinary generic instantiations' .name
                    // is already their final mangled name with isPointer
                    // false, and plain classes/structs/primitives have
                    // isPointer false too.
                    className = mangleTypeArg(inferType(memberExpr.object));
                } catch (Exception e) {
                    // fall through - className stays "", falls back to the
                    // CLASS_ placeholder below
                }

                // Find the target method's own FunctionDecl(s) (if the class
                // was resolved) to resolve named/default arguments (and,
                // when there's more than one same-named method, which
                // overload) against - unlike the plain/qualified-call
                // paths, there was no FunctionDecl lookup here at all
                // before named arguments existed, since dispatch is just a
                // string-built C call.
                ClassDecl cd = className.length > 0 && className in classRegistry
                    ? classRegistry[className] : null;
                FunctionDecl[] candidates = cd !is null ? methodCandidatesNamed(cd, methodName) : [];
                string calleeDescription = format("method '%s.%s'", className, methodName);
                ASTNode[] resolvedArgs;
                // Blind fallback for a method that isn't in cd.methods at
                // all (e.g. impl-block-provided trait methods, generated
                // separately by processImplBlock under this exact name) -
                // matches this compiler's existing behavior of trusting
                // that mechanism rather than requiring every method to be
                // registered here.
                string methodSymbol = className.length > 0 ? format("%s_%s", className, methodName) : "";
                if (candidates.length == 0) {
                    if (hasNamedArgs(callExpr.argNames)) {
                        throw new CompileError(
                            format("Cannot resolve named arguments for '%s' - its target method " ~
                                "couldn't be determined at compile time", methodName),
                            currentModulePath, callExpr.line, callExpr.column);
                    }
                    resolvedArgs = callExpr.args;
                } else {
                    FunctionDecl methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        calleeDescription, callExpr.line, callExpr.column);
                    checkMemberAccess(methodDecl.isPrivate, className, calleeDescription,
                        callExpr.line, callExpr.column);
                    resolvedArgs = resolveCallArguments(methodDecl.params, false, callExpr.args,
                        callExpr.argNames, calleeDescription, callExpr.line, callExpr.column);
                    methodSymbol = mangleMethodName(cd, className, methodDecl);
                }

                // Generate method call with object as first parameter
                string args = objectExpr;
                foreach (arg; resolvedArgs) {
                    args ~= ", " ~ generateExpression(arg);
                }

                if (className.length > 0) {
                    recordUsage(className ~ "." ~ methodName, memberExpr.line, memberExpr.column);
                    return format("%s(%s)", methodSymbol, args);
                } else {
                    return format("CLASS_%s(%s)", methodName, args);
                }
            } else {
                // A plain identifier resolving to a *known* function (by
                // its pre-overload-suffix name) has to be resolved here,
                // overload-aware, rather than through the ordinary
                // generateExpression(callExpr.callee) path below: that path
                // only has the bare identifier to go on, with no way to
                // know which overload's (possibly suffixed) mangled symbol
                // the call's own arguments actually mean. mangleFreeFunctionName
                // returns today's plain name unchanged whenever there's
                // only one candidate, so this is a no-op for every
                // non-overloaded call.
                FunctionDecl[] candidates;
                string resolvedName;
                if (auto ident = cast(Identifier)callExpr.callee) {
                    resolvedName = resolveName(ident.name, (n) => (n in functionCandidates) !is null);
                    if (auto c = resolvedName in functionCandidates) candidates = *c;
                }

                string callee;
                FunctionDecl calleeDecl;
                ASTNode[] resolvedArgs;
                if (candidates.length > 0) {
                    calleeDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        format("function '%s'", resolvedName), callExpr.line, callExpr.column);
                    callee = mangleFreeFunctionName(calleeDecl);
                    recordUsage(callee, callExpr.callee.line, callExpr.callee.column);
                    resolvedArgs = resolveCallArguments(calleeDecl.params, calleeDecl.isVariadic,
                        callExpr.args, callExpr.argNames, format("function '%s'", resolvedName),
                        callExpr.line, callExpr.column);
                } else {
                    // Not a plain identifier resolving to a known function
                    // (a qualified/generic/closure call already handled
                    // above, an extern function - excluded from
                    // functionCandidates, see mangleFreeFunctionName - or
                    // truly unresolvable) - exactly today's behavior.
                    // generateExpression(callExpr.callee) already records
                    // this as a plain Identifier usage - no separate
                    // recordUsage needed here.
                    callee = generateExpression(callExpr.callee);
                    calleeDecl = resolveCalledFunction(callExpr.callee);
                    if (calleeDecl !is null) {
                        resolvedArgs = resolveCallArguments(calleeDecl.params, calleeDecl.isVariadic,
                            callExpr.args, callExpr.argNames, format("function '%s'", calleeDecl.name),
                            callExpr.line, callExpr.column);
                    } else {
                        if (hasNamedArgs(callExpr.argNames)) {
                            throw new CompileError(
                                "Cannot resolve named arguments - this call's target couldn't be " ~
                                "determined at compile time",
                                currentModulePath, callExpr.line, callExpr.column);
                        }
                        resolvedArgs = callExpr.args;
                    }
                }
                string args = "";
                foreach (i, arg; resolvedArgs) {
                    if (i > 0) args ~= ", ";
                    string argCode = generateExpression(arg);
                    if (calleeDecl !is null && calleeDecl.isVariadic && i >= calleeDecl.params.length) {
                        argCode = variadicPromote(arg, argCode);
                    }
                    args ~= argCode;
                }
                return format("%s(%s)", callee, args);
            }
        } else if (auto memberExpr = cast(MemberExpr)node) {
            // `.stringof` (no call parens - `x.stringof()` already works
            // as an ordinary method call without any special-casing here)
            // - see generateStringofValue's own comment.
            if (memberExpr.member == "stringof") {
                Type objType;
                try {
                    objType = inferType(memberExpr.object);
                } catch (Exception e) {
                    throw new CompileError("'.stringof' needs a typed value",
                        currentModulePath, memberExpr.line, memberExpr.column);
                }
                return generateStringofValue(objType, memberExpr.object, memberExpr.line, memberExpr.column);
            }
            // `.sizeof` - unlike the existing `sizeof(TypeName)` (a real
            // type reference only), this works on any typed *value*
            // (`x.sizeof`), inferring its type the same way `.stringof`
            // does. For a bare type name, `sizeof(TypeName)` is still the
            // spelling to use.
            if (memberExpr.member == "sizeof") {
                Type objType;
                try {
                    objType = inferType(memberExpr.object);
                } catch (Exception e) {
                    throw new CompileError(
                        "'.sizeof' needs a typed value - use 'sizeof(TypeName)' for a bare type",
                        currentModulePath, memberExpr.line, memberExpr.column);
                }
                resolveType(objType);
                return format("sizeof(%s)", typeToC(objType));
            }
            // A namespace-qualified global reference (e.g. Graphics.origin)
            // takes priority over instance field access.
            string qualifiedVar = tryResolveQualifiedPath(memberExpr, (n) => (n in variableTypes) !is null);
            if (qualifiedVar.length > 0) {
                recordUsage(qualifiedVar, memberExpr.line, memberExpr.column);
                return qualifiedVar;
            }

            // A namespace-qualified function referenced as a *value*, not
            // called - e.g. `Task.timer_isr_entry as uint` to get an ISR's
            // address for IDT.set_gate (a bare function name decays to its
            // address in C, same trick already used for unqualified
            // handlers like `isr_timer as uint`). The CallExpr/MemberExpr-
            // callee path above already resolves a qualified *call* this
            // way; this covers the uncalled-reference case function
            // pointers need.
            string qualifiedFunc = tryResolveQualifiedPath(memberExpr, (n) => (n in functionRegistry) !is null);
            if (qualifiedFunc.length == 0) {
                // extern funcs are always registered under their bare,
                // unmangled name regardless of where they're declared (see
                // tryResolveExternFunctionMember's own comment) - e.g.
                // `Task.timer_isr_entry` binds to a real external asm
                // symbol just named `timer_isr_entry`, so no namespaced
                // candidate above would ever match it.
                qualifiedFunc = tryResolveExternFunctionMember(memberExpr);
            }
            if (qualifiedFunc.length > 0) {
                recordUsage(qualifiedFunc, memberExpr.line, memberExpr.column);
                return qualifiedFunc;
            }

            if (auto objIdent = cast(Identifier)memberExpr.object) {
                if (auto objType = objIdent.name in variableTypes) {
                    recordUsage(objType.name ~ "." ~ memberExpr.member, memberExpr.line, memberExpr.column);
                }
            }

            // `f.method` with no call parens (e.g. `f.method as uint`) - a
            // bare method reference, same idea as the qualified-function
            // case above, just for an instance method instead of a plain
            // function. Without this check it falls straight through to
            // ordinary field access below and generates `f->method`, which
            // only compiles if the class happens to also have a field with
            // that exact name (never true for a real method) - see
            // mangleMethodName/methodCandidatesNamed for why a single
            // candidate keeps its plain "ClassName_method" C name (a bare
            // function reference, exactly like a free function decaying to
            // its address), while 2+ overloads can't be disambiguated
            // without a call's argument types. An impl-block-provided
            // method (never added to classDecl.methods - see
            // findIterMethodOrImpl's comment) is checked as a fallback
            // under the same "ClassName_method" key processImplBlock
            // registers it under.
            Type memberObjType = null;
            try {
                memberObjType = inferType(memberExpr.object);
            } catch (Exception e) {
                // Not a typed value - fall through to plain field access.
            }
            if (memberObjType !is null) {
                if (auto classDecl = memberObjType.name in classRegistry) {
                    string ownerClassName = mangledClass(*classDecl);
                    VarDecl matchedField = null;
                    foreach (field; classDecl.fields) {
                        if (field.name == memberExpr.member) { matchedField = field; break; }
                    }
                    if (matchedField !is null) {
                        checkMemberAccess(matchedField.isPrivate, ownerClassName,
                            format("field '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                    } else {
                        auto candidates = methodCandidatesNamed(*classDecl, memberExpr.member);
                        if (candidates.length > 1) {
                            throw new CompileError(
                                format("'%s' is ambiguous - %s has %d overloads named '%s'; a bare " ~
                                    "method reference (no call parens) can't disambiguate them",
                                    memberExpr.member, classDecl.name, candidates.length, memberExpr.member),
                                currentModulePath, memberExpr.line, memberExpr.column);
                        }
                        if (candidates.length == 1) {
                            checkMemberAccess(candidates[0].isPrivate, ownerClassName,
                                format("method '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                            return mangleMethodName(*classDecl, ownerClassName, candidates[0]);
                        }
                        string implKey = ownerClassName ~ "_" ~ memberExpr.member;
                        if (implKey in functionRegistry) {
                            return implKey;
                        }
                    }
                }
            }

            string accessor = memberAccessor(memberExpr.object);
            return format("%s%s%s", generateExpression(memberExpr.object), accessor, memberExpr.member);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            string overloadCall = tryIndexOperatorOverloadCall(indexExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            return format("%s[%s]", generateExpression(indexExpr.array),
                         generateExpression(indexExpr.index));
        } else if (auto ident = cast(Identifier)node) {
            if (auto ctx = ident.name in currentLambdaCaptures) {
                return ctx.useExpr;
            }
            string resolved = resolveName(ident.name,
                (n) => (n in variableTypes) !is null || (n in functionRegistry) !is null);
            recordUsage(resolved, ident.line, ident.column);
            return resolved;
        } else if (auto intLit = cast(IntLiteral)node) {
            return to!string(intLit.value);
        } else if (auto strLit = cast(StringLiteral)node) {
            return format("\"%s\"", escapeCString(strLit.value));
        } else if (auto regexLit = cast(RegexLiteral)node) {
            return format("Regex_new(\"%s\")", escapeCString(regexLit.pattern));
        } else if (auto interp = cast(InterpolatedStringLiteral)node) {
            return generateInterpolatedString(interp);
        } else if (auto arrLit = cast(ArrayLiteral)node) {
            string elems = "";
            foreach (i, elem; arrLit.elements) {
                if (i > 0) elems ~= ", ";
                elems ~= generateExpression(elem);
            }
            return format("{ %s }", elems);
        } else if (auto boolLit = cast(BoolLiteral)node) {
            return boolLit.value ? "1" : "0";
        } else if (auto nullLit = cast(NullLiteral)node) {
            return "NULL";
        } else if (auto newExpr = cast(NewExpr)node) {
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            recordUsage(newExpr.type.name, newExpr.line, newExpr.column);
            ClassDecl cd = newExpr.type.name in classRegistry ? classRegistry[newExpr.type.name] : null;
            FunctionDecl[] ctors = cd !is null ? cd.constructors : [];
            string calleeDescription = format("constructor of '%s'", newExpr.type.name);
            ASTNode[] resolvedArgs;
            string ctorSymbol;
            if (ctors.length == 0) {
                if (hasNamedArgs(newExpr.argNames)) {
                    throw new CompileError(
                        format("Cannot resolve named arguments for '%s''s constructor", newExpr.type.name),
                        currentModulePath, newExpr.line, newExpr.column);
                }
                resolvedArgs = newExpr.args;
                ctorSymbol = format("%s_new", newExpr.type.name);
            } else {
                FunctionDecl ctor = resolveOverload(ctors, newExpr.args, newExpr.argNames, calleeDescription,
                    newExpr.line, newExpr.column);
                resolvedArgs = resolveCallArguments(ctor.params, false, newExpr.args, newExpr.argNames,
                    calleeDescription, newExpr.line, newExpr.column);
                ctorSymbol = mangleConstructorName(cd, newExpr.type.name, ctor);
            }
            string args = "";
            foreach (i, arg; resolvedArgs) {
                if (i > 0) args ~= ", ";
                args ~= generateExpression(arg);
            }
            return format("%s(%s)", ctorSymbol, args);
        } else if (auto castExpr = cast(CastExpr)node) {
            resolveType(castExpr.type);
            // Casting a class/struct value `as string`/`as char*` resolves
            // the same way `.stringof` does (custom method, or the type's
            // own name) instead of reinterpreting the object as a raw
            // char* - see generateStringofValue. Only when the source is
            // actually a known class/struct and the target is exactly
            // `char*` (not `char**` or deeper - that isn't "cast to
            // string"); every other cast (including an already-char*
            // value) is unaffected.
            if (castExpr.type.name == "char" && castExpr.type.pointerDepth == 1) {
                try {
                    Type srcType = inferType(castExpr.expression);
                    if ((srcType.name in classRegistry) !is null || (srcType.name in structRegistry) !is null) {
                        return generateStringofValue(srcType, castExpr.expression, castExpr.line, castExpr.column);
                    }
                } catch (Exception e) {
                    // Not a typed value inferType can see through - fall
                    // through to the ordinary reinterpret cast below.
                }
            }
            return format("((%s)%s)", typeToC(castExpr.type), generateExpression(castExpr.expression));
        } else if (auto macroInvocation = cast(MacroInvocation)node) {
            return generateMacroExpression(macroInvocation);
        } else if (cast(QuoteExpr)node || cast(UnquoteExpr)node) {
            throw new CompileError("'quote'/'unquote' can only be used to build macro expansions",
                currentModulePath, node.line, node.column);
        }

        return "";
    }

    // Infers the type of an expression used as a `let` initializer when no
    // explicit type annotation was given.
    private CompileError inferError(ASTNode node, string message) {
        return new CompileError(message, currentModulePath, node.line, node.column);
    }

    private Type inferType(ASTNode expr) {
        if (cast(IntLiteral)expr) {
            return new Type("int");
        } else if (cast(StringLiteral)expr) {
            return new Type("char", true);
        } else if (cast(RegexLiteral)expr) {
            return new Type("Regex");
        } else if (cast(InterpolatedStringLiteral)expr) {
            return new Type("char", true);
        } else if (cast(BoolLiteral)expr) {
            return new Type("bool");
        } else if (cast(NullLiteral)expr) {
            throw inferError(expr, "Cannot infer type from 'null'; add an explicit type annotation");
        } else if (cast(ArrayLiteral)expr) {
            throw inferError(expr,
                "Cannot infer type of an array literal; declare an explicit array type " ~
                "(e.g. 'let arr: char[3] = [1, 2, 3]')");
        } else if (auto newExpr = cast(NewExpr)expr) {
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            return new Type(newExpr.type.name);
        } else if (cast(SizeofExpr)expr) {
            return new Type("uint");
        } else if (auto structLit = cast(StructLiteral)expr) {
            string mangledName;
            resolveStructLiteralTarget(structLit, null, mangledName); // throws for a generic one with no context
            return new Type(mangledName);
        } else if (auto tupleLit = cast(TupleLiteral)expr) {
            Type[] elemTypes;
            foreach (e; tupleLit.elements) {
                elemTypes ~= inferType(e);
            }
            return makeTupleType(elemTypes, tupleLit.line, tupleLit.column);
        } else if (auto propExpr = cast(PropagateExpr)expr) {
            Type operandType = inferType(propExpr.operand);
            if (auto classDecl = operandType.name in classRegistry) {
                foreach (field; classDecl.fields) {
                    if (field.name == "value") return field.type;
                }
            }
            throw inferError(expr, "Cannot infer type of '?' expression");
        } else if (auto ifExpr = cast(IfExpr)expr) {
            return inferIfExprType(ifExpr);
        } else if (auto castExpr = cast(CastExpr)expr) {
            resolveType(castExpr.type);
            return castExpr.type;
        } else if (auto lambdaExpr = cast(LambdaExpr)expr) {
            resolveType(lambdaExpr.returnType);
            foreach (p; lambdaExpr.params) resolveType(p.type);
            Type t = new Type("__LLPL_Closure");
            t.closureParams = lambdaExpr.params;
            t.closureReturnType = lambdaExpr.returnType;
            return t;
        } else if (auto ident = cast(Identifier)expr) {
            string resolved = resolveName(ident.name, (n) => (n in variableTypes) !is null);
            if (resolved in variableTypes) {
                return variableTypes[resolved];
            }
            throw inferError(expr, format("Cannot infer type: unknown variable '%s'", ident.name));
        } else if (auto memberExpr = cast(MemberExpr)expr) {
            if (memberExpr.member == "stringof") {
                return new Type("char", true);
            }
            if (memberExpr.member == "sizeof") {
                return new Type("uint");
            }
            string qualifiedVar = tryResolveQualifiedPath(memberExpr, (n) => (n in variableTypes) !is null);
            if (qualifiedVar.length > 0) {
                return variableTypes[qualifiedVar];
            }

            Type objType = inferType(memberExpr.object);
            if (auto classDecl = objType.name in classRegistry) {
                foreach (field; classDecl.fields) {
                    if (field.name == memberExpr.member) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        return field.type;
                    }
                }
            }
            if (auto structDecl = objType.name in structRegistry) {
                foreach (field; structDecl.fields) {
                    if (field.name == memberExpr.member) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        return field.type;
                    }
                }
            }
            throw inferError(expr, format("Cannot infer type of field '%s'", memberExpr.member));
        } else if (auto callExpr = cast(CallExpr)expr) {
            if (isEmbedCall(callExpr)) {
                return new Type("EmbeddedFile");
            }
            if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                string qualifiedName = tryResolveQualifiedPath(memberCallee, (n) => (n in functionCandidates) !is null);
                if (qualifiedName.length > 0) {
                    auto candidates = functionCandidates[qualifiedName];
                    auto decl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        format("function '%s'", qualifiedName), callExpr.line, callExpr.column);
                    return decl.returnType;
                }
                string qualifiedFunc = tryResolveExternFunctionMember(memberCallee);
                if (qualifiedFunc.length > 0) {
                    return functionRegistry[qualifiedFunc].returnType;
                }

                string genericKey = tryResolveQualifiedPath(memberCallee,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    auto resolution = resolveGenericFunctionCall(genericKey, callExpr.args, callExpr.argNames);
                    return functionRegistry[resolution.mangledName].returnType;
                }

                Type objType = inferType(memberCallee.object);
                if (auto classDecl = objType.name in classRegistry) {
                    auto candidates = methodCandidatesNamed(*classDecl, memberCallee.member);
                    if (candidates.length > 0) {
                        auto methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                            format("method '%s.%s'", objType.name, memberCallee.member),
                            callExpr.line, callExpr.column);
                        return methodDecl.returnType;
                    }
                }
                throw inferError(expr, format("Cannot infer type: unknown method '%s'", memberCallee.member));
            } else if (auto calleeIdent = cast(Identifier)callExpr.callee) {
                string resolvedVar = resolveName(calleeIdent.name, (n) => (n in variableTypes) !is null);
                if (resolvedVar in variableTypes && variableTypes[resolvedVar].closureReturnType !is null) {
                    return variableTypes[resolvedVar].closureReturnType;
                }
                string resolved = resolveName(calleeIdent.name, (n) => (n in functionCandidates) !is null);
                if (auto candidates = resolved in functionCandidates) {
                    auto decl = resolveOverload(*candidates, callExpr.args, callExpr.argNames,
                        format("function '%s'", resolved), callExpr.line, callExpr.column);
                    return decl.returnType;
                }
                // Extern functions are excluded from functionCandidates
                // (see mangleFreeFunctionName) - still registered in
                // functionRegistry directly under their fixed bare name.
                string externResolved = resolveName(calleeIdent.name, (n) => (n in functionRegistry) !is null);
                if (auto funcDecl = externResolved in functionRegistry) {
                    return funcDecl.returnType;
                }
                string genericKey = findGenericTemplateKey(calleeIdent.name,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    auto resolution = resolveGenericFunctionCall(genericKey, callExpr.args, callExpr.argNames);
                    return functionRegistry[resolution.mangledName].returnType;
                }
                throw inferError(expr, format("Cannot infer type: unknown function '%s'", calleeIdent.name));
            }
            throw inferError(expr, "Cannot infer type of call expression");
        } else if (auto binExpr = cast(BinaryExpr)expr) {
            FunctionDecl binOpMethod = findOperatorMethodDecl(binExpr.left, binExpr.op, false);
            if (binOpMethod !is null) {
                return binOpMethod.returnType;
            }
            switch (binExpr.op) {
                case "==": case "!=": case "<": case ">": case "<=": case ">=":
                case "&&": case "||":
                    return new Type("bool");
                default:
                    return inferType(binExpr.left);
            }
        } else if (auto unaryExpr = cast(UnaryExpr)expr) {
            FunctionDecl unaryOpMethod = findOperatorMethodDecl(unaryExpr.operand, unaryExpr.op, true);
            if (unaryOpMethod !is null) {
                return unaryOpMethod.returnType;
            }
            if (unaryExpr.op == "!") {
                return new Type("bool");
            } else if (unaryExpr.op == "&") {
                // Address-of adds one level of indirection on top of
                // whatever the operand already was - &ptr where
                // ptr: int* yields int**, not int* again.
                Type inner = inferType(unaryExpr.operand);
                return new Type(inner.name, inner.pointerDepth + 1, inner.isArray, inner.arraySize);
            } else if (unaryExpr.op == "*") {
                Type inner = inferType(unaryExpr.operand);
                if (inner.pointerDepth == 0) {
                    throw inferError(expr, "Cannot infer type: dereferencing a non-pointer");
                }
                return new Type(inner.name, inner.pointerDepth - 1, inner.isArray, inner.arraySize);
            }
            return inferType(unaryExpr.operand);
        } else if (auto indexExpr = cast(IndexExpr)expr) {
            Type arrType = inferType(indexExpr.array);
            // Indexing consumes exactly one level of indirection: an
            // array's element keeps whatever pointer depth it already had
            // (int*[5] indexed gives int*, not int); a pointer's pointee
            // drops one level (int** indexed/dereferenced gives int*).
            if (arrType.isArray) {
                return new Type(arrType.name, arrType.pointerDepth, false, 0);
            }
            if (arrType.pointerDepth > 0) {
                return new Type(arrType.name, arrType.pointerDepth - 1, false, 0);
            }
            if (auto classDecl = arrType.name in classRegistry) {
                string methodName = operatorMethodName("[]", false);
                foreach (method; classDecl.methods) {
                    if (method.name == methodName) return method.returnType;
                }
            }
            throw inferError(expr, "Cannot infer type: indexing a non-array, non-pointer value");
        } else if (auto macroInvocation = cast(MacroInvocation)expr) {
            MacroDecl decl = resolveMacroInvocation(macroInvocation);
            QuoteExpr quoteExpr = macroQuoteBody(decl);
            if (quoteExpr is null || quoteExpr.isBlock) {
                throw inferError(expr, format("Macro '%s' does not expand to an expression", decl.name));
            }
            ASTNode expanded = expandQuotedNode(quoteExpr.body, macroSubstitutions(decl, macroInvocation));
            return inferType(expanded);
        }

        throw inferError(expr, "Cannot infer type of this expression; add an explicit type annotation");
    }

    // Maps a base LLPL primitive type name to its C equivalent, leaving
    // anything else (class names) unchanged. Shared by typeToC and the
    // array-declaration code paths, which need the base type without
    // typeToC's pointer-star handling.
    // "*" repeated once per level of indirection - shared by typeToC and
    // the array/bitfield declaration sites that hand-build a base-type
    // string instead of going through typeToC itself.
    private string pointerStars(Type t) {
        return "*".replicate(t.pointerDepth);
    }

    private string primitiveToC(string name) {
        switch (name) {
            case "int": return "int64_t";    // 64-bit integer
            case "uint": return "uint64_t";  // 64-bit unsigned
            case "int16": return "int16_t";
            case "uint16": return "uint16_t";
            case "int32": return "int32_t";
            case "uint32": return "uint32_t";
            case "char": return "char";
            case "string": return "char*";
            case "bool": return "int";
            case "void": return "void";
            default: return name;
        }
    }

    private string typeToC(Type type) {
        string cType = primitiveToC(type.name);

        // Classes are always heap-allocated and accessed by pointer; structs
        // are plain value types with no such auto-pointering.
        if (!isPrimitiveTypeName(type.name) && !isStructTypeName(type.name)) {
            if (!type.isPointer && !type.isArray) {
                cType ~= "*"; // Classes are always pointers
            }
        }

        cType ~= pointerStars(type);

        // Don't add array notation here - it's handled specially in var declarations
        // because C requires array size after variable name

        return cType;
    }
}
