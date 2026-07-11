module codegen;

import std.stdio;
import std.string;
import std.format;
import std.conv;
import std.array;
import std.algorithm;
import std.range;
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

class CodeGenerator {
    private int indentLevel;
    private string[] deferredStatements;
    private int tempVarCounter;
    private string currentClassName;
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
    private int macroExpansionDepth; // Guards against (possibly indirect) macro self-recursion
    private SymbolInfo[] collectedSymbols; // Declaration-site symbol table, built by generateMultiple; see symbols()
    private UsageInfo[] usageRecords; // Resolved reference sites, recorded via recordUsage; see usages()
    private int interpStringCounter; // Numbers each `\(...)` call site's scratch buffer uniquely
    private string[] interpBufferDecls; // `static char __llpl_interpN[SIZE];` decls, emitted up front
    private enum interpBufferSize = 256; // Scratch buffer size for one interpolated string's result
    private int lambdaCounter; // Numbers each lambda literal's env struct/trampoline function uniquely
    private string[] lambdaDecls; // Per-lambda `struct __LambdaEnvN {...};` + trampoline function decls, emitted up front
    private string[string] currentLambdaCaptureAccess; // Capture name -> "__env->name", set around a lambda body's generation

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
    private bool[string] monomorphizedInstances; // mangled instantiation name -> reserved/emitted, dedupes + guards recursion
    private string[] genericForwardDecls; // opaque struct tags / function prototypes, spliced before genericInstanceDecls
    private string[] genericInstanceDecls; // full monomorphized class/struct/function bodies, emitted up front

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
                fmt ~= interpFormatSpecifier(expr, interp.specs[i]);
                args ~= ", " ~ variadicPromote(expr, generateExpression(expr));
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
            } else if (auto macroDecl = cast(MacroDecl)decl) {
                macroDecl.namespaceSegments = segments;
                result ~= macroDecl;
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
                        genericFunctionTemplates[mangledFunc(funcDecl)] = funcDecl;
                        continue;
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.typeParams.length > 0) {
                        genericClassTemplates[mangledClass(classDecl)] = classDecl;
                        continue;
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    if (structDecl.typeParams.length > 0) {
                        genericStructTemplates[mangledStruct(structDecl)] = structDecl;
                        continue;
                    }
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
                    bool isTypeAlias = aliasDecl.targetIsPointer || aliasDecl.targetIsArray ||
                        (aliasDecl.targetPath.length == 1 && isPrimitiveTypeName(aliasDecl.targetPath[0]));
                    if (isTypeAlias) {
                        string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);
                        string baseName = aliasDecl.targetPath.join("_");
                        typeAliases[mangledName] = new Type(baseName, aliasDecl.targetIsPointer,
                            aliasDecl.targetIsArray, aliasDecl.targetArraySize);
                    }
                }
            }
        }
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    functionRegistry[mangledFunc(funcDecl)] = funcDecl;
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    classRegistry[mangledClass(classDecl)] = classDecl;
                } else if (auto structDecl = cast(StructDecl)decl) {
                    structRegistry[mangledStruct(structDecl)] = structDecl;
                } else if (auto macroDecl = cast(MacroDecl)decl) {
                    macroRegistry[mangled(macroDecl.namespaceSegments, macroDecl.name)] = macroDecl;
                } else if (auto varDecl = cast(VarDecl)decl) {
                    globalVarRegistry[mangled(varDecl.namespaceSegments, varDecl.name)] = varDecl;
                }
            }
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

        // Forward declarations for classes and structs from all modules
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    string cName = mangledClass(classDecl);
                    code ~= format("typedef struct %s %s;\n", cName, cName);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string sName = mangledStruct(structDecl);
                    code ~= format("typedef struct %s %s;\n", sName, sName);
                }
            }
        }
        code ~= "\n";

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
                        code ~= format("extern %s %s(%s);\n",
                            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                    } else if (funcDecl.isInterrupt) {
                        string params = "void* __frame";
                        if (funcDecl.params.length >= 1) {
                            resolveType(funcDecl.params[0].type);
                            params ~= format(", %s %s",
                                typeToC(funcDecl.params[0].type), funcDecl.params[0].name);
                        }
                        code ~= format("__attribute__((interrupt)) void %s(%s);\n",
                            mangledFunc(funcDecl), params);
                    } else {
                        resolveType(funcDecl.returnType);
                        string params = "";
                        foreach (i, param; funcDecl.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        code ~= format("%s %s(%s);\n",
                            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    string cName = mangledClass(classDecl);
                    // Constructor forward declaration
                    if (classDecl.constructor) {
                        string params = "";
                        foreach (i, param; classDecl.constructor.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= format("%s %s", typeToC(param.type), param.name);
                        }
                        code ~= format("%s* %s_new(%s);\n", cName, cName, params);
                    }

                    // Destructor forward declaration
                    if (classDecl.destructor) {
                        code ~= format("void %s_destroy(void* ptr);\n", cName);
                    }

                    // Method forward declarations
                    foreach (method; classDecl.methods) {
                        resolveType(method.returnType);
                        string params = format("%s* self", cName);
                        foreach (param; method.params) {
                            resolveType(param.type);
                            params ~= format(", %s %s", typeToC(param.type), param.name);
                        }
                        code ~= format("%s %s_%s(%s);\n",
                            typeToC(method.returnType), cName, method.name, params);
                    }
                }
            }
        }
        code ~= "\n";

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
                        if (varDecl.type.isPointer) baseType ~= "*";
                        code ~= format("extern %s%s %s[%d];\n", constPrefix, baseType, cName, varDecl.type.arraySize);
                    } else {
                        code ~= format("extern %s%s %s;\n", constPrefix, typeToC(varDecl.type), cName);
                    }
                }
            }
        }
        code ~= "\n";

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
                    code ~= generateAlias(aliasDecl);
                }
            }
        }
        code ~= "\n";

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
                declCode ~= generateDeclaration(decl);
                declCode ~= "\n";
            }
        }

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

        code ~= declCode;

        collectSymbolTable(programs);

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
        bool isTypeAlias = aliasDecl.targetIsPointer || aliasDecl.targetIsArray ||
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

    private string generateStruct(StructDecl structDecl) {
        string sName = mangledStruct(structDecl);
        currentNamespaceSegments = structDecl.namespaceSegments;

        string attr = structDecl.packed ? " __attribute__((packed))" : "";
        string code = format("struct%s %s {\n", attr, sName);
        foreach (field; structDecl.fields) {
            if (field.bitWidth >= 0) {
                code ~= format("    %s %s : %d;\n", typeToC(field.type), field.name, field.bitWidth);
            } else {
                code ~= format("    %s %s;\n", typeToC(field.type), field.name);
            }
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
        resolveType(varDecl.type);
        checkArrayLiteralInit(varDecl);
        string cName = mangled(varDecl.namespaceSegments, varDecl.name);
        variableTypes[cName] = varDecl.type;
        if (varDecl.isConst) {
            constVariables[cName] = true;
        }

        // Handle array declarations specially
        string constPrefix = (varDecl.isVolatile ? "volatile " : "") ~ (varDecl.isConst ? "const " : "");
        string code;
        if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
            string baseType = primitiveToC(varDecl.type.name);
            if (varDecl.type.isPointer) baseType ~= "*";
            code = format("%s%s %s[%d]", constPrefix, baseType, cName, varDecl.type.arraySize);
        } else {
            code = format("%s%s %s", constPrefix, typeToC(varDecl.type), cName);
        }

        if (varDecl.initializer) {
            code ~= " = " ~ generateExpression(varDecl.initializer);
        }
        code ~= ";\n";
        return code;
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
            if (field.bitWidth >= 0) {
                code ~= format("    %s %s : %d;\n", typeToC(field.type), field.name, field.bitWidth);
            } else {
                code ~= format("    %s %s;\n", typeToC(field.type), field.name);
            }
        }
        code ~= "};\n\n";

        // Generate constructor
        if (classDecl.constructor) {
            code ~= generateConstructor(classDecl, classDecl.constructor);
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

        code ~= format("%s* %s_new(%s) {\n", cName, cName, params);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n",
            cName, cName, cName);
        code ~= indent() ~ "if (!self) return NULL;\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n\n";

        // Generate constructor body
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

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

        // Generate destructor body
        if (destructor.body_) {
            foreach (stmt; destructor.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

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

        resolveType(method.returnType);
        foreach (param; method.params) {
            resolveType(param.type);
            params ~= format(", %s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }

        code ~= format("%s %s_%s(%s) {\n",
            typeToC(method.returnType), cName, method.name, params);
        indentLevel++;

        deferredStatements = [];

        if (method.body_) {
            foreach (stmt; method.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        // Add deferred statements before return
        if (deferredStatements.length > 0) {
            foreach_reverse (deferStmt; deferredStatements) {
                code ~= deferStmt;
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;

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
        resolveType(funcDecl.returnType);

        foreach (i, param; funcDecl.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= format("%s %s", typeToC(param.type), param.name);
            variableTypes[param.name] = param.type;
        }
        if (funcDecl.isVariadic) params ~= ", ...";

        code ~= format("%s %s(%s) {\n",
            typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
        indentLevel++;

        deferredStatements = [];

        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        // Replay deferred statements for a fall-off-the-end return (every
        // *explicit* `return` already replays them inline - see
        // generateStatement's ReturnStmt case - but a void function that
        // never writes one needs this too, the same as generateMethod
        // already does).
        if (deferredStatements.length > 0) {
            foreach_reverse (deferStmt; deferredStatements) {
                code ~= deferStmt;
            }
        }

        indentLevel--;
        code ~= "}\n";

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

        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                code ~= generateStatement(stmt, false);
            }
        }

        indentLevel--;
        code ~= "}\n";

        return code;
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
                if (varDecl.type.isPointer) baseType ~= "*";
                code ~= indent() ~ format("%s%s %s[%d]", constPrefix, baseType, varDecl.name, varDecl.type.arraySize);
            } else {
                code ~= indent() ~ format("%s%s %s", constPrefix, typeToC(varDecl.type), varDecl.name);
            }

            if (varDecl.initializer) {
                code ~= " = " ~ generateExpression(varDecl.initializer);
            }
            code ~= ";\n";
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
            // Execute deferred statements before return
            if (!isDeferred && deferredStatements.length > 0) {
                foreach_reverse (deferStmt; deferredStatements) {
                    code ~= deferStmt;
                }
            }
            code ~= indent() ~ "return";
            if (returnStmt.value) {
                code ~= " " ~ generateExpression(returnStmt.value);
            }
            code ~= ";\n";
        } else if (auto deferStmt = cast(DeferStmt)node) {
            // Store deferred statement for later
            string deferCode = generateStatement(deferStmt.statement, true);
            deferredStatements ~= deferCode;
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
                // Merge best-effort, same as resolveType's alias
                // substitution: a use site that also wrote its own
                // `*`/`[...]` on top of an already-pointer/array type
                // parameter binding just ORs the flags together (no way to
                // represent "pointer to pointer" in this single-flag Type
                // model, same limitation as everywhere else).
                auto merged = new Type(sub.name, t.isPointer || sub.isPointer, t.isArray || sub.isArray,
                    t.arraySize > 0 ? t.arraySize : sub.arraySize);
                merged.typeArgs = sub.typeArgs.map!(a => cloneType(a, typeSubs)).array;
                merged.closureParams = sub.closureParams;
                merged.closureReturnType = sub.closureReturnType;
                return merged;
            }
        }
        auto copy = new Type(t.name, t.isPointer, t.isArray, t.arraySize);
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
                callExpr.line, callExpr.column);
        } else if (auto memberExpr = cast(MemberExpr)node) {
            return new MemberExpr(cloneNode(memberExpr.object, subs, typeSubs), memberExpr.member,
                memberExpr.line, memberExpr.column);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            return new IndexExpr(cloneNode(indexExpr.array, subs, typeSubs), cloneNode(indexExpr.index, subs, typeSubs),
                indexExpr.line, indexExpr.column);
        } else if (auto newExpr = cast(NewExpr)node) {
            return new NewExpr(cloneType(newExpr.type, typeSubs), cloneNodes(newExpr.args, subs, typeSubs),
                newExpr.line, newExpr.column);
        } else if (auto castExpr = cast(CastExpr)node) {
            return new CastExpr(cloneType(castExpr.type, typeSubs), cloneNode(castExpr.expression, subs, typeSubs),
                castExpr.line, castExpr.column);
        } else if (auto sizeofExpr = cast(SizeofExpr)node) {
            return new SizeofExpr(cloneType(sizeofExpr.type, typeSubs), sizeofExpr.line, sizeofExpr.column);
        } else if (auto lambdaExpr = cast(LambdaExpr)node) {
            Parameter[] lps;
            foreach (p; lambdaExpr.params) lps ~= new Parameter(p.name, cloneType(p.type, typeSubs));
            return new LambdaExpr(lambdaExpr.captures.dup, lps, cloneType(lambdaExpr.returnType, typeSubs),
                cloneBlock(lambdaExpr.body_, subs, typeSubs), lambdaExpr.line, lambdaExpr.column);
        } else if (auto varDecl = cast(VarDecl)node) {
            return new VarDecl(varDecl.name, cloneType(varDecl.type, typeSubs), cloneNode(varDecl.initializer, subs, typeSubs),
                varDecl.isConst, varDecl.line, varDecl.column, varDecl.bitWidth, varDecl.isVolatile);
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
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(cloneNode(returnStmt.value, subs, typeSubs));
        } else if (auto deferStmt = cast(DeferStmt)node) {
            return new DeferStmt(cloneNode(deferStmt.statement, subs, typeSubs));
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
        foreach (p; fn.params) params ~= new Parameter(p.name, cloneType(p.type, typeSubs));
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
        FunctionDecl ctor = cls.constructor is null ? null :
            cloneFunctionDeclWithTypeSubs(cls.constructor, typeSubs, cls.constructor.name);
        FunctionDecl dtor = cls.destructor is null ? null :
            cloneFunctionDeclWithTypeSubs(cls.destructor, typeSubs, cls.destructor.name);
        FunctionDecl[] methods;
        foreach (m; cls.methods) methods ~= cloneFunctionDeclWithTypeSubs(m, typeSubs, m.name);
        auto clone = new ClassDecl(newName, fields, ctor, dtor, methods, cls.line, cls.column);
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
                expandQuotedNodes(callExpr.args, subs), callExpr.line, callExpr.column);
        } else if (auto memberExpr = cast(MemberExpr)node) {
            return new MemberExpr(expandQuotedNode(memberExpr.object, subs), memberExpr.member,
                memberExpr.line, memberExpr.column);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            return new IndexExpr(expandQuotedNode(indexExpr.array, subs),
                expandQuotedNode(indexExpr.index, subs), indexExpr.line, indexExpr.column);
        } else if (auto newExpr = cast(NewExpr)node) {
            return new NewExpr(cloneType(newExpr.type), expandQuotedNodes(newExpr.args, subs),
                newExpr.line, newExpr.column);
        } else if (auto castExpr = cast(CastExpr)node) {
            return new CastExpr(cloneType(castExpr.type), expandQuotedNode(castExpr.expression, subs),
                castExpr.line, castExpr.column);
        } else if (auto varDecl = cast(VarDecl)node) {
            return new VarDecl(varDecl.name, cloneType(varDecl.type),
                expandQuotedNode(varDecl.initializer, subs), varDecl.isConst,
                varDecl.line, varDecl.column, varDecl.bitWidth, varDecl.isVolatile);
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
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(expandQuotedNode(returnStmt.value, subs));
        } else if (auto deferStmt = cast(DeferStmt)node) {
            return new DeferStmt(expandQuotedNode(deferStmt.statement, subs));
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
            case "char": case "bool": case "void":
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

    // Fills in `varDecl.type.arraySize` from an array-literal initializer
    // when none was given (`let arr: char[] = [1, 2, 3]`), or checks it
    // matches when one was (`let arr: char[8] = [...]` needs exactly 8
    // elements) - called for both local (generateStatement) and global
    // (generateGlobalVar) `let`/`const` declarations. A no-op unless the
    // initializer is actually an ArrayLiteral.
    private void checkArrayLiteralInit(VarDecl varDecl) {
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

    // The instantiation-suffix fragment for one concrete type argument,
    // e.g. Type("int") -> "int", Type("char", isPointer: true) -> "char_ptr".
    // By the time this runs, a nested generic argument (Vector<Vector<int>>)
    // has already had its own name rewritten to its mangled instantiation
    // name by the recursive resolveType call in instantiateGenericTypeArgs,
    // so this never needs to recurse into typeArgs itself.
    private string mangleTypeArg(Type t) {
        string s = t.name;
        if (t.isPointer) s ~= "_ptr";
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
        string templateLeafName = isClass ?
            genericClassTemplates[templateKey].name : genericStructTemplates[templateKey].name;
        string[] templateNamespaceSegments = isClass ?
            genericClassTemplates[templateKey].namespaceSegments : genericStructTemplates[templateKey].namespaceSegments;

        if (typeArgs.length != templateTypeParams.length) {
            throw new CompileError(format("Generic type '%s' expects %d type argument(s), got %d",
                templateKey, templateTypeParams.length, typeArgs.length), currentModulePath, 0, 0);
        }

        string mangledName = mangled(templateNamespaceSegments, instantiatedLeafName(templateLeafName, typeArgs));

        if (mangledName !in monomorphizedInstances) {
            monomorphizedInstances[mangledName] = true; // reserve before generating the body - guards
                                                          // self-referential fields from re-triggering
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
                if (clone.constructor) {
                    string ctorParams = "";
                    foreach (i, param; clone.constructor.params) {
                        resolveType(param.type);
                        if (i > 0) ctorParams ~= ", ";
                        ctorParams ~= format("%s %s", typeToC(param.type), param.name);
                    }
                    genericForwardDecls ~= format("%s* %s_new(%s);\n", mangledName, mangledName, ctorParams);
                }
                if (clone.destructor) {
                    genericForwardDecls ~= format("void %s_destroy(void* ptr);\n", mangledName);
                }
                foreach (method; clone.methods) {
                    resolveType(method.returnType);
                    string methodParams = format("%s* self", mangledName);
                    foreach (param; method.params) {
                        resolveType(param.type);
                        methodParams ~= format(", %s %s", typeToC(param.type), param.name);
                    }
                    genericForwardDecls ~= format("%s %s_%s(%s);\n",
                        typeToC(method.returnType), mangledName, method.name, methodParams);
                }

                genericInstanceDecls ~= generateClass(clone);
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
    private string resolveGenericFunctionCall(string templateKey, ASTNode[] args) {
        FunctionDecl tmpl = genericFunctionTemplates[templateKey];

        Type[string] bindings;
        foreach (i, param; tmpl.params) {
            if (tmpl.typeParams.canFind(param.type.name) && (param.type.name in bindings) is null
                    && i < args.length) {
                bindings[param.type.name] = inferType(args[i]);
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
            resolveType(clone.returnType);
            genericForwardDecls ~= format("%s %s(%s);\n", typeToC(clone.returnType), mangledName, protoParams);

            functionRegistry[mangledName] = clone;
            genericInstanceDecls ~= generateFunction(clone);
        }

        return mangledName;
    }

    // Resolves a possibly-unqualified class type name to its mangled form
    // in place, the same way resolveName does for functions/variables, so a
    // namespaced class can be referenced unqualified (or partially qualified)
    // from sibling code in that namespace. No-op for primitives or names that
    // are already fully qualified/unresolvable.
    private void resolveType(Type t) {
        if (t is null) return;
        if (auto aliased = t.name in typeAliases) {
            // Substitute the alias's own type in place. `||`/best-effort
            // merge, not a proper multi-level pointer: if the use site
            // *also* wrote `*`/`[...]` on an already-pointer/array alias
            // (`string*` where `string` is `char*`), there's no way to
            // represent "pointer to pointer" in this single-flag Type
            // model - same limitation as everywhere else in the language.
            t.name = aliased.name;
            t.isPointer = t.isPointer || aliased.isPointer;
            t.isArray = t.isArray || aliased.isArray;
            if (aliased.arraySize > 0) t.arraySize = aliased.arraySize;
        }

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

    // `foreach let x in iterable { ... }` desugars to either a counted
    // index loop (iterable is a fixed-size array) or a has_next/next loop
    // (iterable is a class implementing the iterator protocol above) -
    // whichever matches is decided purely from iterable's inferred type,
    // the same way operator overloading is resolved from an operand's type.
    private string generateForeachStmt(ForeachStmt foreachStmt, bool isDeferred) {
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
            FunctionDecl hasNextMethod = findIterMethod(*classDecl, ITER_HAS_NEXT);
            FunctionDecl nextMethod = findIterMethod(*classDecl, ITER_NEXT);
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

        if (findIterMethod(classDecl, ITER_RESET) !is null) {
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

    // Finds the operator-overload method (see ast.operatorMethodName) a
    // class defines for `op`, given the left/self operand's inferred type.
    // Returns null if there isn't one - the caller falls back to the plain
    // C operator.
    private FunctionDecl findOperatorMethod(ASTNode selfOperand, string op, bool isUnary) {
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
        } catch (Exception e) {
            // fall through - not an overload
        }
        return null;
    }

    private string tryBinaryOperatorOverloadCall(BinaryExpr binExpr) {
        FunctionDecl method = findOperatorMethod(binExpr.left, binExpr.op, false);
        if (method is null) return "";
        Type selfType = inferType(binExpr.left);
        resolveType(selfType);
        return format("%s_%s(%s, %s)", selfType.name, method.name,
            generateExpression(binExpr.left), generateExpression(binExpr.right));
    }

    private string tryUnaryOperatorOverloadCall(UnaryExpr unaryExpr) {
        FunctionDecl method = findOperatorMethod(unaryExpr.operand, unaryExpr.op, true);
        if (method is null) return "";
        Type selfType = inferType(unaryExpr.operand);
        resolveType(selfType);
        return format("%s_%s(%s)", selfType.name, method.name, generateExpression(unaryExpr.operand));
    }

    // Same idea as tryBinaryOperatorOverloadCall, for `arr[index]` where
    // `arr` is a class instance defining `operator[]` (op_index). Read-only:
    // there's no op_index= counterpart, so this never fires for the left
    // side of an assignment in a way that would need an lvalue - see
    // ast.operatorMethodName's doc comment.
    private string tryIndexOperatorOverloadCall(IndexExpr indexExpr) {
        FunctionDecl method = findOperatorMethod(indexExpr.array, "[]", false);
        if (method is null) return "";
        Type selfType = inferType(indexExpr.array);
        resolveType(selfType);
        return format("%s_%s(%s, %s)", selfType.name, method.name,
            generateExpression(indexExpr.array), generateExpression(indexExpr.index));
    }

    // Tries to resolve a dotted chain as a namespace-qualified reference
    // (checked via `exists`, e.g. against functionRegistry or variableTypes)
    // rather than instance member access. Returns "" if it isn't one.
    private string tryResolveQualifiedPath(ASTNode expr, bool delegate(string) exists) {
        string root = leftmostName(expr);
        if (root.length == 0 || (root in variableTypes)) {
            return ""; // root is a real local/instance variable; prefer normal member access
        }

        string flat = flattenPath(expr);
        if (flat.length == 0) return "";

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
    // one) without prefixing.
    private string resolveName(string name, bool delegate(string) exists) {
        if (exists(name)) return name;
        foreach (candidate; enclosingQualifications(name)) {
            if (exists(candidate)) return candidate;
        }
        return name;
    }

    // `func[cap1, cap2](params) -> T { ... }` - see ast.d's LambdaExpr and
    // runtime.h's __LLPL_Closure for the overall design: every closure
    // shares the same two-word {fn, env} runtime representation regardless
    // of its signature, so this only needs to synthesize a per-lambda
    // environment struct (one field per capture) and a trampoline function
    // taking that environment (cast back from void*) as an extra leading
    // parameter, then return a single C expression building the closure
    // value - its env allocated fresh, by value, from the *current* value
    // of each captured variable (a snapshot, never a live reference back
    // into the enclosing scope).
    private string generateLambdaExpr(LambdaExpr lambdaExpr) {
        int id = lambdaCounter++;
        string envType = format("__LambdaEnv%d", id);
        string trampolineName = format("__lambda%d", id);

        resolveType(lambdaExpr.returnType);
        foreach (p; lambdaExpr.params) resolveType(p.type);

        // Resolve each capture's current type and the C expression that
        // reads its current value. A capture named in currentLambdaCaptureAccess
        // is itself an outer lambda's own capture (a lambda nested in
        // another lambda's body, re-capturing one of the enclosing
        // lambda's captures) - otherwise it's an ordinary in-scope
        // variable, resolved the same way any other identifier is.
        Type[] captureTypes;
        string[] captureAccess;
        foreach (cap; lambdaExpr.captures) {
            string accessExpr;
            Type capType;
            if (auto outerAccess = cap in currentLambdaCaptureAccess) {
                accessExpr = *outerAccess;
                capType = variableTypes[cap];
            } else {
                string resolved = resolveName(cap, (n) => (n in variableTypes) !is null);
                if ((resolved in variableTypes) is null) {
                    throw new CompileError(format("Unknown capture '%s'", cap),
                        currentModulePath, lambdaExpr.line, lambdaExpr.column);
                }
                accessExpr = resolved;
                capType = variableTypes[resolved];
            }
            captureAccess ~= accessExpr;
            captureTypes ~= capType;
        }

        string envDecl = "typedef struct {\n";
        foreach (i, cap; lambdaExpr.captures) {
            envDecl ~= format("    %s %s;\n", typeToC(captureTypes[i]), cap);
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
        // function's variableTypes once it's done generating (the same
        // param-leak discipline every other generator function follows).
        string[] savedDeferred = deferredStatements;
        deferredStatements = [];
        string[string] savedCaptureAccess = currentLambdaCaptureAccess.dup;

        foreach (i, cap; lambdaExpr.captures) {
            currentLambdaCaptureAccess[cap] = format("__env->%s", cap);
            variableTypes[cap] = captureTypes[i];
        }
        foreach (p; lambdaExpr.params) {
            variableTypes[p.name] = p.type;
        }

        int savedIndent = indentLevel;
        indentLevel = 1;
        foreach (stmt; lambdaExpr.body_.statements) {
            trampolineCode ~= generateStatement(stmt, false);
        }
        if (deferredStatements.length > 0) {
            foreach_reverse (deferStmt; deferredStatements) {
                trampolineCode ~= deferStmt;
            }
        }
        indentLevel = savedIndent;

        foreach (cap; lambdaExpr.captures) {
            variableTypes.remove(cap);
        }
        foreach (p; lambdaExpr.params) {
            variableTypes.remove(p.name);
        }
        currentLambdaCaptureAccess = savedCaptureAccess;
        deferredStatements = savedDeferred;

        trampolineCode ~= "}\n";

        lambdaDecls ~= envDecl;
        lambdaDecls ~= trampolineCode;
        lambdaDecls ~= "\n";

        string envInit = format("({ %s* __e = (%s*)rc_alloc(sizeof(%s)); ", envType, envType, envType);
        foreach (i, cap; lambdaExpr.captures) {
            envInit ~= format("__e->%s = %s; ", cap, captureAccess[i]);
        }
        envInit ~= "(void*)__e; })";

        return format("((__LLPL_Closure){ .fn = (void*)%s, .env = %s })", trampolineName, envInit);
    }

    private string generateExpression(ASTNode node) {
        if (auto binExpr = cast(BinaryExpr)node) {
            if (binExpr.op == "=") {
                checkNotConstAssignment(binExpr.left);
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
        } else if (auto callExpr = cast(CallExpr)node) {
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
                string cargs = format("(%s).env", calleeCode);
                foreach (arg; callExpr.args) {
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
                string mangledName = resolveGenericFunctionCall(genericTemplateKey, callExpr.args);
                recordUsage(mangledName, callExpr.line, callExpr.column);
                string gargs = "";
                foreach (i, arg; callExpr.args) {
                    if (i > 0) gargs ~= ", ";
                    gargs ~= generateExpression(arg);
                }
                return format("%s(%s)", mangledName, gargs);
            }
            // Check if this is a method call
            if (auto memberExpr = cast(MemberExpr)callExpr.callee) {
                // A namespace-qualified function call (e.g. Graphics.helper())
                // takes priority over instance-method-call syntax.
                string qualifiedFunc = tryResolveQualifiedPath(memberExpr,
                    (n) => (n in functionRegistry) !is null);
                if (qualifiedFunc.length == 0) {
                    qualifiedFunc = tryResolveExternFunctionMember(memberExpr);
                }
                if (qualifiedFunc.length > 0) {
                    recordUsage(qualifiedFunc, memberExpr.line, memberExpr.column);
                    FunctionDecl qualifiedDecl = functionRegistry[qualifiedFunc];
                    string qargs = "";
                    foreach (i, arg; callExpr.args) {
                        if (i > 0) qargs ~= ", ";
                        string argCode = generateExpression(arg);
                        if (qualifiedDecl.isVariadic && i >= qualifiedDecl.params.length) {
                            argCode = variadicPromote(arg, argCode);
                        }
                        qargs ~= argCode;
                    }
                    return format("%s(%s)", qualifiedFunc, qargs);
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
                    className = inferType(memberExpr.object).name;
                } catch (Exception e) {
                    // fall through - className stays "", falls back to the
                    // CLASS_ placeholder below
                }

                // Generate method call with object as first parameter
                string args = objectExpr;
                foreach (arg; callExpr.args) {
                    args ~= ", " ~ generateExpression(arg);
                }

                if (className.length > 0) {
                    recordUsage(className ~ "." ~ methodName, memberExpr.line, memberExpr.column);
                    return format("%s_%s(%s)", className, methodName, args);
                } else {
                    return format("CLASS_%s(%s)", methodName, args);
                }
            } else {
                // generateExpression(callExpr.callee) already records this as a
                // plain Identifier usage (see that branch below) - no separate
                // recordUsage needed here.
                string callee = generateExpression(callExpr.callee);
                FunctionDecl calleeDecl = resolveCalledFunction(callExpr.callee);
                string args = "";
                foreach (i, arg; callExpr.args) {
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
            if (auto access = ident.name in currentLambdaCaptureAccess) {
                return *access;
            }
            string resolved = resolveName(ident.name,
                (n) => (n in variableTypes) !is null || (n in functionRegistry) !is null);
            recordUsage(resolved, ident.line, ident.column);
            return resolved;
        } else if (auto intLit = cast(IntLiteral)node) {
            return to!string(intLit.value);
        } else if (auto strLit = cast(StringLiteral)node) {
            return format("\"%s\"", escapeCString(strLit.value));
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
            string args = "";
            foreach (i, arg; newExpr.args) {
                if (i > 0) args ~= ", ";
                args ~= generateExpression(arg);
            }
            return format("%s_new(%s)", newExpr.type.name, args);
        } else if (auto castExpr = cast(CastExpr)node) {
            resolveType(castExpr.type);
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
            if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                string qualifiedFunc = tryResolveQualifiedPath(memberCallee, (n) => (n in functionRegistry) !is null);
                if (qualifiedFunc.length == 0) {
                    qualifiedFunc = tryResolveExternFunctionMember(memberCallee);
                }
                if (qualifiedFunc.length > 0) {
                    return functionRegistry[qualifiedFunc].returnType;
                }

                string genericKey = tryResolveQualifiedPath(memberCallee,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    string mangledName = resolveGenericFunctionCall(genericKey, callExpr.args);
                    return functionRegistry[mangledName].returnType;
                }

                Type objType = inferType(memberCallee.object);
                if (auto classDecl = objType.name in classRegistry) {
                    foreach (method; classDecl.methods) {
                        if (method.name == memberCallee.member) {
                            return method.returnType;
                        }
                    }
                }
                throw inferError(expr, format("Cannot infer type: unknown method '%s'", memberCallee.member));
            } else if (auto calleeIdent = cast(Identifier)callExpr.callee) {
                string resolvedVar = resolveName(calleeIdent.name, (n) => (n in variableTypes) !is null);
                if (resolvedVar in variableTypes && variableTypes[resolvedVar].closureReturnType !is null) {
                    return variableTypes[resolvedVar].closureReturnType;
                }
                string resolved = resolveName(calleeIdent.name, (n) => (n in functionRegistry) !is null);
                if (auto funcDecl = resolved in functionRegistry) {
                    return funcDecl.returnType;
                }
                string genericKey = findGenericTemplateKey(calleeIdent.name,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    string mangledName = resolveGenericFunctionCall(genericKey, callExpr.args);
                    return functionRegistry[mangledName].returnType;
                }
                throw inferError(expr, format("Cannot infer type: unknown function '%s'", calleeIdent.name));
            }
            throw inferError(expr, "Cannot infer type of call expression");
        } else if (auto binExpr = cast(BinaryExpr)expr) {
            FunctionDecl binOpMethod = findOperatorMethod(binExpr.left, binExpr.op, false);
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
            FunctionDecl unaryOpMethod = findOperatorMethod(unaryExpr.operand, unaryExpr.op, true);
            if (unaryOpMethod !is null) {
                return unaryOpMethod.returnType;
            }
            if (unaryExpr.op == "!") {
                return new Type("bool");
            } else if (unaryExpr.op == "&") {
                Type inner = inferType(unaryExpr.operand);
                return new Type(inner.name, true, inner.isArray, inner.arraySize);
            } else if (unaryExpr.op == "*") {
                Type inner = inferType(unaryExpr.operand);
                if (!inner.isPointer) {
                    throw inferError(expr, "Cannot infer type: dereferencing a non-pointer");
                }
                return new Type(inner.name, false, inner.isArray, inner.arraySize);
            }
            return inferType(unaryExpr.operand);
        } else if (auto indexExpr = cast(IndexExpr)expr) {
            Type arrType = inferType(indexExpr.array);
            if (arrType.isArray || arrType.isPointer) {
                return new Type(arrType.name, false, false, 0);
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
    private string primitiveToC(string name) {
        switch (name) {
            case "int": return "int64_t";    // 64-bit integer
            case "uint": return "uint64_t";  // 64-bit unsigned
            case "int16": return "int16_t";
            case "uint16": return "uint16_t";
            case "int32": return "int32_t";
            case "uint32": return "uint32_t";
            case "char": return "char";
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

        if (type.isPointer) {
            cType ~= "*";
        }

        // Don't add array notation here - it's handled specially in var declarations
        // because C requires array size after variable name

        return cType;
    }
}
