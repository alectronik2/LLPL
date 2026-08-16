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
import std.datetime.stopwatch;
import ast;
import errors;
import grammar;

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

struct LocalInfo {
    string name;
    string type;
    string file;
    int line;
    int column;
    string scopeName;
    string kind; // "parameter", "local", or "self"
}

// Conservative per-function capability/effect summary. This is intentionally
// a compiler side-channel rather than new syntax for now: audit/debug tooling
// can consume it today, and later language-level capability checks can reuse
// the same walker.
struct EffectInfo {
    string name;
    string kind; // "function", "method", "constructor", "destructor"
    string file;
    int line;
    int column;
    string[] effects; // sorted labels: alloc, asm, cache, dma, ffi, mmio, paging, panic, throw, unsafe
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

private struct AsyncCallInfo {
    FunctionDecl fn;
    string baseName;
    string usageName;
    ASTNode usageNode;
    ASTNode[] argsWithReceiver;
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
    // Library names requested by `#link "NAME"` directives (see LinkDecl),
    // in first-seen order, deduplicated. Populated by generateMultiple;
    // read by main.d's --binary mode to pass `-l<name>` to the system C
    // compiler. Public since main.d has no other reason to reach into the
    // generator's internals.
    string[] linkLibraries;

    // Raw compiler flags requested by `#flags "..."` directives (see
    // FlagsDecl), in first-seen order, deduplicated - same mechanism and
    // caller (main.d's --binary mode) as linkLibraries, just for arbitrary
    // extra flags (`-O2`, `-Wall`, a `-D` define, ...) instead of `-l`.
    string[] compilerFlags;

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
    private string currentScopeName;
    private Type currentReturnType; // Enclosing function/method/lambda's declared return type, for ReturnStmt's nullable-sugar auto-wrap (see generateNullableWrap)
    private Type currentReturnTypeAsWritten; // Same, but a clone captured *before* resolveType mutated it - see resolveStructLiteralTarget
    private string currentModulePath; // Module whose code is currently being generated, for error citations
    private string[] currentNamespaceSegments; // Enclosing namespace path of the declaration being generated
    // The *template's* original namespace, for resolving a sibling generic
    // type mentioned anywhere inside a monomorphized clone's body (fields,
    // constructor/method signatures, and - unlike currentNamespaceSegments,
    // which generateClass/generateMethod overwrite back to the clone's own
    // always-empty namespaceSegments before generating each method body,
    // see cloneClassDeclWithTypeSubs's own comment - method *bodies* too).
    // Set (and restored) around one instantiateGenericTypeArgs call in
    // resolveType's typeArgs branch; enclosingQualifications below tries it
    // in addition to currentNamespaceSegments. Needed for e.g. Queue<T>
    // (namespace std.collections) whose own field type DoublyLinkedList<T>
    // is a sibling generic in that same namespace, whose *own* fields/
    // methods in turn reference another sibling, DListNode<T> - three
    // levels deep, all needing the same original namespace to resolve
    // long after currentNamespaceSegments has been cleared for mangling.
    private string[] currentGenericTemplateNamespace;
    private string[][string] moduleUsingNamespaces; // Maps module path to list of using-namespace declarations (each is "Foo.Bar")
    private Type[string] variableTypes; // Maps variable names to their types
    // Source variable name -> the C identifier it currently emits as. Only
    // populated by a plain `let name = ...` (generateStatement's VarDecl
    // case) - re-`let`ing a name already in variableTypes shadows it (C has
    // no such concept: two declarations of the same name in one block is a
    // hard "redefinition" error), so the *emitted* name gets a fresh unique
    // suffix instead, recorded here so every later reference to `name` (see
    // generateExpression's Identifier case) picks up the shadowed variable,
    // not the original. Absent for anything that was never `let`-declared
    // (function/method/constructor params, `self`, ...) - those still
    // resolve exactly as before.
    private string[string] variableCNames;
    private int shadowRenameCounter;
    private int[string] pointerIndexBounds;
    // RAII tracking for the function/method/constructor body currently
    // being generated - see generateStatement's VarDecl case (registers +
    // retains-on-alias), generateReturnStmt (releases everything except a
    // directly-returned identifier), generateDeleteStmt (deregisters), and
    // every function-body-generating site's own trailing "release what's
    // still live" emission. Only tracks a `let` declared directly in the
    // function/method/constructor/destructor body's own top-level statement
    // list (gated by `indentLevel == rcFunctionBodyIndent`, recorded right
    // after that body's own opening brace) - NOT one nested inside an
    // `if`/`while`/`for`/etc: real C block scoping means a variable
    // declared inside a nested `{ ... }` no longer exists once that block's
    // own closing brace has run, so releasing it from code emitted at the
    // *function's* closing brace (outside that inner block) would reference
    // an out-of-scope C identifier - a hard compile error, not just
    // imprecise (this was caught for real: prelude.llpl's
    // Regex.replace_all's `let m = it.iter_next()`, declared inside a
    // `while`, broke the build before this gating was added). A top-level
    // local's own release code, by contrast, is always valid from any point
    // in the function (including inside a nested block that returns) since
    // C always lets an inner block see its enclosing scope's locals. Net
    // effect: this fixes the reported bug (RAII for locals declared
    // directly in a function body, the common case) without attempting
    // real per-block scope tracking - a nested-block class-typed local
    // still just leaks exactly as it did before this feature existed, a
    // pre-existing gap, not a new regression.
    private string[] rcLocalNames;
    private Type[] rcLocalTypes;
    private int rcFunctionBodyIndent = -1;

    private bool isRcManagedType(Type t) {
        return !isPrimitiveTypeName(t.name) && !t.isPointer && !t.isArray &&
            !isStructTypeName(t.name) && !isUnionTypeName(t.name);
    }

    private void trackRcLocal(string emitName, Type type) {
        rcLocalNames ~= emitName;
        rcLocalTypes ~= type;
    }

    // Stops tracking `emitName` (used by `delete`, so a later function-exit
    // release doesn't double-release something already explicitly deleted).
    private void untrackRcLocal(string emitName) {
        foreach (i, name; rcLocalNames) {
            if (name == emitName) {
                rcLocalNames = rcLocalNames[0 .. i] ~ rcLocalNames[i + 1 .. $];
                rcLocalTypes = rcLocalTypes[0 .. i] ~ rcLocalTypes[i + 1 .. $];
                break;
            }
        }
    }

    // Emits `rc_release` for every currently-tracked local, in reverse
    // declaration order, skipping `exceptName` (the "move" exception for a
    // bare-identifier `return`). Does NOT itself mutate rcLocalNames - the
    // two call sites (mid-function early return, and true end-of-body) have
    // different needs: a `return` may run this several times (once per
    // early exit) while more locals are still yet to be declared further
    // down in the same function, so untracking here would incorrectly
    // "forget" a local that a *later* return in the same function still
    // needs to release too.
    // Whether `expr` reads an *existing* reference (a variable, a field, or
    // a container element) rather than producing a fresh one - the former
    // needs an `rc_retain` when it's copied into a new owning slot (a `let`
    // or a plain reassignment), since something else already owns it and
    // will release its own copy independently; a `new X(...)` call or any
    // function/method call result is assumed fresh (the callee either just
    // allocated it, or - like Rc<T>.clone() - already transferred a real
    // retained reference to the caller), so retaining those too would leak
    // a reference that's never released. This can't be proven sound in
    // general (a method that returns `self` for chaining and gets bound to
    // a persistent `let` would be mis-classified as fresh) - no code in
    // this codebase does that today, so it's not a new bug in practice,
    // just a known sharp edge if a future chaining API gets `let`-bound.
    private bool isAliasingRcExpr(ASTNode expr) {
        return cast(Identifier)expr !is null || cast(MemberExpr)expr !is null ||
            cast(IndexExpr)expr !is null;
    }

    // --- Owned RC temporaries inside a single expression -----------------
    //
    // A call that returns a class type hands back a fresh reference nobody
    // owns: `if s.byte_substring(0, 5) == "hi"` allocates a String, compares
    // it, and drops the only pointer to it. rcLocalNames above only covers
    // values bound to a `let`, so these intermediates used to leak outright -
    // fatal on the 1MB heap once a loop runs a few thousand times.
    //
    // The fix wraps the whole expression in a statement-expression holding
    // one NULL-initialised slot per temporary. Each producing subexpression
    // becomes `(__llpl_rctmp0 = <call>)` *in place*, so evaluation order and
    // `&&`/`||` short-circuiting are untouched - a temp whose branch never
    // ran simply stays NULL and its guarded release is a no-op.
    // Whether the expression currently being generated sits in a position
    // where releasing a temporary is safe. It is *not* safe in an argument
    // list: `tokens.push(new CToken(...))` looks like a discarded statement,
    // but push stores the argument, so freeing it afterwards would hand the
    // vector a dangling element. Since a callee taking ownership can't be
    // seen from the call site, argument position simply opts out and keeps
    // the old leak. Comparison operands are the safe, common case worth
    // capturing - `s.trim() == "x"` compares and drops.
    private bool rcTempEligible;
    private bool rcTempActive;
    private string[] rcTempDecls;
    private string[] rcTempReleases;
    private int rcTempCounter;
    // The one node a scope must *not* capture: when the expression's own
    // result is being stored (a `let` initialiser, `return`, assignment RHS),
    // ownership transfers to that slot, so releasing it here would hand the
    // caller a dangling pointer.
    private ASTNode rcTempExcludedRoot;

    // C symbols whose LLPL definition provably returns a *fresh* reference.
    // Built once up front by ownedReturnSymbols below.
    //
    // Not every call result is safe to release: a chaining method like
    // stringstream's `operator<<` hands back `self`, so releasing it would
    // destroy an object the caller still owns. Since that can't be decided
    // from the call site, it's decided from the callee - and anything this
    // table can't account for (extern C, closures, function pointers) is
    // treated as borrowed, which is the pre-existing leak rather than a new
    // double-free.
    private bool[string] rcOwnedReturnSymbols;

    // A function returns a borrowed reference when any `return` hands back
    // something somebody else already owns - `self` (the chaining pattern),
    // one of its parameters, a field, or a container element.
    //
    // Note this is deliberately narrower than isAliasingRcExpr, which treats
    // every bare identifier as an alias: returning a *local* is a move (the
    // local's own release is skipped for exactly that reason - see
    // releaseRcLocals' exceptName), so `let r = new String(...); return r`
    // still hands the caller a fresh reference it owns.
    private bool returnsBorrowedReference(FunctionDecl fn) {
        if (fn.body_ is null) return true;
        bool[string] paramNames;
        foreach (p; fn.params) paramNames[p.name] = true;

        bool borrowed = false;
        void walk(ASTNode n) {
            if (n is null || borrowed) return;
            if (auto ret = cast(ReturnStmt)n) {
                if (ret.value is null) return;
                if (auto id = cast(Identifier)ret.value) {
                    if (id.name == "self" || (id.name in paramNames) !is null) {
                        borrowed = true;
                    }
                } else if (cast(MemberExpr)ret.value !is null ||
                        cast(IndexExpr)ret.value !is null) {
                    borrowed = true;
                }
                return;
            }
            if (auto blk = cast(Block)n) {
                foreach (s; blk.statements) walk(s);
            } else if (auto ifs = cast(IfStmt)n) {
                walk(ifs.thenBlock);
                walk(ifs.elseBlock);
            } else if (auto wh = cast(WhileStmt)n) {
                walk(wh.body_);
            } else if (auto dw = cast(DoWhileStmt)n) {
                walk(dw.body_);
            } else if (auto fs = cast(ForStmt)n) {
                walk(fs.body_);
            }
        }
        walk(fn.body_);
        return borrowed;
    }

    private void buildRcOwnedReturnSymbols() {
        foreach (mangled, fn; functionRegistry) {
            if (fn.returnType is null || !isRcManagedType(fn.returnType)) continue;
            if (!returnsBorrowedReference(fn)) {
                rcOwnedReturnSymbols[mangled] = true;
            }
        }
        foreach (mangled, cd; classRegistry) {
            string cName = mangled;
            foreach (m; cd.methods) {
                if (m.returnType is null || !isRcManagedType(m.returnType)) continue;
                if (!returnsBorrowedReference(m)) {
                    rcOwnedReturnSymbols[mangleMethodName(cd, cName, m)] = true;
                }
            }
        }
    }

    // Pulls `Foo_bar` out of generated text like `Foo_bar(a, b)`. Returns ""
    // for anything that isn't a plain direct call.
    private string leadingCallSymbol(string code) {
        size_t i = 0;
        while (i < code.length && (code[i] == '_' ||
                (code[i] >= 'a' && code[i] <= 'z') ||
                (code[i] >= 'A' && code[i] <= 'Z') ||
                (i > 0 && code[i] >= '0' && code[i] <= '9'))) {
            i++;
        }
        if (i == 0 || i >= code.length || code[i] != '(') return "";
        return code[0 .. i];
    }

    // Whether `node` hands back a brand-new reference that nothing else will
    // ever release. `new X(...)` always allocates; a call only counts when
    // the callee is in rcOwnedReturnSymbols (see above).
    private bool producesOwnedRcTemp(ASTNode node, string generated) {
        if (cast(NewExpr)node !is null) return true;
        if (cast(CallExpr)node is null) return false;
        string sym = leadingCallSymbol(generated);
        return sym.length > 0 && (sym in rcOwnedReturnSymbols) !is null;
    }

    private Type tryInferType(ASTNode node) {
        try {
            return inferType(node);
        } catch (Exception e) {
            return null;
        }
    }

    // Runs `gen` with temp collection enabled and wraps the result so every
    // captured temporary is released once the expression has been consumed.
    // `resultCType` is the C type of the whole expression, or "" when its
    // value is discarded (an expression statement) - the discarding form
    // avoids having to name a type for a `void` call.
    private string rcTempScope(ASTNode excludedRoot, string resultCType, string delegate() gen) {
        bool savedActive = rcTempActive;
        string[] savedDecls = rcTempDecls;
        string[] savedReleases = rcTempReleases;
        ASTNode savedExcluded = rcTempExcludedRoot;

        bool savedEligible = rcTempEligible;
        rcTempActive = true;
        rcTempDecls = [];
        rcTempReleases = [];
        rcTempExcludedRoot = excludedRoot;
        // The scope root itself is a safe place to release: a condition's
        // value is tested and dropped, an expression statement's is ignored.
        rcTempEligible = true;

        string code = gen();
        rcTempEligible = savedEligible;
        string decls = rcTempDecls.join(" ");
        string releases = rcTempReleases.join(" ");
        bool captured = rcTempDecls.length > 0;

        rcTempActive = savedActive;
        rcTempDecls = savedDecls;
        rcTempReleases = savedReleases;
        rcTempExcludedRoot = savedExcluded;

        if (!captured) {
            return code;
        }
        if (resultCType.length == 0) {
            return format("({ %s %s; %s })", decls, code, releases);
        }

        return format("({ %s %s __llpl_rcres%d = %s; %s __llpl_rcres%d; })",
            decls, resultCType, rcTempCounter, code, releases, rcTempCounter);
    }

    // Conditions are the common home for a throwaway RC temporary
    // (`if s.trim() == "x"`), and a `while` condition is re-evaluated every
    // iteration - exactly the shape that exhausts the heap fastest.
    private string generateCondition(ASTNode cond) {
        return rcTempScope(null, "bool", () => generateExpression(cond));
    }

    // An expression statement discards its value, so nothing here needs a
    // result type - and the outermost call is itself a temporary to free.
    // Returns the expression *without* a trailing `;` either way, so the
    // caller punctuates it the same whether or not a temp was captured.
    //
    // The exception is an assignment: `self.field = new String("")` reads as
    // a discarded statement but its right-hand side is being *stored*, so
    // that one node is excluded from capture and its reference belongs to the
    // destination from here on.
    private string generateDiscardedExpression(ASTNode expr) {
        ASTNode stored = null;
        if (auto bin = cast(BinaryExpr)expr) {
            if (bin.op.length > 0 && bin.op[$ - 1] == '=' &&
                    bin.op != "==" && bin.op != "!=" && bin.op != "<=" && bin.op != ">=") {
                stored = bin.right;
            }
        }
        return rcTempScope(stored, "", () => generateExpression(expr));
    }

    private string captureRcTemp(string generated, Type t) {
        string name = format("__llpl_rctmp%d", rcTempCounter++);
        // `0`, not `NULL` - the generated preamble `#undef`s NULL so LLPL's
        // own `null` keyword owns the spelling.
        rcTempDecls ~= format("%s %s = 0;", typeToC(t), name);
        rcTempReleases ~= format("if (%s) rc_release(%s, %s);",
            name, name, fieldDestructorSymbol(t));
        return format("(%s = %s)", name, generated);
    }

    private string releaseRcLocals(string exceptName) {
        string code = "";
        foreach_reverse (i, name; rcLocalNames) {
            if (name == exceptName) continue;
            code ~= indent() ~ format("if (%s) rc_release(%s, %s);\n",
                name, name, fieldDestructorSymbol(rcLocalTypes[i]));
        }
        return code;
    }

    private struct DeferredRcState {
        DeferInfo[] deferredStatements;
        string[] rcLocalNames;
        Type[] rcLocalTypes;
        int rcFunctionBodyIndent;
    }

    private DeferredRcState saveDeferredRcState() {
        return DeferredRcState(deferredStatements.dup, rcLocalNames.dup, rcLocalTypes.dup, rcFunctionBodyIndent);
    }

    private void restoreDeferredRcState(DeferredRcState state) {
        deferredStatements = state.deferredStatements;
        rcLocalNames = state.rcLocalNames;
        rcLocalTypes = state.rcLocalTypes;
        rcFunctionBodyIndent = state.rcFunctionBodyIndent;
    }
    private bool[string] constVariables; // Names (mangled) of `const`-declared variables
    private FunctionDecl[string] functionRegistry; // Functions, by mangled (namespace-prefixed) name
    private ClassDecl[string] classRegistry; // Classes, by mangled (namespace-prefixed) name
    // Mangled class name -> true if some other class's (resolved)
    // baseClassName points at it - populated once, in the base-class
    // resolution pass in generateMultiple, alongside baseClassName
    // resolution itself. A class is "polymorphic" (needs the
    // constructor/destructor _new+_init/_destroy+__destroy_impl split,
    // and later a vtable) if it has a base OR is itself a base for
    // something - see isPolymorphic.
    private bool[string] hasSubclasses;
    // Mangled base class name -> its direct derived ClassDecls - populated
    // alongside hasSubclasses, used to walk a hierarchy top-down (e.g.
    // collectVtableSlots) when all that's known up front is the root.
    private ClassDecl[][string] subclassesOf;
    // Full `RootName_VTable ClassName_vtable = { ... };` definitions,
    // accumulated once per polymorphic class during the main per-class
    // generation pass and flushed at the very end of the file (see
    // generateMultiple) - by then every method in every class (regardless
    // of textual declaration order) is both forward-declared and defined,
    // so an initializer can safely name any of them.
    private string[] vtableInstanceDefs;
    private StructDecl[string] structRegistry; // Structs, by mangled (namespace-prefixed) name
    private UnionDecl[string] unionRegistry; // Unions, by mangled (namespace-prefixed) name
    private MacroDecl[string] macroRegistry; // Macros, by mangled (namespace-prefixed) name
    private VarDecl[string] globalVarRegistry; // Global lets/consts (incl. enum members), by mangled name
    private long[string] foldedIntegerConsts; // Numeric global const values, by mangled name
    private bool[string] foldingIntegerConsts; // Recursion guard for const folding
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
    private string[string] functionCandidateModulePath;
    private string[string] classModulePath;
    private string[string] structModulePath;
    private string[string] unionModulePath;
    private string[string] macroModulePath;
    private string[string] globalVarModulePath;
    private string[string] typeAliasModulePath;
    private int macroExpansionDepth; // Guards against (possibly indirect) macro self-recursion
    private SymbolInfo[] collectedSymbols; // Declaration-site symbol table, built by generateMultiple; see symbols()
    private UsageInfo[] usageRecords; // Resolved reference sites, recorded via recordUsage; see usages()
    private LocalInfo[] localRecords; // Function-scope variables for LSP/editor tooling; see locals()
    private EffectInfo[] effectRecords; // Conservative per-function effect summaries; see effects()
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
    private string[] lambdaForwardDecls; // Per-lambda env typedef + trampoline prototype, emitted before closure creation sites
    private string[] lambdaBodyDecls; // Per-lambda trampoline bodies, emitted after class/struct layouts exist
    private string[string] functionClosureAdapters; // Free-function symbol -> closure trampoline symbol
    private int embeddedFileCounter; // Numbers each embed("path") static blob uniquely
    private string[] embeddedFileDecls; // Static byte arrays emitted before function bodies
    private bool[string] emittedBoundsCheckHelpers; // Set of C element-type signatures already emitted
    private string[] boundsCheckHelpers; // Declarations emitted at the top of the C file
    private bool[string] reachableFunctions; // Set of reachable free-function mangled names
    private bool[string] originalFreeFunctionKeys; // Free functions from the original programs (not generic instantiations)
    private bool enableDCE; // Whether dead-code elimination is enabled
    private double codegenPreprocessTime = 0.0;
    private double codegenRegistryTime = 0.0;
    private double codegenAnalysisTime = 0.0;
    private double codegenForwardDeclTime = 0.0;
    private double codegenDeclarationTime = 0.0;
    private double codegenAssemblyMetadataTime = 0.0;

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
    private bool[string] moduleHasExplicitExports;          // module -> contains at least one `public` declaration
    private string preludeModulePath;                       // treated as implicitly imported everywhere

    // `alias hf = HAL.Foo` - a name standing in for a *namespace path*
    // rather than a single symbol (see generateAlias, which detects this:
    // "HAL_Foo" itself is never a real registered symbol, only a prefix
    // of ones like "HAL_Foo_Bar"). Keyed by the alias's own mangled name,
    // valued by the mangled namespace prefix it stands for - unlike
    // moduleAliases this is process-wide, not per-importing-module, since
    // it names a namespace within the same compiled program, not another
    // file's exports.
    private string[string] namespaceAliases;

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
    private string[] genericStructInstances; // monomorphized struct instances only
    private string[] genericClassInstances;  // monomorphized class instances only

    // Which monomorphized instantiations came specifically from prelude.llpl's
    // `Optional<T>`/`Result<T, E>` templates, by mangled name (e.g.
    // "Optional_int") - used by generatePropagateExpr (`expr?`) to know
    // which of the two unwrap/early-return shapes applies, and by
    // generateNullableWrap's callers to recognize a `T?`-sugared Optional.
    private bool[string] optionalInstantiations;
    private bool[string] resultInstantiations;
    private int propagateCounter; // numbers each `expr?`'s scratch temp var uniquely
    private int inExprCounter; // numbers each `value in arr`'s scratch temp vars uniquely
    private int rcAssignTmpCounter; // numbers each RAII reassignment's scratch temp var uniquely

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

    private bool safeMode;
    private string targetProfile;
    private bool currentFunctionIsInterrupt;
    private bool suppressSourceLineDirectives;
    private bool enableUnitTests;
    private int unitTestCounter;

    this(bool safeMode = true, bool enableDCE = true, string targetProfile = "hosted",
         bool enableUnitTests = false) {
        indentLevel = 0;
        tempVarCounter = 0;
        this.safeMode = safeMode;
        this.enableDCE = enableDCE;
        this.targetProfile = targetProfile;
        this.enableUnitTests = enableUnitTests;
    }

    void reportTiming() {
        writefln("  Codegen preprocess/desugar: %.2f ms", codegenPreprocessTime);
        writefln("  Codegen registry/reachability: %.2f ms", codegenRegistryTime);
        writefln("  Codegen type analysis: %.2f ms", codegenAnalysisTime);
        writefln("  Codegen forward declarations: %.2f ms", codegenForwardDeclTime);
        writefln("  Codegen declaration bodies: %.2f ms", codegenDeclarationTime);
        writefln("  Codegen assembly/metadata: %.2f ms", codegenAssemblyMetadataTime);
    }

    private bool isFreestandingTarget() {
        return targetProfile == "freestanding" || targetProfile == "kernel";
    }

    private string normalizedPathForPolicy(string path) {
        return path.replace("\\", "/");
    }

    private bool isHostedOnlyModulePath(string path) {
        string p = normalizedPathForPolicy(path);
        return p.canFind("/stdlib/io/") || p.canFind("/stdlib/net/") ||
            p.canFind("/stdlib/sdl/") || p.canFind("/examples/stdlib/") ||
            p.canFind("/examples/sdl/");
    }

    private string hostedOnlyCapability(string path) {
        string p = normalizedPathForPolicy(path);
        if (p.canFind("/stdlib/io/")) return "filesystem I/O";
        if (p.canFind("/stdlib/net/")) return "host networking";
        if (p.canFind("/stdlib/sdl/")) return "SDL";
        if (p.canFind("/examples/stdlib/")) return "hosted stdlib example";
        if (p.canFind("/examples/sdl/")) return "SDL example";
        return "hosted runtime";
    }

    private void checkTargetProfile(Program[] programs) {
        if (targetProfile != "hosted" && targetProfile != "freestanding" && targetProfile != "kernel") {
            throw new CompileError(format("Unknown target profile '%s' (expected hosted, freestanding, or kernel)",
                targetProfile), "", 1, 1);
        }
        if (!isFreestandingTarget()) return;

        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            if (isHostedOnlyModulePath(prog.modulePath)) {
                throw new CompileError(
                    format("Target '%s' forbids %s module '%s'",
                        targetProfile, hostedOnlyCapability(prog.modulePath), prog.modulePath),
                    prog.modulePath, 1, 1);
            }
            foreach (decl; prog.declarations) {
                if (auto linkDecl = cast(LinkDecl)decl) {
                    throw new CompileError(
                        format("Target '%s' forbids '#link \"%s\"'; provide freestanding link flags in the external build",
                            targetProfile, linkDecl.libraryName),
                        prog.modulePath, linkDecl.line, linkDecl.column);
                }
            }
        }
    }

    private long parseDeviceInteger(string value, string path, int lineNo) {
        string s = value.strip();
        if (s.startsWith("0x") || s.startsWith("0X")) {
            long result = 0;
            foreach (ch; s[2 .. $]) {
                int digit;
                if (ch >= '0' && ch <= '9') digit = ch - '0';
                else if (ch >= 'a' && ch <= 'f') digit = ch - 'a' + 10;
                else if (ch >= 'A' && ch <= 'F') digit = ch - 'A' + 10;
                else throw new CompileError(format("Invalid hex integer '%s' in device descriptor", value),
                    path, lineNo, 1);
                result = result * 16 + digit;
            }
            return result;
        }
        try {
            return to!long(s);
        } catch (Exception) {
            throw new CompileError(format("Invalid integer '%s' in device descriptor", value),
                path, lineNo, 1);
        }
    }

    private string deviceWidthName(string width, string path, int lineNo) {
        switch (width) {
            case "u8": return "8";
            case "u16": return "16";
            case "u32": return "32";
            case "u64": return "64";
            default:
                throw new CompileError(format("Unsupported register width '%s' (expected u8, u16, u32, or u64)",
                    width), path, lineNo, 1);
        }
    }

    private VarDecl deviceConst(string name, long value, int line, int column) {
        return new VarDecl(name, new Type("u64"), new IntLiteral(value, line, column), true, line, column);
    }

    private NamespaceDecl expandDeviceDescriptor(DeviceDecl decl, string modulePath) {
        string baseDir = modulePath.length > 0 ? dirName(modulePath) : ".";
        string path = isAbsolute(decl.descriptorPath) ? decl.descriptorPath :
            buildNormalizedPath(baseDir, decl.descriptorPath);
        if (!exists(path)) {
            throw new CompileError(format("Device descriptor not found: %s", path),
                modulePath, decl.line, decl.column);
        }

        string deviceName;
        ASTNode[] rootDecls;
        ASTNode[] regDecls;
        ASTNode[] widthDecls;
        ASTNode[] dmaDecls;
        bool sawBase = false;

        foreach (i, rawLine; readText(path).splitLines()) {
            int lineNo = cast(int)i + 1;
            string line = rawLine;
            ptrdiff_t comment = line.indexOf("#");
            if (comment >= 0) line = line[0 .. comment];
            auto parts = line.strip().split();
            if (parts.length == 0) continue;

            string directive = parts[0];
            if (directive == "device") {
                if (parts.length != 2) {
                    throw new CompileError("'device' expects exactly one name", path, lineNo, 1);
                }
                deviceName = parts[1];
            } else if (directive == "base") {
                if (parts.length != 2) {
                    throw new CompileError("'base' expects one address", path, lineNo, 1);
                }
                rootDecls ~= deviceConst("BASE", parseDeviceInteger(parts[1], path, lineNo), decl.line, decl.column);
                sawBase = true;
            } else if (directive == "irq") {
                if (parts.length != 2) {
                    throw new CompileError("'irq' expects one interrupt number", path, lineNo, 1);
                }
                rootDecls ~= deviceConst("IRQ", parseDeviceInteger(parts[1], path, lineNo), decl.line, decl.column);
            } else if (directive == "reg") {
                if (parts.length != 4) {
                    throw new CompileError("'reg' expects: reg NAME OFFSET WIDTH", path, lineNo, 1);
                }
                regDecls ~= deviceConst(parts[1], parseDeviceInteger(parts[2], path, lineNo), decl.line, decl.column);
                widthDecls ~= deviceConst(parts[1], parseDeviceInteger(deviceWidthName(parts[3], path, lineNo), path, lineNo),
                    decl.line, decl.column);
            } else if (directive == "dma") {
                if (parts.length != 5) {
                    throw new CompileError("'dma' expects: dma NAME ENTRIES BYTES ALIGN", path, lineNo, 1);
                }
                string prefix = parts[1] ~ "_";
                dmaDecls ~= deviceConst(prefix ~ "ENTRIES", parseDeviceInteger(parts[2], path, lineNo),
                    decl.line, decl.column);
                dmaDecls ~= deviceConst(prefix ~ "BYTES", parseDeviceInteger(parts[3], path, lineNo),
                    decl.line, decl.column);
                dmaDecls ~= deviceConst(prefix ~ "ALIGN", parseDeviceInteger(parts[4], path, lineNo),
                    decl.line, decl.column);
            } else {
                throw new CompileError(format("Unknown device descriptor directive '%s'", directive),
                    path, lineNo, 1);
            }
        }

        if (deviceName.length == 0) {
            throw new CompileError("Device descriptor must start with 'device NAME'", path, 1, 1);
        }
        if (!sawBase) {
            throw new CompileError("Device descriptor must declare a base address", path, 1, 1);
        }
        if (regDecls.length > 0) rootDecls ~= new NamespaceDecl("Reg", regDecls, decl.line, decl.column);
        if (widthDecls.length > 0) rootDecls ~= new NamespaceDecl("Width", widthDecls, decl.line, decl.column);
        if (dmaDecls.length > 0) rootDecls ~= new NamespaceDecl("Dma", dmaDecls, decl.line, decl.column);
        return new NamespaceDecl(deviceName, rootDecls, decl.line, decl.column);
    }

    private ASTNode[] expandDeviceDescriptors(ASTNode[] declarations, string modulePath) {
        ASTNode[] result;
        foreach (decl; declarations) {
            if (auto dev = cast(DeviceDecl)decl) {
                result ~= expandDeviceDescriptor(dev, modulePath);
            } else {
                result ~= decl;
            }
        }
        return result;
    }

    // Computes a conservative set of reachable free functions. This is the
    // only kind of DCE implemented in this version; classes, methods,
    // globals, and structs are kept. Overloaded free functions are also kept
    // conservatively because call-site resolution needs argument types.
    private void computeReachableFunctions(Program[] programs) {
        if (!enableDCE) return;

        // Roots: main / kernel_main / extern functions. Async functions also
        // expose public start/poll ABI helpers, so keep their bodies even when
        // the blocking wrapper is not called directly.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                auto funcDecl = cast(FunctionDecl)decl;
                if (funcDecl is null) continue;
                string key = mangleFreeFunctionName(funcDecl);
                if (funcDecl.isExtern || funcDecl.name == "main" ||
                    funcDecl.name == "_start" || funcDecl.name == "kernel_main" ||
                    funcDecl.name == "llpl_panic_putc" ||
                    funcDecl.name == "llpl_panic_halt" ||
                    funcDecl.isAsync ||
                    funcDecl.isInterrupt ||
                    isExternalAbiRoot(key)) {
                    markFunctionReachable(key);
                }
            }
        }

        // Generic functions are cloned lazily, after this pass has started.
        // Walk their templates as well so a concrete function called only
        // from an instantiation is retained (for example alloc_page from
        // kmalloc<T>).
        foreach (key, template_; genericFunctionTemplates) {
            if (template_.body_ is null) continue;
            currentModulePath = genericTemplateModulePath[key];
            currentNamespaceSegments = template_.namespaceSegments;
            walkForReachableCalls(template_.body_);
        }

        // Iteratively walk reachable function bodies to find more free calls.
        // Classes and their methods are kept conservatively by DCE, so method
        // bodies must take part in reachability too. Otherwise a free helper
        // used only from a method can lose its prototype while its definition
        // still appears later in the generated C.
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (prog; programs) {
                currentModulePath = prog.modulePath;
                foreach (decl; prog.declarations) {
                    if (auto funcDecl = cast(FunctionDecl)decl) {
                        string key = mangleFreeFunctionName(funcDecl);
                        if (key !in reachableFunctions) continue;
                        if (funcDecl.body_ is null) continue;
                        currentNamespaceSegments = funcDecl.namespaceSegments;
                        changed |= walkForReachableCalls(funcDecl.body_);
                    } else if (auto classDecl = cast(ClassDecl)decl) {
                        currentNamespaceSegments = classDecl.namespaceSegments;
                        foreach (ctor; classDecl.constructors) {
                            if (ctor.body_ !is null) changed |= walkForReachableCalls(ctor.body_);
                        }
                        if (classDecl.destructor !is null && classDecl.destructor.body_ !is null) {
                            changed |= walkForReachableCalls(classDecl.destructor.body_);
                        }
                        foreach (method; classDecl.methods) {
                            if (method.body_ !is null) changed |= walkForReachableCalls(method.body_);
                        }
                    } else if (auto structDecl = cast(StructDecl)decl) {
                        currentNamespaceSegments = structDecl.namespaceSegments;
                        foreach (ctor; structDecl.constructors) {
                            if (ctor.body_ !is null) changed |= walkForReachableCalls(ctor.body_);
                        }
                        foreach (method; structDecl.methods) {
                            if (method.body_ !is null) changed |= walkForReachableCalls(method.body_);
                        }
                    } else if (auto unionDecl = cast(UnionDecl)decl) {
                        currentNamespaceSegments = unionDecl.namespaceSegments;
                        foreach (ctor; unionDecl.constructors) {
                            if (ctor.body_ !is null) changed |= walkForReachableCalls(ctor.body_);
                        }
                        foreach (method; unionDecl.methods) {
                            if (method.body_ !is null) changed |= walkForReachableCalls(method.body_);
                        }
                    } else if (enableUnitTests) {
                        if (auto unitTestDecl = cast(UnitTestDecl)decl) {
                            currentNamespaceSegments = unitTestDecl.namespaceSegments;
                            if (unitTestDecl.body_ !is null) changed |= walkForReachableCalls(unitTestDecl.body_);
                        }
                    }
                }
            }
        }
    }

    private bool markFunctionReachable(string key) {
        if (key in reachableFunctions) return false;
        reachableFunctions[key] = true;
        return true;
    }

    private bool isExternalAbiRoot(string key) {
        if (key.startsWith("sys_") || key.startsWith("syscall")) {
            return true;
        }
        switch (key) {
            case "Task_schedule_next":
            case "Task_should_reschedule_current":
            case "Task_pick_next":
            case "Syscall_dispatch":
            case "isr_handler":
                return true;
            default:
                return false;
        }
    }

    // Walk a statement or expression and mark any free functions called
    // from reachable code as reachable. Returns true if anything changed.
    private bool walkForReachableCalls(ASTNode node) {
        if (node is null) return false;
        bool changed = false;

        if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) changed |= walkForReachableCalls(stmt);
        } else if (auto exprStmt = cast(ExprStmt)node) {
            changed |= walkForReachableCalls(exprStmt.expression);
        } else if (auto varDecl = cast(VarDecl)node) {
            if (varDecl.initializer) changed |= walkForReachableCalls(varDecl.initializer);
        } else if (auto ifStmt = cast(IfStmt)node) {
            changed |= walkForReachableCalls(ifStmt.condition);
            changed |= walkForReachableCalls(ifStmt.thenBlock);
            if (ifStmt.elseBlock) changed |= walkForReachableCalls(ifStmt.elseBlock);
        } else if (auto whileStmt = cast(WhileStmt)node) {
            changed |= walkForReachableCalls(whileStmt.condition);
            changed |= walkForReachableCalls(whileStmt.body_);
        } else if (auto doWhileStmt = cast(DoWhileStmt)node) {
            changed |= walkForReachableCalls(doWhileStmt.body_);
            changed |= walkForReachableCalls(doWhileStmt.condition);
        } else if (auto forStmt = cast(ForStmt)node) {
            foreach (init; forStmt.initializers) {
                changed |= walkForReachableCalls(init);
            }
            if (forStmt.condition) changed |= walkForReachableCalls(forStmt.condition);
            if (forStmt.update) changed |= walkForReachableCalls(forStmt.update);
            changed |= walkForReachableCalls(forStmt.body_);
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            changed |= walkForReachableCalls(foreachStmt.iterable);
            changed |= walkForReachableCalls(foreachStmt.body_);
        } else if (auto withStmt = cast(WithStmt)node) {
            changed |= walkForReachableCalls(withStmt.object);
            changed |= walkForReachableCalls(withStmt.body_);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            if (returnStmt.value) changed |= walkForReachableCalls(returnStmt.value);
        } else if (auto deferStmt = cast(DeferStmt)node) {
            changed |= walkForReachableCalls(deferStmt.statement);
        } else if (auto tryStmt = cast(TryStmt)node) {
            changed |= walkForReachableCalls(tryStmt.tryBlock);
            if (tryStmt.catchBlock) changed |= walkForReachableCalls(tryStmt.catchBlock);
            if (tryStmt.finallyBlock) changed |= walkForReachableCalls(tryStmt.finallyBlock);
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            changed |= walkForReachableCalls(throwStmt.value);
        } else if (auto assertStmt = cast(AssertStmt)node) {
            changed |= walkForReachableCalls(assertStmt.condition);
            if (assertStmt.message) changed |= walkForReachableCalls(assertStmt.message);
        } else if (auto destructStmt = cast(DestructuringStmt)node) {
            changed |= walkForReachableCalls(destructStmt.initializer);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            changed |= walkForReachableCalls(matchStmt.subject);
            foreach (case_; matchStmt.cases) {
                foreach (pattern; case_.patterns) changed |= walkForReachableCalls(pattern);
                if (case_.body_) changed |= walkForReachableCalls(case_.body_);
            }
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            changed |= walkForReachableCalls(deleteStmt.value);
        } else if (auto binaryExpr = cast(BinaryExpr)node) {
            changed |= walkForReachableCalls(binaryExpr.left);
            changed |= walkForReachableCalls(binaryExpr.right);
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            changed |= walkForReachableCalls(unaryExpr.operand);
        } else if (auto awaitExpr = cast(AwaitExpr)node) {
            changed |= walkForReachableCalls(awaitExpr.expression);
        } else if (auto callExpr = cast(CallExpr)node) {
            changed |= markReachableCall(callExpr.callee);
            foreach (arg; callExpr.args) changed |= walkForReachableCalls(arg);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            changed |= walkForReachableCalls(indexExpr.array);
            changed |= walkForReachableCalls(indexExpr.index);
        } else if (auto ident = cast(Identifier)node) {
            changed |= markReachableCall(ident);
        } else if (auto memberExpr = cast(MemberExpr)node) {
            changed |= walkForReachableCalls(memberExpr.object);
            changed |= markReachableCall(memberExpr);
        } else if (auto castExpr = cast(CastExpr)node) {
            changed |= walkForReachableCalls(castExpr.expression);
        } else if (auto newExpr = cast(NewExpr)node) {
            foreach (arg; newExpr.args) changed |= walkForReachableCalls(arg);
        } else if (auto arrayLit = cast(ArrayLiteral)node) {
            foreach (elem; arrayLit.elements) changed |= walkForReachableCalls(elem);
        } else if (auto structLit = cast(StructLiteral)node) {
            foreach (value; structLit.fieldValues) changed |= walkForReachableCalls(value);
        } else if (auto tupleLit = cast(TupleLiteral)node) {
            foreach (elem; tupleLit.elements) changed |= walkForReachableCalls(elem);
        } else if (auto lambdaExpr = cast(LambdaExpr)node) {
            if (lambdaExpr.body_) changed |= walkForReachableCalls(lambdaExpr.body_);
        } else if (auto ifExpr = cast(IfExpr)node) {
            changed |= walkForReachableCalls(ifExpr.condition);
            changed |= walkForReachableCalls(ifExpr.thenBlock);
            changed |= walkForReachableCalls(ifExpr.elseBlock);
        } else if (auto sizeOfExpr = cast(SizeofExpr)node) {
            // No runtime expressions to walk.
        } else if (auto interpolated = cast(InterpolatedStringLiteral)node) {
            foreach (expr; interpolated.expressions) changed |= walkForReachableCalls(expr);
        } else if (auto propagate = cast(PropagateExpr)node) {
            changed |= walkForReachableCalls(propagate.operand);
        } else if (auto quoteExpr = cast(QuoteExpr)node) {
            changed |= walkForReachableCalls(quoteExpr.body);
        } else if (auto unquoteExpr = cast(UnquoteExpr)node) {
            changed |= walkForReachableCalls(unquoteExpr.expression);
        } else if (auto macroInvocation = cast(MacroInvocation)node) {
            foreach (arg; macroInvocation.args) changed |= walkForReachableCalls(arg);
        } else if (auto patternExpr = cast(PatternExpr)node) {
            // PatternExpr wraps a non-AST Pattern hierarchy; it cannot
            // reference free functions, so nothing to do.
        } else if (auto rangeExpr = cast(RangeExpr)node) {
            changed |= walkForReachableCalls(rangeExpr.start);
            changed |= walkForReachableCalls(rangeExpr.end);
        }

        return changed;
    }

    // Marks a function (or all candidates of an overloaded base name) as
    // reachable if it is an original free function. Returns true if the set
    // changed.
    private bool markReachableFunctionRef(string resolvedName) {
        if (resolvedName.length == 0) return false;
        if (resolvedName in originalFreeFunctionKeys) {
            return markFunctionReachable(resolvedName);
        }
        if (auto candidates = resolvedName in functionCandidates) {
            bool changed = false;
            foreach (candidate; *candidates) {
                string key = mangleFreeFunctionName(candidate);
                if (key in originalFreeFunctionKeys) {
                    changed |= markFunctionReachable(key);
                }
            }
            return changed;
        }
        return false;
    }

    // If a callee expression resolves to an original free function, mark it
    // reachable. Overloaded calls are resolved conservatively: all overloads
    // sharing the resolved base name are marked reachable, so DCE never
    // removes the wrong overload. Methods and generic instantiations are kept
    // as part of their class/generation pass. Handles both simple identifiers
    // and qualified paths (module aliases, namespace prefixes, namespace aliases).
    private bool markReachableCall(ASTNode callee) {
        if (auto ident = cast(Identifier)callee) {
            try {
                string resolved = resolveName(ident.name, (n) => (n in functionRegistry) !is null);
                if (markReachableFunctionRef(resolved)) return true;
                resolved = resolveName(ident.name, (n) => (n in functionCandidates) !is null);
                return markReachableFunctionRef(resolved);
            } catch (Exception e) {
                // Ignore resolution failures during reachability; DCE is
                // conservative and will keep the function.
            }
        } else if (auto member = cast(MemberExpr)callee) {
            try {
                string resolved = tryResolveQualifiedPath(member, (n) => (n in functionRegistry) !is null);
                if (markReachableFunctionRef(resolved)) return true;
                resolved = tryResolveQualifiedPath(member, (n) => (n in functionCandidates) !is null);
                return markReachableFunctionRef(resolved);
            } catch (Exception e) {
                // Ignore resolution failures during reachability.
            }
        }
        return false;
    }

    private bool isReachableFreeFunction(FunctionDecl funcDecl) {
        if (!enableDCE) return true;
        string key = mangleFreeFunctionName(funcDecl);
        // Overloaded functions, methods, and generic instantiations are kept
        // conservatively. Only plain, non-overloaded free functions from the
        // original source are candidates for removal.
        if (key !in originalFreeFunctionKeys) return true;
        return (key in reachableFunctions) !is null;
    }

    private bool isOrdinaryTopLevelMain(FunctionDecl funcDecl) {
        return funcDecl.name == "main" && funcDecl.namespaceSegments.length == 0;
    }

    private string indent() {
        string result = "";
        for (int i = 0; i < indentLevel; i++) {
            result ~= "    ";
        }
        return result;
    }

    // Keep runtime panic locations readable while retaining the source
    // directory that identifies a module (for example, `mm/heap.llpl`).
    private string shortSourcePath(string path) {
        if (path.length == 0) return "";
        string file = baseName(path);
        string directory = baseName(dirName(path));
        if (directory.length == 0 || directory == ".") return file;
        return buildNormalizedPath(directory, file);
    }

    private string sourceLineDirective(ASTNode node) {
        if (suppressSourceLineDirectives) return "";
        if (node is null || node.line <= 0 || currentModulePath.length == 0) {
            return "";
        }
        return format("#line %d \"%s\"\n", node.line, escapeCString(currentModulePath));
    }

    private string withSourceLine(ASTNode node, string code) {
        if (code.length == 0) {
            return code;
        }
        return sourceLineDirective(node) ~ code;
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
    // Parser.splitInterpolationFormat); integers and pointers accept either.
    private string interpFormatSpecifier(ASTNode expr, InterpFormat spec) {
        Type t = inferType(expr);
        resolveType(t);

        bool isPlainInt = isIntegerType(t);
        // Radix formatting prints the numeric address represented by a
        // pointer. Treat pointers as unsigned integer-like values here; the
        // interpolation emitter casts them to uintptr_t before passing them
        // to ksnprintf, so the generated format argument has the right ABI.
        bool isIntegerLike = isPlainInt || t.isPointer;
        bool isUnsigned = t.isPointer || isUnsignedIntegerType(t);
        bool isFloat = !t.isPointer && !t.isArray && (t.name == "f32" || t.name == "f64");

        if (spec.precision >= 0) {
            if (!isFloat) {
                throw new CompileError(
                    format("Cannot use ':.%d' precision on a value of type '%s' - only floats support it",
                        spec.precision, t.toString()),
                    currentModulePath, expr.line, expr.column);
            }
            return format("%%.%df", spec.precision);
        }

        if (spec.radix.length > 0 || spec.width > 0) {
            if (!isIntegerLike) {
                string what = spec.radix.length > 0 ? format("':%s'", spec.radix) : "width";
                throw new CompileError(
                    format("Cannot use %s formatting on a value of type '%s' - only integers and pointers support it",
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
            case "i64": case "i8": case "int8": case "i16": case "int16":
            case "i32": case "int32": case "int64": case "int":
                return "%d";
            case "u64": case "u8": case "uint8": case "u16": case "uint16":
            case "u32": case "uint32": case "uint64": case "uint":
                return "%u";
            // f32/f64 (see canonicalIntTypeName) both promote to `double`
            // in the generated ksnprintf varargs call regardless, same as
            // C's own float->double default argument promotion - runtime.c's
            // kvsnprintf reads it back with `va_arg(args, double)`.
            case "f32": case "f64": return "%f";
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
                // implicitly resolve it the same way `.as_string`/`as
                // string` do (a custom as_string() method, or the type's
                // own name) instead of requiring `"\(f.as_string)"` to be
                // spelled out every time. Not offered alongside an
                // explicit width/radix modifier (`\(f:016)`) - that's
                // still a plain-integer-only error, unchanged.
                bool useAsString = false;
                Type asStringType;
                if (spec.radix.length == 0 && spec.width == 0) {
                    try {
                        asStringType = inferType(expr);
                        resolveType(asStringType);
                        // pointerDepth == 0 only - see the matching check
                        // in CastExpr's own `as char*` handling for why an
                        // explicit pointer (Foo*) must not be stringified.
                        useAsString = asStringType.pointerDepth == 0 &&
                            ((asStringType.name in classRegistry) !is null ||
                             (asStringType.name in structRegistry) !is null);
                    } catch (Exception e) {
                        // fall through to the ordinary path below
                    }
                }
                if (useAsString) {
                    fmt ~= "%s";
                    args ~= ", " ~ generateAsStringValue(asStringType, expr, expr.line, expr.column);
                } else {
                    fmt ~= interpFormatSpecifier(expr, spec);
                    string argCode = generateExpression(expr);
                    Type exprType = inferType(expr);
                    resolveType(exprType);
                    if ((spec.radix.length > 0 || spec.width > 0) && exprType.isPointer) {
                        argCode = format("((uintptr_t)(%s))", argCode);
                    }
                    args ~= ", " ~ variadicPromote(expr, argCode);
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
    LocalInfo[] locals() { return localRecords; }
    EffectInfo[] effects() { return effectRecords; }

    private void recordUsage(string name, int line, int column) {
        usageRecords ~= UsageInfo(name, currentModulePath, line, column);
    }

    private void recordLocal(string name, Type type, int line, int column, string kind) {
        if (currentScopeName.length == 0) return;
        localRecords ~= LocalInfo(name, type !is null ? type.toString() : "?",
            currentModulePath, line, column, currentScopeName, kind);
    }

    private void recordPointerBound(string emittedName, Type type) {
        if (type !is null && type.isArray && type.arraySize > 0) {
            pointerIndexBounds[emittedName] = type.arraySize;
        }
    }

    private int knownBoundFromInitializer(ASTNode initializer) {
        if (initializer is null) return 0;
        try {
            Type initType = inferType(initializer);
            resolveType(initType);
            if (initType.isArray && initType.arraySize > 0) return initType.arraySize;
            string initCode = generateExpression(initializer);
            if (auto bound = initCode in pointerIndexBounds) return *bound;
        } catch (Exception e) {
            return 0;
        }
        return 0;
    }

    private string functionSignature(FunctionDecl fn, string displayName) {
        string sig = "";
        if (fn.isExtern) sig ~= "extern ";
        if (fn.isInterrupt) sig ~= "interrupt ";
        if (fn.isAsync) sig ~= "async ";
        if (fn.isVirtual) sig ~= "virtual ";
        if (fn.isOverride) sig ~= "override ";
        sig ~= "func " ~ displayName ~ "(";
        foreach (i, p; fn.params) {
            if (i > 0) sig ~= ", ";
            sig ~= (p.initializesField ? "@" : "") ~ p.name ~ ": " ~ p.type.toString();
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
        string baseSuffix = cls.baseClassName.length > 0 ? " : " ~ cls.baseClassName : "";
        return format("class %s%s (%d field(s), %d method(s))",
            displayName, baseSuffix, cls.fields.length, cls.methods.length);
    }

    private string structSignature(StructDecl st, string displayName) {
        return format("%sstruct %s (%d field(s))", st.packed ? "packed " : "", displayName, st.fields.length);
    }

    private string unionSignature(UnionDecl ud, string displayName) {
        return format("%sunion %s (%d field(s))", ud.packed ? "packed " : "", displayName, ud.fields.length);
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
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    string dname = mangledUnion(unionDecl);
                    collectedSymbols ~= SymbolInfo(dname, "union", prog.modulePath,
                        unionDecl.line, unionDecl.column, unionSignature(unionDecl, dname));
                    foreach (field; unionDecl.fields) {
                        collectedSymbols ~= SymbolInfo(dname ~ "." ~ field.name, "field", prog.modulePath,
                            field.line, field.column, fieldSignature(field, dname));
                    }
                    foreach (method; unionDecl.methods) {
                        collectedSymbols ~= SymbolInfo(dname ~ "." ~ method.name, "method", prog.modulePath,
                            method.line, method.column, methodSignature(method, dname));
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

    private void addEffect(ref bool[string] set, string effect) {
        set[effect] = true;
    }

    private string[] sortedEffects(bool[string] set) {
        auto result = set.keys.array;
        sort(result);
        return result;
    }

    private string qualifiedExprName(ASTNode node) {
        if (auto ident = cast(Identifier)node) return ident.name;
        if (auto member = cast(MemberExpr)node) {
            string prefix = qualifiedExprName(member.object);
            return prefix.length > 0 ? prefix ~ "." ~ member.member : member.member;
        }
        return "";
    }

    private void addPathEffects(string path, ref bool[string] effects) {
        string lower = path.toLower();
        if (lower.indexOf("mmio") >= 0) {
            addEffect(effects, "mmio");
            addEffect(effects, "unsafe");
        }
        if (lower.indexOf("dma") >= 0) addEffect(effects, "dma");
        if (lower.indexOf("cache") >= 0 || lower.indexOf("barrier") >= 0) {
            addEffect(effects, "cache");
            addEffect(effects, "unsafe");
        }
        if (lower.indexOf("paging") >= 0 || lower.indexOf("page_table") >= 0) {
            addEffect(effects, "paging");
            addEffect(effects, "unsafe");
        }
        if (lower.indexOf("device") >= 0) addEffect(effects, "device");
    }

    private void addCallEffects(CallExpr call, ref bool[string] effects) {
        string qname = qualifiedExprName(call.callee);
        string lookupName = qname.replace(".", "_");
        string resolved = lookupName;

        if (qname.length > 0) {
            addPathEffects(qname, effects);
            if (qname == "llpl_panic" || qname.endsWith(".panic")) addEffect(effects, "panic");
            if (qname == "llpl_alloc" || qname == "rc_alloc" || qname.endsWith(".alloc")) {
                addEffect(effects, "alloc");
                addEffect(effects, "unsafe");
            }
        }

        try {
            if (qname.indexOf(".") >= 0) {
                auto member = cast(MemberExpr)call.callee;
                string qualified = tryResolveQualifiedPath(member, (n) => (n in functionRegistry) !is null);
                if (qualified.length > 0) resolved = qualified;
            } else if (auto ident = cast(Identifier)call.callee) {
                resolved = resolveName(ident.name, (n) => (n in functionRegistry) !is null);
            }
        } catch (Exception) {
            resolved = lookupName;
        }

        if (auto fn = resolved in functionRegistry) {
            if (fn.isExtern) addEffect(effects, "ffi");
            if (auto mod = resolved in functionModulePath) addPathEffects(*mod, effects);
        }

        foreach (arg; call.args) collectNodeEffects(arg, effects);
        collectNodeEffects(call.callee, effects);
    }

    private bool isClassAllocation(NewExpr expr) {
        Type t = cloneType(expr.type);
        try resolveType(t); catch (Exception) {}
        return (t.name in classRegistry) !is null;
    }

    private void collectNodeEffects(ASTNode node, ref bool[string] effects) {
        if (node is null) return;

        if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) collectNodeEffects(stmt, effects);
        } else if (auto v = cast(VarDecl)node) {
            collectNodeEffects(v.initializer, effects);
        } else if (auto d = cast(DestructuringStmt)node) {
            collectNodeEffects(d.initializer, effects);
        } else if (auto e = cast(ExprStmt)node) {
            collectNodeEffects(e.expression, effects);
        } else if (auto i = cast(IfStmt)node) {
            collectNodeEffects(i.condition, effects);
            collectNodeEffects(i.thenBlock, effects);
            collectNodeEffects(i.elseBlock, effects);
        } else if (auto i = cast(IfExpr)node) {
            collectNodeEffects(i.condition, effects);
            collectNodeEffects(i.thenBlock, effects);
            collectNodeEffects(i.elseBlock, effects);
        } else if (auto w = cast(WhileStmt)node) {
            collectNodeEffects(w.condition, effects);
            collectNodeEffects(w.body_, effects);
        } else if (auto dw = cast(DoWhileStmt)node) {
            collectNodeEffects(dw.body_, effects);
            collectNodeEffects(dw.condition, effects);
        } else if (auto f = cast(ForStmt)node) {
            foreach (init; f.initializers) {
                collectNodeEffects(init, effects);
            }
            collectNodeEffects(f.condition, effects);
            collectNodeEffects(f.update, effects);
            collectNodeEffects(f.body_, effects);
        } else if (auto f = cast(ForeachStmt)node) {
            collectNodeEffects(f.iterable, effects);
            collectNodeEffects(f.body_, effects);
        } else if (auto w = cast(WithStmt)node) {
            collectNodeEffects(w.object, effects);
            collectNodeEffects(w.body_, effects);
        } else if (auto r = cast(ReturnStmt)node) {
            collectNodeEffects(r.value, effects);
        } else if (auto d = cast(DeferStmt)node) {
            addEffect(effects, "defer");
            collectNodeEffects(d.statement, effects);
        } else if (auto a = cast(AsmStmt)node) {
            addEffect(effects, "asm");
            addEffect(effects, "unsafe");
            foreach (op; a.outputs) collectNodeEffects(op.expr, effects);
            foreach (op; a.inputs) collectNodeEffects(op.expr, effects);
        } else if (auto t = cast(TryStmt)node) {
            addEffect(effects, "throw");
            collectNodeEffects(t.tryBlock, effects);
            collectNodeEffects(t.catchBlock, effects);
            collectNodeEffects(t.finallyBlock, effects);
        } else if (auto t = cast(ThrowStmt)node) {
            addEffect(effects, "throw");
            collectNodeEffects(t.value, effects);
        } else if (auto d = cast(DeleteStmt)node) {
            addEffect(effects, "alloc");
            collectNodeEffects(d.value, effects);
        } else if (auto a = cast(AssertStmt)node) {
            if (a.fatal) addEffect(effects, "panic");
            collectNodeEffects(a.condition, effects);
            collectNodeEffects(a.message, effects);
        } else if (auto m = cast(MatchStmt)node) {
            collectNodeEffects(m.subject, effects);
            foreach (c; m.cases) {
                foreach (p; c.patterns) collectNodeEffects(p, effects);
                collectNodeEffects(c.body_, effects);
            }
        } else if (auto b = cast(BinaryExpr)node) {
            collectNodeEffects(b.left, effects);
            collectNodeEffects(b.right, effects);
        } else if (auto u = cast(UnaryExpr)node) {
            if (u.op == "*") addEffect(effects, "unsafe");
            collectNodeEffects(u.operand, effects);
        } else if (auto a = cast(AwaitExpr)node) {
            addEffect(effects, "await");
            collectNodeEffects(a.expression, effects);
        } else if (auto c = cast(CallExpr)node) {
            addCallEffects(c, effects);
        } else if (auto m = cast(MemberExpr)node) {
            addPathEffects(qualifiedExprName(m), effects);
            collectNodeEffects(m.object, effects);
        } else if (auto idx = cast(IndexExpr)node) {
            collectNodeEffects(idx.array, effects);
            collectNodeEffects(idx.index, effects);
        } else if (auto n = cast(NewExpr)node) {
            if (isClassAllocation(n)) addEffect(effects, "alloc");
            foreach (arg; n.args) collectNodeEffects(arg, effects);
        } else if (auto c = cast(CastExpr)node) {
            if (c.type.isPointer) addEffect(effects, "unsafe");
            collectNodeEffects(c.expression, effects);
        } else if (auto l = cast(LambdaExpr)node) {
            addEffect(effects, "alloc");
            collectNodeEffects(l.body_, effects);
        } else if (auto s = cast(StructLiteral)node) {
            foreach (value; s.fieldValues) collectNodeEffects(value, effects);
        } else if (auto t = cast(TupleLiteral)node) {
            foreach (elem; t.elements) collectNodeEffects(elem, effects);
        } else if (auto p = cast(PropagateExpr)node) {
            addEffect(effects, "throw");
            collectNodeEffects(p.operand, effects);
        } else if (auto r = cast(RangeExpr)node) {
            collectNodeEffects(r.start, effects);
            collectNodeEffects(r.end, effects);
        } else if (auto a = cast(ArrayLiteral)node) {
            foreach (elem; a.elements) collectNodeEffects(elem, effects);
        } else if (auto i = cast(InterpolatedStringLiteral)node) {
            addEffect(effects, "io");
            foreach (expr; i.expressions) collectNodeEffects(expr, effects);
        } else if (auto q = cast(QuoteExpr)node) {
            collectNodeEffects(q.body, effects);
        } else if (auto u = cast(UnquoteExpr)node) {
            collectNodeEffects(u.expression, effects);
        } else if (auto m = cast(MacroInvocation)node) {
            foreach (arg; m.args) collectNodeEffects(arg, effects);
        }
    }

    private void collectFunctionEffects(FunctionDecl fn, string name, string kind, string file) {
        bool[string] effects;
        if (fn.isExtern) addEffect(effects, "ffi");
        if (fn.isInterrupt) addEffect(effects, "interrupt");
        addPathEffects(file, effects);

        string oldModule = currentModulePath;
        string[] oldNamespace = currentNamespaceSegments;
        currentModulePath = file;
        currentNamespaceSegments = fn.namespaceSegments;
        collectNodeEffects(fn.body_, effects);
        currentModulePath = oldModule;
        currentNamespaceSegments = oldNamespace;

        effectRecords ~= EffectInfo(name, kind, file, fn.line, fn.column, sortedEffects(effects));
    }

    private void collectEffects(Program[] programs) {
        effectRecords.length = 0;
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto fn = cast(FunctionDecl)decl) {
                    collectFunctionEffects(fn, mangledFunc(fn), "function", prog.modulePath);
                } else if (auto cls = cast(ClassDecl)decl) {
                    string owner = mangledClass(cls);
                    foreach (ctor; cls.constructors) {
                        collectFunctionEffects(ctor, owner ~ ".new", "constructor", prog.modulePath);
                    }
                    if (cls.destructor !is null) {
                        collectFunctionEffects(cls.destructor, owner ~ ".destroy", "destructor", prog.modulePath);
                    }
                    foreach (method; cls.methods) {
                        collectFunctionEffects(method, owner ~ "." ~ method.name, "method", prog.modulePath);
                    }
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
        // An "SDL_"-named struct (see sdl_core.llpl/sdl_audio.llpl) mirrors
        // a real SDL3 struct that <SDL3/SDL.h> already defines under its
        // own, unnamespaced tag (plain "SDL_Rect", not "std_sdl_SDL_Rect") -
        // matching the real header's own name exactly (skipping the
        // namespace prefix entirely, unlike every other struct) is what
        // lets `SDL_RenderRect(renderer, &rect)` (a real extern C function
        // whose prototype - see the isSdlBinding skip above - comes
        // straight from that header) accept a pointer to this struct as
        // the *same* C type, not a same-layout-but-distinct one GCC
        // rejects as an incompatible pointer type.
        if (st.name.startsWith("SDL_")) return st.name;
        return mangled(st.namespaceSegments, st.name);
    }

    // See mangledStruct's matching comment - same "SDL_"-named exception,
    // same reason (SDL_Event is the motivating case: a real SDL3 union).
    private string mangledUnion(UnionDecl ud) {
        if (ud.name.startsWith("SDL_")) return ud.name;
        return mangled(ud.namespaceSegments, ud.name);
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
        structDecl.isPublic = enumDecl.isPublic;

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
            bodyStmts ~= new ReturnStmt(new Identifier("__enum_result", variant.line, variant.column),
                variant.line, variant.column);

            auto ctor = new FunctionDecl(variant.name, variant.fields, resultType, new Block(bodyStmts),
                false, false, false, variant.line, variant.column);
            ctor.isPublic = enumDecl.isPublic;
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
    private ASTNode[] flattenNamespaces(ASTNode[] decls, string[] segments, string modulePath = "",
            bool publicContext = false) {
        ASTNode[] result;
        foreach (decl; decls) {
            bool effectivePublic = publicContext || decl.isPublic;
            if (auto usingStmt = cast(UsingNamespaceStmt)decl) {
                // Collect using-namespace declarations for this module
                if (modulePath !in moduleUsingNamespaces) {
                    moduleUsingNamespaces[modulePath] = [];
                }
                moduleUsingNamespaces[modulePath] ~= usingStmt.namespacePath;
                // Don't include in result - these are processed during name resolution
            } else if (auto ns = cast(NamespaceDecl)decl) {
                if (ns.enumBackingType !is null) {
                    auto enumAlias = new AliasDecl(ns.name, [ns.enumBackingType.name],
                        ns.enumBackingType.pointerDepth, ns.enumBackingType.isArray,
                        ns.enumBackingType.arraySize, ns.line, ns.column);
                    enumAlias.namespaceSegments = segments;
                    enumAlias.isPublic = effectivePublic;
                    result ~= enumAlias;
                }
                result ~= flattenNamespaces(ns.declarations, segments ~ ns.name, modulePath, effectivePublic);
            } else if (auto funcDecl = cast(FunctionDecl)decl) {
                funcDecl.namespaceSegments = segments;
                funcDecl.isPublic = effectivePublic;
                result ~= funcDecl;
            } else if (auto classDecl = cast(ClassDecl)decl) {
                classDecl.namespaceSegments = segments;
                classDecl.isPublic = effectivePublic;
                result ~= classDecl;
            } else if (auto structDecl = cast(StructDecl)decl) {
                structDecl.namespaceSegments = segments;
                structDecl.isPublic = effectivePublic;
                result ~= structDecl;
            } else if (auto unionDecl = cast(UnionDecl)decl) {
                unionDecl.namespaceSegments = segments;
                unionDecl.isPublic = effectivePublic;
                result ~= unionDecl;
            } else if (auto uiDecl = cast(UiDecl)decl) {
                uiDecl.namespaceSegments = segments;
                uiDecl.isPublic = effectivePublic;
                result ~= uiDecl;
            } else if (auto enumDecl = cast(EnumDecl)decl) {
                enumDecl.namespaceSegments = segments;
                enumDecl.isPublic = effectivePublic;
                result ~= enumDecl;
            } else if (auto grammarDecl = cast(GrammarDecl)decl) {
                grammarDecl.namespaceSegments = segments;
                grammarDecl.isPublic = effectivePublic;
                result ~= grammarDecl;
            } else if (auto varDecl = cast(VarDecl)decl) {
                varDecl.namespaceSegments = segments;
                varDecl.isPublic = effectivePublic;
                result ~= varDecl;
            } else if (auto aliasDecl = cast(AliasDecl)decl) {
                aliasDecl.namespaceSegments = segments;
                aliasDecl.isPublic = effectivePublic;
                result ~= aliasDecl;
            } else if (auto arrayAliasDecl = cast(ArrayAliasDecl)decl) {
                arrayAliasDecl.namespaceSegments = segments;
                arrayAliasDecl.isPublic = effectivePublic;
                result ~= arrayAliasDecl;
            } else if (auto macroDecl = cast(MacroDecl)decl) {
                macroDecl.namespaceSegments = segments;
                macroDecl.isPublic = effectivePublic;
                result ~= macroDecl;
            } else if (auto traitDecl = cast(TraitDecl)decl) {
                traitDecl.namespaceSegments = segments;
                traitDecl.isPublic = effectivePublic;
                result ~= traitDecl;
            } else if (auto implDecl = cast(ImplDecl)decl) {
                implDecl.namespaceSegments = segments;
                implDecl.isPublic = effectivePublic;
                result ~= implDecl;
            } else if (auto unitTestDecl = cast(UnitTestDecl)decl) {
                unitTestDecl.namespaceSegments = segments;
                unitTestDecl.isPublic = effectivePublic;
                result ~= unitTestDecl;
            } else if (auto linkDecl = cast(LinkDecl)decl) {
                // Not namespace-scoped (see LinkDecl's own doc comment) -
                // passed through unchanged, same as the fallback branch
                // below would do anyway; called out explicitly so it's
                // clear this is deliberate, not an oversight.
                result ~= linkDecl;
            } else if (auto flagsDecl = cast(FlagsDecl)decl) {
                // Same as LinkDecl just above.
                result ~= flagsDecl;
            } else {
                result ~= decl;
            }
        }
        return result;
    }

    private void collectExplicitExportModes(Program[] programs) {
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (decl.isPublic) {
                    moduleHasExplicitExports[prog.modulePath] = true;
                    break;
                }
            }
        }
    }

    private bool shouldExportDecl(string modulePath, ASTNode decl) {
        if (auto fn = cast(FunctionDecl)decl) {
            if (fn.isPrivate) return false;
        }
        return (modulePath !in moduleHasExplicitExports) || decl.isPublic;
    }

    private void exportDeclSymbol(string modulePath, ASTNode decl, string key) {
        if (shouldExportDecl(modulePath, decl)) {
            exportsByModule[modulePath][key] = true;
        }
    }

    private bool uiCaptureExists(Capture[] captures, string name) {
        foreach (cap; captures) {
            if (cap.name == name) return true;
        }
        return false;
    }

    private Capture[] uiCallbackCaptures(Capture[] existing, string[] namedUiVars) {
        Capture[] captures = existing.dup;
        foreach (name; namedUiVars) {
            if (!uiCaptureExists(captures, name)) {
                captures ~= new Capture(name, false);
            }
        }
        return captures;
    }

    private string desugarUiNode(UiNode node, string parentVar, ref ASTNode[] stmts, ref int counter, ref string[] namedUiVars) {
        string varName = node.instanceName.length > 0 ? node.instanceName : format("__ui%d", counter++);
        stmts ~= new VarDecl(varName, new Type(node.typeName),
            new NewExpr(new Type(node.typeName), [], node.line, node.column),
            false, node.line, node.column);
        if (node.instanceName.length > 0 && !namedUiVars.canFind(node.instanceName)) {
            namedUiVars ~= node.instanceName;
        }

        foreach (prop; node.properties) {
            ASTNode value;
            if (prop.isHandler) {
                value = cast(ASTNode)new LambdaExpr(uiCallbackCaptures([], namedUiVars), [],
                    new Type("void"), prop.handlerBody, prop.line, prop.column);
            } else if (auto lambda = cast(LambdaExpr)prop.value) {
                value = cast(ASTNode)new LambdaExpr(uiCallbackCaptures(lambda.captures, namedUiVars),
                    lambda.params, lambda.returnType, lambda.body_, lambda.line, lambda.column);
            } else {
                value = prop.value;
            }
            // A callback property has two spellings - the shorthand block
            // (`onClick: { ... }`, which parser.d turns into isHandler with
            // a bare Block) and an explicit lambda (`onClick: func() { ... }`,
            // which comes through the ordinary expression path). Both must
            // set the companion `has_<name>` flag the widget classes test
            // before invoking a handler, otherwise the lambda spelling
            // assigns a live closure that nothing ever calls.
            bool setsHandler = prop.isHandler || cast(LambdaExpr)prop.value !is null;
            stmts ~= new ExprStmt(new BinaryExpr("=",
                new MemberExpr(new Identifier(varName, prop.line, prop.column), prop.name, prop.line, prop.column),
                value, prop.line, prop.column));
            if (setsHandler) {
                stmts ~= new ExprStmt(new BinaryExpr("=",
                    new MemberExpr(new Identifier(varName, prop.line, prop.column),
                        "has_" ~ prop.name, prop.line, prop.column),
                    new BoolLiteral(true, prop.line, prop.column), prop.line, prop.column));
            }
        }

        if (parentVar.length > 0) {
            stmts ~= new ExprStmt(new CallExpr(
                new MemberExpr(new Identifier(parentVar, node.line, node.column), "add_child", node.line, node.column),
                [new Identifier(varName, node.line, node.column)], node.line, node.column));
        }

        foreach (child; node.children) {
            desugarUiNode(child, varName, stmts, counter, namedUiVars);
        }

        return varName;
    }

    private FunctionDecl desugarUiDecl(UiDecl decl) {
        ASTNode[] stmts;
        int counter = 0;
        string[] namedUiVars;
        decl.root.instanceName = decl.name;
        string rootVar = desugarUiNode(decl.root, "", stmts, counter, namedUiVars);
        stmts ~= new ReturnStmt(new Identifier(rootVar, decl.line, decl.column), decl.line, decl.column);

        auto fn = new FunctionDecl("build", [], new Type(decl.root.typeName),
            new Block(stmts), false, false, false, decl.line, decl.column);
        fn.namespaceSegments = decl.namespaceSegments ~ decl.name;
        return fn;
    }

    string generateMultiple(Program[] programs) {
        string code = "";
        StopWatch codegenPhaseTimer;
        codegenPhaseTimer.start();
        void finishCodegenPhase(ref double target) {
            codegenPhaseTimer.stop();
            target += codegenPhaseTimer.peek().total!"msecs";
            codegenPhaseTimer.reset();
            codegenPhaseTimer.start();
        }

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

        // Expand hardware descriptor imports before namespace flattening so
        // generated device constants use the same namespace/name-resolution
        // path as handwritten LLPL declarations.
        foreach (prog; programs) {
            prog.declarations = expandDeviceDescriptors(prog.declarations, prog.modulePath);
        }

        // Resolve namespace blocks into flat, mangled top-level declarations
        // before anything else looks at prog.declarations.
        foreach (prog; programs) {
            prog.declarations = flattenNamespaces(prog.declarations, [], prog.modulePath);
        }

        checkTargetProfile(programs);

        // Collect `#link "NAME"` directives from every module into a flat,
        // deduplicated list (see linkLibraries' own doc comment) - a shared
        // library like SDL3 only needs to be named once even if several
        // modules (or the same one, imported more than once) all declare it.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto linkDecl = cast(LinkDecl)decl) {
                    if (!linkLibraries.canFind(linkDecl.libraryName)) {
                        linkLibraries ~= linkDecl.libraryName;
                    }
                } else if (auto flagsDecl = cast(FlagsDecl)decl) {
                    if (!compilerFlags.canFind(flagsDecl.flags)) {
                        compilerFlags ~= flagsDecl.flags;
                    }
                }
            }
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

        // Desugar `grammar Name { ... }` blocks into the ClassDecl they
        // actually compile to (see grammar.d's desugarGrammar) - same
        // "before anything else looks at prog.declarations" placement and
        // reasoning as the tagged-enum desugaring just above.
        foreach (prog; programs) {
            ASTNode[] withGrammarsDesugared;
            foreach (decl; prog.declarations) {
                if (auto grammarDecl = cast(GrammarDecl)decl) {
                    withGrammarsDesugared ~= desugarGrammar(grammarDecl, prog.modulePath);
                } else {
                    withGrammarsDesugared ~= decl;
                }
            }
            prog.declarations = withGrammarsDesugared;
        }

        // Desugar `ui Name: Root { ... }` into a normal `Name.build()`
        // function before registries/reachability/codegen see declarations.
        foreach (prog; programs) {
            ASTNode[] withUiDesugared;
            foreach (decl; prog.declarations) {
                if (auto uiDecl = cast(UiDecl)decl) {
                    auto desugared = desugarUiDecl(uiDecl);
                    desugared.isPublic = uiDecl.isPublic;
                    withUiDesugared ~= desugared;
                } else {
                    withUiDesugared ~= decl;
                }
            }
            prog.declarations = withUiDesugared;
        }

        collectExplicitExportModes(programs);

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
                        exportDeclSymbol(prog.modulePath, funcDecl, key);
                        continue;
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.typeParams.length > 0) {
                        string key = mangledClass(classDecl);
                        genericClassTemplates[key] = classDecl;
                        genericTemplateModulePath[key] = prog.modulePath;
                        exportDeclSymbol(prog.modulePath, classDecl, key);
                        continue;
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    if (structDecl.typeParams.length > 0) {
                        string key = mangledStruct(structDecl);
                        genericStructTemplates[key] = structDecl;
                        genericTemplateModulePath[key] = prog.modulePath;
                        exportDeclSymbol(prog.modulePath, structDecl, key);
                        continue;
                    }
                } else if (auto traitDecl = cast(TraitDecl)decl) {
                    // A trait is purely a compile-time contract - it never
                    // produces any C code itself (same treatment as
                    // MacroDecl), so registering it is all that's needed.
                    string key = mangled(traitDecl.namespaceSegments, traitDecl.name);
                    traitRegistry[key] = traitDecl;
                    traitModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, traitDecl, key);
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
        finishCodegenPhase(codegenPreprocessTime);

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
                    bool isTypeAlias = aliasDecl.targetType !is null ||
                        aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
                        (aliasDecl.targetPath.length == 1 &&
                            (isPrimitiveTypeName(aliasDecl.targetPath[0]) ||
                             isKnownTypeName(aliasDecl.targetPath[0])));
                    if (isTypeAlias) {
                        string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);
                        // An `alias X = u32` target is parsed as a plain
                        // dotted identifier path, not a type annotation, so
                        // it never goes through the parser's short-form
                        // rewrite (see canonicalIntTypeName) - normalize it
                        // here too, or primitiveToC (which only knows the
                        // long forms) emits the literal, meaningless C type
                        // name "u32" verbatim.
                        if (aliasDecl.targetType !is null) {
                            typeAliases[mangledName] = cloneType(aliasDecl.targetType);
                        } else {
                            string baseName = aliasDecl.targetPath.length == 1 ?
                                canonicalIntTypeName(aliasDecl.targetPath[0]) : aliasDecl.targetPath.join("_");
                            typeAliases[mangledName] = new Type(baseName, aliasDecl.targetPointerDepth,
                                aliasDecl.targetIsArray, aliasDecl.targetArraySize);
                        }
                        typeAliasModulePath[mangledName] = prog.modulePath;
                        exportDeclSymbol(prog.modulePath, aliasDecl, mangledName);
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
                        if (key !in functionCandidateModulePath) functionCandidateModulePath[key] = prog.modulePath;
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
                    exportDeclSymbol(prog.modulePath, funcDecl, key);
                    originalFreeFunctionKeys[key] = true;
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    string key = mangledClass(classDecl);
                    classRegistry[key] = classDecl;
                    classModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, classDecl, key);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    string key = mangledStruct(structDecl);
                    structRegistry[key] = structDecl;
                    structModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, structDecl, key);
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    string key = mangledUnion(unionDecl);
                    unionRegistry[key] = unionDecl;
                    unionModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, unionDecl, key);
                } else if (auto macroDecl = cast(MacroDecl)decl) {
                    string key = mangled(macroDecl.namespaceSegments, macroDecl.name);
                    macroRegistry[key] = macroDecl;
                    macroModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, macroDecl, key);
                } else if (auto varDecl = cast(VarDecl)decl) {
                    string key = mangled(varDecl.namespaceSegments, varDecl.name);
                    globalVarRegistry[key] = varDecl;
                    globalVarModulePath[key] = prog.modulePath;
                    exportDeclSymbol(prog.modulePath, varDecl, key);
                }
            }
        }

        // Build per-module import metadata (aliases, selective imports) now
        // that every module's exports are known.
        collectImports(programs);

        // Namespace aliases must be known before reachability analysis runs,
        // since qualified calls like `hf.greet()` rely on them.
        collectNamespaceAliases(programs);

        // Compute which free functions are reachable before any code is
        // emitted, so the forward-decl and definition loops below can skip
        // the dead ones.
        computeReachableFunctions(programs);
        finishCodegenPhase(codegenRegistryTime);

        // Process every parked `impl Trait for Type { ... }` block now
        // that classRegistry/structRegistry are populated (so a
        // user-defined target type resolves correctly) but before the
        // field-resolution pass just below - the earliest point a generic
        // instantiation's trait-bound check could otherwise fire, which
        // needs traitImplemented already populated (see processImplBlock).
        foreach (i, impl; pendingImpls) {
            currentModulePath = pendingImplModulePaths[i];
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
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    currentNamespaceSegments = unionDecl.namespaceSegments;
                    foreach (field; unionDecl.fields) {
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

        // Resolve `class Derived : Base { ... }` base-class references now
        // that classRegistry is fully populated (line ~1044) - canonicalizes
        // baseClassName in place (namespace-qualified) the same way an
        // ordinary field/parameter type name gets resolved via resolveType,
        // and enforces the scope this feature was built to: single
        // inheritance only, mutually exclusive with generics (a generic
        // ClassDecl's manual, non-reflective cloning in
        // cloneClassDeclWithTypeSubs would otherwise need to also thread
        // baseClassName through by hand, which it doesn't).
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.baseClassName.length == 0) continue;
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    auto baseType = new Type(classDecl.baseClassName);
                    resolveType(baseType);
                    auto basePtr = baseType.name in classRegistry;
                    if (basePtr is null) {
                        throw new CompileError(
                            format("Unknown base class '%s' for class '%s'",
                                classDecl.baseClassName, classDecl.name),
                            currentModulePath, classDecl.line, classDecl.column);
                    }
                    if (classDecl.typeParams.length > 0 || basePtr.typeParams.length > 0) {
                        throw new CompileError(
                            format("Class '%s' cannot inherit from '%s' - inheritance and generics " ~
                                "are mutually exclusive", classDecl.name, classDecl.baseClassName),
                            currentModulePath, classDecl.line, classDecl.column);
                    }
                    classDecl.baseClassName = baseType.name;
                }
            }
        }

        // Both registries are fully populated and every return type is
        // resolved, so the "does this call hand back a fresh reference"
        // table can be settled before a single expression is emitted (see
        // rcOwnedReturnSymbols).
        buildRcOwnedReturnSymbols();

        // Every baseClassName is now resolved/canonicalized - build the
        // "has subclasses" set (see hasSubclasses' own comment) and, for
        // every polymorphic class with zero explicit constructors written,
        // synthesize one implicit trivial constructor (no params, empty
        // body) so a subclass always has *some* real `_init` to chain
        // into via `super()` - mutated onto the shared ClassDecl object
        // itself (from classRegistry), not a local copy, so every other
        // class's own super()-resolution sees the same synthesized
        // constructor regardless of per-file generation order.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.baseClassName.length > 0) {
                        hasSubclasses[classDecl.baseClassName] = true;
                        subclassesOf[classDecl.baseClassName] ~= classDecl;
                    }
                }
            }
        }
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.constructors.length == 0 && isPolymorphic(classDecl)) {
                        classDecl.constructors ~= new FunctionDecl(
                            mangledClass(classDecl) ~ "_constructor", [], new Type("void"),
                            new Block([]), false, false, false, classDecl.line, classDecl.column);
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
        finishCodegenPhase(codegenAnalysisTime);

        // Include runtime header
        code ~= "/*\n";
        code ~= " * AUTO-GENERATED FILE - DO NOT EDIT.\n";
        code ~= " * This C source was generated by the LLPL compiler.\n";
        code ~= " * Edit the original .llpl source instead.\n";
        code ~= " */\n\n";
        code ~= "#include <stdint.h>\n";
        code ~= "#include <stddef.h>\n";
        code ~= "#include <stdbool.h>\n"; // for `bool` - see primitiveToC's own comment
        code ~= "#include \"runtime.h\"\n";

        // Check if SDL is used and include SDL3 headers
        bool usesSDL = false;
        foreach (prog; programs) {
            import std.algorithm : canFind;
            import std.uni : toLower;
            // Check if module path contains sdl
            if (prog.modulePath.toLower().canFind("sdl")) {
                usesSDL = true;
                break;
            }
        }

        if (usesSDL) {
            code ~= "#include <SDL3/SDL.h>\n";
            if (linkLibraries.canFind("SDL3_ttf")) {
                code ~= "#include <SDL3_ttf/SDL_ttf.h>\n";
            }
        }

        code ~= "#undef NULL\n";

        code ~= "\n";

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
                    // An "SDL_"-named struct's own typedef already exists,
                    // straight from <SDL3/SDL.h> - and unlike every other
                    // struct this codebase ever generates, some real SDL3
                    // types (SDL_Event) are actually a C `union`, not a
                    // `struct` - blindly forward-declaring "typedef struct
                    // SDL_Event SDL_Event;" here is a hard "defined as
                    // wrong kind of tag" error against that real
                    // definition, not a harmless redundant one. See
                    // mangledStruct/generateStruct's matching comments.
                    if (!structDecl.name.startsWith("SDL_")) {
                        string sName = mangledStruct(structDecl);
                        earlyDeclCode ~= format("typedef struct %s %s;\n", sName, sName);
                    }
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    // Same "SDL_"-prefix exception as the StructDecl case
                    // just above.
                    if (!unionDecl.name.startsWith("SDL_")) {
                        string uName = mangledUnion(unionDecl);
                        earlyDeclCode ~= format("typedef union %s %s;\n", uName, uName);
                    }
                }
            }
        }
        earlyDeclCode ~= "\n";

        // Shared vtable struct typedef, once per hierarchy root - must be
        // emitted before any class's own struct layout (the `void*
        // __vtable` field is untyped precisely so it never needs this) or
        // vtable-instance definition references it below, regardless of
        // per-file declaration order (a subclass can be declared textually
        // before its base). Iterated here, in its own pass straight after
        // the class/struct/union typedef loop above, rather than inline in
        // the main per-class forward-decl loop further down, for exactly
        // that reason - every class's own opaque struct tag already exists
        // by now, but a root reached only via a later-processed subclass
        // wouldn't have emitted its typedef yet if this were folded into
        // that per-class loop instead.
        foreach (prog; programs) {
            foreach (decl; prog.declarations) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.baseClassName.length > 0 || !isPolymorphic(classDecl)) continue;
                    string rootName = mangledClass(classDecl);
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    auto slots = collectVtableSlots(classDecl);
                    earlyDeclCode ~= "typedef struct {\n    void (*destroy)(void*);\n";
                    foreach (slot; slots) {
                        Type retType = cloneType(slot.returnType);
                        resolveType(retType);
                        string paramTypesC = format("%s*", rootName);
                        foreach (p; slot.params) {
                            auto pt = cloneType(p.type);
                            resolveType(pt);
                            paramTypesC ~= format(", %s", typeToC(pt));
                        }
                        earlyDeclCode ~= format("    %s (*%s)(%s);\n", typeToC(retType), slot.name, paramTypesC);
                    }
                    earlyDeclCode ~= format("} %s_VTable;\n\n", rootName);
                }
            }
        }

        // Forward declarations for functions and methods from all modules.
        // currentNamespaceSegments is set per-declaration so resolveType
        // resolves unqualified namespaced types exactly the way the real
        // definition will, keeping each forward declaration's signature
        // consistent with the definition that follows it later. currentModulePath
        // also has to track which module `decl` came from, not just its
        // namespace - enclosingQualifications' "using namespace" fallback
        // keys off moduleUsingNamespaces[currentModulePath], and without
        // this a free function whose parameter type only resolves via a
        // `using namespace` in its own module (not by namespace nesting)
        // gets forward-declared with the bare, unqualified type name -
        // stale from whichever module's path this was last left at -
        // instead of the real definition's correctly-qualified one.
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    if (enableUnitTests && isOrdinaryTopLevelMain(funcDecl)) continue;
                    if (!isReachableFreeFunction(funcDecl)) continue;
                    currentNamespaceSegments = funcDecl.namespaceSegments;
                    if (funcDecl.isExtern) {
                        // An `extern func SDL_Whatever(...)` binds to a
                        // real SDL3 library symbol that <SDL3/SDL.h> (see
                        // generateMultiple's own usesSDL check) already
                        // declares, correctly, including `const`-qualified
                        // pointer params LLPL's own type system has no way
                        // to spell (there's no "pointer to const" type at
                        // all - see this module's own header comments).
                        // Re-declaring it here too, with LLPL's best
                        // non-const approximation, doesn't just duplicate
                        // that declaration, it *conflicts* with it - GCC
                        // treats a bare `char*` extern re-declaration of a
                        // symbol the real header already declared
                        // `const char*` (or `SDL_FRect*` vs `const
                        // SDL_FRect*`, etc.) as a hard "conflicting types"
                        // error, not a harmless duplicate. Skipping the
                        // redeclaration for anything named like an SDL3
                        // symbol leaves the real header's own prototype as
                        // the only one in scope, which is both correct
                        // and sufficient - LLPL's own extern func still
                        // provides the parameter/return *types* codegen
                        // needs to generate a correct call site, it just
                        // doesn't need to also re-assert them to the C
                        // compiler.
                        bool isSdlBinding = funcDecl.name.startsWith("SDL_") || funcDecl.name.startsWith("TTF_");
                        if (!isSdlBinding) {
                            string params = "";
                            foreach (i, param; funcDecl.params) {
                                if (i > 0) params ~= ", ";
                                params ~= parameterDeclaration(param);
                            }
                            if (funcDecl.isVariadic) params ~= ", ...";
                            earlyDeclCode ~= format("extern %s %s(%s);\n",
                                typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
                        }
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
                            params ~= parameterDeclaration(param);
                        }
                        if (funcDecl.isVariadic) params ~= ", ...";
                        string baseName = mangleFreeFunctionName(funcDecl);
                        earlyDeclCode ~= format("%s%s %s(%s);\n",
                            inlineFunctionPrefix(funcDecl), typeToC(returnTypeForFwd),
                            baseName, params);
                        if (funcDecl.isAsync) {
                            string startParams = "void* __frame";
                            if (params.length > 0) startParams ~= ", " ~ params;
                            earlyDeclCode ~= format("uintptr_t %s_async_frame_size();\n", baseName);
                            earlyDeclCode ~= format("void %s_async_start_into(%s);\n", baseName, startParams);
                            earlyDeclCode ~= format("intptr_t %s_async_poll_erased(void* __frame, void* __out);\n", baseName);
                        }
                    }
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    currentNamespaceSegments = classDecl.namespaceSegments;
                    string cName = mangledClass(classDecl);
                    // Constructor forward declaration(s)
                    checkNoDuplicateSignatures(classDecl.constructors, format("constructor of '%s'", cName),
                        classDecl.line, classDecl.column);
                    bool classIsPolymorphic = isPolymorphic(classDecl);
                    if (classDecl.constructors.length == 0) {
                        earlyDeclCode ~= format("%s* %s_new();\n", cName, cName);
                    }
                    foreach (ctor; classDecl.constructors) {
                        string params = "";
                        foreach (i, param; ctor.params) {
                            resolveType(param.type);
                            if (i > 0) params ~= ", ";
                            params ~= parameterDeclaration(param);
                        }
                        earlyDeclCode ~= format("%s* %s(%s);\n", cName, mangleConstructorName(classDecl, cName, ctor), params);
                        // A polymorphic class's constructor also has an
                        // internal `_init` half (see
                        // generatePolymorphicConstructor) - a brand-new
                        // symbol with no pre-existing forward-decl site.
                        if (classIsPolymorphic) {
                            string initParams = format("%s* self%s", cName, params.length > 0 ? ", " ~ params : "");
                            earlyDeclCode ~= format("void %s(%s);\n",
                                mangleInitName(classDecl, cName, ctor), initParams);
                        }
                    }

                    // Destructor forward declaration. A polymorphic class
                    // always gets one regardless of whether it wrote its
                    // own destructor{} block (see generatePolymorphicDestructor) -
                    // a base-class-typed field/vtable slot must always
                    // resolve to something real - plus the internal
                    // __destroy_impl half.
                    if (classIsPolymorphic) {
                        earlyDeclCode ~= format("void %s_destroy(void* ptr);\n", cName);
                        earlyDeclCode ~= format("void %s__destroy_impl(void* ptr);\n", cName);
                    } else if (classDecl.destructor) {
                        earlyDeclCode ~= format("void %s_destroy(void* ptr);\n", cName);
                    }

                    // This class's own concrete vtable instance - one slot
                    // per distinct virtual/override method name anywhere in
                    // the whole hierarchy (see collectVtableSlots), each
                    // filled with whichever implementation this class
                    // itself actually resolves to (its own override, or the
                    // nearest ancestor's, via resolveMethodOnHierarchy -
                    // the same lookup a call site uses). Built here, in the
                    // same pass as every method's forward declaration, but
                    // *appended to a separate buffer* rather than
                    // earlyDeclCode directly and spliced in right after it
                    // (see generateMultiple) - the initializer can
                    // reference any class's method by name, including one
                    // from a class not yet reached by this same loop, and
                    // needs every prototype to already exist first. A
                    // function pointer cast is required at each slot
                    // (rather than changing the method's own C signature)
                    // because the slot's declared parameter type is the
                    // hierarchy *root's* pointer type, while the actual
                    // implementing function's `self` is typed to whichever
                    // class really declares it - exactly the same
                    // prefix-compatible-but-nominally-different-types
                    // situation the `super(...)` chaining call already
                    // works around with an explicit cast.
                    if (classIsPolymorphic) {
                        ClassDecl root = hierarchyRoot(classDecl);
                        string rootName = mangledClass(root);
                        auto slots = collectVtableSlots(root);
                        string vtCode = format("static %s_VTable %s_vtable = {\n", rootName, cName);
                        vtCode ~= format("    .destroy = %s__destroy_impl,\n", cName);
                        foreach (slot; slots) {
                            ClassDecl owner;
                            auto candidates = resolveMethodOnHierarchy(classDecl, slot.name, owner);
                            if (candidates.length == 0) continue;
                            string implSymbol = mangleMethodName(owner, mangledClass(owner), candidates[0]);
                            Type retType = cloneType(slot.returnType);
                            resolveType(retType);
                            string paramTypesC = format("%s*", rootName);
                            foreach (p; slot.params) {
                                auto pt = cloneType(p.type);
                                resolveType(pt);
                                paramTypesC ~= format(", %s", typeToC(pt));
                            }
                            vtCode ~= format("    .%s = (%s (*)(%s))%s,\n",
                                slot.name, typeToC(retType), paramTypesC, implSymbol);
                        }
                        vtCode ~= "};\n\n";
                        vtableInstanceDefs ~= vtCode;
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
                        string params = "";
                        // Static methods don't receive a 'self' parameter
                        if (!method.isStatic) {
                            params = format("%s* self", cName);
                        }
                        foreach (i, param; method.params) {
                            resolveType(param.type);
                            if (!method.isStatic || i > 0) params ~= ", ";
                            params ~= parameterDeclaration(param);
                        }
                        earlyDeclCode ~= format("%s%s %s(%s);\n",
                            inlineFunctionPrefix(method), typeToC(returnTypeForFwd),
                            mangleMethodName(classDecl, cName, method), params);
                        if (method.isAsync) {
                            string baseName = mangleMethodName(classDecl, cName, method);
                            string startParams = "void* __frame";
                            if (params.length > 0) startParams ~= ", " ~ params;
                            earlyDeclCode ~= format("uintptr_t %s_async_frame_size();\n", baseName);
                            earlyDeclCode ~= format("void %s_async_start_into(%s);\n", baseName, startParams);
                            earlyDeclCode ~= format("intptr_t %s_async_poll_erased(void* __frame, void* __out);\n", baseName);
                        }
                    }
                } else if (auto structDecl = cast(StructDecl)decl) {
                    // Constructor forward declaration(s) - see
                    // generateStructConstructor's own comment: unlike a
                    // class constructor, this returns the struct *by
                    // value* (no trailing `*`), and there's no destructor/
                    // methods branch to mirror since a struct has neither.
                    if (structDecl.constructors.length > 0) {
                        currentNamespaceSegments = structDecl.namespaceSegments;
                        string sName = mangledStruct(structDecl);
                        checkNoDuplicateSignatures(structDecl.constructors, format("constructor of '%s'", sName),
                            structDecl.line, structDecl.column);
                        foreach (ctor; structDecl.constructors) {
                            string params = "";
                            foreach (i, param; ctor.params) {
                                resolveType(param.type);
                                if (i > 0) params ~= ", ";
                                params ~= parameterDeclaration(param);
                            }
                            earlyDeclCode ~= format("%s %s(%s);\n", sName, mangleConstructorName(structDecl, sName, ctor), params);
                        }
                    }
                    // Method forward declaration(s) - struct methods receive
                    // a pointer receiver, like class methods, so mutations
                    // and address-taking operate on the caller's value.
                    if (structDecl.methods.length > 0) {
                        currentNamespaceSegments = structDecl.namespaceSegments;
                        string sName = mangledStruct(structDecl);
                        bool[string] checkedMethodNames;
                        foreach (method; structDecl.methods) {
                            if (method.name !in checkedMethodNames) {
                                checkedMethodNames[method.name] = true;
                                checkNoDuplicateSignatures(methodCandidatesNamed(structDecl, method.name),
                                    format("method '%s.%s'", sName, method.name), method.line, method.column);
                            }
                            Type returnTypeForFwd = cloneType(method.returnType);
                            resolveType(returnTypeForFwd);
                            string params = format("%s* self", sName);
                            foreach (param; method.params) {
                                resolveType(param.type);
                                params ~= ", " ~ parameterDeclaration(param);
                            }
                            earlyDeclCode ~= format("%s%s %s(%s);\n",
                                inlineFunctionPrefix(method), typeToC(returnTypeForFwd),
                                mangleMethodName(structDecl, sName, method), params);
                        }
                    }
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    // Same shape as the StructDecl case just above.
                    if (unionDecl.constructors.length > 0) {
                        currentNamespaceSegments = unionDecl.namespaceSegments;
                        string uName = mangledUnion(unionDecl);
                        checkNoDuplicateSignatures(unionDecl.constructors, format("constructor of '%s'", uName),
                            unionDecl.line, unionDecl.column);
                        foreach (ctor; unionDecl.constructors) {
                            string params = "";
                            foreach (i, param; ctor.params) {
                                resolveType(param.type);
                                if (i > 0) params ~= ", ";
                                params ~= parameterDeclaration(param);
                            }
                            earlyDeclCode ~= format("%s %s(%s);\n", uName, mangleConstructorName(unionDecl, uName, ctor), params);
                        }
                    }
                    if (unionDecl.methods.length > 0) {
                        currentNamespaceSegments = unionDecl.namespaceSegments;
                        string uName = mangledUnion(unionDecl);
                        bool[string] checkedMethodNames;
                        foreach (method; unionDecl.methods) {
                            if (method.name !in checkedMethodNames) {
                                checkedMethodNames[method.name] = true;
                                checkNoDuplicateSignatures(methodCandidatesNamed(unionDecl, method.name),
                                    format("method '%s.%s'", uName, method.name), method.line, method.column);
                            }
                            Type returnTypeForFwd = cloneType(method.returnType);
                            resolveType(returnTypeForFwd);
                            string params = format("%s* self", uName);
                            foreach (param; method.params) {
                                resolveType(param.type);
                                params ~= ", " ~ parameterDeclaration(param);
                            }
                            earlyDeclCode ~= format("%s%s %s(%s);\n",
                                inlineFunctionPrefix(method), typeToC(returnTypeForFwd),
                                mangleMethodName(unionDecl, uName, method), params);
                        }
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
                    bool needsCompleteElement = !varDecl.type.isPointer &&
                        (isStructTypeName(varDecl.type.name) || isUnionTypeName(varDecl.type.name));
                    if (varDecl.type.isArray && varDecl.type.arraySize > 0 && needsCompleteElement) {
                        // An array of struct/union values (not pointers) needs
                        // its element type *complete* even just to declare the
                        // array's size - but aggregate bodies aren't defined
                        // until later in the file (after all these forward
                        // declarations). Class-typed arrays are arrays of
                        // pointers, so they can be declared with only the
                        // earlier opaque typedef.
                    } else if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
                        string baseType = fixedArrayElementCType(varDecl.type);
                        earlyDeclCode ~= format("extern %s%s %s[%d]%s;\n", constPrefix, baseType, cName,
                            varDecl.type.arraySize, extraDimsSuffix(varDecl.type));
                    } else {
                        earlyDeclCode ~= format("extern %s%s %s;\n", constPrefix, typeToC(varDecl.type), cName);
                    }
                }
            }
        }
        earlyDeclCode ~= "\n";
        finishCodegenPhase(codegenForwardDeclTime);

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
        // Collected into structDeclCode and classDeclCode separately to ensure
        // proper ordering: all structs before all classes to avoid dependency issues.
        string structDeclCode = "";
        string classDeclCode = "";
        unitTestCounter = 0;

        // Every plain struct/union/class's *layout* only (struct/union
        // header + fields, no constructors/destructor/methods) - see
        // generateClassLayout/generateStructLayout/generateUnionLayout's
        // own comments. Emitted before any generic instantiation (this
        // file's own "1. Generic struct instances" comment below), since
        // a generic instantiated with a plain type used by value - e.g.
        // Vector<String>, whose methods do `sizeof(String)`-style pointer
        // arithmetic over a `String*` buffer - needs that plain type's
        // layout complete first. structDeclCode/classDeclCode (just below)
        // hold the *rest* (constructors/destructor/methods) instead, kept
        // at their original position after generic instantiations, since
        // those bodies just as often need a generic instance complete
        // first (a method that constructs/unwraps a Result<T,E>) - see
        // this file's own git history for the "invalid use of incomplete
        // typedef 'Result_int_char_ptr'" regression an earlier ordering
        // caused, and the "invalid use of incomplete typedef 'String'"
        // one this layoutCode split fixes.
        string layoutCode = "";

        // First pass: generate all structs (and unions - same "plain
        // value type, no dependency on classes" shape)
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            bool hasStructs = false;
            foreach (decl; prog.declarations) {
                auto structDecl = cast(StructDecl)decl;
                auto unionDecl = cast(UnionDecl)decl;
                if (structDecl !is null || unionDecl !is null) {
                    if (!hasStructs) {
                        if (prog.modulePath.length > 0) {
                            structDeclCode ~= format("// Module: %s (structs)\n", prog.modulePath);
                        }
                        hasStructs = true;
                    }
                    try {
                        layoutCode ~= structDecl !is null ?
                            generateStructLayout(structDecl) : generateUnionLayout(unionDecl);
                        layoutCode ~= "\n";
                        structDeclCode ~= structDecl !is null ?
                            generateStructMethods(structDecl) : generateUnionMethods(unionDecl);
                        structDeclCode ~= "\n";
                    } catch (CompileError e) {
                        collectedErrors ~= e;
                    }
                }
            }
        }

        // Second pass: generate all non-struct declarations (classes, functions, etc.)
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            bool hasNonStructs = false;
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
                if (cast(StructDecl)decl || cast(UnionDecl)decl) {
                    continue;  // Already generated in first pass
                }
                // Caught and collected, not left to abort the whole
                // compile - see collectedErrors's own comment. Safe to
                // just skip this one declaration's contribution to
                // classDeclCode and move on: every registry/field/generic-
                // template resolution any *other* declaration could
                // depend on already happened in the passes above, so
                // this declaration's own failure can't cascade into a
                // false error anywhere else. None of classDeclCode ends up
                // used anyway once collectedErrors is non-empty (see the
                // very end of this function).
                if (!hasNonStructs) {
                    if (prog.modulePath.length > 0) {
                        classDeclCode ~= format("// Module: %s\n", prog.modulePath);
                    }
                    hasNonStructs = true;
                }
                try {
                    auto classDecl = cast(ClassDecl)decl;
                    if (classDecl !is null) {
                        layoutCode ~= generateClassLayout(classDecl);
                        layoutCode ~= "\n";
                        classDeclCode ~= generateClassMethods(classDecl);
                    } else {
                        classDeclCode ~= generateDeclaration(decl);
                    }
                    classDeclCode ~= "\n";
                } catch (CompileError e) {
                    collectedErrors ~= e;
                }
            }
        }

        string abiAssertCode = generateAbiAssertions(programs);
        finishCodegenPhase(codegenDeclarationTime);

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

        // Regular class forward declarations must come before generic instance bodies
        // so that generic destructors can call regular class destructors
        code ~= earlyDeclCode;

        // Vtable instance definitions - see their own construction comment
        // (in the per-class forward-decl loop above) for why these are
        // spliced in right here rather than folded into earlyDeclCode
        // itself: every method/constructor/destructor across every class
        // is now forward-declared (earlyDeclCode just above is complete),
        // so an initializer here can safely name any of them regardless of
        // which class it belongs to or where it sits in the source.
        if (vtableInstanceDefs.length > 0) {
            code ~= "// Vtable instances - one per concrete polymorphic class\n";
            foreach (vtDef; vtableInstanceDefs) {
                code ~= vtDef;
            }
            code ~= "\n";
        }

        if (interpBufferDecls.length > 0) {
            code ~= "// String-interpolation scratch buffers (one per `\\(...)` call site)\n";
            foreach (bufDecl; interpBufferDecls) {
                code ~= bufDecl;
            }
            code ~= "\n";
        }

        if (lambdaForwardDecls.length > 0) {
            code ~= "// Lambda literal environment structs + trampoline prototypes\n";
            foreach (lambdaDecl; lambdaForwardDecls) {
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

        // Output in dependency order.
        // 0. Every plain struct/union/class's layout (see layoutCode's
        // own comment) - before anything that might need one of them
        // complete, including the generic instantiations just below.
        code ~= layoutCode;

        // Generic instantiations (Result<T,E>, Optional<T>, ...) go next,
        // matching this codebase's own prior, long-proven-correct
        // ordering (genericInstanceDecls used to be emitted before
        // earlyDeclCode entirely) - plain top-level functions in
        // classDeclCode routinely propagate/unwrap a Result<T,E>/
        // Optional<T> (via `?`, match, etc.), so those monomorphized
        // class bodies must be *fully* defined before classDeclCode, not
        // after it: emitting genericClassInstances after classDeclCode
        // (as a struct-vs-class split first did) left every such call
        // site referencing an incomplete typedef - see this file's own
        // git history for the "invalid use of incomplete typedef
        // 'Result_int_char_ptr'" regression this fixed.
        // 1. Generic struct instances (e.g., Slice<char>)
        if (genericStructInstances.length > 0) {
            code ~= "// Monomorphized struct instantiations\n";
            foreach (instDecl; genericStructInstances) {
                code ~= instDecl;
            }
            code ~= "\n";
        }

        // 2. Generic class instances (e.g., Vector<String>, Result<T,E>)
        if (genericClassInstances.length > 0) {
            code ~= "// Monomorphized class instantiations\n";
            foreach (instDecl; genericClassInstances) {
                code ~= instDecl;
            }
            code ~= "\n";
        }

        code ~= abiAssertCode;

        // 3. Regular structs
        code ~= structDeclCode;

        // 4. Regular classes
        code ~= classDeclCode;
        if (enableUnitTests) {
            code ~= generateUnitTestMain(unitTestCounter);
        }

        if (deferredFunctionBodies.length > 0) {
            code ~= "// Function bodies deferred until after plain class/struct definitions exist\n";
            foreach (b; deferredFunctionBodies) {
                code ~= b;
            }
            code ~= "\n";
        }

        if (lambdaBodyDecls.length > 0) {
            code ~= "// Lambda literal trampoline functions\n";
            foreach (lambdaDecl; lambdaBodyDecls) {
                code ~= lambdaDecl;
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

        collectEffects(programs);
        collectSymbolTable(programs);
        finishCodegenPhase(codegenAssemblyMetadataTime);

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
            if (enableUnitTests && isOrdinaryTopLevelMain(funcDecl)) return "";
            if (!isReachableFreeFunction(funcDecl)) return "";
            return withSourceLine(node, generateFunction(funcDecl));
        } else if (auto unitTestDecl = cast(UnitTestDecl)node) {
            if (!enableUnitTests) return "";
            return withSourceLine(node, generateUnitTestFunction(unitTestDecl, unitTestCounter++));
        } else if (auto classDecl = cast(ClassDecl)node) {
            return withSourceLine(node, generateClass(classDecl));
        } else if (auto structDecl = cast(StructDecl)node) {
            return withSourceLine(node, generateStruct(structDecl));
        } else if (auto unionDecl = cast(UnionDecl)node) {
            return withSourceLine(node, generateUnion(unionDecl));
        } else if (auto varDecl = cast(VarDecl)node) {
            return withSourceLine(node, generateGlobalVar(varDecl));
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            return withSourceLine(node, generateAlias(aliasDecl));
        }
        return "";
    }

    // True if some real, registered symbol's mangled name starts with
    // `prefix ~ "_"` - i.e. `prefix` names an actual namespace (or part of
    // one), even though it's never a symbol in its own right the way
    // resolveAliasTarget's exact-match check requires. Checked once, at
    // an `alias`'s own declaration (see generateAlias); not on any hot
    // path.
    private bool isNamespacePrefix(string prefix) {
        string withUnderscore = prefix ~ "_";
        foreach (key; functionRegistry.byKey()) if (key.startsWith(withUnderscore)) return true;
        foreach (key; classRegistry.byKey()) if (key.startsWith(withUnderscore)) return true;
        foreach (key; structRegistry.byKey()) if (key.startsWith(withUnderscore)) return true;
        foreach (key; variableTypes.byKey()) if (key.startsWith(withUnderscore)) return true;
        return false;
    }

    // If `flatName` starts with a namespace alias's own mangled name
    // (see namespaceAliases), substitutes that alias for the real
    // namespace prefix it stands for - e.g. "hf_Bar" -> "HAL_Foo_Bar".
    // Unlike resolveAliasedQualifiedName (module aliases), there's no
    // separate "does the target module actually export this" check
    // needed: a namespace alias names a prefix within this same compiled
    // program, so the substituted name either is a real registered
    // symbol (checked by the caller's own `exists` predicate) or isn't.
    private string resolveNamespaceAlias(string flatName) {
        foreach (aliasName, prefix; namespaceAliases) {
            string withUnderscore = aliasName ~ "_";
            if (!flatName.startsWith(withUnderscore)) continue;
            string suffix = flatName[withUnderscore.length .. $];
            if (suffix.length == 0) continue;
            return prefix ~ "_" ~ suffix;
        }
        return "";
    }

    // Like isKnownSymbol, but also includes global variables so alias
    // collection can run before any function-level variableTypes exist.
    private bool isKnownSymbolForAlias(string name) {
        return (name in functionRegistry) !is null || (name in classRegistry) !is null ||
               (name in structRegistry) !is null || (name in globalVarRegistry) !is null;
    }

    // True if `name` already names a concrete type and can be used as the
    // target of a type alias.
    private bool isKnownTypeName(string name) {
        return (name in classRegistry) !is null || (name in structRegistry) !is null ||
               (name in unionRegistry) !is null || (name in typeAliases) !is null ||
               (name in genericClassTemplates) !is null || (name in genericStructTemplates) !is null;
    }

    // Namespace aliases (`alias hf = HAL.Foo`) are needed by dead-code
    // reachability, which runs before generateAlias is called. Pre-register
    // them here; generateAlias will re-register them harmlessly when it
    // emits the alias #defines later.
    private void collectNamespaceAliases(Program[] programs) {
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                auto aliasDecl = cast(AliasDecl)decl;
                if (aliasDecl is null) continue;
                currentNamespaceSegments = aliasDecl.namespaceSegments;
                string mangledName = mangled(aliasDecl.namespaceSegments, aliasDecl.name);

                bool isTypeAlias = aliasDecl.targetType !is null ||
                    aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
                    (aliasDecl.targetPath.length == 1 &&
                        (isPrimitiveTypeName(aliasDecl.targetPath[0]) ||
                         isKnownTypeName(aliasDecl.targetPath[0]))) ||
                    isKnownTypeName(aliasDecl.targetPath.join("_"));
                if (isTypeAlias) continue;

                string flatTarget = aliasDecl.targetPath.join("_");
                if (!isKnownSymbolForAlias(flatTarget) && isNamespacePrefix(flatTarget)) {
                    namespaceAliases[mangledName] = flatTarget;
                }
            }
            foreach (decl; prog.declarations) {
                if (auto funcDecl = cast(FunctionDecl)decl) {
                    collectLocalNamespaceAliases(funcDecl.body_);
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    foreach (ctor; classDecl.constructors) collectLocalNamespaceAliases(ctor.body_);
                    if (classDecl.destructor !is null) collectLocalNamespaceAliases(classDecl.destructor.body_);
                    foreach (method; classDecl.methods) collectLocalNamespaceAliases(method.body_);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    foreach (ctor; structDecl.constructors) collectLocalNamespaceAliases(ctor.body_);
                    foreach (method; structDecl.methods) collectLocalNamespaceAliases(method.body_);
                } else if (auto unionDecl = cast(UnionDecl)decl) {
                    foreach (ctor; unionDecl.constructors) collectLocalNamespaceAliases(ctor.body_);
                    foreach (method; unionDecl.methods) collectLocalNamespaceAliases(method.body_);
                }
            }
        }
    }

    private void collectLocalNamespaceAliases(ASTNode node) {
        if (node is null) return;
        if (auto aliasDecl = cast(AliasDecl)node) {
            string flatTarget = aliasDecl.targetPath.join("_");
            bool isTypeAlias = aliasDecl.targetType !is null ||
                aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
                (aliasDecl.targetPath.length == 1 &&
                    (isPrimitiveTypeName(aliasDecl.targetPath[0]) ||
                     isKnownTypeName(aliasDecl.targetPath[0]))) ||
                isKnownTypeName(flatTarget);
            if (!isTypeAlias && !isKnownSymbolForAlias(flatTarget) && isNamespacePrefix(flatTarget)) {
                namespaceAliases[aliasDecl.name] = flatTarget;
            }
        } else if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) collectLocalNamespaceAliases(stmt);
        } else if (auto ifStmt = cast(IfStmt)node) {
            collectLocalNamespaceAliases(ifStmt.thenBlock);
            collectLocalNamespaceAliases(ifStmt.elseBlock);
        } else if (auto whileStmt = cast(WhileStmt)node) {
            collectLocalNamespaceAliases(whileStmt.body_);
        } else if (auto doWhileStmt = cast(DoWhileStmt)node) {
            collectLocalNamespaceAliases(doWhileStmt.body_);
        } else if (auto forStmt = cast(ForStmt)node) {
            foreach (init; forStmt.initializers) collectLocalNamespaceAliases(init);
            collectLocalNamespaceAliases(forStmt.body_);
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            collectLocalNamespaceAliases(foreachStmt.body_);
        } else if (auto withStmt = cast(WithStmt)node) {
            collectLocalNamespaceAliases(withStmt.body_);
        } else if (auto deferStmt = cast(DeferStmt)node) {
            collectLocalNamespaceAliases(deferStmt.statement);
        } else if (auto tryStmt = cast(TryStmt)node) {
            collectLocalNamespaceAliases(tryStmt.tryBlock);
            collectLocalNamespaceAliases(tryStmt.catchBlock);
            collectLocalNamespaceAliases(tryStmt.finallyBlock);
        } else if (auto matchStmt = cast(MatchStmt)node) {
            foreach (case_; matchStmt.cases) collectLocalNamespaceAliases(case_.body_);
        }
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
        bool isTypeAlias = aliasDecl.targetType !is null ||
            aliasDecl.targetPointerDepth > 0 || aliasDecl.targetIsArray ||
            (aliasDecl.targetPath.length == 1 &&
                (isPrimitiveTypeName(aliasDecl.targetPath[0]) ||
                 isKnownTypeName(aliasDecl.targetPath[0]))) ||
            isKnownTypeName(aliasDecl.targetPath.join("_"));
        if (isTypeAlias) {
            return "";
        }

        // `alias hf = HAL.Foo` - "HAL_Foo" is never a symbol in its own
        // right (namespaces don't register anything themselves, only
        // their contents do), so resolveAliasTarget's exact-match lookup
        // below would always fail for one. Checked first: if no exact
        // symbol matches but "HAL_Foo_" is a real prefix of something
        // that does exist, this names a namespace, not a single symbol -
        // register it and emit nothing (there's no one C symbol to
        // #define against), the same "nothing left to do here" stance
        // a type alias already takes.
        string flatTarget = aliasDecl.targetPath.join("_");
        if (!isKnownSymbol(flatTarget) && isNamespacePrefix(flatTarget)) {
            namespaceAliases[mangledName] = flatTarget;
            return "";
        }

        // `alias LinkedList = collections.LinkedList` where LinkedList<T>
        // is a generic class/struct template, not yet instantiated with
        // any concrete type argument - isKnownSymbol only ever finds
        // *monomorphized* instances (genericClassTemplates/
        // genericStructTemplates is a separate table, see
        // instantiateGenericTypeArgs), so resolveAliasTarget below would
        // always fail for a bare, uninstantiated template name, even
        // though it's exactly the kind of re-export a stdlib aggregator
        // module wants (so callers can write `std.LinkedList<int>`
        // instead of spelling out `std.collections.LinkedList<int>`).
        // Same "nothing to #define, just register the name" shape as the
        // namespace-alias case just above: there's no single concrete C
        // symbol to point at until someone actually instantiates it, at
        // which point findGenericTemplateKey's own exact-match check
        // (tried first, before enclosingQualifications) finds it under
        // this alias name directly.
        if (!isKnownSymbol(flatTarget)) {
            string classKey = findGenericTemplateKey(flatTarget, (k) => (k in genericClassTemplates) !is null);
            if (classKey.length > 0) {
                genericClassTemplates[mangledName] = genericClassTemplates[classKey];
                // collectSymbolTable (LSP symbol listing) walks every
                // genericClassTemplates entry and indexes straight into
                // genericTemplateModulePath by the same key with no
                // existence check - every key in the former must have a
                // matching one in the latter, or it's a RangeError crash,
                // not a compile error.
                genericTemplateModulePath[mangledName] = genericTemplateModulePath[classKey];
                exportDeclSymbol(currentModulePath, aliasDecl, mangledName);
                return "";
            }
            string structKey = findGenericTemplateKey(flatTarget, (k) => (k in genericStructTemplates) !is null);
            if (structKey.length > 0) {
                genericStructTemplates[mangledName] = genericStructTemplates[structKey];
                genericTemplateModulePath[mangledName] = genericTemplateModulePath[structKey];
                exportDeclSymbol(currentModulePath, aliasDecl, mangledName);
                return "";
            }
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
            if (name in originalFreeFunctionKeys && (name in reachableFunctions) is null) continue;
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
            string baseType = fixedArrayElementCType(type);
            return format("    %s %s[%d]%s;\n", baseType, name, type.arraySize, extraDimsSuffix(type));
        }
        return format("    %s %s;\n", typeToC(type), name);
    }

    // Just the `struct Name { ... };` header/fields - no constructors -
    // see generateStructMethods for those. Split out so generateMultiple
    // can emit every plain struct/union/class's *layout* before any
    // generic instantiation (Vector<T>, Result<T,E>, ...), while still
    // emitting their constructors/methods after (see generateMultiple's
    // own "layoutCode" comment for the full explanation - in short, a
    // generic instantiated with a plain type argument used by value,
    // e.g. Vector<String>, needs String's complete layout to do pointer
    // arithmetic over it, but only in Vector_String's *methods*, not its
    // own layout).
    private string generateStructLayout(StructDecl structDecl) {
        string sName = mangledStruct(structDecl);
        currentNamespaceSegments = structDecl.namespaceSegments;

        string code = "";
        // An "SDL_"-named struct's body is never (re-)defined here - see
        // mangledStruct's own comment: <SDL3/SDL.h> already provides the
        // complete `struct SDL_Rect { ... }` definition (the *earlier*
        // `typedef struct SDL_Rect SDL_Rect;` forward-declaration pass is
        // harmless to repeat - C11 explicitly allows redeclaring a typedef
        // to the exact same type - but defining the same struct tag's
        // body twice is a hard "redefinition" error). This struct's own
        // fields are only needed by LLPL's own type-checking (structRegistry
        // already has them from parsing); constructors, if any, are still
        // generated separately (see generateStructMethods) - they're just
        // ordinary LLPL-side convenience functions over the type, real
        // SDL3 has no notion of them at all.
        if (!structDecl.name.startsWith("SDL_")) {
            string attr = structDecl.packed ? " __attribute__((packed))" : "";
            code ~= format("struct%s %s {\n", attr, sName);
            bool[string] anonymousUnionFieldNames;
            foreach (unionFields; structDecl.anonymousUnions) {
                foreach (field; unionFields) {
                    anonymousUnionFieldNames[field.name] = true;
                }
            }
            foreach (field; structDecl.fields) {
                if (field.name in anonymousUnionFieldNames) continue;
                code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
            }
            foreach (unionFields; structDecl.anonymousUnions) {
                code ~= "    union {\n";
                foreach (field; unionFields) {
                    code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
                }
                code ~= "    };\n";
            }
            code ~= "};\n";
        }
        return code;
    }

    // This struct's constructors and methods - see generateStructLayout's
    // own comment for why these are split apart and emitted at a
    // different point in the final output.
    private string generateStructMethods(StructDecl structDecl) {
        currentNamespaceSegments = structDecl.namespaceSegments;
        string code = "";
        foreach (ctor; structDecl.constructors) {
            code ~= generateStructConstructor(structDecl, ctor);
        }
        foreach (method; structDecl.methods) {
            code ~= generateStructMethod(structDecl, method);
        }
        return code;
    }

    private string generateStruct(StructDecl structDecl) {
        return generateStructLayout(structDecl) ~ generateStructMethods(structDecl);
    }

    // A struct constructor's body-generation twin to generateConstructor
    // (classes) - deliberately much simpler, since a struct has none of a
    // class's reference-counting machinery to set up: `self` here is a
    // local *value* of the struct's own type (zero-initialized, so any
    // field the constructor's own body doesn't explicitly assign reads as
    // 0/NULL rather than whatever garbage happened to be on the stack),
    // and the generated function returns that value directly - `new
    // StructName(...)` (see checkNotStruct and the NewExpr codegen sites)
    // compiles straight to a call to this function, which is itself just
    // an ordinary value-returning C function; no allocation, no pointer.
    private string generateStructConstructor(StructDecl structDecl, FunctionDecl constructor) {
        string sName = mangledStruct(structDecl);
        string code = "";
        string params = "";

        string prevClassName = currentClassName;
        currentClassName = sName;
        currentNamespaceSegments = structDecl.namespaceSegments;
        variableTypes["self"] = new Type(sName);
        string prevScopeName = currentScopeName;
        currentScopeName = sName ~ ".constructor";
        recordLocal("self", variableTypes["self"], constructor.line, constructor.column, "self");
        // See variableCNames' own comment: a `let`-shadow's renamed-C-name
        // mapping only ever applies within the one function/method/
        // constructor body it was recorded in, never across into the next
        // one generated after it - reset at the start of every such
        // independent body, the same "own params, own scope" boundary
        // variableTypes itself already treats params/self as being.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, constructor.line, constructor.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        code ~= format("%s %s(%s) {\n", sName, mangleConstructorName(structDecl, sName, constructor), params);
        indentLevel++;
        code ~= indent() ~ format("%s self = {0};\n\n", sName);

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        bodyCode ~= generateFieldDefaultInitializers(structDecl.fields);
        bodyCode ~= generateConstructorParameterInitializers(constructor.params, structDecl.fields,
            constructor.line, constructor.column);
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        currentScopeName = prevScopeName;

        // See generateConstructor's matching comment on why these are
        // un-bound again immediately after: leaving them live would
        // permanently shadow any later same-named global/field.
        foreach (param; constructor.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    private string inlineFunctionPrefix(FunctionDecl fn) {
        return fn.isInline ? "static inline " : "";
    }

    // A struct method (`func`/`func operator...` in the struct body - see
    // ast.StructDecl.methods). Structs are values, but methods need a stable
    // receiver so mutations and `&self` refer to the caller's object rather
    // than a temporary copy on the stack.
    private string generateStructMethod(StructDecl structDecl, FunctionDecl method) {
        if (method.isAsync) {
            throw new CompileError(
                "async method lowering is not implemented yet: parser and AST support are enabled, but the C backend still needs the state-machine transform",
                currentModulePath, method.line, method.column);
        }

        string sName = mangledStruct(structDecl);
        string code = "";
        string params = format("%s* self", sName);

        string prevClassName = currentClassName;
        currentClassName = sName;
        currentNamespaceSegments = structDecl.namespaceSegments;
        string prevScopeName = currentScopeName;
        currentScopeName = sName ~ "." ~ method.name;
        Type prevReturnType = currentReturnType;
        currentReturnType = method.returnType;
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(method.returnType);
        variableTypes["self"] = new Type(sName, 1);
        recordLocal("self", variableTypes["self"], method.line, method.column, "self");
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (param; method.params) {
            resolveType(param.type);
            params ~= ", " ~ parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, method.line, method.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        resolveType(method.returnType);
        code ~= format("%s%s %s(%s) {\n", inlineFunctionPrefix(method), typeToC(method.returnType),
            mangleMethodName(structDecl, sName, method), params);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (method.body_) {
            foreach (stmt; withImplicitReturn(method.body_.statements, method.returnType)) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentScopeName = prevScopeName;

        foreach (param; method.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    // generateStruct's twin for `union` - same "skip the body for an
    // 'SDL_'-named one, the real header already defines it" exception
    // (see mangledUnion/mangledStruct's own comments), just emitting
    // `union` instead of `struct`.
    // Split the same way generateStructLayout/generateStructMethods are -
    // see generateStructLayout's own comment.
    private string generateUnionLayout(UnionDecl unionDecl) {
        string uName = mangledUnion(unionDecl);
        currentNamespaceSegments = unionDecl.namespaceSegments;

        string code = "";
        if (!unionDecl.name.startsWith("SDL_")) {
            string attr = unionDecl.packed ? " __attribute__((packed))" : "";
            code ~= format("union%s %s {\n", attr, uName);
            foreach (field; unionDecl.fields) {
                code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
            }
            code ~= "};\n";
        }
        return code;
    }

    private string generateUnionMethods(UnionDecl unionDecl) {
        currentNamespaceSegments = unionDecl.namespaceSegments;
        string code = "";
        foreach (ctor; unionDecl.constructors) {
            code ~= generateUnionConstructor(unionDecl, ctor);
        }
        foreach (method; unionDecl.methods) {
            code ~= generateUnionMethod(unionDecl, method);
        }
        return code;
    }

    private string generateUnion(UnionDecl unionDecl) {
        return generateUnionLayout(unionDecl) ~ generateUnionMethods(unionDecl);
    }

    // A union method is generated the same way as a struct method: `self`
    // is an ordinary by-value first parameter, and field access uses `.`
    // through the existing value-type member access path.
    private string generateUnionMethod(UnionDecl unionDecl, FunctionDecl method) {
        if (method.isAsync) {
            throw new CompileError(
                "async method lowering is not implemented yet: parser and AST support are enabled, but the C backend still needs the state-machine transform",
                currentModulePath, method.line, method.column);
        }

        string uName = mangledUnion(unionDecl);
        string code = "";
        string params = format("%s* self", uName);

        string prevClassName = currentClassName;
        currentClassName = uName;
        currentNamespaceSegments = unionDecl.namespaceSegments;
        string prevScopeName = currentScopeName;
        currentScopeName = uName ~ "." ~ method.name;
        Type prevReturnType = currentReturnType;
        currentReturnType = method.returnType;
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(method.returnType);
        variableTypes["self"] = new Type(uName, 1);
        recordLocal("self", variableTypes["self"], method.line, method.column, "self");
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (param; method.params) {
            resolveType(param.type);
            params ~= ", " ~ parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, method.line, method.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        resolveType(method.returnType);
        code ~= format("%s%s %s(%s) {\n", inlineFunctionPrefix(method), typeToC(method.returnType),
            mangleMethodName(unionDecl, uName, method), params);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (method.body_) {
            foreach (stmt; withImplicitReturn(method.body_.statements, method.returnType)) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentScopeName = prevScopeName;

        foreach (param; method.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    // generateStructConstructor's twin for `union` - see its own comment
    // for the overall shape (local value, zero-initialized, returned by
    // value, no allocation). `self = {0}` zero-fills the *entire* union
    // here too, not just its first member - see UnionDecl's own doc
    // comment on why a union constructor assigning more than one field
    // just overwrites the same bytes rather than storing them all
    // (that's what a union *is*, not a bug in this codegen).
    private string generateUnionConstructor(UnionDecl unionDecl, FunctionDecl constructor) {
        string uName = mangledUnion(unionDecl);
        string code = "";
        string params = "";

        string prevClassName = currentClassName;
        currentClassName = uName;
        currentNamespaceSegments = unionDecl.namespaceSegments;
        variableTypes["self"] = new Type(uName);
        string prevScopeName = currentScopeName;
        currentScopeName = uName ~ ".constructor";
        recordLocal("self", variableTypes["self"], constructor.line, constructor.column, "self");
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, constructor.line, constructor.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        code ~= format("%s %s(%s) {\n", uName, mangleConstructorName(unionDecl, uName, constructor), params);
        indentLevel++;
        code ~= indent() ~ format("%s self = {0};\n\n", uName);

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        bodyCode ~= generateConstructorParameterInitializers(constructor.params, unionDecl.fields,
            constructor.line, constructor.column);
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        currentScopeName = prevScopeName;

        foreach (param; constructor.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    private string generateGlobalVar(VarDecl varDecl) {
        currentNamespaceSegments = varDecl.namespaceSegments;
        if (varDecl.bitWidth >= 0) {
            throw new CompileError("Bit-fields are only allowed on aggregate fields, not global variables",
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
            string baseType = fixedArrayElementCType(varDecl.type);
            code = format("%s%s%s %s[%d]%s", attrPrefix, constPrefix, baseType, cName, varDecl.type.arraySize,
                extraDimsSuffix(varDecl.type));
        } else {
            code = format("%s%s%s %s", attrPrefix, constPrefix, typeToC(varDecl.type), cName);
        }

        if (varDecl.initializer) {
            if (auto structLit = cast(StructLiteral)varDecl.initializer) {
                code ~= " = " ~ generateStructLiteralValue(structLit, declaredTypeAsWritten);
            } else {
                long constValue;
                if (varDecl.isConst && tryEvalGlobalIntegerConst(varDecl.initializer, constValue)) {
                    code ~= " = " ~ to!string(constValue);
                } else {
                    code ~= " = " ~ generateExpression(varDecl.initializer);
                }
            }
        }
        long foldedValue;
        if (varDecl.isConst && varDecl.initializer !is null &&
                tryEvalGlobalIntegerConst(varDecl.initializer, foldedValue)) {
            foldedIntegerConsts[cName] = foldedValue;
        }
        code ~= ";\n";
        return code;
    }

    private bool tryEvalGlobalIntegerConst(ASTNode node, out long value) {
        if (auto intLit = cast(IntLiteral)node) {
            value = intLit.value;
            return true;
        }
        if (auto ident = cast(Identifier)node) {
            string resolved = resolveName(ident.name, (n) => (n in globalVarRegistry) !is null);
            return tryEvalGlobalIntegerConstByName(resolved, value);
        }
        if (auto unaryExpr = cast(UnaryExpr)node) {
            long inner;
            if (!tryEvalGlobalIntegerConst(unaryExpr.operand, inner)) return false;
            switch (unaryExpr.op) {
                case "+": value = inner; return true;
                case "-": value = -inner; return true;
                case "~": value = ~inner; return true;
                default: return false;
            }
        }
        if (auto binExpr = cast(BinaryExpr)node) {
            long left;
            long right;
            if (!tryEvalGlobalIntegerConst(binExpr.left, left) ||
                    !tryEvalGlobalIntegerConst(binExpr.right, right)) {
                return false;
            }
            switch (binExpr.op) {
                case "+": value = left + right; return true;
                case "-": value = left - right; return true;
                case "*": value = left * right; return true;
                case "/":
                    if (right == 0) return false;
                    value = left / right;
                    return true;
                case "%":
                    if (right == 0) return false;
                    value = left % right;
                    return true;
                case "<<": value = left << right; return true;
                case ">>": value = left >> right; return true;
                case "&": value = left & right; return true;
                case "^": value = left ^ right; return true;
                case "|": value = left | right; return true;
                default: return false;
            }
        }
        return false;
    }

    private bool tryEvalGlobalIntegerConstByName(string name, out long value) {
        if (auto folded = name in foldedIntegerConsts) {
            value = *folded;
            return true;
        }
        auto declPtr = name in globalVarRegistry;
        if (declPtr is null || !declPtr.isConst || declPtr.initializer is null) return false;
        if ((name in foldingIntegerConsts) !is null) return false;

        foldingIntegerConsts[name] = true;
        scope(exit) foldingIntegerConsts.remove(name);

        if (!tryEvalGlobalIntegerConst(declPtr.initializer, value)) return false;
        foldedIntegerConsts[name] = value;
        return true;
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

    private string generateAbiAssert(AbiAssertDecl decl) {
        Type t = cloneType(decl.targetType);
        resolveType(t);
        string cType = typeToC(t);
        string msg;
        string expr;
        final switch (decl.kind) {
            case AbiAssertKind.Size:
                msg = format("sizeof(%s) == %d", t.toString(), decl.expected);
                expr = format("sizeof(%s) == %d", cType, decl.expected);
                break;
            case AbiAssertKind.Align:
                msg = format("_Alignof(%s) == %d", t.toString(), decl.expected);
                expr = format("_Alignof(%s) == %d", cType, decl.expected);
                break;
            case AbiAssertKind.Offset:
                if (decl.fieldName.length == 0) {
                    throw new CompileError("#assert_offset requires a field name",
                        currentModulePath, decl.line, decl.column);
                }
                msg = format("offsetof(%s.%s) == %d", t.toString(), decl.fieldName, decl.expected);
                expr = format("offsetof(%s, %s) == %d", cType, decl.fieldName, decl.expected);
                break;
        }
        return format("_Static_assert(%s, \"%s\");\n", expr, escapeCString(msg));
    }

    private string generateAbiAssertions(Program[] programs) {
        string code = "";
        foreach (prog; programs) {
            currentModulePath = prog.modulePath;
            foreach (decl; prog.declarations) {
                if (auto abi = cast(AbiAssertDecl)decl) {
                    code ~= sourceLineDirective(abi);
                    code ~= generateAbiAssert(abi);
                }
            }
        }
        return code.length > 0 ? "// ABI/layout assertions\n" ~ code ~ "\n" : "";
    }

    // Just the `struct Name { RefCount ref_count; ... };` header/fields -
    // no constructors/destructor/methods - see generateStructLayout's own
    // comment for why this is split from generateClassMethods below (the
    // class equivalent of the same struct/generic ordering problem: a
    // `Vector<String>`'s own methods do `sizeof(String)`-style pointer
    // arithmetic and need String's layout complete first, even though
    // Vector_String's *own* layout - just a `String*` field - never did).
    // Every field declared by `cd`'s ancestors, root-first (the
    // immediate base's own ancestors before the immediate base's own
    // fields) - the exact order generateClassLayout needs to flatten
    // them into a derived struct so that a `Base*` and a `Derived*` agree
    // on every inherited field's offset. Empty for a class with no base.
    private VarDecl[] collectAncestorFields(ClassDecl cd) {
        if (cd.baseClassName.length == 0) return [];
        auto basePtr = cd.baseClassName in classRegistry;
        if (basePtr is null) return []; // already validated during the base-class resolution pass
        return collectAncestorFields(*basePtr) ~ basePtr.fields;
    }

    // A class that has a base, or is itself a base for something else -
    // see hasSubclasses' own comment. Only a polymorphic class pays for
    // the constructor/destructor _new+_init/_destroy+__destroy_impl split
    // (and, once vtables exist, the dispatch machinery); an ordinary class
    // with no inheritance relationship at all generates exactly as it did
    // before this feature existed.
    private bool isPolymorphic(ClassDecl cd) {
        return cd.baseClassName.length > 0 || (mangledClass(cd) in hasSubclasses) !is null;
    }

    // A class only ever gets a real `ClassName_destroy` C symbol generated
    // if it wrote its own destructor{} block or is polymorphic (see
    // generateClassMethods/generatePolymorphicDestructor) - a plain class
    // with neither (an ordinary value-holder like RadioGroup) has no
    // destructor at all. Every field-release site below (`rc_release(self->
    // field, <symbol>)`) needs *some* symbol to name regardless, since it
    // was already assuming one always exists for any class-typed field -
    // this returns the real one when there is one, or the literal `NULL`
    // otherwise, which rc_release's own contract already treats as "nothing
    // to run at zero refcount" (see runtime.c).
    private string fieldDestructorSymbol(Type fieldType) {
        auto classDecl = fieldType.name in classRegistry;
        if (classDecl !is null && (classDecl.destructor !is null || isPolymorphic(*classDecl))) {
            return format("%s_destroy", fieldType.name);
        }
        return "((void*)0)";
    }

    // Looks up a field by name anywhere in cd's own fields or its ancestor
    // chain (own fields checked first, so a derived field always wins over
    // a same-named ancestor one - though generateClassLayout already
    // rejects that collision at compile time). Needed because the C struct
    // is flattened (self->x already works for inherited fields with zero
    // codegen changes) but the LLPL-level AST field list on `cd` itself
    // only ever holds that class's own declared fields - every "find field
    // by name for member access/type-inference" site has to walk the
    // chain explicitly instead of just scanning cd.fields.
    private VarDecl findFieldOnHierarchy(ClassDecl cd, string fieldName) {
        ClassDecl owner;
        return findFieldOnHierarchy(cd, fieldName, owner);
    }

    // Same lookup, but also reports which class in the chain actually
    // declares the field (via `owner`) - needed anywhere the caller must
    // distinguish "found on cd itself" from "inherited from an ancestor",
    // such as checkMemberAccess's private-field check: `private` is not
    // inherited-visible (see class ClassDecl comment / plan Scope), so a
    // private ancestor field must stay inaccessible from a derived class's
    // own methods, which only holds if the check runs against the field's
    // true declaring class, not the receiver's static type.
    private VarDecl findFieldOnHierarchy(ClassDecl cd, string fieldName, out ClassDecl owner) {
        foreach (field; cd.fields) {
            if (field.name == fieldName) { owner = cd; return field; }
        }
        if (cd.baseClassName.length == 0) return null;
        auto basePtr = cd.baseClassName in classRegistry;
        if (basePtr is null) return null;
        return findFieldOnHierarchy(*basePtr, fieldName, owner);
    }

    // The topmost ancestor of cd's hierarchy (cd itself if it has no
    // base) - the class the shared vtable struct type is named after,
    // since every class in a hierarchy dispatches through the same
    // struct layout regardless of how deep it sits.
    private ClassDecl hierarchyRoot(ClassDecl cd) {
        if (cd.baseClassName.length == 0) return cd;
        auto basePtr = cd.baseClassName in classRegistry;
        if (basePtr is null) return cd;
        return hierarchyRoot(*basePtr);
    }

    // Finds the method(s) named `name` reachable from `cd`: cd's own
    // methods first (so an override always wins over whatever it
    // overrides), else the nearest ancestor that declares one, walking up
    // via baseClassName exactly like findFieldOnHierarchy. `owner` reports
    // which class actually declares the returned candidates - callers must
    // mangle/check-access against `owner`, never against `cd` itself,
    // since a purely-inherited (non-overridden) method was only ever
    // generated once, as `owner`'s own C symbol (see mangleMethodName) -
    // re-mangling it against a receiver's more-derived static class would
    // name a symbol that was never generated.
    private FunctionDecl[] resolveMethodOnHierarchy(ClassDecl cd, string name, out ClassDecl owner) {
        auto candidates = methodCandidatesNamed(cd, name);
        if (candidates.length > 0) { owner = cd; return candidates; }
        if (cd.baseClassName.length == 0) return [];
        auto basePtr = cd.baseClassName in classRegistry;
        if (basePtr is null) return [];
        return resolveMethodOnHierarchy(*basePtr, name, owner);
    }

    // The full, deduped list of virtual/override method slots anywhere in
    // root's whole hierarchy (root itself plus every descendant, walked
    // via subclassesOf) - one representative FunctionDecl per distinct
    // name, used only for that slot's C signature (return + param types)
    // when emitting the shared vtable struct type. `override` requires an
    // exact signature match against whatever it overrides (Scope: "no
    // covariance"), so every declaration sharing a name is expected to
    // agree; a mismatch is a compile error here rather than silently
    // picking one arbitrarily.
    private FunctionDecl[] collectVtableSlots(ClassDecl root) {
        FunctionDecl[] slots;
        void visit(ClassDecl cd) {
            foreach (m; cd.methods) {
                if (!m.isVirtual && !m.isOverride) continue;
                bool matched = false;
                foreach (existing; slots) {
                    if (existing.name != m.name) continue;
                    matched = true;
                    if (!sameParameterTypes(existing.params, m.params) ||
                            !sameErrorType(existing.returnType, m.returnType)) {
                        collectedErrors ~= new CompileError(
                            format("'%s' overrides '%s.%s' with a different signature - " ~
                                "overrides must match exactly (no covariance)",
                                mangleMethodName(cd, mangledClass(cd), m), mangledClass(root), m.name),
                            currentModulePath, m.line, m.column);
                    }
                    break;
                }
                if (!matched) slots ~= m;
            }
            foreach (sub; subclassesOf.get(mangledClass(cd), [])) visit(sub);
        }
        visit(root);
        return slots;
    }

    // Struct layout is flattened, not nested: a derived class's fields
    // are `RefCount ref_count; <every ancestor field, root-to-leaf>;
    // <this class's own fields>;` - literally copied in as plain flat
    // members (the same textual-flattening style desugarTaggedEnum uses
    // for its own struct), not a nested `struct Base __base;` member.
    // This is what lets ordinary field access (`self->x`) work completely
    // unchanged everywhere else in codegen for an inherited field - it's
    // indistinguishable from an own field once flattened - and what makes
    // a `Derived*` safely reinterpretable as a `Base*` (the base's own
    // fields, including its RefCount, always sit at the same offsets).
    private string generateClassLayout(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";
        code ~= format("struct %s {\n", cName);
        code ~= "    RefCount ref_count;\n";
        // Every polymorphic class gets this at the same offset (right
        // after ref_count, before any ancestor/own field) - since it's
        // added independently here rather than threaded through
        // collectAncestorFields, a derived class's own `__vtable` line
        // lines up with its base's regardless of how many fields either
        // declares. Untyped (void*) rather than a strongly-typed
        // `RootName_VTable*` because a subclass can be declared textually
        // before its base (classes are emitted per-file in declaration
        // order), so the vtable struct type isn't always known yet at
        // every point a class layout is emitted - every dispatch site
        // casts it on use instead.
        if (isPolymorphic(classDecl)) {
            code ~= "    void* __vtable;\n";
        }
        VarDecl[] ancestorFields = collectAncestorFields(classDecl);
        foreach (field; ancestorFields) {
            code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
        }
        foreach (field; classDecl.fields) {
            foreach (ancestorField; ancestorFields) {
                if (ancestorField.name == field.name) {
                    throw new CompileError(
                        format("Field '%s' in class '%s' is already defined in its base class chain",
                            field.name, classDecl.name),
                        currentModulePath, field.line, field.column);
                }
            }
            code ~= fieldDeclaration(field.type, field.name, field.bitWidth);
        }
        code ~= "};\n\n";
        return code;
    }

    // This class's constructor(s)/destructor/methods only - see
    // generateClassLayout's own comment.
    private string generateClassMethods(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = "";

        bool polymorphic = isPolymorphic(classDecl);
        if (classDecl.constructors.length == 0) {
            code ~= generateDefaultConstructor(classDecl);
        }
        foreach (ctor; classDecl.constructors) {
            code ~= polymorphic ? generatePolymorphicConstructor(classDecl, ctor)
                                 : generateConstructor(classDecl, ctor);
        }

        if (polymorphic) {
            code ~= generatePolymorphicDestructor(classDecl);
        } else if (classDecl.destructor) {
            code ~= generateDestructor(classDecl, classDecl.destructor);
        }

        foreach (method; classDecl.methods) {
            code ~= generateMethod(classDecl, method);
        }

        currentClassName = "";
        return code;
    }

    private string generateClass(ClassDecl classDecl) {
        return generateClassLayout(classDecl) ~ generateClassMethods(classDecl);
    }

    private string generateDefaultConstructor(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        string code = "";

        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);
        string prevScopeName = currentScopeName;
        currentScopeName = cName ~ ".constructor";
        recordLocal("self", variableTypes["self"], classDecl.line, classDecl.column, "self");
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        code ~= format("%s* %s_new() {\n", cName, cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n",
            cName, cName, cName);
        code ~= indent() ~ "if (!self) return ((void*)0);\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n\n";

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = generateFieldDefaultInitializers(classDecl.fields);
        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        currentScopeName = prevScopeName;
        variableTypes.remove("self");

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

    private string generateFieldDefaultInitializers(VarDecl[] fields) {
        string code = "";
        foreach (field; fields) {
            if (field.initializer is null) continue;
            auto lhs = new MemberExpr(new Identifier("self", field.line, field.column),
                field.name, field.line, field.column);
            auto assign = new BinaryExpr("=", lhs, field.initializer, field.line, field.column);
            code ~= generateBodyStatement(new ExprStmt(assign), false);
        }
        return code;
    }

    private bool hasFieldNamed(VarDecl[] fields, string name) {
        foreach (field; fields) {
            if (field.name == name) return true;
        }
        return false;
    }

    private string generateConstructorParameterInitializers(Parameter[] params, VarDecl[] fields,
            int line, int column) {
        string code = "";
        foreach (param; params) {
            if (!param.initializesField) continue;
            if (!hasFieldNamed(fields, param.name)) {
                throw new CompileError(format(
                    "Constructor parameter '@%s' does not match a field on '%s'",
                    param.name, currentClassName), currentModulePath, line, column);
            }
            auto lhs = new MemberExpr(new Identifier("self", line, column), param.name, line, column);
            auto rhs = new Identifier(param.name, line, column);
            auto assign = new BinaryExpr("=", lhs, rhs, line, column);
            code ~= generateBodyStatement(new ExprStmt(assign), false);
        }
        return code;
    }

    private VarDecl findFieldOnCurrentAggregate(string name) {
        if (currentClassName.length == 0) return null;
        if (auto classDecl = currentClassName in classRegistry) {
            return findFieldOnHierarchy(*classDecl, name);
        }
        if (auto structDecl = currentClassName in structRegistry) {
            foreach (field; structDecl.fields) {
                if (field.name == name) return field;
            }
        }
        if (auto unionDecl = currentClassName in unionRegistry) {
            foreach (field; unionDecl.fields) {
                if (field.name == name) return field;
            }
        }
        return null;
    }

    private string tryGenerateBareFieldAccess(Identifier ident) {
        if (findFieldOnCurrentAggregate(ident.name) is null) return "";
        auto member = new MemberExpr(new Identifier("self", ident.line, ident.column),
            ident.name, ident.line, ident.column);
        return generateExpression(member);
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
        if (exprStmt is null) {
            // `value if condition else other` is parsed as a postfix IfStmt
            // so ordinary statement modifiers keep their existing behavior.
            // At the end of a value-returning body, both branches are return
            // values rather than discarded expression statements.
            auto postfix = cast(IfStmt)statements[$ - 1];
            if (postfix is null || !postfix.isPostfix) return statements;

            Block returnBlock(Block body) {
                if (body is null || body.statements.length != 1) return body;
                auto branchExpr = cast(ExprStmt)body.statements[0];
                if (branchExpr is null) return body;
                return new Block([new ReturnStmt(branchExpr.expression,
                    branchExpr.line, branchExpr.column)]);
            }

            auto result = statements.dup;
            result[$ - 1] = new IfStmt(postfix.condition,
                returnBlock(postfix.thenBlock), returnBlock(postfix.elseBlock), true);
            return result;
        }
        auto result = statements.dup;
        result[$ - 1] = new ReturnStmt(exprStmt.expression, exprStmt.line, exprStmt.column);
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
        string prevScopeName = currentScopeName;
        currentScopeName = cName ~ ".constructor";
        recordLocal("self", variableTypes["self"], constructor.line, constructor.column, "self");
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, constructor.line, constructor.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        code ~= format("%s* %s(%s) {\n", cName, mangleConstructorName(classDecl, cName, constructor), params);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n",
            cName, cName, cName);
        code ~= indent() ~ "if (!self) return ((void*)0);\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n\n";

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        // Generate constructor body
        string bodyCode = "";
        bodyCode ~= generateFieldDefaultInitializers(classDecl.fields);
        bodyCode ~= generateConstructorParameterInitializers(constructor.params, classDecl.fields,
            constructor.line, constructor.column);
        if (constructor.body_) {
            foreach (stmt; constructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;
        currentScopeName = prevScopeName;

        // Un-bind the constructor's own params (and self) from
        // variableTypes now that its body is done - otherwise their bare,
        // unqualified names would keep resolving here for every
        // subsequently-generated function/method, permanently shadowing
        // any later global/field that happens to share one of those names
        // (resolveName checks a bare name before any namespace-qualified
        // candidate - see enclosingQualifications).
        foreach (param; constructor.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes.remove("self");

        return code;
    }

    // True when `stmt` is `super(args)` - a constructor's own leading
    // statement chaining into its base class's constructor. `super` is
    // not a keyword (no TokenType.Super exists) - it parses as a plain
    // `Identifier("super")`, the same "special contextual name resolved
    // by codegen convention, not the lexer" pattern `self` already uses,
    // so this is recognized purely by shape: an ExprStmt wrapping a
    // CallExpr whose callee is exactly that identifier.
    private bool isSuperConstructorCall(ASTNode stmt, out ASTNode[] superArgs) {
        auto exprStmt = cast(ExprStmt)stmt;
        if (exprStmt is null) return false;
        auto callExpr = cast(CallExpr)exprStmt.expression;
        if (callExpr is null) return false;
        auto ident = cast(Identifier)callExpr.callee;
        if (ident is null || ident.name != "super") return false;
        superArgs = callExpr.args;
        return true;
    }

    // A polymorphic class's constructor (see isPolymorphic) generates two
    // C functions instead of generateConstructor's usual one:
    //
    //   <cName>_new(args) -> cName*   - allocates via rc_alloc, then hands
    //                                   off to...
    //   <cName>_init(self, args)      - a plain void function, no
    //                                   allocation, running this
    //                                   constructor's own body against an
    //                                   already-allocated `self` - first
    //                                   chaining into the base class's own
    //                                   `_init` (explicit `super(args)`,
    //                                   or an implicit zero-arg call if
    //                                   the constructor didn't write one)
    //                                   if this class has a base.
    //
    // Only ONE rc_alloc ever happens per `new`, in the outermost concrete
    // class's own `_new` - every ancestor's own `_init` just runs against
    // that same already-allocated `self`, safe because the flattened
    // layout (see generateClassLayout) makes a `Derived*` and a `Base*`
    // agree on every ancestor field's offset.
    private string generatePolymorphicConstructor(ClassDecl classDecl, FunctionDecl constructor) {
        string cName = mangledClass(classDecl);
        string newName = mangleConstructorName(classDecl, cName, constructor);
        string initName = mangleInitName(classDecl, cName, constructor);

        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        string paramsNoSelf = "";
        string forwardArgs = "";
        foreach (i, param; constructor.params) {
            resolveType(param.type);
            if (i > 0) { paramsNoSelf ~= ", "; forwardArgs ~= ", "; }
            paramsNoSelf ~= parameterDeclaration(param);
            forwardArgs ~= param.name;
            variableTypes[param.name] = param.type;
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }
        string initParams = format("%s* self%s", cName, paramsNoSelf.length > 0 ? ", " ~ paramsNoSelf : "");

        // The outward `_new` - thin: allocate, then delegate to `_init`.
        string code = "";
        code ~= format("%s* %s(%s) {\n", cName, newName, paramsNoSelf);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)rc_alloc(sizeof(%s));\n", cName, cName, cName);
        code ~= indent() ~ "if (!self) return ((void*)0);\n";
        code ~= indent() ~ "rc_init(&self->ref_count);\n";
        // Set once, here, in the outermost concrete class's own `_new` -
        // every ancestor's `_init` below just runs against this same
        // already-allocated `self` and never touches `__vtable` again.
        code ~= indent() ~ format("self->__vtable = (void*)&%s_vtable;\n", cName);
        code ~= indent() ~ format("%s(self%s%s);\n", initName, forwardArgs.length > 0 ? ", " : "", forwardArgs);
        code ~= indent() ~ "return self;\n";
        indentLevel--;
        code ~= "}\n\n";

        // The internal `_init` - this class's own body, plus base
        // chaining, against an already-allocated `self`.
        code ~= format("void %s(%s) {\n", initName, initParams);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        ASTNode[] statements = constructor.body_ ? constructor.body_.statements : [];
        size_t bodyStart = 0;
        ASTNode[] superArgs;
        bool hasExplicitSuper = statements.length > 0 && isSuperConstructorCall(statements[0], superArgs);
        if (hasExplicitSuper) bodyStart = 1;

        string chainCode = "";
        if (classDecl.baseClassName.length > 0) {
            try {
                auto basePtr = classDecl.baseClassName in classRegistry;
                ClassDecl baseDecl = *basePtr;
                int chainLine = hasExplicitSuper ? statements[0].line : constructor.line;
                int chainColumn = hasExplicitSuper ? statements[0].column : constructor.column;
                string baseDesc = format("constructor of '%s'", baseDecl.name);
                FunctionDecl baseCtor = resolveOverload(baseDecl.constructors, superArgs, [], baseDesc,
                    chainLine, chainColumn);
                ASTNode[] resolvedBaseArgs = applyImplicitArgumentConversions(
                    resolveCallArguments(baseCtor.params, false, superArgs, [], baseDesc, chainLine, chainColumn),
                    baseCtor.params);
                string baseInitName = mangleInitName(baseDecl, mangledClass(baseDecl), baseCtor);
                string baseArgsCode = "";
                foreach (i, arg; resolvedBaseArgs) {
                    if (i > 0) baseArgsCode ~= ", ";
                    baseArgsCode ~= generateExpression(arg);
                }
                chainCode ~= indent() ~ format("%s((%s*)self%s%s);\n", baseInitName, mangledClass(baseDecl),
                    baseArgsCode.length > 0 ? ", " : "", baseArgsCode);
            } catch (CompileError e) {
                collectedErrors ~= e;
            }
        } else if (hasExplicitSuper) {
            collectedErrors ~= new CompileError(
                format("'super(...)' used in class '%s', which has no base class", classDecl.name),
                currentModulePath, statements[0].line, statements[0].column);
        }

        string bodyCode = "";
        bodyCode ~= generateFieldDefaultInitializers(classDecl.fields);
        bodyCode ~= generateConstructorParameterInitializers(constructor.params, classDecl.fields,
            constructor.line, constructor.column);
        foreach (stmt; statements[bodyStart .. $]) {
            bodyCode ~= generateBodyStatement(stmt, false);
        }

        code ~= deferFrameDeclarations();
        code ~= chainCode;
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);
        indentLevel--;
        code ~= "}\n\n";

        currentClassName = prevClassName;
        foreach (param; constructor.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
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
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        code ~= format("void %s_destroy(void* ptr) {\n", cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)ptr;\n", cName, cName);

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

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
        code ~= releaseRcLocals(null);

        // Release reference-counted fields. Struct-typed fields (including
        // __LLPL_Closure - see runtime.h/generateLambdaExpr) are plain
        // value types, not heap-allocated class instances, so they're
        // never reference-counted and must be excluded here the same way
        // typeToC/isStructTypeName already exclude them from auto-pointering.
        // A dynamic array field (Vector<T>/Slice<T>'s own raw backing
        // buffer - see typeToC's isDynamicArray comment) is excluded the
        // same way a plain pointer field already is: it's raw storage the
        // container frees by hand (see Vector<T>'s own destructor in
        // prelude.llpl), not a single ref-counted instance rc_release
        // could even correctly operate on.
        foreach (field; classDecl.fields) {
            if (!isPrimitiveTypeName(field.type.name) && !field.type.isPointer && !field.type.isArray &&
                    !isStructTypeName(field.type.name) && !isUnionTypeName(field.type.name)) {
                code ~= indent() ~ format("if (self->%s) rc_release(self->%s, %s);\n",
                    field.name, field.name, fieldDestructorSymbol(field.type));
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        variableTypes.remove("self");

        return code;
    }

    // A polymorphic class's destructor (see isPolymorphic) is a mirrored
    // split of generatePolymorphicConstructor, in reverse: construction
    // runs root-to-leaf via `super(...)` chaining into `_init`; destruction
    // runs leaf-to-root via `__destroy_impl` cascading into the base's own.
    //
    //   <cName>_destroy(void* ptr)         - the exact symbol every
    //                                         existing rc_release/delete
    //                                         call site already
    //                                         interpolates by static type
    //                                         name; a one-line trampoline
    //                                         to __destroy_impl. Stage 5
    //                                         will redirect this trampoline
    //                                         through the hierarchy's
    //                                         vtable instead, for genuine
    //                                         runtime-polymorphic dispatch
    //                                         (deleting a Widget* that's
    //                                         actually a Button instance
    //                                         must run Button's own
    //                                         cleanup) - until then it's
    //                                         only correct when destruction
    //                                         happens through the exact
    //                                         static type, which is all
    //                                         that's exercised before
    //                                         Stage 5 introduces mixed-type
    //                                         containers.
    //   <cName>__destroy_impl(void* ptr)   - this class's own destructor
    //                                         body + own-field releases,
    //                                         then cascades into
    //                                         BaseClassName__destroy_impl.
    private string generatePolymorphicDestructor(ClassDecl classDecl) {
        string cName = mangledClass(classDecl);
        currentNamespaceSegments = classDecl.namespaceSegments;
        variableTypes["self"] = new Type(cName);
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        string rootName = mangledClass(hierarchyRoot(classDecl));

        string code = "";
        // Dispatches through the hierarchy's vtable rather than calling
        // this class's own __destroy_impl directly - deleting via a
        // Base*-typed pointer that actually points at a more-derived
        // instance must still run the derived class's own cleanup first.
        code ~= format("void %s_destroy(void* ptr) {\n", cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)ptr;\n", cName, cName);
        code ~= indent() ~ format("((%s_VTable*)self->__vtable)->destroy(ptr);\n", rootName);
        indentLevel--;
        code ~= "}\n\n";

        code ~= format("void %s__destroy_impl(void* ptr) {\n", cName);
        indentLevel++;
        code ~= indent() ~ format("%s* self = (%s*)ptr;\n", cName, cName);

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (classDecl.destructor !is null && classDecl.destructor.body_ !is null) {
            foreach (stmt; classDecl.destructor.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);

        // See generateDestructor's matching comment.
        foreach (field; classDecl.fields) {
            if (!isPrimitiveTypeName(field.type.name) && !field.type.isPointer && !field.type.isArray &&
                    !isStructTypeName(field.type.name) && !isUnionTypeName(field.type.name)) {
                code ~= indent() ~ format("if (self->%s) rc_release(self->%s, %s);\n",
                    field.name, field.name, fieldDestructorSymbol(field.type));
            }
        }

        if (classDecl.baseClassName.length > 0) {
            auto basePtr = classDecl.baseClassName in classRegistry;
            if (basePtr !is null) {
                string baseName = mangledClass(*basePtr);
                code ~= indent() ~ format("%s__destroy_impl((%s*)self);\n", baseName, baseName);
            }
        }

        indentLevel--;
        code ~= "}\n\n";

        variableTypes.remove("self");
        return code;
    }

    private string generateMethod(ClassDecl classDecl, FunctionDecl method) {
        if (method.isAsync) {
            return generateAsyncMethod(classDecl, method);
        }

        string cName = mangledClass(classDecl);
        string code = "";
        string params = "";

        // Static methods don't receive a 'self' parameter
        if (!method.isStatic) {
            params = format("%s* self", cName);
        }

        // Set current class/namespace context
        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        string prevScopeName = currentScopeName;
        currentScopeName = cName ~ "." ~ method.name;

        // Register 'self' only for non-static methods
        if (!method.isStatic) {
            variableTypes["self"] = new Type(cName);
            recordLocal("self", variableTypes["self"], method.line, method.column, "self");
        }
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(method.returnType);
        resolveType(method.returnType);
        Type prevReturnType = currentReturnType;
        currentReturnType = method.returnType;
        foreach (i, param; method.params) {
            resolveType(param.type);
            if (!method.isStatic || i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, method.line, method.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        code ~= format("%s%s %s(%s) {\n",
            inlineFunctionPrefix(method), typeToC(method.returnType),
            mangleMethodName(classDecl, cName, method), params);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (method.body_) {
            foreach (stmt; withImplicitReturn(method.body_.statements, method.returnType)) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);

        indentLevel--;
        code ~= "}\n\n";

        // Restore previous context
        currentClassName = prevClassName;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentScopeName = prevScopeName;

        // See generateConstructor's matching comment: params (and self)
        // are only valid names inside this method's own body.
        foreach (param; method.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        if (!method.isStatic) {
            variableTypes.remove("self");
        }

        return code;
    }

    private string generateAsyncMethod(ClassDecl classDecl, FunctionDecl method) {
        if (method.isStatic || method.isVirtual || method.isOverride) {
            throw new CompileError("async methods currently support ordinary instance methods only",
                currentModulePath, method.line, method.column);
        }
        string cName = mangledClass(classDecl);
        Parameter[] leadingParams = [new Parameter("self", new Type(cName))];

        string prevClassName = currentClassName;
        currentClassName = cName;
        currentNamespaceSegments = classDecl.namespaceSegments;
        string code = generateAsyncFunction(method, mangleMethodName(classDecl, cName, method), leadingParams);
        currentClassName = prevClassName;
        return code;
    }

    private string generateFunction(FunctionDecl funcDecl) {
        if (funcDecl.isExtern) {
            // Just a forward declaration - but see the early-forward-decl
            // loop's own isSdlBinding comment: a symbol named like an SDL3
            // function already has the real, correct prototype in scope
            // via <SDL3/SDL.h>, and re-declaring it here too (with LLPL's
            // best non-const approximation) conflicts with it rather than
            // harmlessly duplicating it. Same skip, same reason.
            if (funcDecl.name.startsWith("SDL_") || funcDecl.name.startsWith("TTF_")) return "";
            string params = "";
            foreach (i, param; funcDecl.params) {
                if (i > 0) params ~= ", ";
                params ~= parameterDeclaration(param);
            }
            if (funcDecl.isVariadic) params ~= ", ...";
            return format("extern %s %s(%s);\n",
                typeToC(funcDecl.returnType), mangledFunc(funcDecl), params);
        }

        if (funcDecl.isInterrupt) {
            return generateInterruptFunction(funcDecl);
        }

        if (funcDecl.isAsync) {
            return generateAsyncFunction(funcDecl);
        }

        string code = "";
        string params = "";
        currentNamespaceSegments = funcDecl.namespaceSegments;
        string prevScopeName = currentScopeName;
        currentScopeName = mangleFreeFunctionName(funcDecl);
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(funcDecl.returnType);
        resolveType(funcDecl.returnType);
        Type prevReturnType = currentReturnType;
        currentReturnType = funcDecl.returnType;
        Type[string] savedFunctionVariableTypes = variableTypes.dup;
        bool[string] savedFunctionConstVariables = constVariables.dup;
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        foreach (i, param; funcDecl.params) {
            resolveType(param.type);
            if (i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordLocal(param.name, param.type, funcDecl.line, funcDecl.column, "parameter");
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
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

        code ~= format("%s%s %s(%s) {\n",
            inlineFunctionPrefix(funcDecl), typeToC(funcDecl.returnType),
            mangleFreeFunctionName(funcDecl), params);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

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
        code ~= releaseRcLocals(null);

        indentLevel--;
        code ~= "}\n";

        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentClassName = prevClassNameForSelf;
        currentScopeName = prevScopeName;

        // See generateConstructor's matching comment: params are only
        // valid names inside this function's own body.
        foreach (param; funcDecl.params) {
            variableTypes.remove(param.name);
            constVariables.remove(param.name);
        }
        variableTypes = savedFunctionVariableTypes;
        constVariables = savedFunctionConstVariables;

        if (isMainArgsFunction(funcDecl)) {
            code ~= generateMainWrapper(funcDecl);
        }

        return code;
    }

    private bool isDirectAwaitExpr(ASTNode node) {
        return cast(AwaitExpr)node !is null;
    }

    private bool asyncNodeContainsAwait(ASTNode node) {
        if (node is null) return false;
        if (cast(AwaitExpr)node) return true;
        if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) if (asyncNodeContainsAwait(stmt)) return true;
            return false;
        }
        if (auto i = cast(IfStmt)node) {
            if (asyncNodeContainsAwait(i.condition)) return true;
            if (asyncNodeContainsAwait(i.thenBlock)) return true;
            return asyncNodeContainsAwait(i.elseBlock);
        }
        if (auto w = cast(WhileStmt)node) {
            return asyncNodeContainsAwait(w.condition) || asyncNodeContainsAwait(w.body_);
        }
        if (auto d = cast(DoWhileStmt)node) return asyncNodeContainsAwait(d.body_) || asyncNodeContainsAwait(d.condition);
        if (auto f = cast(ForStmt)node) {
            foreach (init; f.initializers) if (asyncNodeContainsAwait(init)) return true;
            return asyncNodeContainsAwait(f.condition) || asyncNodeContainsAwait(f.update) || asyncNodeContainsAwait(f.body_);
        }
        if (auto f = cast(ForeachStmt)node) return asyncNodeContainsAwait(f.iterable) || asyncNodeContainsAwait(f.body_);
        if (auto d = cast(DeferStmt)node) return asyncNodeContainsAwait(d.statement);
        if (auto t = cast(TryStmt)node) {
            return asyncNodeContainsAwait(t.tryBlock) || asyncNodeContainsAwait(t.catchBlock) ||
                asyncNodeContainsAwait(t.finallyBlock);
        }
        if (auto m = cast(MatchStmt)node) {
            if (asyncNodeContainsAwait(m.subject)) return true;
            foreach (case_; m.cases) if (asyncNodeContainsAwait(case_.body_)) return true;
            return false;
        }
        if (auto l = cast(LambdaExpr)node) return asyncNodeContainsAwait(l.body_);
        if (auto v = cast(VarDecl)node) return asyncNodeContainsAwait(v.initializer);
        if (auto e = cast(ExprStmt)node) return asyncNodeContainsAwait(e.expression);
        if (auto r = cast(ReturnStmt)node) return asyncNodeContainsAwait(r.value);
        if (auto b = cast(BinaryExpr)node) return asyncNodeContainsAwait(b.left) || asyncNodeContainsAwait(b.right);
        if (auto u = cast(UnaryExpr)node) return asyncNodeContainsAwait(u.operand);
        if (auto c = cast(CallExpr)node) {
            if (asyncNodeContainsAwait(c.callee)) return true;
            foreach (arg; c.args) if (asyncNodeContainsAwait(arg)) return true;
            return false;
        }
        if (auto m = cast(MemberExpr)node) return asyncNodeContainsAwait(m.object);
        if (auto idx = cast(IndexExpr)node) return asyncNodeContainsAwait(idx.array) || asyncNodeContainsAwait(idx.index);
        if (auto n = cast(NewExpr)node) {
            foreach (arg; n.args) if (asyncNodeContainsAwait(arg)) return true;
            return false;
        }
        if (auto c = cast(CastExpr)node) return asyncNodeContainsAwait(c.expression);
        if (auto p = cast(PropagateExpr)node) return asyncNodeContainsAwait(p.operand);
        if (auto a = cast(ArrayLiteral)node) {
            foreach (elem; a.elements) if (asyncNodeContainsAwait(elem)) return true;
            return false;
        }
        if (auto t = cast(TupleLiteral)node) {
            foreach (elem; t.elements) if (asyncNodeContainsAwait(elem)) return true;
            return false;
        }
        if (auto s = cast(StructLiteral)node) {
            foreach (value; s.fieldValues) if (asyncNodeContainsAwait(value)) return true;
            return false;
        }
        return false;
    }

    private ASTNode[] normalizeAsyncStatement(ASTNode stmt, ref int tempIndex);

    private Block normalizeAsyncBlock(Block block, ref int tempIndex) {
        if (block is null) return null;
        ASTNode[] statements;
        foreach (stmt; block.statements) {
            statements ~= normalizeAsyncStatement(stmt, tempIndex);
        }
        return new Block(statements, block.isHolding);
    }

    private ASTNode asyncTempIdentifier(string name, ASTNode source) {
        return new Identifier(name, source !is null ? source.line : 0, source !is null ? source.column : 0);
    }

    private ASTNode extractAsyncAwaits(ASTNode expr, ref ASTNode[] prelude, ref int tempIndex) {
        if (expr is null) return null;
        if (auto awaitExpr = cast(AwaitExpr)expr) {
            ASTNode[] nested;
            ASTNode awaited = extractAsyncAwaits(awaitExpr.expression, nested, tempIndex);
            foreach (stmt; nested) prelude ~= stmt;
            string tempName = format("__llpl_async_tmp%d", tempIndex++);
            prelude ~= new VarDecl(tempName, null, new AwaitExpr(awaited, awaitExpr.line, awaitExpr.column),
                false, awaitExpr.line, awaitExpr.column);
            return asyncTempIdentifier(tempName, awaitExpr);
        }
        if (auto b = cast(BinaryExpr)expr) {
            return new BinaryExpr(b.op, extractAsyncAwaits(b.left, prelude, tempIndex),
                extractAsyncAwaits(b.right, prelude, tempIndex), b.line, b.column);
        }
        if (auto u = cast(UnaryExpr)expr) {
            return new UnaryExpr(u.op, extractAsyncAwaits(u.operand, prelude, tempIndex),
                u.line, u.column, u.isPostfix);
        }
        if (auto c = cast(CallExpr)expr) {
            ASTNode[] args;
            foreach (arg; c.args) args ~= extractAsyncAwaits(arg, prelude, tempIndex);
            return new CallExpr(extractAsyncAwaits(c.callee, prelude, tempIndex), args,
                c.line, c.column, c.argNames, c.typeArgs);
        }
        if (auto m = cast(MemberExpr)expr) {
            return new MemberExpr(extractAsyncAwaits(m.object, prelude, tempIndex), m.member, m.line, m.column);
        }
        if (auto idx = cast(IndexExpr)expr) {
            return new IndexExpr(extractAsyncAwaits(idx.array, prelude, tempIndex),
                extractAsyncAwaits(idx.index, prelude, tempIndex), idx.line, idx.column);
        }
        if (auto n = cast(NewExpr)expr) {
            ASTNode[] args;
            foreach (arg; n.args) args ~= extractAsyncAwaits(arg, prelude, tempIndex);
            return new NewExpr(n.type, args, n.line, n.column, n.argNames);
        }
        if (auto c = cast(CastExpr)expr) {
            return new CastExpr(c.type, extractAsyncAwaits(c.expression, prelude, tempIndex),
                c.line, c.column, c.useImplicitConversion);
        }
        if (auto p = cast(PropagateExpr)expr) {
            return new PropagateExpr(extractAsyncAwaits(p.operand, prelude, tempIndex), p.line, p.column);
        }
        if (auto a = cast(ArrayLiteral)expr) {
            ASTNode[] elements;
            foreach (elem; a.elements) elements ~= extractAsyncAwaits(elem, prelude, tempIndex);
            return new ArrayLiteral(elements, a.line, a.column);
        }
        if (auto t = cast(TupleLiteral)expr) {
            ASTNode[] elements;
            foreach (elem; t.elements) elements ~= extractAsyncAwaits(elem, prelude, tempIndex);
            return new TupleLiteral(elements, t.line, t.column);
        }
        if (auto s = cast(StructLiteral)expr) {
            ASTNode[] values;
            foreach (value; s.fieldValues) values ~= extractAsyncAwaits(value, prelude, tempIndex);
            return new StructLiteral(s.typeName, s.fieldNames, values, s.line, s.column, s.typeArgs);
        }
        return expr;
    }

    private ASTNode[] normalizeAsyncStatement(ASTNode stmt, ref int tempIndex) {
        ASTNode[] result;
        if (auto v = cast(VarDecl)stmt) {
            if (isDirectAwaitExpr(v.initializer)) {
                result ~= stmt;
                return result;
            }
            ASTNode[] prelude;
            ASTNode init = extractAsyncAwaits(v.initializer, prelude, tempIndex);
            result ~= prelude;
            result ~= new VarDecl(v.name, v.type, init, v.isConst, v.line, v.column,
                v.bitWidth, v.isVolatile, v.attributes);
            return result;
        }
        if (auto r = cast(ReturnStmt)stmt) {
            ASTNode[] prelude;
            ASTNode value = extractAsyncAwaits(r.value, prelude, tempIndex);
            result ~= prelude;
            result ~= new ReturnStmt(value, r.line, r.column);
            return result;
        }
        if (auto e = cast(ExprStmt)stmt) {
            if (isDirectAwaitExpr(e.expression)) {
                result ~= stmt;
                return result;
            }
            ASTNode[] prelude;
            ASTNode expr = extractAsyncAwaits(e.expression, prelude, tempIndex);
            result ~= prelude;
            result ~= new ExprStmt(expr);
            return result;
        }
        if (auto i = cast(IfStmt)stmt) {
            ASTNode[] prelude;
            ASTNode condition = extractAsyncAwaits(i.condition, prelude, tempIndex);
            result ~= prelude;
            result ~= new IfStmt(condition, normalizeAsyncBlock(i.thenBlock, tempIndex),
                normalizeAsyncBlock(i.elseBlock, tempIndex), i.isPostfix);
            return result;
        }
        if (auto w = cast(WhileStmt)stmt) {
            if (asyncNodeContainsAwait(w.condition)) {
                ASTNode[] prelude;
                ASTNode condition = extractAsyncAwaits(w.condition, prelude, tempIndex);
                ASTNode[] bodyStatements;
                bodyStatements ~= prelude;
                bodyStatements ~= new IfStmt(new UnaryExpr("!", condition, condition.line, condition.column),
                    new Block([cast(ASTNode)new BreakStmt(w.line, w.column)]));
                bodyStatements ~= normalizeAsyncBlock(w.body_, tempIndex).statements;
                result ~= new WhileStmt(new BoolLiteral(true, w.line, w.column), new Block(bodyStatements));
            } else {
                result ~= new WhileStmt(w.condition, normalizeAsyncBlock(w.body_, tempIndex));
            }
            return result;
        }
        if (auto block = cast(Block)stmt) {
            result ~= normalizeAsyncBlock(block, tempIndex);
            return result;
        }
        result ~= stmt;
        return result;
    }

    private AwaitExpr directAwaitFromStatement(ASTNode stmt) {
        if (auto v = cast(VarDecl)stmt) return cast(AwaitExpr)v.initializer;
        if (auto e = cast(ExprStmt)stmt) return cast(AwaitExpr)e.expression;
        return null;
    }

    private void checkAsyncLowering(ASTNode node) {
        if (node is null) return;
        if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) checkAsyncLowering(stmt);
            return;
        }
        if (auto i = cast(IfStmt)node) {
            if (asyncNodeContainsAwait(i.condition)) {
                throw new CompileError("async lowering expected awaits in if conditions to be normalized",
                    currentModulePath, i.line, i.column);
            }
            checkAsyncLowering(i.thenBlock);
            checkAsyncLowering(i.elseBlock);
            return;
        }
        if (auto w = cast(WhileStmt)node) {
            if (asyncNodeContainsAwait(w.condition)) {
                throw new CompileError("async lowering expected awaits in while conditions to be normalized",
                    currentModulePath, w.line, w.column);
            }
            checkAsyncLowering(w.body_);
            return;
        }
        if (auto d = cast(DoWhileStmt)node) {
            if (asyncNodeContainsAwait(d)) {
                throw new CompileError("async lowering does not support await inside do/while statements yet",
                    currentModulePath, d.line, d.column);
            }
            return;
        }
        if (auto f = cast(ForStmt)node) {
            if (asyncNodeContainsAwait(f)) {
                throw new CompileError("async lowering does not support await inside for statements yet",
                    currentModulePath, f.line, f.column);
            }
            return;
        }
        if (auto f = cast(ForeachStmt)node) {
            if (asyncNodeContainsAwait(f)) {
                throw new CompileError("async lowering does not support await inside foreach statements yet",
                    currentModulePath, f.line, f.column);
            }
            return;
        }
        if (auto d = cast(DeferStmt)node) {
            if (asyncNodeContainsAwait(d)) {
                throw new CompileError("async lowering does not support await inside defer statements",
                    currentModulePath, d.line, d.column);
            }
            return;
        }
        if (auto t = cast(TryStmt)node) {
            if (asyncNodeContainsAwait(t)) {
                throw new CompileError("async lowering does not support await inside try/catch/finally statements yet",
                    currentModulePath, t.line, t.column);
            }
            return;
        }
        if (auto m = cast(MatchStmt)node) {
            if (asyncNodeContainsAwait(m)) {
                throw new CompileError("async lowering does not support await inside match statements yet",
                    currentModulePath, m.line, m.column);
            }
            return;
        }
        if (auto v = cast(VarDecl)node) {
            if (asyncNodeContainsAwait(v.initializer) && !isDirectAwaitExpr(v.initializer)) {
                throw new CompileError("async lowering expected embedded awaits to be normalized",
                    currentModulePath, v.line, v.column);
            }
            return;
        }
        if (auto e = cast(ExprStmt)node) {
            if (asyncNodeContainsAwait(e.expression) && !isDirectAwaitExpr(e.expression)) {
                throw new CompileError("async lowering expected embedded awaits to be normalized",
                    currentModulePath, e.line, e.column);
            }
            return;
        }
        if (auto r = cast(ReturnStmt)node) {
            if (asyncNodeContainsAwait(r.value)) {
                throw new CompileError("async lowering expected awaits in return expressions to be normalized",
                    currentModulePath, r.line, r.column);
            }
            return;
        }
        if (asyncNodeContainsAwait(node)) {
            throw new CompileError("async lowering does not support await in this statement yet",
                currentModulePath, node.line, node.column);
        }
    }

    private Block normalizedAsyncBody(FunctionDecl fn) {
        if (fn.body_ is null) {
            throw new CompileError("async function lowering requires a function body",
                currentModulePath, fn.line, fn.column);
        }
        int tempIndex = 0;
        Block body = normalizeAsyncBlock(fn.body_, tempIndex);
        checkAsyncLowering(body);
        return body;
    }

    private Type resolveAsyncVarType(VarDecl varDecl) {
        if (varDecl.type is null) {
            FunctionDecl fn = resolveFunctionReference(varDecl.initializer);
            varDecl.type = fn !is null ? closureTypeFromFunction(fn) : inferType(varDecl.initializer);
        }
        resolveType(varDecl.type);
        return varDecl.type;
    }

    private bool asyncFutureHasStateField(Type futureType) {
        return asyncFutureHasField(futureType, "state");
    }

    private bool asyncFutureHasField(Type futureType, string fieldName) {
        if (auto structDecl = futureType.name in structRegistry) {
            foreach (field; structDecl.fields) {
                if (field.name == fieldName) return true;
            }
        }
        return false;
    }

    private string generateAsyncAwaitReadinessCheck(int awaitIndex, int resumeState, Type awaitType) {
        if (!asyncFutureHasStateField(awaitType)) return "";
        return format(
            "        if (self->__await%d.state == 0) {\n" ~
            "            self->state = %d;\n" ~
            "            return __poll;\n" ~
            "        }\n",
            awaitIndex, resumeState);
    }

    private string generateAsyncAwaitReadinessCheck(int awaitIndex, int resumeState, Type awaitType, string pad) {
        string code;
        if (asyncFutureHasField(awaitType, "deadline_ms")) {
            code ~= format("%sif (llpl_async_now_ms() >= self->__await%d.deadline_ms) {\n", pad, awaitIndex);
            code ~= format("%s    self->__await%d.state = 1;\n", pad, awaitIndex);
            code ~= pad ~ "}\n";
        }
        if (!asyncFutureHasStateField(awaitType)) return code;
        code ~= format(
            "%sif (self->__await%d.state == 0) {\n" ~
            "%s    self->state = %d;\n" ~
            "%s    return __poll;\n" ~
            "%s}\n",
            pad, awaitIndex, pad, resumeState, pad, pad);
        return code;
    }

    private void collectAsyncLocalsAndAwaits(ASTNode node, ref VarDecl[] locals, ref AwaitExpr[] awaits, ref Type[] awaitTypes) {
        if (node is null) return;
        if (auto block = cast(Block)node) {
            foreach (stmt; block.statements) collectAsyncLocalsAndAwaits(stmt, locals, awaits, awaitTypes);
            return;
        }
        if (auto v = cast(VarDecl)node) {
            Type localType = resolveAsyncVarType(v);
            locals ~= v;
            variableTypes[v.name] = localType;
            variableCNames[v.name] = "self->" ~ v.name;
            recordLocal(v.name, localType, v.line, v.column, "local");
            if (auto awaitExpr = cast(AwaitExpr)v.initializer) {
                Type awaitType = inferType(awaitExpr.expression);
                resolveType(awaitType);
                if (awaitType.isPointer || awaitType.isArray) {
                    throw new CompileError("async lowering expects await expressions to return a Future<T> value, not a pointer or array",
                        currentModulePath, awaitExpr.line, awaitExpr.column);
                }
                if (futureValueType(awaitType) is null) {
                    throw new CompileError(format("Cannot await '%s'; expected Future<T> or AsyncFuture<T>",
                            awaitType.toString()),
                        currentModulePath, awaitExpr.line, awaitExpr.column);
                }
                awaits ~= awaitExpr;
                awaitTypes ~= awaitType;
            }
            return;
        }
        if (auto e = cast(ExprStmt)node) {
            if (auto awaitExpr = cast(AwaitExpr)e.expression) {
                Type awaitType = inferType(awaitExpr.expression);
                resolveType(awaitType);
                if (awaitType.isPointer || awaitType.isArray) {
                    throw new CompileError("async lowering expects await expressions to return a Future<T> value, not a pointer or array",
                        currentModulePath, awaitExpr.line, awaitExpr.column);
                }
                if (futureValueType(awaitType) is null) {
                    throw new CompileError(format("Cannot await '%s'; expected Future<T> or AsyncFuture<T>",
                            awaitType.toString()),
                        currentModulePath, awaitExpr.line, awaitExpr.column);
                }
                awaits ~= awaitExpr;
                awaitTypes ~= awaitType;
            }
            return;
        }
        if (auto i = cast(IfStmt)node) {
            collectAsyncLocalsAndAwaits(i.thenBlock, locals, awaits, awaitTypes);
            collectAsyncLocalsAndAwaits(i.elseBlock, locals, awaits, awaitTypes);
            return;
        }
        if (auto w = cast(WhileStmt)node) {
            collectAsyncLocalsAndAwaits(w.body_, locals, awaits, awaitTypes);
            return;
        }
    }

    private string asyncFrameValueAssignment(VarDecl varDecl, string exprCode) {
        if (varDecl.type.isNullableSugar) {
            return generateNullableWrap(varDecl.type, varDecl.initializer);
        }
        if (auto tupleLit = cast(TupleLiteral)varDecl.initializer) {
            return generateTupleLiteral(tupleLit, cloneType(varDecl.type));
        }
        if (auto structLit = cast(StructLiteral)varDecl.initializer) {
            return generateStructLiteralValue(structLit, cloneType(varDecl.type));
        }
        string converted = tryImplicitConversionCall(varDecl.initializer, varDecl.type);
        if (converted.length > 0) return converted;
        ASTNode initExpr = insertUpcastIfNeeded(varDecl.initializer, varDecl.type);
        initExpr = insertNumericCoercionIfNeeded(initExpr, varDecl.type);
        return generateExpression(initExpr);
    }

    private string generateAsyncStatements(ASTNode[] statements, Type[] awaitTypes,
            ref int state, ref int awaitIndex, ref bool needCaseLabel, int asyncIndentLevel) {
        string code;
        string pad(int level) {
            string s;
            foreach (_; 0 .. level) s ~= "    ";
            return s;
        }
        void emitCaseIfNeeded() {
            if (needCaseLabel) {
                code ~= pad(asyncIndentLevel - 1) ~ format("case %d:\n", state);
                needCaseLabel = false;
            }
        }

        foreach (stmt; statements) {
            emitCaseIfNeeded();
            if (auto varDecl = cast(VarDecl)stmt) {
                if (auto awaitExpr = cast(AwaitExpr)varDecl.initializer) {
                    code ~= pad(asyncIndentLevel) ~ format("self->__await%d = %s;\n", awaitIndex,
                        generateExpression(awaitExpr.expression));
                    code ~= pad(asyncIndentLevel) ~ format("self->state = %d;\n", state + 1);
                    code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
                    state++;
                    code ~= pad(asyncIndentLevel - 1) ~ format("case %d:\n", state);
                    code ~= generateAsyncAwaitReadinessCheck(awaitIndex, state, awaitTypes[awaitIndex], pad(asyncIndentLevel));
                    code ~= pad(asyncIndentLevel) ~ format("self->%s = self->__await%d.value;\n", varDecl.name, awaitIndex);
                    code ~= pad(asyncIndentLevel) ~ format("self->state = %d;\n", state + 1);
                    state++;
                    awaitIndex++;
                    needCaseLabel = true;
                } else if (varDecl.initializer !is null) {
                    code ~= pad(asyncIndentLevel) ~ format("self->%s = %s;\n", varDecl.name,
                        asyncFrameValueAssignment(varDecl, generateExpression(varDecl.initializer)));
                }
                code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
            } else if (auto exprStmt = cast(ExprStmt)stmt) {
                if (auto awaitExpr = cast(AwaitExpr)exprStmt.expression) {
                    code ~= pad(asyncIndentLevel) ~ format("self->__await%d = %s;\n", awaitIndex,
                        generateExpression(awaitExpr.expression));
                    code ~= pad(asyncIndentLevel) ~ format("self->state = %d;\n", state + 1);
                    code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
                    state++;
                    code ~= pad(asyncIndentLevel - 1) ~ format("case %d:\n", state);
                    code ~= generateAsyncAwaitReadinessCheck(awaitIndex, state, awaitTypes[awaitIndex], pad(asyncIndentLevel));
                    code ~= pad(asyncIndentLevel) ~ format("(void)self->__await%d.value;\n", awaitIndex);
                    code ~= pad(asyncIndentLevel) ~ format("self->state = %d;\n", state + 1);
                    state++;
                    awaitIndex++;
                    needCaseLabel = true;
                } else {
                    code ~= pad(asyncIndentLevel) ~ format("%s;\n", generateDiscardedExpression(exprStmt.expression));
                }
                code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
            } else if (auto returnStmt = cast(ReturnStmt)stmt) {
                if (returnStmt.value !is null) {
                    ASTNode retExpr = returnStmt.value;
                    if (currentReturnType !is null) {
                        retExpr = insertUpcastIfNeeded(retExpr, currentReturnType);
                        retExpr = insertNumericCoercionIfNeeded(retExpr, currentReturnType);
                    }
                    code ~= pad(asyncIndentLevel) ~ format("self->__result = %s;\n", generateExpression(retExpr));
                    code ~= pad(asyncIndentLevel) ~ "__poll.value = self->__result;\n";
                }
                code ~= pad(asyncIndentLevel) ~ format("self->state = %d;\n", state + 1);
                code ~= pad(asyncIndentLevel) ~ "__poll.state = 1;\n";
                code ~= pad(asyncIndentLevel) ~ "return __poll;\n";
                state++;
                needCaseLabel = true;
            } else if (auto ifStmt = cast(IfStmt)stmt) {
                code ~= pad(asyncIndentLevel) ~ "if (" ~ generateCondition(ifStmt.condition) ~ ") {\n";
                code ~= generateAsyncStatements(ifStmt.thenBlock.statements, awaitTypes,
                    state, awaitIndex, needCaseLabel, asyncIndentLevel + 1);
                if (needCaseLabel) {
                    needCaseLabel = false;
                }
                if (ifStmt.elseBlock) {
                    code ~= pad(asyncIndentLevel) ~ "} else {\n";
                    code ~= generateAsyncStatements(ifStmt.elseBlock.statements, awaitTypes,
                        state, awaitIndex, needCaseLabel, asyncIndentLevel + 1);
                    if (needCaseLabel) {
                        needCaseLabel = false;
                    }
                }
                code ~= pad(asyncIndentLevel) ~ "}\n";
                code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
            } else if (auto whileStmt = cast(WhileStmt)stmt) {
                code ~= pad(asyncIndentLevel) ~ "while (" ~ generateCondition(whileStmt.condition) ~ ") {\n";
                code ~= generateAsyncStatements(whileStmt.body_.statements, awaitTypes,
                    state, awaitIndex, needCaseLabel, asyncIndentLevel + 1);
                if (needCaseLabel) {
                    needCaseLabel = false;
                }
                code ~= pad(asyncIndentLevel) ~ "}\n";
                code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
            } else if (auto block = cast(Block)stmt) {
                code ~= pad(asyncIndentLevel) ~ "{\n";
                code ~= generateAsyncStatements(block.statements, awaitTypes,
                    state, awaitIndex, needCaseLabel, asyncIndentLevel + 1);
                if (needCaseLabel) {
                    needCaseLabel = false;
                }
                code ~= pad(asyncIndentLevel) ~ "}\n";
                code ~= pad(asyncIndentLevel) ~ "/* fallthrough */\n";
            } else if (cast(ContinueStmt)stmt) {
                code ~= pad(asyncIndentLevel) ~ "continue;\n";
            } else if (cast(BreakStmt)stmt) {
                code ~= pad(asyncIndentLevel) ~ "break;\n";
            } else if (asyncNodeContainsAwait(stmt)) {
                throw new CompileError("async lowering does not support await in this statement yet",
                    currentModulePath, stmt.line, stmt.column);
            } else {
                code ~= generateStatement(stmt, false);
            }
        }
        return code;
    }

    private string generateAsyncFunction(FunctionDecl funcDecl, string baseNameOverride = "", Parameter[] leadingParams = []) {
        Block asyncBody = normalizedAsyncBody(funcDecl);

        string code = "";
        string baseName = baseNameOverride.length > 0 ? baseNameOverride : mangleFreeFunctionName(funcDecl);
        string frameName = baseName ~ "_AsyncFrame";
        string pollName = baseName ~ "_AsyncPoll";
        string startName = baseName ~ "_async_start";
        string pollFuncName = baseName ~ "_async_poll";

        currentNamespaceSegments = funcDecl.namespaceSegments;
        string prevScopeName = currentScopeName;
        currentScopeName = baseName;
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = cloneType(funcDecl.returnType);
        resolveType(funcDecl.returnType);
        Type prevReturnType = currentReturnType;
        currentReturnType = funcDecl.returnType;
        Type[string] savedFunctionVariableTypes = variableTypes.dup;
        bool[string] savedFunctionConstVariables = constVariables.dup;
        auto savedDeferredRc = saveDeferredRcState();

        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        Parameter[] allParams = leadingParams ~ funcDecl.params;
        foreach (param; allParams) {
            resolveType(param.type);
            variableTypes[param.name] = param.type;
            variableCNames[param.name] = "self->" ~ param.name;
            recordLocal(param.name, param.type, funcDecl.line, funcDecl.column, "parameter");
        }

        VarDecl[] locals;
        AwaitExpr[] awaits;
        Type[] awaitTypes;
        collectAsyncLocalsAndAwaits(asyncBody, locals, awaits, awaitTypes);

        code ~= format("typedef struct %s %s;\n", frameName, frameName);
        code ~= format("typedef struct %s %s;\n", pollName, pollName);
        code ~= format("struct %s {\n", frameName);
        code ~= "    int state;\n";
        if (funcDecl.returnType.name != "void" || funcDecl.returnType.isPointer) {
            code ~= format("    %s __result;\n", typeToC(funcDecl.returnType));
        }
        foreach (param; allParams) {
            code ~= "    " ~ typedParameterDeclaration(param.type, param.name) ~ ";\n";
        }
        foreach (local; locals) {
            code ~= "    " ~ typedParameterDeclaration(local.type, local.name) ~ ";\n";
        }
        foreach (i, awaitType; awaitTypes) {
            code ~= format("    %s __await%d;\n", typeToC(awaitType), i);
        }
        code ~= "};\n";

        code ~= format("struct %s {\n", pollName);
        code ~= "    int state;\n";
        if (funcDecl.returnType.name != "void" || funcDecl.returnType.isPointer) {
            code ~= format("    %s value;\n", typeToC(funcDecl.returnType));
        }
        code ~= "};\n\n";

        string params = "";
        foreach (i, param; allParams) {
            if (i > 0) params ~= ", ";
            params ~= parameterDeclaration(param);
        }

        code ~= format("%s %s(%s) {\n", frameName, startName, params);
        code ~= format("    %s __frame_init;\n", frameName);
        code ~= "    __frame_init.state = 0;\n";
        foreach (param; allParams) {
            code ~= format("    __frame_init.%s = %s;\n", param.name, param.name);
        }
        code ~= "    return __frame_init;\n";
        code ~= "}\n\n";

        code ~= format("%s %s(%s* self) {\n", pollName, pollFuncName, frameName);
        code ~= format("    %s __poll;\n", pollName);
        code ~= "    __poll.state = 0;\n";
        code ~= "    switch (self->state) {\n";

        int state = 0;
        int awaitIndex = 0;
        bool needCaseLabel = true;
        foreach (param; allParams) {
            variableCNames[param.name] = "self->" ~ param.name;
        }
        foreach (local; locals) {
            variableCNames[local.name] = "self->" ~ local.name;
        }
        code ~= generateAsyncStatements(asyncBody.statements, awaitTypes, state, awaitIndex, needCaseLabel, 2);

        code ~= "    default:\n";
        if (funcDecl.returnType.name != "void" || funcDecl.returnType.isPointer) {
            code ~= "        __poll.value = self->__result;\n";
        }
        code ~= "        __poll.state = 1;\n";
        code ~= "        return __poll;\n";
        code ~= "    }\n";
        code ~= "}\n\n";

        code ~= format("%s %s(%s) {\n", typeToC(funcDecl.returnType), baseName, params);
        code ~= format("    %s __frame = %s(%s);\n", frameName, startName,
            allParams.map!(p => p.name).array.join(", "));
        code ~= "    while (1) {\n";
        code ~= format("        %s __poll = %s(&__frame);\n", pollName, pollFuncName);
        code ~= "        if (__poll.state == 1) {\n";
        if (funcDecl.returnType.name != "void" || funcDecl.returnType.isPointer) {
            code ~= "            return __poll.value;\n";
        } else {
            code ~= "            return;\n";
        }
        code ~= "        }\n";
        code ~= "    }\n";
        code ~= "}\n\n";

        code ~= format("uintptr_t %s_async_frame_size() {\n", baseName);
        code ~= format("    return sizeof(%s);\n", frameName);
        code ~= "}\n\n";

        code ~= format("void %s_async_start_into(void* __frame", baseName);
        foreach (param; allParams) {
            code ~= ", " ~ parameterDeclaration(param);
        }
        code ~= ") {\n";
        code ~= format("    %s __tmp = %s(", frameName, startName);
        foreach (i, param; allParams) {
            if (i > 0) code ~= ", ";
            code ~= param.name;
        }
        code ~= ");\n";
        code ~= format("    memcpy(__frame, &__tmp, sizeof(%s));\n", frameName);
        code ~= "}\n\n";

        code ~= format("intptr_t %s_async_poll_erased(void* __frame, void* __out) {\n", baseName);
        code ~= format("    %s __poll = %s((%s*)__frame);\n", pollName, pollFuncName, frameName);
        if (funcDecl.returnType.name != "void" || funcDecl.returnType.isPointer) {
            code ~= "    if (__poll.state == 1 && __out != ((void*)0)) {\n";
            code ~= "        memcpy(__out, &__poll.value, sizeof(__poll.value));\n";
            code ~= "    }\n";
        }
        code ~= "    return __poll.state;\n";
        code ~= "}\n\n";

        restoreDeferredRcState(savedDeferredRc);
        variableTypes = savedFunctionVariableTypes;
        constVariables = savedFunctionConstVariables;
        variableCNames = null;
        pointerIndexBounds = null;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentScopeName = prevScopeName;

        return code;
    }

    private string unitTestFunctionName(int index) {
        return format("__llpl_unittest_%d", index);
    }

    private string generateUnitTestFunction(UnitTestDecl unitTestDecl, int index) {
        string name = unitTestFunctionName(index);
        string code = format("static void %s(void) {\n", name);

        string prevScopeName = currentScopeName;
        currentScopeName = name;
        Type prevReturnType = currentReturnType;
        currentReturnType = new Type("void");
        Type prevReturnTypeAsWritten = currentReturnTypeAsWritten;
        currentReturnTypeAsWritten = new Type("void");
        string prevClassName = currentClassName;
        currentClassName = "";
        currentNamespaceSegments = unitTestDecl.namespaceSegments;
        auto savedVariableTypes = variableTypes.dup;
        auto savedConstVariables = constVariables.dup;
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        indentLevel++;
        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (unitTestDecl.body_ !is null) {
            foreach (stmt; unitTestDecl.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);

        indentLevel--;
        code ~= "}\n\n";

        currentScopeName = prevScopeName;
        currentReturnType = prevReturnType;
        currentReturnTypeAsWritten = prevReturnTypeAsWritten;
        currentClassName = prevClassName;
        variableTypes = savedVariableTypes;
        constVariables = savedConstVariables;
        return code;
    }

    private string generateUnitTestMain(int count) {
        if (count == 0) return "\nint main(void) {\n    return 0;\n}\n";
        string code = "\nint main(void) {\n";
        foreach (i; 0 .. count) {
            code ~= format("    %s();\n", unitTestFunctionName(i));
        }
        code ~= "    return 0;\n}\n";
        return code;
    }

    private Type resolveDirectConstructorType(string name) {
        Type t = new Type(name);
        resolveType(t);
        if ((t.name in classRegistry) !is null || (t.name in structRegistry) !is null ||
                (t.name in unionRegistry) !is null) {
            return t;
        }
        return null;
    }

    private Type resolveQualifiedConstructorType(MemberExpr memberExpr) {
        string key = tryResolveQualifiedPath(memberExpr,
            (n) => (n in classRegistry) !is null || (n in structRegistry) !is null ||
                (n in unionRegistry) !is null);
        if (key.length == 0) return null;
        return new Type(key);
    }

    // The real C `int main(int argc, char** argv)` entry point for a
    // `func main(args: string[]) -> ...` - the one shape that can't just be
    // an ordinary function the way `func main(argc: i32, argv: char**)`
    // or plain `func main()` already are (see isMainArgsFunction's own
    // comment): the C runtime always calls main with (argc, argv[, envp]),
    // never a single char** - a real int32_t-argc, char** parameter list
    // is the only one that's ABI-correct to *be* main, regardless of how
    // this language would rather let a program spell "give me my args".
    // `args` itself skips argv[0] (the program's own path, never something
    // callers of this shape want to see) - argv + 1 is still a valid,
    // null-terminated char** since the C runtime always null-terminates
    // argv at argv[argc], and adding 1 doesn't undo that.
    private string generateMainWrapper(FunctionDecl funcDecl) {
        string call = format("%s(argv + 1)", mainArgsImplName);
        string body = funcDecl.returnType.name == "void" ?
            format("%s;\n    return 0;\n", call) :
            format("return (int)%s;\n", call);
        return format("\nint main(int argc, char** argv) {\n    %s}\n", body);
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
        bool prevInterrupt = currentFunctionIsInterrupt;
        currentFunctionIsInterrupt = true;
        // See generateStructConstructor's matching comment.
        variableCNames = null;
        pointerIndexBounds = null;
        shadowRenameCounter = 0;

        string params = "void* __frame";
        variableTypes["__frame"] = new Type("void", true);
        if (funcDecl.params.length == 1) {
            Parameter param = funcDecl.params[0];
            resolveType(param.type);
            params ~= ", " ~ parameterDeclaration(param);
            variableTypes[param.name] = param.type;
            recordPointerBound(param.name, param.type);
            if (param.isConst) constVariables[param.name] = true;
        }

        string code = format("__attribute__((interrupt)) void %s(%s) {\n", mangledFunc(funcDecl), params);
        indentLevel++;

        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;

        string bodyCode = "";
        if (funcDecl.body_) {
            foreach (stmt; funcDecl.body_.statements) {
                bodyCode ~= generateBodyStatement(stmt, false);
            }
        }

        code ~= deferFrameDeclarations();
        code ~= bodyCode;
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(null);

        indentLevel--;
        code ~= "}\n";

        variableTypes.remove("__frame");
        if (funcDecl.params.length == 1) {
            variableTypes.remove(funcDecl.params[0].name);
            constVariables.remove(funcDecl.params[0].name);
        }
        currentFunctionIsInterrupt = prevInterrupt;

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

    private bool isIntegerType(Type t) {
        if (t is null || t.isPointer || t.isArray) return false;
        switch (t.name) {
            case "i64": case "u64":
            case "u8": case "char":
            case "i8": case "int8": case "uint8":
            case "i16": case "u16": case "int16": case "uint16":
            case "i32": case "u32": case "int32": case "uint32":
            case "int64": case "uint64":
            // int/uint are a third, separate integer family - native
            // machine-word-sized (C intptr_t/uintptr_t), not aliases of
            // i64/u64. See primitiveToC and integerRank's own comments.
            case "int": case "uint":
                return true;
            default:
                return false;
        }
    }

    private bool isSignedIntegerType(Type t) {
        if (!isIntegerType(t)) return false;
        switch (t.name) {
            // char is treated as unsigned here to match how it's actually
            // compiled (run_tests.sh passes -funsigned-char) and to avoid a
            // signed/unsigned surprise against u8, the other 8-bit type.
            case "u64": case "u8": case "char": case "uint8":
            case "u16": case "uint16": case "u32": case "uint32": case "uint64":
            case "uint":
                return false;
            default:
                return true;
        }
    }

    private bool isUnsignedIntegerType(Type t) {
        return isIntegerType(t) && !isSignedIntegerType(t);
    }

    private bool isFloatType(Type t) {
        return t !is null && !t.isPointer && !t.isArray &&
            (t.name == "f32" || t.name == "f64");
    }

    private bool isNumericType(Type t) {
        return isIntegerType(t) || isFloatType(t);
    }

    // Bit width of an integer type, or -1 if not one. Used to allow
    // same-signedness widening (i32->i64, u8->u64) without also allowing
    // narrowing (i64->i32) - narrowing still needs an explicit `as` cast,
    // same rationale as float-narrowing/uint->int below. Reuses
    // primitiveBitSize (originally added for bit-field validation) rather
    // than duplicating its width table.
    private int integerRank(Type t) {
        if (!isIntegerType(t)) return -1;
        return primitiveBitSize(t.name);
    }

    private int numericCoercionCost(Type source, Type target) {
        if (sameErrorType(source, target)) return 0;
        if (source is null || target is null) return -1;
        if (target.name == "String" && target.pointerDepth == 0 && !target.isArray &&
                source.name == "char" && source.pointerDepth == 1 && !source.isArray) return 1;
        if (source.isPointer || source.isArray || target.isPointer || target.isArray) return -1;

        // Limited implicit numeric conversions: integer values can flow to
            // float/double, signed integer values can flow to unsigned
        // integer parameters/targets, and a narrower integer can flow to a
        // wider one of the same signedness. Keep float narrowing and
        // uint->int explicit; those lose information in ways that are hard
        // to spot at a call site. The width-widening rule needs both sides'
        // bit width known (integerRank >= 0) - int/uint are native machine-
        // word-sized (4 bytes on i386, 8 on x86_64: see primitiveToC), so
        // their actual width isn't known at LLPL-compile-time, and silently
        // treating them as narrower/wider than a specific fixed-width type
        // could be wrong depending on target - int/uint always need an
        // explicit `as` cast to/from a fixed-width integer type.
        if (isIntegerType(source) && isFloatType(target)) return 1;
        if (isSignedIntegerType(source) && isUnsignedIntegerType(target)) return 1;
        if (integerRank(source) >= 0 && integerRank(target) >= 0) {
            if (isSignedIntegerType(source) && isSignedIntegerType(target) && integerRank(source) < integerRank(target)) return 1;
            if (isUnsignedIntegerType(source) && isUnsignedIntegerType(target) && integerRank(source) < integerRank(target)) return 1;
        }
        return -1;
    }

    private bool canNumericCoerce(Type source, Type target) {
        return numericCoercionCost(source, target) >= 0;
    }

    private Type numericBinaryResultType(Type left, Type right) {
        if (!isNumericType(left) || !isNumericType(right)) return null;
        if (left.name == "f64" || right.name == "f64") return new Type("f64");
        if (left.name == "f32" || right.name == "f32") return new Type("f32");
        if (isSignedIntegerType(left) && isSignedIntegerType(right)) {
            return integerRank(left) >= integerRank(right) ? cloneType(left) : cloneType(right);
        }
        if (isUnsignedIntegerType(left) && isUnsignedIntegerType(right)) {
            return integerRank(left) >= integerRank(right) ? cloneType(left) : cloneType(right);
        }
        if (isUnsignedIntegerType(left) && canNumericCoerce(right, left)) return cloneType(left);
        if (isUnsignedIntegerType(right) && canNumericCoerce(left, right)) return cloneType(right);
        return cloneType(left);
    }

    private ASTNode insertNumericCoercionIfNeeded(ASTNode arg, Type targetType) {
        Type argType;
        try {
            argType = inferType(arg);
            resolveType(argType);
        } catch (Exception e) {
            return arg;
        }
        resolveType(targetType);
        if (!sameErrorType(argType, targetType) && canNumericCoerce(argType, targetType)) {
            return new CastExpr(cloneType(targetType), arg, arg.line, arg.column);
        }
        return arg;
    }

    private string generateNumericCoercedExpression(ASTNode expr, Type targetType) {
        return generateExpression(insertNumericCoercionIfNeeded(expr, targetType));
    }

    private void rejectInInterrupt(ASTNode node, string feature) {
        if (!currentFunctionIsInterrupt) return;
        throw new CompileError(format("%s is not allowed inside an interrupt function", feature),
            currentModulePath, node.line, node.column);
    }

    private void checkInterruptSafeCall(CallExpr callExpr) {
        if (!currentFunctionIsInterrupt) return;
        auto ident = cast(Identifier)callExpr.callee;
        if (ident is null) return;
        switch (ident.name) {
            case "llpl_alloc":
            case "llpl_free":
            case "rc_alloc":
            case "rc_release":
            case "llpl_panic":
            case "panic":
                rejectInInterrupt(callExpr, format("Call to '%s'", ident.name));
                break;
            default:
                break;
        }
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

    // `exceptName` is the "move" exception - a bare-identifier `return`
    // hands its tracked local's own reference straight to the caller
    // rather than releasing it here (see rcLocalNames' own comment); every
    // other early-exit site (an Optional/Result `?` propagation building
    // its own fresh return value) has nothing to except and passes null.
    private string cleanupCodeForFunctionExit(string exceptName = null) {
        string code = allActiveFinallyCode();
        if (tryFrameStack.length > 0) {
            foreach_reverse (frame; tryFrameStack) {
                if (frame.frameVarName.length > 0) {
                    code ~= indent() ~ format("llpl_eh_pop(&%s);\n", frame.frameVarName);
                }
            }
        }
        code ~= deferredCleanupCode();
        code ~= releaseRcLocals(exceptName);
        return code;
    }

    private string deferredCleanupCode(DeferInfo[] statements) {
        string code = "";
        if (statements.length > 0) {
            foreach_reverse (deferInfo; statements) {
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

    private string deferredCleanupCode() {
        return deferredCleanupCode(deferredStatements);
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
        code ~= indent() ~ format("%s.type_id = ((void*)0);\n", frameVar);
        code ~= indent() ~ format("%s.error_slot = ((void*)0);\n", frameVar);
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
            code ~= indent() ~ format("%s.type_id = ((void*)0);\n", frameVarName);
            code ~= indent() ~ format("%s.error_slot = ((void*)0);\n", frameVarName);
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
        code ~= indent() ~ format("llpl_eh_throw(%s, &%s, sizeof(%s), \"%s\", %d);\n",
            typeId(thrownType), tmp, typeToC(thrownType), escapeCString(baseName(currentModulePath)), stmt.line);
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
        string targetCode = generateExpression(stmt.value);
        // A tracked local that's been explicitly `delete`d is no longer
        // this scope's responsibility - stop tracking it so the function's
        // own exit-time release (see rcLocalNames) doesn't release it
        // a second time.
        if (cast(Identifier)stmt.value !is null) {
            untrackRcLocal(targetCode);
        }
        return indent() ~ format("rc_release(%s, %s);\n", targetCode, fieldDestructorSymbol(t));
    }

    private bool isRawStringType(Type t) {
        return t !is null && t.name == "char" && t.isPointer && !t.isArray;
    }

    private bool isStringClassType(Type t) {
        return t !is null && t.name == "String" && !t.isArray;
    }

    private string tryContainsMethodCall(BinaryExpr binExpr, Type containerType) {
        string containerKey = mangleTypeArg(containerType);
        string methodName = "contains";
        ASTNode[] oneArg = [binExpr.left];

        if (auto classDecl = containerKey in classRegistry) {
            ClassDecl owner;
            auto candidates = resolveMethodOnHierarchy(*classDecl, methodName, owner);
            if (candidates.length > 0) {
                auto methodDecl = resolveOverload(candidates, oneArg, [""],
                    format("method '%s.%s'", containerKey, methodName), binExpr.line, binExpr.column);
                auto resolvedArgs = applyImplicitArgumentConversions(
                    resolveCallArguments(methodDecl.params, false, oneArg, [""],
                        format("method '%s.%s'", containerKey, methodName), binExpr.line, binExpr.column),
                    methodDecl.params);
                string receiver = generateExpression(binExpr.right);
                string ownerName = mangledClass(owner);
                if (ownerName != containerKey) {
                    receiver = format("((%s*)%s)", ownerName, receiver);
                }
                string callArgs = receiver;
                foreach (arg; resolvedArgs) callArgs ~= ", " ~ generateExpression(arg);
                recordUsage(containerKey ~ "." ~ methodName, binExpr.line, binExpr.column);
                return format("%s(%s)", mangleMethodName(owner, ownerName, methodDecl), callArgs);
            }
        }

        if (auto structDecl = containerKey in structRegistry) {
            auto candidates = methodCandidatesNamed(*structDecl, methodName);
            if (candidates.length > 0) {
                auto methodDecl = resolveOverload(candidates, oneArg, [""],
                    format("method '%s.%s'", containerKey, methodName), binExpr.line, binExpr.column);
                auto resolvedArgs = applyImplicitArgumentConversions(
                    resolveCallArguments(methodDecl.params, false, oneArg, [""],
                        format("method '%s.%s'", containerKey, methodName), binExpr.line, binExpr.column),
                    methodDecl.params);
                string callArgs = generateExpression(binExpr.right);
                foreach (arg; resolvedArgs) callArgs ~= ", " ~ generateExpression(arg);
                recordUsage(containerKey ~ "." ~ methodName, binExpr.line, binExpr.column);
                return format("%s(%s)", mangleMethodName(*structDecl, containerKey, methodDecl), callArgs);
            }
        }

        string implKey = containerKey ~ "_" ~ methodName;
        if (auto fn = implKey in functionRegistry) {
            if ((*fn).params.length == 2) {
                recordUsage(containerKey ~ "." ~ methodName, binExpr.line, binExpr.column);
                return format("%s(%s, %s)", implKey,
                    generateExpression(binExpr.right), generateExpression(binExpr.left));
            }
        }

        return "";
    }

    // `value in container` - true if the right side contains value.
    // Built-ins handle fixed-size arrays, raw char* strings, String, and
    // exclusive ranges. Everything else falls back to a `contains(value)`
    // method, including methods supplied by `impl Contains<T> for Type`.
    private string generateInExpr(BinaryExpr binExpr) {
        if (auto rangeExpr = cast(RangeExpr)binExpr.right) {
            Type valueType = inferType(binExpr.left);
            Type startType = inferType(rangeExpr.start);
            Type endType = inferType(rangeExpr.end);
            resolveType(valueType);
            resolveType(startType);
            resolveType(endType);
            Type rangeType = numericBinaryResultType(numericBinaryResultType(valueType, startType), endType);
            if (rangeType is null) {
                throw new CompileError("'in' range membership needs numeric value/start/end expressions",
                    currentModulePath, binExpr.line, binExpr.column);
            }
            string tmp = format("__in%d", inExprCounter++);
            return format("({ %s %s_value = %s; %s %s_start = %s; %s %s_end = %s; " ~
                "(%s_value >= %s_start && %s_value < %s_end); })",
                typeToC(rangeType), tmp, generateNumericCoercedExpression(binExpr.left, rangeType),
                typeToC(rangeType), tmp, generateNumericCoercedExpression(rangeExpr.start, rangeType),
                typeToC(rangeType), tmp, generateNumericCoercedExpression(rangeExpr.end, rangeType),
                tmp, tmp, tmp, tmp);
        }

        Type containerType;
        try {
            containerType = inferType(binExpr.right);
            resolveType(containerType);
        } catch (Exception e) {
            throw new CompileError("'in' needs a typed container on its right side",
                currentModulePath, binExpr.line, binExpr.column);
        }

        if (containerType.isArray) {
            if (containerType.arraySize <= 0) {
                throw new CompileError(
                    format("'in' needs a fixed-size array (T[N]) on its right side, not '%s'", containerType.toString()),
                    currentModulePath, binExpr.line, binExpr.column);
            }
            string valueCode = generateExpression(binExpr.left);
            string arrCode = generateExpression(binExpr.right);
            string tmp = format("__in%d", inExprCounter++);
            return format("({ bool %s_found = false; for (uint64_t %s_i = 0; %s_i < %d; %s_i++) " ~
                "{ if (%s[%s_i] == (%s)) { %s_found = true; break; } } %s_found; })",
                tmp, tmp, tmp, containerType.arraySize, tmp, arrCode, tmp, valueCode, tmp, tmp);
        }

        Type needleType = inferType(binExpr.left);
        resolveType(needleType);
        if (isIntegerType(needleType) && (isRawStringType(containerType) || isStringClassType(containerType))) {
            string tmp = format("__in%d", inExprCounter++);
            string haystackExpr = isStringClassType(containerType)
                ? format("(%s)->buf", generateExpression(binExpr.right))
                : generateExpression(binExpr.right);
            return format("({ char %s_needle = (char)(%s); char* %s_s = %s; bool %s_found = false; " ~
                "if (((uint64_t)%s_s) != 0) { for (uint64_t %s_i = 0; %s_s[%s_i] != 0; %s_i++) " ~
                "{ if (%s_s[%s_i] == %s_needle) { %s_found = true; break; } } } %s_found; })",
                tmp, generateExpression(binExpr.left), tmp, haystackExpr, tmp,
                tmp, tmp, tmp, tmp, tmp, tmp, tmp, tmp, tmp, tmp);
        }

        string containsCall = tryContainsMethodCall(binExpr, containerType);
        if (containsCall.length > 0) return containsCall;

        throw new CompileError(
            format("'%s' can't be used on the right side of 'in' - use a fixed-size array, " ~
                "string, range, or define contains(value) / impl Contains<T> for this type",
                containerType.toString()),
            currentModulePath, binExpr.line, binExpr.column);
    }

    private string generateAssertStmt(AssertStmt stmt) {
        string condition = generateExpression(stmt.condition);
        string message = "";
        if (stmt.message !is null) {
            message = generateExpression(stmt.message);
        } else {
            message = format("\"assertion failed at %s:%d\"", currentModulePath, stmt.line);
        }
        string call = stmt.fatal ? "llpl_panic" : "llpl_check";
        return indent() ~ format("if (!(%s)) %s(%s);\n", condition, call, message);
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
        bool prevSuppressSourceLines = suppressSourceLineDirectives;
        suppressSourceLineDirectives = true;
        scope(exit) suppressSourceLineDirectives = prevSuppressSourceLines;
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
        string code = sourceLineDirective(node);

        if (auto varDecl = cast(VarDecl)node) {
            if (varDecl.bitWidth >= 0) {
                throw new CompileError("Bit-fields are only allowed on aggregate fields, not local variables",
                    currentModulePath, varDecl.line, varDecl.column);
            }

            // Infer the type from the initializer if none was declared
            if (varDecl.type is null) {
                FunctionDecl fn = resolveFunctionReference(varDecl.initializer);
                varDecl.type = fn !is null ? closureTypeFromFunction(fn) : inferType(varDecl.initializer);
            }
            // Captured *before* resolveType mutates varDecl.type in place -
            // a generic struct literal initializer (Pair { ... }) needs the
            // declared type's original, unmangled name/typeArgs to supply
            // its own type arguments (see resolveStructLiteralTarget).
            Type declaredTypeAsWritten = cloneType(varDecl.type);
            resolveType(varDecl.type);
            checkArrayLiteralInit(varDecl);
            if (currentFunctionIsInterrupt && !varDecl.type.isPointer && !varDecl.type.isArray &&
                    (varDecl.type.name in classRegistry) !is null) {
                throw new CompileError("Class-typed locals are not allowed inside an interrupt function",
                    currentModulePath, varDecl.line, varDecl.column);
            }

            // A `let name = ...` re-declaring a name already `let` earlier
            // in this function body shadows it - see variableCNames' own
            // comment for why the *emitted* C identifier gets a fresh
            // unique suffix instead of colliding. Checked against
            // variableCNames, not variableTypes - unlike variableCNames,
            // variableTypes is never cleared for a plain local (only for
            // params, at the end of each function/method/constructor), so
            // it can still hold a stale entry left over from an earlier,
            // unrelated function's own local of the same name.
            string emitName = varDecl.name;
            if (varDecl.name in variableCNames) {
                shadowRenameCounter++;
                emitName = format("%s__shadow%d", varDecl.name, shadowRenameCounter);
            }
            variableCNames[varDecl.name] = emitName;

            // Track the variable type
            variableTypes[varDecl.name] = varDecl.type;
            recordLocal(varDecl.name, varDecl.type, varDecl.line, varDecl.column, "local");
            if (varDecl.isConst) {
                constVariables[varDecl.name] = true;
            }

            // Handle array declarations specially
            string constPrefix = (varDecl.isVolatile ? "volatile " : "") ~ (varDecl.isConst ? "const " : "");
            if (varDecl.type.isArray && varDecl.type.arraySize > 0) {
                string baseType = fixedArrayElementCType(varDecl.type);
                code ~= indent() ~ format("%s%s %s[%d]%s", constPrefix, baseType, emitName, varDecl.type.arraySize,
                    extraDimsSuffix(varDecl.type));
            } else {
                code ~= indent() ~ format("%s%s %s", constPrefix, typeToC(varDecl.type), emitName);
            }

            if (varDecl.initializer) {
                if (varDecl.type.isNullableSugar) {
                    code ~= " = " ~ generateNullableWrap(varDecl.type, varDecl.initializer);
                } else if (auto tupleLit = cast(TupleLiteral)varDecl.initializer) {
                    code ~= " = " ~ generateTupleLiteral(tupleLit, declaredTypeAsWritten);
                } else if (auto structLit = cast(StructLiteral)varDecl.initializer) {
                    code ~= " = " ~ generateStructLiteralValue(structLit, declaredTypeAsWritten);
                } else {
                    // See tryImplicitConversionCall's own comment - e.g.
                    // `let s: string = someYamlValue` calling
                    // YamlValue.as_string() automatically, the same way
                    // `let s: string = someYamlValue as string` does below.
                    string converted = tryImplicitConversionCall(varDecl.initializer, varDecl.type);
                    if (converted.length > 0) {
                        code ~= " = " ~ converted;
                    } else {
                        ASTNode initExpr = insertUpcastIfNeeded(varDecl.initializer, varDecl.type);
                        initExpr = insertNumericCoercionIfNeeded(initExpr, varDecl.type);
                        code ~= " = " ~ generateExpression(initExpr);
                    }
                }
            } else if (varDecl.type.isNullableSugar) {
                // No initializer at all (`let x: int?`) - default to an
                // empty Optional rather than an uninitialized pointer,
                // which would crash the moment any method (is_some(), ...)
                // ran on it.
                code ~= " = " ~ format("%s_new()", varDecl.type.name);
            }
            code ~= ";\n";

            if (varDecl.type.pointerDepth > 0 && varDecl.initializer !is null) {
                int bound = knownBoundFromInitializer(varDecl.initializer);
                if (bound > 0) pointerIndexBounds[emitName] = bound;
            }

            // RAII: a class-typed local is now this function's
            // responsibility to release at scope exit (see rcLocalNames'
            // own comment) - and if its initializer merely aliases an
            // existing reference rather than producing a fresh one, it
            // needs its own retain first so the alias and the original can
            // each be safely released independently.
            if (varDecl.initializer && isRcManagedType(varDecl.type) &&
                    indentLevel == rcFunctionBodyIndent) {
                if (isAliasingRcExpr(varDecl.initializer)) {
                    code ~= indent() ~ format("if (%s) rc_retain((char*)%s);\n", emitName, emitName);
                }
                trackRcLocal(emitName, varDecl.type);
            }
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            // Local aliases are compile-time-only. Register them at the
            // point they occur so later expressions in this scope can use
            // namespace-qualified names such as `alias f = Foo.Bar`.
            code ~= generateAlias(aliasDecl);
        } else if (auto destructStmt = cast(DestructuringStmt)node) {
            code ~= generateDestructuringStmt(destructStmt);
        } else if (auto ifStmt = cast(IfStmt)node) {
            code ~= indent() ~ "if (" ~ generateCondition(ifStmt.condition) ~ ") {\n";
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
            code ~= indent() ~ "while (" ~ generateCondition(whileStmt.condition) ~ ") {\n";
            indentLevel++;
            foreach (stmt; whileStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto doWhileStmt = cast(DoWhileStmt)node) {
            code ~= indent() ~ "do {\n";
            indentLevel++;
            foreach (stmt; doWhileStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "} while (" ~ generateCondition(doWhileStmt.condition) ~ ");\n";
        } else if (auto forStmt = cast(ForStmt)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (init; forStmt.initializers) {
                code ~= generateStatement(init, isDeferred);
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
        } else if (auto withStmt = cast(WithStmt)node) {
            code ~= generateWithStmt(withStmt, isDeferred);
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
                    ASTNode retExpr = returnStmt.value;
                    if (currentReturnType !is null) {
                        retExpr = insertUpcastIfNeeded(retExpr, currentReturnType);
                        retExpr = insertNumericCoercionIfNeeded(retExpr, currentReturnType);
                    }
                    valueCode = generateExpression(retExpr);
                }
                tempVarCounter++;
                string retName = format("__llpl_ret%d", tempVarCounter);
                code ~= indent() ~ format("%s %s = %s;\n", typeToC(currentReturnType), retName, valueCode);
                if (!isDeferred) {
                    // A bare `return someTrackedLocal` moves that local's
                    // own reference out to the caller (already copied into
                    // retName above) rather than releasing it here - see
                    // cleanupCodeForFunctionExit's own comment.
                    string exceptName = null;
                    if (auto retIdent = cast(Identifier)returnStmt.value) {
                        string emitName = generateExpression(retIdent);
                        if (rcLocalNames.canFind(emitName)) exceptName = emitName;
                    }
                    code ~= cleanupCodeForFunctionExit(exceptName);
                }
                code ~= indent() ~ format("return %s;\n", retName);
            } else {
                if (!isDeferred) {
                    code ~= cleanupCodeForFunctionExit();
                }
                code ~= indent() ~ "return;\n";
            }
        } else if (cast(ContinueStmt)node) {
            code ~= indent() ~ "continue;\n";
        } else if (cast(BreakStmt)node) {
            code ~= indent() ~ "break;\n";
        } else if (auto deferStmt = cast(DeferStmt)node) {
            if (currentFunctionIsInterrupt) {
                throw new CompileError("'defer' is not allowed inside an interrupt function",
                    currentModulePath, deferStmt.line, deferStmt.column);
            }
            code ~= generateDeferStmt(deferStmt);
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            if (currentFunctionIsInterrupt) {
                throw new CompileError("'throw' is not allowed inside an interrupt function",
                    currentModulePath, throwStmt.line, throwStmt.column);
            }
            code ~= generateThrowStmt(throwStmt, isDeferred);
        } else if (auto tryStmt = cast(TryStmt)node) {
            if (currentFunctionIsInterrupt) {
                throw new CompileError("'try' is not allowed inside an interrupt function",
                    currentModulePath, tryStmt.line, tryStmt.column);
            }
            code ~= generateTryStmt(tryStmt, isDeferred);
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            code ~= generateDeleteStmt(deleteStmt);
        } else if (auto assertStmt = cast(AssertStmt)node) {
            code ~= generateAssertStmt(assertStmt);
        } else if (auto block = cast(Block)node) {
            code ~= indent() ~ "{\n";
            indentLevel++;
            size_t deferStart = deferredStatements.length;
            foreach (stmt; block.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            if (block.isHolding && deferredStatements.length > deferStart) {
                // A holding block owns every defer registered while its
                // body is generated. Keep the entries in the function-wide
                // list so their frame declarations are emitted, but run
                // only this block's defers at its normal closing brace.
                code ~= deferredCleanupCode(deferredStatements[deferStart .. $]);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
        } else if (auto exprStmt = cast(ExprStmt)node) {
            string arrayAssign = generateArrayLiteralAssignmentStmt(exprStmt.expression);
            if (arrayAssign.length > 0) {
                code ~= arrayAssign;
            } else {
                code ~= indent() ~ generateDiscardedExpression(exprStmt.expression) ~ ";\n";
            }
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
        copy.extraDims = t.extraDims.dup;
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
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            return new AliasDecl(aliasDecl.name, aliasDecl.targetPath.dup,
                aliasDecl.targetPointerDepth, aliasDecl.targetIsArray,
                aliasDecl.targetArraySize, aliasDecl.line, aliasDecl.column,
                cloneType(aliasDecl.targetType, typeSubs));
        } else if (auto intLit = cast(IntLiteral)node) {
            return new IntLiteral(intLit.value, intLit.line, intLit.column);
        } else if (auto floatLit = cast(FloatLiteral)node) {
            return new FloatLiteral(floatLit.value, floatLit.line, floatLit.column);
        } else if (auto charLit = cast(CharLiteral)node) {
            return new CharLiteral(charLit.value, charLit.line, charLit.column);
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
                unaryExpr.line, unaryExpr.column, unaryExpr.isPostfix);
        } else if (auto awaitExpr = cast(AwaitExpr)node) {
            return new AwaitExpr(cloneNode(awaitExpr.expression, subs, typeSubs),
                awaitExpr.line, awaitExpr.column);
        } else if (auto callExpr = cast(CallExpr)node) {
            return new CallExpr(cloneNode(callExpr.callee, subs, typeSubs), cloneNodes(callExpr.args, subs, typeSubs),
                callExpr.line, callExpr.column, callExpr.argNames.dup,
                callExpr.typeArgs.map!(a => cloneType(a, typeSubs)).array);
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
                castExpr.line, castExpr.column, castExpr.useImplicitConversion);
        } else if (auto sizeofExpr = cast(SizeofExpr)node) {
            return new SizeofExpr(cloneType(sizeofExpr.type, typeSubs), sizeofExpr.line, sizeofExpr.column);
        } else if (auto structLit = cast(StructLiteral)node) {
            return new StructLiteral(structLit.typeName, structLit.fieldNames.dup,
                cloneNodes(structLit.fieldValues, subs, typeSubs), structLit.line, structLit.column,
                structLit.typeArgs.map!(a => cloneType(a, typeSubs)).array);
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
                cloneBlock(ifStmt.elseBlock, subs, typeSubs), ifStmt.isPostfix);
        } else if (auto whileStmt = cast(WhileStmt)node) {
            return new WhileStmt(cloneNode(whileStmt.condition, subs, typeSubs), cloneBlock(whileStmt.body_, subs, typeSubs));
        } else if (auto doWhileStmt = cast(DoWhileStmt)node) {
            return new DoWhileStmt(cloneBlock(doWhileStmt.body_, subs, typeSubs),
                cloneNode(doWhileStmt.condition, subs, typeSubs), doWhileStmt.line, doWhileStmt.column);
        } else if (auto forStmt = cast(ForStmt)node) {
            ASTNode[] initializers;
            foreach (init; forStmt.initializers) {
                initializers ~= cloneNode(init, subs, typeSubs);
            }
            return new ForStmt(initializers, cloneNode(forStmt.condition, subs, typeSubs),
                cloneNode(forStmt.update, subs, typeSubs), cloneBlock(forStmt.body_, subs, typeSubs));
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            return new ForeachStmt(foreachStmt.varName, cloneNode(foreachStmt.iterable, subs, typeSubs),
                cloneBlock(foreachStmt.body_, subs, typeSubs), foreachStmt.line, foreachStmt.column);
        } else if (auto withStmt = cast(WithStmt)node) {
            return new WithStmt(cloneNode(withStmt.object, subs, typeSubs),
                cloneBlock(withStmt.body_, subs, typeSubs), withStmt.contextName,
                withStmt.line, withStmt.column, withStmt.bindingName);
        } else if (auto rangeExpr = cast(RangeExpr)node) {
            return new RangeExpr(cloneNode(rangeExpr.start, subs, typeSubs), cloneNode(rangeExpr.end, subs, typeSubs),
                rangeExpr.line, rangeExpr.column);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(cloneNode(returnStmt.value, subs, typeSubs),
                returnStmt.line, returnStmt.column);
        } else if (auto continueStmt = cast(ContinueStmt)node) {
            return new ContinueStmt(continueStmt.line, continueStmt.column);
        } else if (auto breakStmt = cast(BreakStmt)node) {
            return new BreakStmt(breakStmt.line, breakStmt.column);
        } else if (auto deferStmt = cast(DeferStmt)node) {
            return new DeferStmt(cloneNode(deferStmt.statement, subs, typeSubs));
        } else if (auto throwStmt = cast(ThrowStmt)node) {
            return new ThrowStmt(cloneNode(throwStmt.value, subs, typeSubs),
                throwStmt.line, throwStmt.column);
        } else if (auto deleteStmt = cast(DeleteStmt)node) {
            return new DeleteStmt(cloneNode(deleteStmt.value, subs, typeSubs),
                deleteStmt.line, deleteStmt.column);
        } else if (auto assertStmt = cast(AssertStmt)node) {
            return new AssertStmt(cloneNode(assertStmt.condition, subs, typeSubs),
                cloneNode(assertStmt.message, subs, typeSubs), assertStmt.line, assertStmt.column,
                assertStmt.fatal);
        } else if (auto tryStmt = cast(TryStmt)node) {
            return new TryStmt(cloneBlock(tryStmt.tryBlock, subs, typeSubs), tryStmt.catchVar,
                cloneType(tryStmt.catchType, typeSubs), cloneBlock(tryStmt.catchBlock, subs, typeSubs),
                cloneBlock(tryStmt.finallyBlock, subs, typeSubs), tryStmt.line, tryStmt.column);
        } else if (auto block = cast(Block)node) {
            auto cloned = cloneBlock(block, subs, typeSubs);
            cloned.isHolding = block.isHolding;
            return cloned;
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
            params ~= new Parameter(p.name, cloneType(p.type, typeSubs), defaultValue,
                p.isConst, p.initializesField);
        }
        auto clone = new FunctionDecl(newName, params, cloneType(fn.returnType, typeSubs),
            cloneBlock(fn.body_, null, typeSubs), fn.isExtern, fn.isInterrupt, fn.isVariadic,
            fn.line, fn.column);
        clone.namespaceSegments = [];
        clone.isPrivate = fn.isPrivate;
        clone.isProtected = fn.isProtected;
        clone.isStatic = fn.isStatic;
        clone.isVirtual = fn.isVirtual;
        clone.isOverride = fn.isOverride;
        clone.isProperty = fn.isProperty;
        clone.isInline = fn.isInline;
        clone.isAsync = fn.isAsync;
        return clone;
    }

    private ClassDecl cloneClassDeclWithTypeSubs(ClassDecl cls, Type[string] typeSubs, string newName) {
        VarDecl[] fields;
        foreach (f; cls.fields) {
            auto field = new VarDecl(f.name, cloneType(f.type, typeSubs),
                cloneNode(f.initializer, null, typeSubs), f.isConst,
                f.line, f.column, f.bitWidth, f.isVolatile);
            field.isPrivate = f.isPrivate;
            field.isProtected = f.isProtected;
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
            fields ~= new VarDecl(f.name, cloneType(f.type, typeSubs),
                cloneNode(f.initializer, null, typeSubs), f.isConst,
                f.line, f.column, f.bitWidth, f.isVolatile);
        }
        FunctionDecl[] ctors;
        foreach (c; st.constructors) ctors ~= cloneFunctionDeclWithTypeSubs(c, typeSubs, c.name);
        auto clone = new StructDecl(newName, fields, st.packed, st.line, st.column, [], [], [], ctors);
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
        } else if (auto floatLit = cast(FloatLiteral)node) {
            return new FloatLiteral(floatLit.value, floatLit.line, floatLit.column);
        } else if (auto charLit = cast(CharLiteral)node) {
            return new CharLiteral(charLit.value, charLit.line, charLit.column);
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
                unaryExpr.line, unaryExpr.column, unaryExpr.isPostfix);
        } else if (auto callExpr = cast(CallExpr)node) {
            return new CallExpr(expandQuotedNode(callExpr.callee, subs),
                expandQuotedNodes(callExpr.args, subs), callExpr.line, callExpr.column,
                callExpr.argNames.dup, callExpr.typeArgs.map!(a => cloneType(a)).array);
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
                castExpr.line, castExpr.column, castExpr.useImplicitConversion);
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
        } else if (auto doWhileStmt = cast(DoWhileStmt)node) {
            return new DoWhileStmt(expandQuotedBlock(doWhileStmt.body_, subs),
                expandQuotedNode(doWhileStmt.condition, subs), doWhileStmt.line, doWhileStmt.column);
        } else if (auto forStmt = cast(ForStmt)node) {
            ASTNode[] initializers;
            foreach (init; forStmt.initializers) {
                initializers ~= expandQuotedNode(init, subs);
            }
            return new ForStmt(initializers, expandQuotedNode(forStmt.condition, subs), expandQuotedNode(forStmt.update, subs),
                expandQuotedBlock(forStmt.body_, subs));
        } else if (auto foreachStmt = cast(ForeachStmt)node) {
            return new ForeachStmt(foreachStmt.varName, expandQuotedNode(foreachStmt.iterable, subs),
                expandQuotedBlock(foreachStmt.body_, subs), foreachStmt.line, foreachStmt.column);
        } else if (auto withStmt = cast(WithStmt)node) {
            return new WithStmt(expandQuotedNode(withStmt.object, subs),
                expandQuotedBlock(withStmt.body_, subs), withStmt.contextName,
                withStmt.line, withStmt.column, withStmt.bindingName);
        } else if (auto rangeExpr = cast(RangeExpr)node) {
            return new RangeExpr(expandQuotedNode(rangeExpr.start, subs), expandQuotedNode(rangeExpr.end, subs),
                rangeExpr.line, rangeExpr.column);
        } else if (auto returnStmt = cast(ReturnStmt)node) {
            return new ReturnStmt(expandQuotedNode(returnStmt.value, subs),
                returnStmt.line, returnStmt.column);
        } else if (auto continueStmt = cast(ContinueStmt)node) {
            return new ContinueStmt(continueStmt.line, continueStmt.column);
        } else if (auto breakStmt = cast(BreakStmt)node) {
            return new BreakStmt(breakStmt.line, breakStmt.column);
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
                // `case 1..5 => ...` - an inclusive range pattern (same
                // `..` RangeExpr `for i in 1..5` already uses), matched by
                // bounds rather than equality. Only meaningful for a
                // numeric subject - isString's own strcmp path has no
                // sensible reading of "in range".
                if (auto rangeExpr = cast(RangeExpr)pattern) {
                    if (isString) {
                        throw new CompileError("A range pattern ('..') needs a numeric match subject, not a string",
                            currentModulePath, rangeExpr.line, rangeExpr.column);
                    }
                    cond ~= format("(%s >= %s && %s <= %s)", tmpName, generateExpression(rangeExpr.start),
                        tmpName, generateExpression(rangeExpr.end));
                    continue;
                }
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

        // Check current namespace and all enclosing namespaces
        for (size_t i = currentNamespaceSegments.length; i > 0; i--) {
            candidates ~= currentNamespaceSegments[0 .. i].join("_") ~ "_" ~ suffix;
        }

        // A monomorphized generic clone's own namespaceSegments is always
        // empty (needed for correct mangling - see
        // cloneClassDeclWithTypeSubs), so once its body is being generated,
        // currentNamespaceSegments no longer reflects where it was
        // originally declared - currentGenericTemplateNamespace is the
        // separate, non-mangling-affecting record of that, kept alive for
        // the clone's whole field/signature/body generation. See its own
        // declaration comment.
        for (size_t i = currentGenericTemplateNamespace.length; i > 0; i--) {
            candidates ~= currentGenericTemplateNamespace[0 .. i].join("_") ~ "_" ~ suffix;
        }

        // Check imported namespaces from 'using namespace' declarations
        if (currentModulePath in moduleUsingNamespaces) {
            foreach (usingPath; moduleUsingNamespaces[currentModulePath]) {
                // Convert "Foo.Bar" to "Foo_Bar_suffix"
                string mangledPrefix = usingPath.replace(".", "_");
                candidates ~= mangledPrefix ~ "_" ~ suffix;
            }
        }

        return candidates;
    }

    // Mirrors parser.d's own canonicalIntTypeName - see this module's
    // alias-registration comment on why an alias target needs this same
    // rewrite applied again here.
    private static string canonicalIntTypeName(string name) {
        switch (name) {
            case "u8": return "u8";
            case "u16": return "u16";
            case "u32": return "u32";
            case "u64": return "u64";
            case "i8": return "i8";
            case "i16": return "i16";
            case "i32": return "i32";
            case "i64": return "i64";
            // See parser.d's own copy of this function - same rewrite,
            // needed again here for an alias target (below), which never
            // goes through the parser's own call to it.
            case "float": return "f32";
            case "double": return "f64";
            default: return name;
        }
    }

    private bool isPrimitiveTypeName(string name) {
        switch (name) {
            case "i64": case "u64":
            case "u8": case "char":
            case "int8": case "uint8":
            case "int16": case "uint16":
            case "int32": case "uint32":
            case "int64": case "uint64":
            // The short forms (u8/u16/.../i64) are normally rewritten to
            // their long-form name above by the parser the moment a type
            // annotation is parsed (`let x: u32` never reaches codegen as
            // "u32" at all) - but an `alias X = u32` target is parsed as a
            // plain dotted identifier path, not a type annotation, so it
            // never goes through that rewrite and reaches here exactly as
            // written. Recognized here too so a short-form alias target
            // is still correctly treated as a type alias, not an unknown
            // symbol reference.
            case "i8":
            case "u16": case "i16":
            case "u32": case "i32":
            case "bool": case "void": case "string":
            // Same story as float/double just below, in reverse: f32/f64
            // are what canonicalIntTypeName above rewrites float/double
            // *to*, so an alias target already spelled the new way
            // (`alias Real = f64`) needs recognizing directly too.
            case "f32": case "f64":
            case "float": case "double":
            case "int": case "uint":
                return true;
            default:
                return false;
        }
    }

    // Number of storage bits available for a bit-field of this base type, or
    // -1 if the type can't back a bit-field at all (classes, void, ...).
    private int primitiveBitSize(string name) {
        switch (name) {
            case "i64": case "u64": return 64;
            case "i32": case "u32": case "int32": case "uint32": return 32;
            case "i16": case "u16": case "int16": case "uint16": return 16;
            case "u8": case "char": case "i8": case "int8": case "uint8": return 8;
            case "bool": return 8; // backed by C `_Bool` (1 byte)
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
        if (varDecl.type.extraDims.length > 0) {
            checkNestedArrayDims(lit, varDecl.type.extraDims, varDecl.name, varDecl.type.name);
        }
    }

    // `T[2][3]`'s own nested-literal check - each element of `lit` must
    // itself be an array literal of size `dims[0]`, recursing for any
    // further dims. Only the outer dimension auto-fills its size from the
    // literal (checkArrayLiteralInit above); every nested dimension must
    // already be written explicitly in the declared type.
    private void checkNestedArrayDims(ArrayLiteral lit, int[] dims, string varName, string typeName) {
        if (dims.length == 0) return;
        foreach (elem; lit.elements) {
            auto subLit = cast(ArrayLiteral)elem;
            if (subLit is null) {
                throw new CompileError(
                    format("Array literal for '%s' needs a nested array literal here (declared as %s[]...[%d])",
                        varName, typeName, dims[0]),
                    currentModulePath, elem.line, elem.column);
            }
            if (subLit.elements.length != dims[0]) {
                throw new CompileError(
                    format("Nested array literal for '%s' has %d element(s), expected %d",
                        varName, subLit.elements.length, dims[0]),
                    currentModulePath, subLit.line, subLit.column);
            }
            checkNestedArrayDims(subLit, dims[1 .. $], varName, typeName);
        }
    }

    // `arr = [1, 2, 3]` (or a nested `arr = [[1,2],[3,4]]`) as a
    // standalone assignment, not just a `let` initializer. Same shape
    // validation as checkArrayLiteralInit/checkNestedArrayDims, but the
    // target's size is already fixed (nothing to auto-fill from the
    // literal - the variable was declared earlier), and instead of C's
    // own brace-init (only legal in a declaration) this compiles to a
    // memcpy from a GCC compound literal, which C does allow anywhere an
    // expression goes.
    private string generateArrayLiteralAssignment(BinaryExpr binExpr, ArrayLiteral arrLit, Type leftType) {
        if (!leftType.isArray || leftType.arraySize <= 0) {
            throw new CompileError(
                "Cannot assign an array literal here: target isn't a fixed-size array",
                currentModulePath, arrLit.line, arrLit.column);
        }
        if (cast(int)arrLit.elements.length != leftType.arraySize) {
            throw new CompileError(
                format("Array literal has %d element(s), but the target is %s[%d]",
                    arrLit.elements.length, leftType.name, leftType.arraySize),
                currentModulePath, arrLit.line, arrLit.column);
        }
        if (leftType.extraDims.length > 0) {
            checkNestedArrayDims(arrLit, leftType.extraDims, "assignment target", leftType.name);
        }

        string baseType = fixedArrayElementCType(leftType);
        string typeText = format("%s[%d]%s", baseType, leftType.arraySize, extraDimsSuffix(leftType));
        string targetCode = generateExpression(binExpr.left);
        string valueCode = generateExpression(arrLit);
        // memcpy is a GCC/libc builtin recognized without any explicit
        // extern/include - same "GCC already knows this symbol" reasoning
        // this codebase's own puts/ksnprintf declarations already lean on.
        return format("memcpy(%s, (%s)%s, sizeof(%s))", targetCode, typeText, valueCode, targetCode);
    }

    private Type fixedArrayElementType(Type arrType) {
        Type elemType = cloneType(arrType);
        if (arrType.extraDims.length > 0) {
            elemType.isArray = true;
            elemType.arraySize = arrType.extraDims[0];
            elemType.extraDims = arrType.extraDims[1 .. $].dup;
        } else {
            elemType.isArray = false;
            elemType.arraySize = 0;
            elemType.extraDims = [];
        }
        return elemType;
    }

    private void checkArrayLiteralAssignment(ArrayLiteral lit, Type targetType) {
        if (!targetType.isArray || targetType.arraySize <= 0) {
            throw new CompileError(
                format("Cannot assign an array literal here: target type is '%s', not a fixed-size array",
                    targetType.toString()),
                currentModulePath, lit.line, lit.column);
        }
        if (targetType.arraySize != lit.elements.length) {
            throw new CompileError(
                format("Array literal has %d element(s), but assignment target is declared as %s[%d]",
                    lit.elements.length, targetType.name, targetType.arraySize),
                currentModulePath, lit.line, lit.column);
        }
        if (targetType.extraDims.length > 0) {
            checkNestedArrayDims(lit, targetType.extraDims, "assignment target", targetType.name);
        } else {
            foreach (elem; lit.elements) {
                if (cast(ArrayLiteral)elem) {
                    throw new CompileError(
                        "Nested array literal cannot be assigned into a one-dimensional array",
                        currentModulePath, elem.line, elem.column);
                }
            }
        }
    }

    private string generateArrayLiteralStores(string targetCode, Type targetType, ArrayLiteral lit) {
        Type elemType = fixedArrayElementType(targetType);
        string code = "";
        foreach (i, elem; lit.elements) {
            string slot = format("%s[%d]", targetCode, i);
            if (auto nested = cast(ArrayLiteral)elem) {
                code ~= generateArrayLiteralStores(slot, elemType, nested);
            } else {
                ASTNode value = insertNumericCoercionIfNeeded(elem, elemType);
                code ~= indent() ~ format("%s = %s;\n", slot, generateExpression(value));
            }
        }
        return code;
    }

    private string generateArrayLiteralAssignmentStmt(ASTNode expr) {
        auto binExpr = cast(BinaryExpr)expr;
        if (binExpr is null || binExpr.op != "=") return "";

        ASTNode rhs = expandArrayAliasesShallow(binExpr.right);
        auto lit = cast(ArrayLiteral)rhs;
        if (lit is null) return "";

        checkNotConstAssignment(binExpr.left);
        Type targetType = inferType(binExpr.left);
        resolveType(targetType);
        checkArrayLiteralAssignment(lit, targetType);
        return generateArrayLiteralStores(generateExpression(binExpr.left), targetType, lit);
    }

    // Structs (and unions) are plain value types with no allocator -
    // `new StructName(...)`/`new UnionName(...)` only makes sense at all
    // if a constructor was actually declared (see generateStructConstructor/
    // generateUnionConstructor); otherwise there's nothing to call.
    private void checkNotStruct(NewExpr newExpr) {
        if (auto sd = newExpr.type.name in structRegistry) {
            if (sd.constructors.length > 0) return;
            string message = format(
                "Cannot 'new' a struct: '%s' is a value type with no declared constructor - " ~
                "either add one, or declare a variable of that type and assign its fields directly",
                newExpr.type.name);
            throw new CompileError(message, currentModulePath, newExpr.line, newExpr.column);
        }
        if (auto ud = newExpr.type.name in unionRegistry) {
            if (ud.constructors.length > 0) return;
            string message = format(
                "Cannot 'new' a union: '%s' is a value type with no declared constructor - " ~
                "either add one, or declare a variable of that type and assign its fields directly",
                newExpr.type.name);
            throw new CompileError(message, currentModulePath, newExpr.line, newExpr.column);
        }
    }

    private void checkNotGenericFunctionConstruction(NewExpr newExpr) {
        if (newExpr.type.typeArgs.length == 0) return;
        string classKey = findGenericTemplateKey(newExpr.type.name,
            (n) => (n in genericClassTemplates) !is null);
        string structKey = findGenericTemplateKey(newExpr.type.name,
            (n) => (n in genericStructTemplates) !is null);
        string functionKey = findGenericTemplateKey(newExpr.type.name,
            (n) => (n in genericFunctionTemplates) !is null);
        if (classKey.length == 0 && structKey.length == 0 && functionKey.length > 0) {
            throw new CompileError(format(
                "'%s' is a generic function, not a generic type; " ~
                "`new %s<...>(...)` is invalid. Call `%s(...)` with arguments " ~
                "so its type parameters can be inferred.",
                newExpr.type.name, newExpr.type.name, newExpr.type.name),
                currentModulePath, newExpr.line, newExpr.column);
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

    // Enforces class-member visibility. Private members are class-scoped;
    // protected members are accessible from the declaring class and any
    // derived class body, including through another instance of that type.
    private void checkMemberAccess(bool isPrivate, bool isProtected, string ownerClassName,
            string memberDescription,
            int line, int column) {
        if (isPrivate && currentClassName != ownerClassName) {
            throw new CompileError(
                format("%s is private - only accessible from within '%s'", memberDescription, ownerClassName),
                currentModulePath, line, column);
        }
        if (isProtected && currentClassName != ownerClassName) {
            auto currentClass = currentClassName in classRegistry;
            if (currentClass is null || !classInheritsFrom(*currentClass, ownerClassName)) {
                throw new CompileError(
                    format("%s is protected - only accessible from '%s' or its subclasses",
                        memberDescription, ownerClassName),
                    currentModulePath, line, column);
            }
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
    // type arguments for context-only literals (`Pair { ... }`). A literal
    // may also write them directly (`Pair<int> { ... }`), in which case
    // those explicit args take precedence.
    private StructDecl resolveStructLiteralTarget(StructLiteral lit, Type expectedType, out string mangledName) {
        if (lit.typeName.length == 0) {
            if (expectedType is null) {
                throw new CompileError(
                    "Anonymous struct literal needs an explicit expected type",
                    currentModulePath, lit.line, lit.column);
            }
            Type targetType = cloneType(expectedType);
            resolveType(targetType);
            string resolvedName = resolveStructOrClassTypeName(targetType.name);
            if (resolvedName.length > 0 && resolvedName in structRegistry) {
                mangledName = resolvedName;
                return structRegistry[mangledName];
            }
            if (resolvedName.length > 0 && resolvedName in classRegistry) {
                throw new CompileError(
                    "Anonymous struct literal target is a class; use 'new' instead",
                    currentModulePath, lit.line, lit.column);
            }
            throw new CompileError(
                format("Anonymous struct literal target type '%s' is not a struct", targetType.toString()),
                currentModulePath, lit.line, lit.column);
        }

        lit.typeName = resolveStructOrClassTypeName(lit.typeName);

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
        if (lit.typeArgs.length > 0) {
            typeArgsToUse = lit.typeArgs.map!(a => cloneType(a)).array;
            haveTypeArgs = true;
        } else if (expectedType !is null && expectedType.name == lit.typeName && expectedType.typeArgs.length > 0) {
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

        if (lit.fieldNames.length > decl.fields.length) {
            string displayName = lit.typeName.length > 0 ? lit.typeName : mangledName;
            throw new CompileError(format(
                "Struct literal for '%s' has %d field(s), but '%s' declares only %d",
                displayName, lit.fieldNames.length, mangledName, decl.fields.length),
                currentModulePath, lit.line, lit.column);
        }

        bool[string] seen;
        int[string] valueIndexByField;
        foreach (i, fieldName; lit.fieldNames) {
            if (fieldName in seen) {
                string displayName = lit.typeName.length > 0 ? lit.typeName : mangledName;
                throw new CompileError(format("Field '%s' given more than once in this '%s' literal",
                    fieldName, displayName), currentModulePath, lit.line, lit.column);
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
            valueIndexByField[fieldName] = cast(int)i;
        }

        string result = format("(%s){ ", mangledName);
        foreach (i, field; decl.fields) {
            ASTNode value = null;
            if (auto valueIndex = field.name in valueIndexByField) {
                value = lit.fieldValues[*valueIndex];
            } else {
                value = field.initializer;
                if (value is null) {
                    string displayName = lit.typeName.length > 0 ? lit.typeName : mangledName;
                    throw new CompileError(format(
                        "Struct literal for '%s' omits field '%s', which has no default initializer",
                        displayName, field.name), currentModulePath, lit.line, lit.column);
                }
            }
            if (i > 0) result ~= ", ";
            value = expandArrayAliasesShallow(value);
            Type fieldTypeAsWritten = cloneType(field.type);
            result ~= format(".%s = ", field.name);
            if (auto structLit = cast(StructLiteral)value) {
                result ~= generateStructLiteralValue(structLit, fieldTypeAsWritten);
            } else if (auto tupleLit = cast(TupleLiteral)value) {
                result ~= generateTupleLiteral(tupleLit, fieldTypeAsWritten);
            } else {
                ASTNode coerced = insertNumericCoercionIfNeeded(value, field.type);
                result ~= generateExpression(coerced);
            }
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

    private string generateWithStmt(WithStmt withStmt, bool isDeferred) {
        Type objectType = inferType(withStmt.object);
        resolveType(objectType);
        Type contextType = objectType;
        string initializer = generateExpression(withStmt.object);
        if (withStmt.bindingName.length > 0) {
            // The named form keeps its binding in the surrounding scope so
            // later statements can continue to use it.
            variableTypes[withStmt.bindingName] = objectType;
            string code = indent() ~ format("%s %s = %s;\n",
                typeToC(objectType), withStmt.bindingName, initializer);
            code ~= indent() ~ "{\n";
            indentLevel++;
            foreach (stmt; withStmt.body_.statements) {
                code ~= generateStatement(stmt, isDeferred);
            }
            indentLevel--;
            code ~= indent() ~ "}\n";
            return code;
        }
        if (shouldBindWithByAddress(withStmt.object, objectType)) {
            contextType = cloneType(objectType);
            contextType.pointerDepth++;
            initializer = "&(" ~ initializer ~ ")";
        }

        Type previousType = null;
        bool hadPreviousType = (withStmt.contextName in variableTypes) !is null;
        if (hadPreviousType) previousType = variableTypes[withStmt.contextName];

        variableTypes[withStmt.contextName] = contextType;

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s;\n", typeToC(contextType),
            withStmt.contextName, initializer);
        foreach (stmt; withStmt.body_.statements) {
            code ~= generateStatement(stmt, isDeferred);
        }
        indentLevel--;
        code ~= indent() ~ "}\n";

        if (hadPreviousType) {
            variableTypes[withStmt.contextName] = previousType;
        } else {
            variableTypes.remove(withStmt.contextName);
        }
        return code;
    }

    private bool shouldBindWithByAddress(ASTNode object, Type objectType) {
        if (objectType.pointerDepth > 0 || objectType.isArray) return false;
        if (!isStructTypeName(objectType.name) && !isUnionTypeName(objectType.name)) return false;
        return cast(Identifier)object !is null || cast(MemberExpr)object !is null ||
            cast(IndexExpr)object !is null;
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

    private string resolveStructOrClassTypeName(string name) {
        string resolved = resolveLocalImportAlias(name);
        if (resolved.length > 0) {
            name = resolved;
        }

        string aliased = resolveAliasedTypeName(name);
        if (aliased.length > 0) {
            name = aliased;
        }

        string nsResolved = resolveNamespaceAlias(name);
        if (nsResolved.length > 0) {
            name = nsResolved;
        }

        if (name in structRegistry || name in classRegistry) {
            return name;
        }
        foreach (candidate; enclosingQualifications(name)) {
            if (candidate in structRegistry || candidate in classRegistry) {
                return candidate;
            }
        }
        return name;
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
        // Check imported namespaces from 'using namespace' first, before bare name
        if (currentModulePath in moduleUsingNamespaces) {
            foreach (usingPath; moduleUsingNamespaces[currentModulePath]) {
                string mangledPrefix = usingPath.replace(".", "_");
                string candidate = mangledPrefix ~ "_" ~ name;
                if (exists(candidate)) return candidate;
            }
        }

        // Then check bare name and enclosing qualifications
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
                fwdParams ~= parameterDeclaration(p);
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
            auto savedDeferredRc = saveDeferredRcState();
            deferredFunctionBodies ~= generateFunction(asFunction);
            restoreDeferredRcState(savedDeferredRc);
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
            string functionKey = findGenericTemplateKey(name, (k) => (k in genericFunctionTemplates) !is null);
            if (functionKey.length > 0) {
                throw new CompileError(format(
                    "'%s' is a generic function, not a generic type", name),
                    currentModulePath, 0, 0);
            }
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

            // A type argument that's itself a user-defined class/struct
            // (e.g. Weak<Foo>, Vector<Foo>) needs its OWN typedef visible
            // here too - the constructor/method forward declarations
            // below reference it by name, but the ordinary per-class
            // forward-decl pass (generateMultiple) might not have run
            // yet if monomorphizing this instantiation is the first
            // thing to need Foo's name at all. Same idempotent-
            // redeclaration trick processImplBlock's targetNeedsTypedef
            // already relies on - repeating an identical `typedef struct
            // X X;` is legal C11.
            foreach (typeArg; typeArgs) {
                if ((typeArg.name in classRegistry) !is null || (typeArg.name in structRegistry) !is null) {
                    genericForwardDecls ~= format("typedef struct %s %s;\n", typeArg.name, typeArg.name);
                }
            }

            // generateClass/generateStruct (below) unconditionally set the
            // *shared* currentNamespaceSegments to the clone's own (always
            // empty) namespaceSegments and never restore it - harmless when
            // that's the outermost thing being generated, but this whole
            // instantiation can just as easily run *nested*, mid-generation
            // of some other class's method body (e.g. Graph.bfs resolving
            // `new Vector<int>()` and then, on the very next line, `new
            // Queue<int>()`) - without saving/restoring here, the first
            // monomorphization's clone.namespaceSegments (= []) leaks out
            // and clobbers whatever the *enclosing* generateMethod had
            // correctly set (Graph's own ["std","collections"]), so the
            // second lookup sees an empty namespace and fails to find a
            // perfectly real, already-registered sibling generic.
            string[] savedNamespaceSegments = currentNamespaceSegments;
            scope(exit) currentNamespaceSegments = savedNamespaceSegments;

            if (isClass) {
                auto clone = cloneClassDeclWithTypeSubs(genericClassTemplates[templateKey], typeSubs, mangledName);
                classRegistry[mangledName] = clone;
                string templateModulePath = currentModulePath;
                if (auto modulePath = templateKey in genericTemplateModulePath) {
                    templateModulePath = *modulePath;
                }
                // The template's own namespace, kept alive (via
                // currentGenericTemplateNamespace, not currentNamespaceSegments -
                // see that field's own comment) through field resolution,
                // constructor/method signatures, AND generateClass's method
                // *bodies* below - a field, param, or a plain `new Foo<T>()`
                // call anywhere in this clone's body can reference another
                // generic template declared in this same original namespace
                // (e.g. Queue<T>'s `list: DoublyLinkedList<T>` field, whose
                // own methods in turn `new DListNode<T>(...)`  - three
                // namespace-qualified levels deep, std.collections all the
                // way down), and would otherwise resolve as a bare,
                // unqualified name and fail with "'X' is not a generic
                // type" even though X is right there.
                string[] savedGenericNamespace = currentGenericTemplateNamespace;
                currentGenericTemplateNamespace = genericClassTemplates[templateKey].namespaceSegments;

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
                        ctorParams ~= parameterDeclaration(param);
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
                        methodParams ~= ", " ~ parameterDeclaration(param);
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
                auto savedDeferredRc = saveDeferredRcState();
                string savedModulePath = currentModulePath;
                currentModulePath = templateModulePath;
                string classBody = generateClass(clone);
                genericInstanceDecls ~= classBody;
                genericClassInstances ~= classBody;
                currentModulePath = savedModulePath;
                restoreDeferredRcState(savedDeferredRc);
                variableTypes = savedVarTypes;
                currentGenericTemplateNamespace = savedGenericNamespace;
            } else {
                auto clone = cloneStructDeclWithTypeSubs(genericStructTemplates[templateKey], typeSubs, mangledName);
                structRegistry[mangledName] = clone;
                string templateModulePath = currentModulePath;
                if (auto modulePath = templateKey in genericTemplateModulePath) {
                    templateModulePath = *modulePath;
                }
                // See the matching comment in the isClass branch above.
                string[] savedGenericNamespace = currentGenericTemplateNamespace;
                currentGenericTemplateNamespace = genericStructTemplates[templateKey].namespaceSegments;
                foreach (field; clone.fields) {
                    if (field.type is null) field.type = inferType(field.initializer);
                    resolveType(field.type);
                }
                auto savedDeferredRc = saveDeferredRcState();
                string savedModulePath = currentModulePath;
                currentModulePath = templateModulePath;
                string structBody = generateStruct(clone);
                genericInstanceDecls ~= structBody;
                genericStructInstances ~= structBody;
                currentModulePath = savedModulePath;
                restoreDeferredRcState(savedDeferredRc);
                currentGenericTemplateNamespace = savedGenericNamespace;
            }
        }

        return mangledName;
    }

    // Monomorphizes (on first use) or looks up the already-monomorphized
    // mangled name for a call to a generic function template. A caller can
    // either write explicit type arguments (`malloc<T>()`) or omit them and
    // let the resolver infer each type parameter from value arguments.
    private GenericCallResolution resolveGenericFunctionCall(string templateKey, ASTNode[] args,
            string[] argNames, Type[] explicitTypeArgs = null) {
        FunctionDecl tmpl = genericFunctionTemplates[templateKey];
        args = resolveCallArguments(tmpl.params, false, args, argNames,
            format("generic function '%s'", templateKey), 0, 0);

        Type[string] bindings;
        if (explicitTypeArgs.length > 0) {
            if (explicitTypeArgs.length != tmpl.typeParams.length) {
                throw new CompileError(format(
                    "Generic function '%s' expects %d type argument(s), got %d",
                    templateKey, tmpl.typeParams.length, explicitTypeArgs.length),
                    currentModulePath, 0, 0);
            }
            foreach (i, tp; tmpl.typeParams) {
                Type explicitType = cloneType(explicitTypeArgs[i]);
                resolveType(explicitType);
                bindings[tp] = explicitType;
            }
        } else {
            foreach (i, param; tmpl.params) {
                if (i >= args.length) continue;
                if (tmpl.typeParams.canFind(param.type.name) && (param.type.name in bindings) is null) {
                    Type argType = inferType(args[i]);
                    // `param.type` may itself be `T*` and/or `T[]` (pointerDepth
                    // > 0 / isArray true), not just a bare `T` - e.g. `func
                    // swap<T>(a: T*, b: T*)` called as `swap(&x, &y)`, or `func
                    // first<T>(arr: T[]) -> T` called with an `i64[]` argument.
                    // The binding recorded for T needs whichever of those the
                    // parameter's own declared type already accounts for
                    // *removed* from the argument's inferred type, or the
                    // monomorphized clone doubles them - a `T*` parameter making
                    // `i64*` become `i64**` (this file's own cloneType already
                    // adds pointerDepth back on top of a binding that has its
                    // own, deliberately - see its comment - so a binding that
                    // hasn't first had the parameter's own depth subtracted
                    // ends up double-counted), and a bare `T` return type
                    // wrongly inheriting `isArray` from a `T[]` parameter's
                    // argument, turning a plain `i64` return into an `int64_t*`
                    // one instead.
                    int depthAdjust = param.type.pointerDepth;
                    bool bindingIsArray = param.type.isArray ? false : argType.isArray;
                    bindings[param.type.name] = new Type(argType.name, argType.pointerDepth - depthAdjust,
                        bindingIsArray, argType.arraySize);
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
        Type[string] typeSubs;
        foreach (i, tp; tmpl.typeParams) typeSubs[tp] = typeArgs[i];

        if (mangledName !in monomorphizedInstances) {
            monomorphizedInstances[mangledName] = true;

            auto clone = cloneFunctionDeclWithTypeSubs(tmpl, typeSubs, mangledName);
            string templateModulePath = currentModulePath;
            if (auto modulePath = templateKey in genericTemplateModulePath) {
                templateModulePath = *modulePath;
            }

            // Forward-declare the concrete signature immediately (before
            // the body is generated) - resolves the common case of mutual
            // recursion between two different generic function
            // instantiations (see the module-level comment on
            // genericForwardDecls).
            foreach (typeArg; typeArgs) {
                if ((typeArg.name in classRegistry) !is null || (typeArg.name in structRegistry) !is null) {
                    genericForwardDecls ~= format("typedef struct %s %s;\n", typeArg.name, typeArg.name);
                }
            }
            string protoParams = "";
            foreach (i, p; clone.params) {
                resolveType(p.type);
                if (i > 0) protoParams ~= ", ";
                protoParams ~= parameterDeclaration(p);
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
            auto savedDeferredRc = saveDeferredRcState();
            string savedModulePath = currentModulePath;
            currentModulePath = templateModulePath;
            deferredFunctionBodies ~= generateFunction(clone);
            currentModulePath = savedModulePath;
            restoreDeferredRcState(savedDeferredRc);
            variableTypes = savedVarTypes;
        }

        ASTNode[] resolvedArgs;
        foreach (arg; args) {
            resolvedArgs ~= cloneNode(arg, null, typeSubs);
        }
        return GenericCallResolution(mangledName, resolvedArgs);
    }

    // Resolves a possibly-unqualified class, struct, or union type name to
    // its mangled form
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

        // A type alias is stored under its mangled (namespace-qualified)
        // name, but a use site inside the same namespace writes the bare
        // name (e.g. `SDL_AudioDeviceID` inside `namespace std.sdl` itself,
        // where the alias is mangled to `std_sdl_SDL_AudioDeviceID`) - try
        // the bare name first, then each enclosing-namespace qualification,
        // mirroring the classRegistry/structRegistry lookup further below.
        string aliasName = "";
        Type* aliasedPtr = t.name in typeAliases;
        if (aliasedPtr !is null) aliasName = t.name;
        if (aliasedPtr is null) {
            foreach (candidate; enclosingQualifications(t.name)) {
                if (auto found = candidate in typeAliases) {
                    aliasedPtr = found;
                    aliasName = candidate;
                    break;
                }
            }
        }
        Type aliased = aliasedPtr is null ? null : *aliasedPtr;
        if (aliased !is null) {
            if (aliasName.length > 0 && !isSymbolVisibleFromCurrentModule(aliasName)) {
                throw new CompileError(format("Cannot access private type '%s'", t.name),
                    currentModulePath, 0, 0);
            }
            // Substitute the alias's own type in place - a use site that
            // *also* wrote its own `*` on an already-pointer alias
            // (`string*` where `string` is `char*`) stacks depth (giving
            // `char**`) rather than collapsing back to a single `*`.
            t.name = aliased.name;
            t.pointerDepth = t.pointerDepth + aliased.pointerDepth;
            t.isArray = t.isArray || aliased.isArray;
            if (aliased.arraySize > 0) t.arraySize = aliased.arraySize;
            t.extraDims = aliased.extraDims.dup;
            t.typeArgs = aliased.typeArgs.map!(a => cloneType(a)).array;
            if (aliased.closureReturnType !is null) {
                Parameter[] cps;
                foreach (p; aliased.closureParams) cps ~= new Parameter(p.name, cloneType(p.type));
                t.closureParams = cps;
                t.closureReturnType = cloneType(aliased.closureReturnType);
            }
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

        // Same, for a namespace alias (`alias hf = HAL.Foo` - `hf.Bar`
        // flattened to `hf_Bar`, standing in for `HAL_Foo_Bar`).
        string nsResolved = resolveNamespaceAlias(t.name);
        if (nsResolved.length > 0) t.name = nsResolved;

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
        if (t.name in classRegistry || t.name in structRegistry || t.name in unionRegistry) {
            if (!isSymbolVisibleFromCurrentModule(t.name)) {
                throw new CompileError(format("Cannot access private type '%s'", t.name),
                    currentModulePath, 0, 0);
            }
            return;
        }
        foreach (candidate; enclosingQualifications(t.name)) {
            if (candidate in classRegistry || candidate in structRegistry || candidate in unionRegistry) {
                if (!isSymbolVisibleFromCurrentModule(candidate)) {
                    throw new CompileError(format("Cannot access private type '%s'", t.name),
                        currentModulePath, 0, 0);
                }
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

    private bool isUnionTypeName(string name) {
        return (name in unionRegistry) !is null;
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
            if (t.isPointer || t.isArray || isStructTypeName(t.name) || isClassTypeName(t.name) ||
                    isUnionTypeName(t.name)) {
                return argCode;
            }
            // f32/f64 need C's own float->double promotion here, not the
            // long long every other non-pointer vararg needs below - a
            // real `(long long)(3.14)` cast *converts the value* (to 3),
            // which va_arg(args, double) on the receiving end (runtime.c's
            // kvsnprintf, for %f) then reads back as the bit pattern of a
            // completely different, near-zero double. Explicit (double)
            // here isn't even strictly required (C already promotes a
            // bare `float` this way in a varargs call), just documents
            // that this is the one non-pointer type that must *not* fall
            // through to the long long cast below.
            if (t.name == "f32" || t.name == "f64" || t.name == "float" || t.name == "double") {
                return format("((double)(%s))", argCode);
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

    // True if cd provably inherits (directly or transitively) from the
    // class named ancestorName - used only to decide whether an implicit
    // upcast cast is safe to insert (see insertUpcastIfNeeded), never to
    // reject anything: an unrelated pair of types is simply left alone,
    // whatever existing (lack of) type checking already applies to them.
    private bool classInheritsFrom(ClassDecl cd, string ancestorName) {
        if (cd.baseClassName.length == 0) return false;
        if (cd.baseClassName == ancestorName) return true;
        auto basePtr = cd.baseClassName in classRegistry;
        if (basePtr is null) return false;
        return classInheritsFrom(*basePtr, ancestorName);
    }

    // If `arg`'s inferred type is a class that provably inherits from
    // `targetType`'s class, wraps it in an explicit cast to targetType -
    // C's nominal struct typing would otherwise warn/error on passing a
    // `Button*` where a `Widget*` is declared/expected, even though the
    // flattened layout (see generateClassLayout) makes the two safely
    // prefix-compatible (same reasoning as the explicit cast `super(...)`
    // chaining and vtable dispatch already insert by hand). Deliberately
    // narrow, matching the feature's own Scope: this only ever *adds* a
    // cast to keep already-safe, already-related-type code compiling
    // cleanly - it never rejects or flags a genuinely unrelated type;
    // whatever (lack of) checking already applied to `arg` still applies
    // to it unchanged; only returned as a distinct node (not mutated) when
    // wrapping actually happens, so a shared AST node used at multiple
    // sites is never accidentally aliased/mutated for all of them.
    private ASTNode insertUpcastIfNeeded(ASTNode arg, Type targetType) {
        if (targetType.pointerDepth != 0 || targetType.isArray) return arg;
        if ((targetType.name in classRegistry) is null) return arg;
        Type argType;
        try {
            argType = inferType(arg);
        } catch (Exception e) {
            return arg;
        }
        if (argType.pointerDepth != 0 || argType.isArray) return arg;
        if (argType.name == targetType.name) return arg;
        auto argClass = argType.name in classRegistry;
        if (argClass is null) return arg;
        if (!classInheritsFrom(*argClass, targetType.name)) return arg;
        return new CastExpr(cloneType(targetType), arg, arg.line, arg.column);
    }

    // Applies insertUpcastIfNeeded across a final, already-resolved
    // argument list against the callee's own declared parameter types -
    // called only once each call site has settled on its one true target
    // FunctionDecl (never inside resolveOverload's own trial resolution:
    // an implicit cast there would make inferType report the *target*
    // type for every trial, defeating the exact-type matching overload
    // resolution depends on to disambiguate candidates).
    private ASTNode[] applyImplicitArgumentConversions(ASTNode[] args, Parameter[] params) {
        ASTNode[] result = args.dup;
        foreach (i, param; params) {
            if (i >= result.length) break;
            result[i] = insertStringConstructorIfNeeded(result[i], param.type);
            result[i] = insertUpcastIfNeeded(result[i], param.type);
            result[i] = insertNumericCoercionIfNeeded(result[i], param.type);
            result[i] = insertImplicitConversionCastIfNeeded(result[i], param.type);
        }
        return result;
    }

    // Materialize an owning String at a call boundary when a raw string is
    // passed to a String parameter: `use("text")` is `use(new String("text"))`.
    private ASTNode insertStringConstructorIfNeeded(ASTNode arg, Type targetType) {
        Type target = cloneType(targetType);
        Type source;
        try {
            resolveType(target);
            source = inferType(arg);
            resolveType(source);
        } catch (Exception e) {
            return arg;
        }
        if (target.name != "String" || target.pointerDepth != 0 || target.isArray) return arg;
        if (source.name != "char" || source.pointerDepth != 1 || source.isArray) return arg;
        return new NewExpr(new Type("String"), [arg], arg.line, arg.column);
    }

    // Same idea as insertUpcastIfNeeded/insertNumericCoercionIfNeeded just
    // above, for a *class*/struct that implicitly converts (see
    // tryImplicitConversionCall/implicitConversionKind) - `puts(someStream)`
    // now works the same way `let s: char* = someStream` (an assignment,
    // which already went through tryImplicitConversionCall) always could.
    // Wraps the argument in the same synthetic `as TargetType` cast an
    // explicit one would be, so CastExpr's own already-correct codegen
    // (which already calls tryImplicitConversionCall, falling back to a
    // plain C cast when it doesn't apply) does the real work - no new
    // conversion logic here, just reaching the existing one from a new
    // call site.
    //
    // Only wraps when the argument is *actually* a class/struct value -
    // never for an already-compatible or genuinely mismatched primitive,
    // which needs to stay a real "incompatible pointer type" compile
    // error instead of silently type-punning through a pointless cast
    // (an int argument passed where char* was expected, say).
    private ASTNode insertImplicitConversionCastIfNeeded(ASTNode arg, Type targetType) {
        if (implicitConversionKind(targetType).length == 0) return arg;
        Type argType;
        try {
            argType = inferType(arg);
            resolveType(argType);
        } catch (Exception e) {
            return arg;
        }
        if (argType.pointerDepth != 0 || argType.isArray) return arg;
        if ((argType.name in classRegistry) is null && (argType.name in structRegistry) is null) return arg;
        return new CastExpr(cloneType(targetType), arg, arg.line, arg.column, true);
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
    // argument's type is an exact match or numerically coercible (see
    // numericCoercionCost) to that parameter's declared type. Each
    // candidate's total coercion cost is summed; the lowest-cost fit wins,
    // an exact match always beating a coerced one, and a tie between two
    // equally-costed fits is an "Ambiguous call" error.
    private FunctionDecl resolveOverload(FunctionDecl[] candidates, ASTNode[] args, string[] argNames,
            string calleeDescription, int line, int column) {
        if (candidates.length == 1) return candidates[0];

        FunctionDecl[] fits;
        int bestScore = int.max;
        foreach (candidate; candidates) {
            ASTNode[] resolved;
            try {
                resolved = resolveCallArguments(candidate.params, candidate.isVariadic, args, argNames,
                    calleeDescription, line, column);
            } catch (CompileError e) {
                continue;
            }
            bool matches = true;
            int score = 0;
            foreach (i, param; candidate.params) {
                if (i >= resolved.length) { matches = false; break; }
                Type argType;
                try {
                    argType = inferType(resolved[i]);
                    resolveType(argType);
                    resolveType(param.type);
                } catch (Exception e) {
                    matches = false;
                    break;
                }
                int cost = numericCoercionCost(argType, param.type);
                if (cost < 0) {
                    matches = false;
                    break;
                }
                score += cost;
            }
            if (matches) {
                if (fits.length == 0 || score < bestScore) {
                    fits = [candidate];
                    bestScore = score;
                } else if (score == bestScore) {
                    fits ~= candidate;
                }
            }
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

    // The "__ov_int_int"-style suffix appended to an overloaded name's
    // mangled C symbol - one mangleTypeArg per parameter, joined by "_".
    // The reserved marker keeps overload-generated names from colliding
    // with user-declared underscore names such as append_int.
    private string overloadSuffix(Parameter[] params) {
        string suffix = "__ov";
        foreach (p; params) suffix ~= "_" ~ mangleTypeArg(p.type);
        return suffix;
    }

    private FunctionDecl[] methodCandidatesNamed(ClassDecl cd, string name) {
        FunctionDecl[] result;
        foreach (m; cd.methods) if (m.name == name) result ~= m;
        return result;
    }

    private FunctionDecl[] propertyMethodCandidates(FunctionDecl[] candidates, int paramCount = -1) {
        FunctionDecl[] result;
        foreach (m; candidates) {
            if (m.isProperty && (paramCount < 0 || m.params.length == paramCount)) result ~= m;
        }
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

    // Same overload-suffix convention as mangleConstructorName just
    // above, for a polymorphic class's internal "_init" half (see
    // generatePolymorphicConstructor) - keyed off the same
    // cd.constructors overload set, so an overloaded constructor's `_new`
    // and `_init` always agree on which suffix names which overload.
    private string mangleInitName(ClassDecl cd, string cName, FunctionDecl ctor) {
        if (cd.constructors.length <= 1) return format("%s_init", cName);
        return format("%s_init%s", cName, overloadSuffix(ctor.params));
    }

    // Same convention as the ClassDecl overload above - a struct
    // constructor is named identically, it just generates differently
    // (see generateStructConstructor: a plain value-returning function,
    // no heap allocation).
    private string mangleConstructorName(StructDecl sd, string sName, FunctionDecl ctor) {
        if (sd.constructors.length <= 1) return format("%s_new", sName);
        return format("%s_new%s", sName, overloadSuffix(ctor.params));
    }

    private FunctionDecl[] methodCandidatesNamed(StructDecl sd, string name) {
        FunctionDecl[] result;
        foreach (m; sd.methods) if (m.name == name) result ~= m;
        return result;
    }

    // Same convention as the ClassDecl overload above - no hierarchy walk
    // needed (a struct has no base/derived types to search), just this
    // struct's own flat methods list.
    private string mangleMethodName(StructDecl sd, string sName, FunctionDecl method) {
        auto candidates = methodCandidatesNamed(sd, method.name);
        if (candidates.length <= 1) return format("%s_%s", sName, method.name);
        return format("%s_%s%s", sName, method.name, overloadSuffix(method.params));
    }

    // Same convention again, for `union`.
    private string mangleConstructorName(UnionDecl ud, string uName, FunctionDecl ctor) {
        if (ud.constructors.length <= 1) return format("%s_new", uName);
        return format("%s_new%s", uName, overloadSuffix(ctor.params));
    }

    private FunctionDecl[] methodCandidatesNamed(UnionDecl ud, string name) {
        FunctionDecl[] result;
        foreach (m; ud.methods) if (m.name == name) result ~= m;
        return result;
    }

    private string mangleMethodName(UnionDecl ud, string uName, FunctionDecl method) {
        auto candidates = methodCandidatesNamed(ud, method.name);
        if (candidates.length <= 1) return format("%s_%s", uName, method.name);
        return format("%s_%s%s", uName, method.name, overloadSuffix(method.params));
    }

    // Groups every top-level FunctionDecl by its plain (pre-overload-
    // suffix) mangled name - i.e. exactly what mangledFunc(fn) already
    // produces today. A key with more than one candidate is an overloaded
    // name; see mangleFreeFunctionName and every free-function call site.
    private FunctionDecl[][string] functionCandidates;

    // True for exactly one shape: a top-level, unnamespaced `func main(args:
    // string[])`, in either its as-parsed form (name "string", pointerDepth
    // 0 - resolveType hasn't run yet) or its post-resolveType one (`string`
    // canonicalized to name "char", pointerDepth bumped to 1 - see
    // resolveType's own "Built-in lowercase `string`..." comment). Checked
    // both ways since callers reach this at different points in the
    // pipeline (before/after that function's own params are resolved) -
    // see generateMainWrapper's own comment for why this shape specifically
    // needs real main-specific codegen, unlike `func main(argc: i32, argv:
    // char**)` or plain `func main()`, which already just work as ordinary
    // functions with no special-casing at all.
    private bool isMainArgsFunction(FunctionDecl fn) {
        if (fn.name != "main" || fn.namespaceSegments.length != 0) return false;
        if (fn.params.length != 1) return false;
        Type t = fn.params[0].type;
        if (!t.isArray || t.arraySize != 0) return false;
        if (t.name == "string" && t.pointerDepth == 0) return true;
        if (t.name == "char" && t.pointerDepth == 1) return true;
        return false;
    }

    // The internal C symbol a `func main(args: string[])`'s own body is
    // emitted under - never "main" itself, since real main-specific codegen
    // (generateMainWrapper) generates the actual `int main(int argc, char**
    // argv)` C entry point separately and calls this.
    private static immutable string mainArgsImplName = "__llpl_main_args_impl";

    // `mangledFunc(fn)` (today's plain namespace_name) if `fn` is the only
    // function registered under that name, else suffixed per its own
    // parameter types. Extern functions are never suffixed - their C
    // symbol is a real, fixed external name that can't be invented a
    // second spelling for. A `func main(args: string[])` is named
    // mainArgsImplName instead of either scheme - see its own comment.
    private string mangleFreeFunctionName(FunctionDecl fn) {
        if (isMainArgsFunction(fn)) return mainArgsImplName;
        string plain = mangledFunc(fn);
        if (fn.isExtern) return plain;
        auto candidates = plain in functionCandidates;
        if (candidates is null || candidates.length <= 1) return plain;
        return plain ~ overloadSuffix(fn.params);
    }

    // The iterator protocol a class opts into to support `for x in
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

    // `for x in iterable { ... }` desugars to either a counted
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
                // An unsized `T[]` (see typeToC's isDynamicArray comment -
                // Vector<T>.data/Slice<T>.ptr's own backing storage, or a
                // `func main(args: string[])`-style parameter) has no
                // compile-time length to count up to the way a fixed-size
                // `T[N]` does - but if its elements are themselves
                // pointer-shaped (an explicit pointer, or a class - always
                // a pointer under the hood, see typeToC's own "classes are
                // always pointers" rule), NULL is a real, well-defined
                // stopping sentinel (this is exactly what makes `args` in
                // `func main(args: string[])` safely walkable at all: the
                // C runtime's own argv is NULL-terminated, and main-
                // specific codegen's `argv + 1` preserves that - see
                // generateMainWrapper). A dynamic array of plain values
                // (hypothetically `int[]`) has no such sentinel and stays
                // unsupported.
                Type elemType = new Type(iterType.name, iterType.pointerDepth, false, 0);
                bool elementIsPointerLike = elemType.pointerDepth >= 1 ||
                    (elemType.name in classRegistry) !is null;
                if (!elementIsPointerLike) {
                    throw new CompileError(
                        "foreach needs a fixed-size array (e.g. 'T[8]') - this array's size isn't known " ~
                        "at compile time (it's an unsized 'T[]', typically a function parameter), and " ~
                        format("'%s' has no NULL sentinel to stop at", elemType.toString()),
                        currentModulePath, foreachStmt.line, foreachStmt.column);
                }
                return generateDynamicArrayForeach(foreachStmt, iterType, elemType, isDeferred);
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
        code ~= indent() ~ format("%s %s = %s;\n", primitiveToC("int"), endName, generateExpression(range.end));
        code ~= indent() ~ format("%s %s = %s;\n", primitiveToC("int"), foreachStmt.varName, generateExpression(range.start));
        // Put the increment in the loop's third clause so `continue` still
        // advances the range variable instead of jumping back to the test
        // with the same value forever.
        code ~= indent() ~ format("for (; %s < %s; %s = %s + 1) {\n",
            foreachStmt.varName, endName, foreachStmt.varName, foreachStmt.varName);
        indentLevel++;

        variableTypes[foreachStmt.varName] = new Type("int");
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

    private string generateArrayForeach(ForeachStmt foreachStmt, Type arrType, bool isDeferred) {
        Type elemType = new Type(arrType.name, arrType.pointerDepth, false, 0);

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

    // `foreach x in dynArray { ... }` for an unsized `T[]` whose elements
    // are pointer-shaped (see the caller's own comment on why that's
    // required) - counts up from 0 like generateArrayForeach, but stops at
    // the first NULL element instead of a compile-time-known length, the
    // same way walking a real C argv (or any other NULL-terminated
    // pointer array) already works.
    private string generateDynamicArrayForeach(ForeachStmt foreachStmt, Type arrType, Type elemType,
            bool isDeferred) {
        tempVarCounter++;
        // Evaluated into a local once, not re-evaluated every iteration -
        // same reasoning as generateClassForeach's objName.
        string arrName = format("__foreach_arr%d", tempVarCounter);
        string idxName = format("__foreach_i%d", tempVarCounter);

        string code = indent() ~ "{\n";
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s;\n",
            typeToC(arrType), arrName, generateExpression(foreachStmt.iterable));
        code ~= indent() ~ format("int64_t %s = 0;\n", idxName);
        code ~= indent() ~ format("while (%s[%s] != ((void*)0)) {\n", arrName, idxName);
        indentLevel++;
        code ~= indent() ~ format("%s %s = %s[%s];\n",
            typeToC(elemType), foreachStmt.varName, arrName, idxName);

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

    // Shared by the `.as_string` property (see generateExpression's
    // MemberExpr case), casting a class/struct value `as string`/`as
    // char*` and `let s: string = value`/plain assignment (see
    // tryImplicitConversionCall - both go through this for kind ==
    // "string"), and string interpolation's implicit conversion
    // (generateInterpolatedString): a class defining a no-argument
    // `as_string()` or `to_string()` method has it called (bridged through
    // String's own c_str() if it returns this codebase's String class rather
    // than a bare char*/string directly - see bridgeStringReturnToCharPtr);
    // everything else (a struct, which can't have methods at all, or a class
    // that doesn't define one) falls back to a compile-time string literal of
    // the type's own name - there's always *something* meaningful to produce
    // either way.
    private string generateAsStringValue(Type objType, ASTNode objectExpr, int line, int column) {
        if (auto classDecl = objType.name in classRegistry) {
            string call = generateStringConversionMethodCall(*classDecl, objType.name, objectExpr, line, column);
            if (call.length > 0) return call;
        }
        return format("\"%s\"", escapeCString(objType.toString()));
    }

    // One resolver for the supported stringification spellings. `as_string`
    // remains first for compatibility; `to_string` is the newer alias used by
    // code that expects the common method name.
    private string generateStringConversionMethodCall(ClassDecl classDecl, string receiverTypeName,
            ASTNode objectExpr, int line, int column) {
        foreach (methodName; ["as_string", "to_string"]) {
            ClassDecl owner;
            auto candidates = resolveMethodOnHierarchy(classDecl, methodName, owner);
            foreach (m; candidates) {
                if (m.params.length == 0) {
                    recordUsage(receiverTypeName ~ "." ~ methodName, line, column);
                    string call = format("%s(%s)",
                        mangleMethodName(owner, mangledClass(owner), m), generateExpression(objectExpr));
                    return bridgeStringReturnToCharPtr(m.returnType, call);
                }
            }
        }
        return "";
    }

    // `as_string()` conventionally returns this codebase's own String
    // class (e.g. YamlValue.as_string()), not a bare char*/string
    // directly (e.g. testy.llpl's own Klass.as_string()) - if `call`
    // (already-generated code for calling it) has the former return
    // type, bridges it through String's own (always-present) c_str()
    // method, the same extra step a caller manually chaining
    // `.as_string().c_str()` would take. Returns `call` unchanged
    // otherwise (including when the method already returns a bare
    // char*/string, needing no bridge at all).
    private string bridgeStringReturnToCharPtr(Type returnType, string call) {
        Type retType = cloneType(returnType);
        resolveType(retType);
        if (retType.pointerDepth == 0 && !retType.isArray && retType.name == "String") {
            if (auto stringClass = "String" in classRegistry) {
                foreach (m; stringClass.methods) {
                    if (m.name == "c_str" && m.params.length == 0) {
                        return format("%s(%s)",
                            mangleMethodName(*stringClass, mangledClass(*stringClass), m), call);
                    }
                }
            }
        }
        return call;
    }

    // Decides whether member access on `object` should use "." (a value
    // type: struct, array element, or dereferenced pointer) or "->" (a class
    // instance, always heap-allocated, or an explicit pointer type). Falls
    // back to "->" - the historical, only behavior before structs existed -
    // whenever the type can't be determined, so existing class-based code
    // is unaffected.
    private string memberAccessor(ASTNode object) {
        // A direct dereference of a single-starred pointer (`(*p).field`)
        // always yields a genuine C value with zero stars remaining -
        // true for struct/union pointers (handled below via the ordinary
        // type check) and, thanks to ast.d's "classes are always
        // pointers" collapse (see typeToC's own comment: an explicit `*`
        // on a class type never stacks a second star on top of the
        // class's own implicit one), also true for a class used as a
        // raw, manually-managed pointer - stdlib/collections' convention
        // (`ListNode<T>*`, `TrieNode*`, ...). A bare `ListNode<T>` class
        // reference and a fully-dereferenced `*node` both type-infer to
        // the identical Type("ListNode", pointerDepth: 0), so the type
        // alone can't distinguish "needs ->" from "needs ." here - only
        // the syntax (was this an explicit single-level `*`?) can.
        if (auto unary = cast(UnaryExpr)object) {
            if (unary.op == "*") {
                try {
                    if (inferType(unary.operand).pointerDepth == 1) {
                        return ".";
                    }
                } catch (Exception e) {
                    // Fall through to the general type-based check below.
                }
            }
        }
        try {
            Type t = inferType(object);
            if (!t.isPointer && (isStructTypeName(t.name) || isUnionTypeName(t.name))) {
                return ".";
            }
            return "->";
        } catch (Exception e) {
            return "->";
        }
    }

    // Maps a resolved target Type to the "as_<kind>" conversion method name
    // a class can define to support being cast/assigned to it (see
    // tryImplicitConversionCall) - "" if the target isn't one of the
    // supported conversion kinds. Only ever called with an already-
    // resolveType'd target, so `string` has already been canonicalized to
    // name "char", pointerDepth 1 (see resolveType's own comment on that).
    private string implicitConversionKind(Type target) {
        if (target.isArray || target.pointerDepth > 1) return "";
        if (target.name == "char" && target.pointerDepth == 1) return "string";
        if (target.pointerDepth != 0) return "";
        switch (target.name) {
            case "i64": case "u64": case "u8":
            case "i8": case "int8": case "uint8":
            case "i16": case "u16": case "int16": case "uint16":
            case "i32": case "u32": case "int32": case "uint32":
            case "int64": case "uint64":
                return "int";
            case "f32": return "float";
            case "bool": return "bool";
            default: return "";
        }
    }

    private Type closureTypeFromFunction(FunctionDecl fn) {
        Type t = new Type("__LLPL_Closure");
        Parameter[] params;
        foreach (p; fn.params) {
            params ~= new Parameter("", cloneType(p.type));
        }
        t.closureParams = params;
        t.closureReturnType = cloneType(fn.returnType);
        return t;
    }

    private bool sameResolvedType(Type a, Type b) {
        Type aa = cloneType(a);
        Type bb = cloneType(b);
        resolveType(aa);
        resolveType(bb);
        return sameErrorType(aa, bb);
    }

    private bool functionMatchesClosureType(FunctionDecl fn, Type closureType) {
        if (closureType.closureReturnType is null) return false;
        if (fn.params.length != closureType.closureParams.length) return false;
        if (!sameResolvedType(fn.returnType, closureType.closureReturnType)) return false;
        foreach (i, p; fn.params) {
            if (!sameResolvedType(p.type, closureType.closureParams[i].type)) return false;
        }
        return true;
    }

    private FunctionDecl resolveFunctionReference(ASTNode expr, Type targetClosureType = null) {
        FunctionDecl[] candidates;
        string displayName;

        if (auto ident = cast(Identifier)expr) {
            displayName = ident.name;
            try {
                string resolved = resolveName(ident.name, (n) => (n in functionCandidates) !is null);
                if (auto c = resolved in functionCandidates) candidates = *c;
            } catch (CompileError e) {
                return null;
            }
        } else if (auto member = cast(MemberExpr)expr) {
            displayName = qualifiedExprName(member);
            try {
                string resolved = tryResolveQualifiedPath(member, (n) => (n in functionCandidates) !is null);
                if (resolved.length > 0) {
                    if (auto c = resolved in functionCandidates) candidates = *c;
                }
            } catch (CompileError e) {
                return null;
            }
        }

        if (candidates.length == 0) return null;
        if (targetClosureType !is null) {
            FunctionDecl[] matches;
            foreach (candidate; candidates) {
                if (functionMatchesClosureType(candidate, targetClosureType)) matches ~= candidate;
            }
            if (matches.length == 1) return matches[0];
            if (matches.length > 1) {
                throw new CompileError(format("Function reference '%s' is ambiguous for closure type '%s'",
                    displayName, targetClosureType.toString()), currentModulePath, expr.line, expr.column);
            }
            throw new CompileError(format("Function reference '%s' does not match closure type '%s'",
                displayName, targetClosureType.toString()), currentModulePath, expr.line, expr.column);
        }
        if (candidates.length == 1) return candidates[0];
        throw new CompileError(format(
            "Cannot infer type: function '%s' is overloaded; add an explicit closure type annotation",
            displayName), currentModulePath, expr.line, expr.column);
    }

    private string functionClosureAdapter(FunctionDecl fn) {
        string target = mangleFreeFunctionName(fn);
        if (auto existing = target in functionClosureAdapters) return *existing;

        string adapter = format("__llpl_fn_closure%d", lambdaCounter++);
        functionClosureAdapters[target] = adapter;

        string params = "void* __env";
        string args = "";
        foreach (i, p; fn.params) {
            string argName = format("__arg%d", i);
            params ~= format(", %s %s", typeToC(p.type), argName);
            if (i > 0) args ~= ", ";
            args ~= argName;
        }

        string retC = typeToC(fn.returnType);
        lambdaForwardDecls ~= format("%s %s(%s);\n\n", retC, adapter, params);
        string body = format("%s %s(%s) {\n", retC, adapter, params);
        body ~= "    (void)__env;\n";
        if (fn.returnType.name == "void" && fn.returnType.pointerDepth == 0 && !fn.returnType.isArray) {
            body ~= format("    %s(%s);\n", target, args);
        } else {
            body ~= format("    return %s(%s);\n", target, args);
        }
        body ~= "}\n\n";
        lambdaBodyDecls ~= body;
        return adapter;
    }

    private string generateFunctionClosureValue(FunctionDecl fn, int line, int column) {
        string target = mangleFreeFunctionName(fn);
        recordUsage(target, line, column);
        string adapter = functionClosureAdapter(fn);
        return format("((__LLPL_Closure){ .fn = (void*)%s, .env = ((void*)0) })", adapter);
    }

    // If `expr`'s inferred type is a class defining a zero-param
    // `as_<kind>()` method matching `targetType` (see
    // implicitConversionKind - e.g. a `YamlValue`'s `as_string()`/
    // `as_int()`/`as_float()`/`as_bool()`), generates a call to it; ""
    // if no such conversion applies, meaning the caller should fall back
    // to its own ordinary codegen for `expr`. This is how a class opts
    // into "converts like a string/int/float/bool" - purely by naming a
    // method `as_<kind>`, the same unintrusive convention operator
    // overloading already uses (ast.operatorMethodName), rather than
    // this compiler needing a real trait/interface mechanism for it.
    // Deliberately narrow: only a bare class value (not a pointer/array)
    // converts, and only for an exact, zero-param `as_<kind>` match -
    // never partial/fuzzy, so this can't silently paper over a real type
    // error the way a looser rule might.
    private string tryImplicitConversionCall(ASTNode expr, Type targetType) {
        if (targetType.closureReturnType !is null) {
            FunctionDecl fn = resolveFunctionReference(expr, targetType);
            if (fn is null) return "";
            return generateFunctionClosureValue(fn, expr.line, expr.column);
        }

        string kind = implicitConversionKind(targetType);
        if (kind.length == 0) return "";
        Type sourceType;
        try {
            sourceType = inferType(expr);
            resolveType(sourceType);
        } catch (Exception e) {
            return "";
        }
        if (sourceType.pointerDepth != 0 || sourceType.isArray) return "";

        // "string" always converts, the same as the explicit `.as_string`
        // property/`as string` cast already do - see generateAsStringValue's
        // own comment (a class defining as_string() has it called; a
        // struct, or a class without one, falls back to the type's own
        // name). Only for an actual class/struct value, though - unlike
        // those explicit forms, a plain assignment silently "succeeding"
        // for any *other* type (falling back to a meaningless literal)
        // would be a real footgun, not a feature.
        if (kind == "string") {
            if ((sourceType.name in classRegistry) is null && (sourceType.name in structRegistry) is null) {
                return "";
            }
            return generateAsStringValue(sourceType, expr, expr.line, expr.column);
        }

        // "int"/"float"/"bool" have no such generic fallback (there's no
        // equivalent "there's always something to produce" for those) -
        // only an actual matching as_int()/as_float()/as_bool() converts.
        auto classDecl = sourceType.name in classRegistry;
        if (classDecl is null) return "";
        string methodName = "as_" ~ kind;
        ClassDecl owner;
        auto candidates = resolveMethodOnHierarchy(*classDecl, methodName, owner);
        foreach (method; candidates) {
            if (method.params.length == 0) {
                return format("%s(%s)", mangleMethodName(owner, mangledClass(owner), method),
                    generateExpression(expr));
            }
        }
        return "";
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
    //
    // `rightOperand` disambiguates when the class defines more than one
    // inline overload of the same operator (e.g. String's `operator==
    // (other: string)` and `operator==(other: String)`) - picked the same
    // way an ordinary overloaded method call is (see resolveOverload), by
    // matching its inferred type against each candidate's single param.
    // Always null for a unary op (nothing to disambiguate by - a unary
    // operator method takes zero params) and safe to omit for a binary one
    // when the class only ever defines a single overload of it, the case
    // every call site but tryBinaryOperatorOverloadCall was written against
    // before this could happen at all.
    private FunctionDecl findOperatorMethodDecl(ASTNode selfOperand, string op, bool isUnary,
            ASTNode rightOperand = null) {
        string methodName = operatorMethodName(op, isUnary ? 0 : 1);
        if (methodName.length == 0) return null;
        try {
            Type selfType = inferType(selfOperand);
            resolveType(selfType);
            if (!isUnary && selfType.pointerDepth > 0 && isPointerComparisonOperator(op)) {
                return null;
            }
            // Inline class/struct/union operator methods only make sense on
            // aggregate values. Impl-generated operator functions also cover
            // primitive targets. Pointer comparisons are intentionally native
            // identity/order comparisons, not overload dispatch.
            if (selfType.pointerDepth == 0 && !selfType.isArray) {
                if (auto classDecl = selfType.name in classRegistry) {
                    ClassDecl owner;
                    auto candidates = resolveMethodOnHierarchy(*classDecl, methodName, owner);
                    if (candidates.length == 1) return candidates[0];
                    if (candidates.length > 1 && rightOperand !is null) {
                        try {
                            return resolveOverload(candidates, [rightOperand], [],
                                format("operator '%s'", op), selfOperand.line, selfOperand.column);
                        } catch (CompileError e) {
                            // Ambiguous/no exact match among the class's own
                            // overloads - fall through to the functionRegistry
                            // check below (won't find anything either, since
                            // an impl-block operator is never *also* an
                            // inline class method), then to "no overload"
                            // entirely, same as any other lookup failure here.
                        }
                    }
                } else if (auto structDecl = selfType.name in structRegistry) {
                    // Same idea, no hierarchy to walk (a struct has none).
                    auto candidates = methodCandidatesNamed(*structDecl, methodName);
                    if (candidates.length == 1) return candidates[0];
                    if (candidates.length > 1 && rightOperand !is null) {
                        try {
                            return resolveOverload(candidates, [rightOperand], [],
                                format("operator '%s'", op), selfOperand.line, selfOperand.column);
                        } catch (CompileError e) {
                        }
                    }
                } else if (auto unionDecl = selfType.name in unionRegistry) {
                    auto candidates = methodCandidatesNamed(*unionDecl, methodName);
                    if (candidates.length == 1) return candidates[0];
                    if (candidates.length > 1 && rightOperand !is null) {
                        try {
                            return resolveOverload(candidates, [rightOperand], [],
                                format("operator '%s'", op), selfOperand.line, selfOperand.column);
                        } catch (CompileError e) {
                        }
                    }
                }
                if (auto fn = format("%s_%s", mangleTypeArg(selfType), methodName) in functionRegistry) {
                    return *fn;
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

    private bool isPointerComparisonOperator(string op) {
        switch (op) {
            case "==": case "!=": case "<": case ">": case "<=": case ">=":
                return true;
            default:
                return false;
        }
    }

    // The mangled C call name for findOperatorMethodDecl's match. Usually
    // `<mangleTypeArg(selfType)>_<methodName>`, built from the bare
    // operatorMethodName result rather than the matched FunctionDecl's own
    // .name - a class's inline method's .name is bare ("op_add"), but an
    // impl block's desugared method is registered in functionRegistry under
    // the already-fully-mangled name ("Vec2_op_add" - see processImplBlock),
    // so using .name here would double the prefix for that second case.
    // When the class defines more than one overload of `op` (only possible
    // for the inline-method source, never the impl-block one - see
    // findOperatorMethodDecl), the same overloadSuffix mangleMethodName
    // itself would use is appended, so the call actually reaches the
    // specific overload findOperatorMethodDecl picked instead of the bare,
    // ambiguous name (which only ever exists unsuffixed for a single-
    // overload operator).
    private string findOperatorMethodCallName(ASTNode selfOperand, string op, bool isUnary,
            ASTNode rightOperand = null) {
        auto matched = findOperatorMethodDecl(selfOperand, op, isUnary, rightOperand);
        if (matched is null) return "";
        string methodName = operatorMethodName(op, isUnary ? 0 : 1);
        try {
            Type selfType = inferType(selfOperand);
            resolveType(selfType);
            if (auto classDecl = selfType.name in classRegistry) {
                ClassDecl owner;
                auto candidates = resolveMethodOnHierarchy(*classDecl, methodName, owner);
                if (candidates.length > 0) {
                    string ownerName = mangledClass(owner);
                    if (candidates.length > 1) {
                        return format("%s_%s%s", ownerName, methodName, overloadSuffix(matched.params));
                    }
                    return format("%s_%s", ownerName, methodName);
                }
            } else if (auto structDecl = selfType.name in structRegistry) {
                auto candidates = methodCandidatesNamed(*structDecl, methodName);
                if (candidates.length > 0) {
                    string ownerName = mangledStruct(*structDecl);
                    if (candidates.length > 1) {
                        return format("%s_%s%s", ownerName, methodName, overloadSuffix(matched.params));
                    }
                    return format("%s_%s", ownerName, methodName);
                }
            } else if (auto unionDecl = selfType.name in unionRegistry) {
                auto candidates = methodCandidatesNamed(*unionDecl, methodName);
                if (candidates.length > 0) {
                    string ownerName = mangledUnion(*unionDecl);
                    if (candidates.length > 1) {
                        return format("%s_%s%s", ownerName, methodName, overloadSuffix(matched.params));
                    }
                    return format("%s_%s", ownerName, methodName);
                }
            }
            return format("%s_%s", mangleTypeArg(selfType), methodName);
        } catch (Exception e) {
            return "";
        }
    }

    private string tryBinaryOperatorOverloadCall(BinaryExpr binExpr) {
        string callName = findOperatorMethodCallName(binExpr.left, binExpr.op, false, binExpr.right);
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
    // `arr` defines `operator[]` (op_index) - the getter, one param.
    private string tryIndexOperatorOverloadCall(IndexExpr indexExpr) {
        string callName = findOperatorMethodCallName(indexExpr.array, "[]", false, indexExpr.index);
        if (callName.length == 0) return "";
        return format("%s(%s, %s)", callName,
            generateExpression(indexExpr.array), generateExpression(indexExpr.index));
    }

    // The write side of the above: `arr[index] = value` where `arr`'s type
    // defines a 2-param `operator[](index, value)` overload (op_index_set).
    // Handled as its own path rather than folding into
    // tryBinaryOperatorOverloadCall/findOperatorMethodDecl's isUnary/
    // rightOperand model - every other overloadable operator has at most
    // one non-self operand to disambiguate by, but op_index_set has two
    // (index and value), so overload resolution here calls resolveOverload
    // directly with both rather than through findOperatorMethodDecl's
    // single-rightOperand shape. Mirrors findOperatorMethodDecl's own two
    // lookup sources: an inline class method (classRegistry) or an impl
    // block's desugared free function (functionRegistry, mangled
    // `<mangleTypeArg(target)>_op_index_set` by processImplBlock).
    // Returns "" (falling back to a plain, likely-invalid C assignment)
    // when `arr`'s type defines no such overload - same "not found" shape
    // every other tryXOperatorOverloadCall above already uses.
    private string tryIndexSetOperatorOverloadCall(IndexExpr indexExpr, ASTNode valueExpr) {
        string methodName = operatorMethodName("[]", 2);
        try {
            Type selfType = inferType(indexExpr.array);
            resolveType(selfType);
            if (selfType.pointerDepth > 0 || selfType.isArray) return "";

            string callName;
            if (auto classDecl = selfType.name in classRegistry) {
                ClassDecl owner;
                auto candidates = resolveMethodOnHierarchy(*classDecl, methodName, owner);
                if (candidates.length == 1) {
                    callName = format("%s_%s", mangledClass(owner), methodName);
                } else if (candidates.length > 1) {
                    auto matched = resolveOverload(candidates, [indexExpr.index, valueExpr], [],
                        "operator '[]='", indexExpr.line, indexExpr.column);
                    callName = format("%s_%s%s", mangledClass(owner), methodName, overloadSuffix(matched.params));
                }
            } else if (auto structDecl = selfType.name in structRegistry) {
                // Same lookup, no hierarchy - but see generateStructMethod's
                // own comment: self is by value here, so this mutates only
                // the callee's own local copy. Genuinely useless as a
                // plain `x[i] = value` statement (the mutated copy is
                // discarded the moment the call returns) - but still lets
                // `x[i] = value` type-check and run rather than erroring,
                // matching this language's general "struct methods take
                // self by value" stance rather than special-casing this one
                // operator to secretly take a pointer.
                auto candidates = methodCandidatesNamed(*structDecl, methodName);
                if (candidates.length == 1) {
                    callName = format("%s_%s", mangledStruct(*structDecl), methodName);
                } else if (candidates.length > 1) {
                    auto matched = resolveOverload(candidates, [indexExpr.index, valueExpr], [],
                        "operator '[]='", indexExpr.line, indexExpr.column);
                    callName = format("%s_%s%s", mangledStruct(*structDecl), methodName, overloadSuffix(matched.params));
                }
            }
            if (callName.length == 0) {
                if (auto fn = format("%s_%s", mangleTypeArg(selfType), methodName) in functionRegistry) {
                    callName = format("%s_%s", mangleTypeArg(selfType), methodName);
                }
            }
            if (callName.length == 0) {
                // A class/struct with a getter but no setter would otherwise
                // fall through to a plain C assignment against the getter
                // call's result - "lvalue required as left operand of
                // assignment", a real error but a confusing one to land on
                // for a type that quite reasonably only wants to support
                // `arr[i]`, not `arr[i] = x`. Give a clear LLPL-level error
                // instead, but only when the type is unambiguously a
                // class/struct defining the getter - anything else (no
                // operator[] at all) isn't this function's problem to
                // diagnose.
                string getterName = operatorMethodName("[]", 1);
                if (auto classDecl = selfType.name in classRegistry) {
                    ClassDecl owner;
                    if (resolveMethodOnHierarchy(*classDecl, getterName, owner).length > 0) {
                        throw new CompileError(format(
                            "'%s' defines operator[] for reading but not writing - add a 2-parameter " ~
                            "'func operator[](index, value)' overload to support 'x[i] = value'",
                            selfType.name), currentModulePath, indexExpr.line, indexExpr.column);
                    }
                } else if (auto structDecl = selfType.name in structRegistry) {
                    if (methodCandidatesNamed(*structDecl, getterName).length > 0) {
                        throw new CompileError(format(
                            "'%s' defines operator[] for reading but not writing - add a 2-parameter " ~
                            "'func operator[](index, value)' overload to support 'x[i] = value'",
                            selfType.name), currentModulePath, indexExpr.line, indexExpr.column);
                    }
                }
                return "";
            }
            return format("%s(%s, %s, %s)", callName, generateExpression(indexExpr.array),
                generateExpression(indexExpr.index), generateExpression(valueExpr));
        } catch (CompileError e) {
            throw e;
        } catch (Exception e) {
            return "";
        }
    }

    // `obj.prop = value` calls `property prop(value: T)` when there is no
    // real field named `prop`. Getter-only properties get a clear LLPL
    // diagnostic instead of falling through to an invalid C lvalue.
    private string tryPropertySetterCall(MemberExpr memberExpr, ASTNode valueExpr) {
        try {
            Type selfType = inferType(memberExpr.object);
            resolveType(selfType);

            if (auto classDecl = selfType.name in classRegistry) {
                ClassDecl fieldOwner;
                if (findFieldOnHierarchy(*classDecl, memberExpr.member, fieldOwner) !is null) {
                    return "";
                }

                ClassDecl methodOwner;
                auto candidates = resolveMethodOnHierarchy(*classDecl, memberExpr.member, methodOwner);
                auto setters = propertyMethodCandidates(candidates, 1);
                if (setters.length == 0) {
                    auto getters = propertyMethodCandidates(candidates, 0);
                    if (getters.length > 0) {
                        throw new CompileError(format(
                            "'%s.%s' is a read-only property - add 'property %s(value: T)' " ~
                            "to support assignment",
                            selfType.name, memberExpr.member, memberExpr.member),
                            currentModulePath, memberExpr.line, memberExpr.column);
                    }
                    return "";
                }
                auto matched = resolveOverload(setters, [valueExpr], [],
                    format("property '%s' setter", memberExpr.member), memberExpr.line, memberExpr.column);
                checkMemberAccess(matched.isPrivate, matched.isProtected, mangledClass(methodOwner),
                    format("method '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                return generateExpression(new CallExpr(
                    new MemberExpr(memberExpr.object, memberExpr.member, memberExpr.line, memberExpr.column),
                    [valueExpr], memberExpr.line, memberExpr.column));
            }

            if (auto structDecl = selfType.name in structRegistry) {
                foreach (field; structDecl.fields) {
                    if (field.name == memberExpr.member) return "";
                }
                auto candidates = methodCandidatesNamed(*structDecl, memberExpr.member);
                auto setters = propertyMethodCandidates(candidates, 1);
                if (setters.length == 0) {
                    auto getters = propertyMethodCandidates(candidates, 0);
                    if (getters.length > 0) {
                        throw new CompileError(format(
                            "'%s.%s' is a read-only property - add 'property %s(value: T)' " ~
                            "to support assignment",
                            selfType.name, memberExpr.member, memberExpr.member),
                            currentModulePath, memberExpr.line, memberExpr.column);
                    }
                    return "";
                }
                resolveOverload(setters, [valueExpr], [],
                    format("property '%s' setter", memberExpr.member), memberExpr.line, memberExpr.column);
                return generateExpression(new CallExpr(
                    new MemberExpr(memberExpr.object, memberExpr.member, memberExpr.line, memberExpr.column),
                    [valueExpr], memberExpr.line, memberExpr.column));
            }

            if (auto unionDecl = selfType.name in unionRegistry) {
                foreach (field; unionDecl.fields) {
                    if (field.name == memberExpr.member) return "";
                }
                auto candidates = methodCandidatesNamed(*unionDecl, memberExpr.member);
                auto setters = propertyMethodCandidates(candidates, 1);
                if (setters.length == 0) {
                    auto getters = propertyMethodCandidates(candidates, 0);
                    if (getters.length > 0) {
                        throw new CompileError(format(
                            "'%s.%s' is a read-only property - add 'property %s(value: T)' " ~
                            "to support assignment",
                            selfType.name, memberExpr.member, memberExpr.member),
                            currentModulePath, memberExpr.line, memberExpr.column);
                    }
                    return "";
                }
                resolveOverload(setters, [valueExpr], [],
                    format("property '%s' setter", memberExpr.member), memberExpr.line, memberExpr.column);
                return generateExpression(new CallExpr(
                    new MemberExpr(memberExpr.object, memberExpr.member, memberExpr.line, memberExpr.column),
                    [valueExpr], memberExpr.line, memberExpr.column));
            }
        } catch (CompileError e) {
            throw e;
        } catch (Exception e) {
            return "";
        }
        return "";
    }

    // In safe mode, fixed-size array indexing (T[N]) is wrapped with a
    // runtime bounds check. The helper returns a void* pointing at
    // the element, which the generated code casts back to a T* and
    // dereferences - this works for both reads and assignments because the
    // dereferenced pointer is a valid C lvalue.
    private string generateCheckedIndexExpr(IndexExpr indexExpr) {
        try {
            Type arrType = inferType(indexExpr.array);
            resolveType(arrType);
            string arrCode = generateExpression(indexExpr.array);
            int bound = knownIndexBound(indexExpr.array, arrType, arrCode);
            if (bound <= 0) {
                // Fall back to raw indexing if the array isn't a fixed-size array
                // and the pointer has no tracked bound.
                return format("%s[%s]", arrCode, generateExpression(indexExpr.index));
            }

            Type elemType = inferType(indexExpr);
            resolveType(elemType);
            string idxCode = generateExpression(indexExpr.index);
            string elemValueTypeC = valueTypeForSizeof(elemType);
            string checked = format("__llpl_check_index(%s, %s, %d, sizeof(%s), %s, %d)",
                arrCode, idxCode, bound, elemValueTypeC,
                cStringLiteral(currentModulePath.length > 0 ? baseName(currentModulePath) : ""), indexExpr.line);

            if (elemType.isArray && elemType.arraySize > 0) {
                return format("(*(%s)%s)", pointerToValueCastType(elemType), checked);
            }
            string elemTypeC = typeToC(elemType);
            return format("(*(%s*)%s)", elemTypeC, checked);
        } catch (Exception e) {
            // If we can't infer the array type (e.g. a global array), fall back
            // to raw indexing rather than failing compilation.
            return format("%s[%s]", generateExpression(indexExpr.array),
                generateExpression(indexExpr.index));
        }
    }

    private int knownIndexBound(ASTNode arrayExpr, Type arrType, string arrCode) {
        if (arrType.isArray && arrType.arraySize > 0) {
            return arrType.arraySize;
        }
        if (arrType.pointerDepth > 0) {
            if (auto bound = arrCode in pointerIndexBounds) {
                return *bound;
            }
        }
        return 0;
    }

    private string valueTypeForSizeof(Type type) {
        if (type.isArray && type.arraySize > 0) {
            string baseType = fixedArrayElementCType(type);
            return format("%s[%d]%s", baseType, type.arraySize, extraDimsSuffix(type));
        }
        return typeToC(type);
    }

    private string pointerToValueCastType(Type type) {
        string baseType = fixedArrayElementCType(type);
        if (type.isArray && type.arraySize > 0) {
            return format("%s (*)[%d]%s", baseType, type.arraySize, extraDimsSuffix(type));
        }
        return typeToC(type) ~ "*";
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

                string[] targets = imp.resolvedPaths.length > 0 ? imp.resolvedPaths :
                    (imp.resolvedPath.length > 0 ? [imp.resolvedPath] : []);

                if (targets.length == 0) {
                    if (imp.alias_.length > 0 || imp.isSelective) {
                        throw new CompileError(format("Could not resolve import '%s'", imp.modulePath),
                            prog.modulePath, imp.line, imp.column);
                    }
                    continue;
                }
                if (targets.length > 1 && (imp.alias_.length > 0 || imp.isSelective)) {
                    throw new CompileError(
                        "Directory imports cannot use aliases or selective import lists",
                        prog.modulePath, imp.line, imp.column);
                }

                foreach (targetPath; targets) {
                    ModuleImportInfo info;
                    info.targetModulePath = targetPath;
                    info.alias_ = imp.alias_;
                    info.isSelective = imp.isSelective;
                    foreach (n; imp.names) {
                        info.names ~= ImportedNameInfo(n.original, n.alias_);
                    }
                    moduleImports[prog.modulePath] ~= info;
                }

                if (imp.alias_.length > 0) {
                    moduleAliases[prog.modulePath][imp.alias_] = targets[0];
                }

                if (imp.isSelective) {
                    foreach (n; imp.names) {
                        string target = findSymbolInModule(targets[0], n.original);
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

        string nsAliased = resolveNamespaceAlias(flat);
        if (nsAliased.length > 0 && exists(nsAliased)) return nsAliased;

        if (exists(flat) && isSymbolVisibleFromCurrentModule(flat)) return flat;
        foreach (candidate; enclosingQualifications(flat)) {
            if (exists(candidate) && isSymbolVisibleFromCurrentModule(candidate)) return candidate;
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
    //
    // Same "root is a real local/instance variable - prefer normal member
    // access" guard tryResolveQualifiedPath already applies: without it,
    // `file.read(...)` on a File instance whose own `read` *method* exists
    // would incorrectly resolve to this module's unrelated extern
    // `read(fd, buf, count)` instead, just because they happen to share a
    // bare name - a real bug this exact File.read/extern read collision
    // surfaced (stdlib/io/file.llpl).
    private string tryResolveExternFunctionMember(ASTNode expr) {
        if (auto member = cast(MemberExpr)expr) {
            string root = leftmostName(member.object);
            if (root.length > 0 && (root in variableTypes)) {
                return ""; // root is a real local/instance variable; prefer normal member access
            }
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

        if (exists(name) && isSymbolVisibleFromCurrentModule(name)) return name;
        foreach (candidate; enclosingQualifications(name)) {
            if (exists(candidate) && isSymbolVisibleFromCurrentModule(candidate)) return candidate;
        }
        return name;
    }

    private string symbolModulePath(string name) {
        if (auto p = name in functionModulePath) return *p;
        if (auto p = name in functionCandidateModulePath) return *p;
        if (auto p = name in classModulePath) return *p;
        if (auto p = name in structModulePath) return *p;
        if (auto p = name in unionModulePath) return *p;
        if (auto p = name in macroModulePath) return *p;
        if (auto p = name in globalVarModulePath) return *p;
        if (auto p = name in typeAliasModulePath) return *p;
        if (auto p = name in genericTemplateModulePath) return *p;
        if (auto p = name in traitModulePath) return *p;
        return "";
    }

    private bool isSymbolVisibleFromCurrentModule(string name) {
        if (auto fn = name in functionRegistry) {
            if (fn.isExtern) return true;
        }
        string owner = symbolModulePath(name);
        if (owner.length == 0) return true;
        if (owner == currentModulePath) return true;
        if (preludeModulePath.length > 0 && owner == preludeModulePath) return true;
        if (owner !in moduleHasExplicitExports) return true;

        auto selected = currentModulePath in selectiveLocalAliases;
        if (selected !is null) {
            foreach (target; *selected) {
                if (target == name) return true;
            }
        }

        auto aliases = currentModulePath in moduleAliases;
        if (aliases !is null) {
            foreach (_alias, targetModule; *aliases) {
                if (targetModule != owner) continue;
                auto exports = owner in exportsByModule;
                if (exports !is null && (name in *exports) !is null) return true;
            }
        }

        auto imports = currentModulePath in moduleImports;
        if (imports is null) return false;
        foreach (imp; *imports) {
            if (imp.targetModulePath != owner || imp.alias_.length > 0 || imp.isSelective) continue;
            auto exports = owner in exportsByModule;
            if (exports !is null && (name in *exports) !is null) return true;
        }
        return false;
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
        rejectInInterrupt(lambdaExpr, "Lambda allocation");
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
            trampolineParams ~= ", " ~ parameterDeclaration(p);
        }

        string trampolineProto = format("%s %s(%s);\n", typeToC(lambdaExpr.returnType),
            trampolineName, trampolineParams);
        string trampolineCode = format("%s %s(%s) {\n", typeToC(lambdaExpr.returnType), trampolineName, trampolineParams);
        trampolineCode ~= format("    %s* __env = (%s*)__env_raw;\n", envType, envType);

        // Save/restore all per-function generation state around the body,
        // mirroring generateFunction/generateMethod: this trampoline is a
        // real top-level C function with its own fresh defer-stack, and
        // its own params/captures must not leak into the surrounding
        // function's variableTypes once it's done generating.
        DeferInfo[] savedDeferred = deferredStatements;
        deferredStatements = [];
        rcLocalNames = null; rcLocalTypes = null;
        rcFunctionBodyIndent = indentLevel;
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
        trampolineCode ~= releaseRcLocals(null);
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

        lambdaForwardDecls ~= envDecl;
        lambdaForwardDecls ~= trampolineProto;
        lambdaForwardDecls ~= "\n";
        lambdaBodyDecls ~= trampolineCode;
        lambdaBodyDecls ~= "\n";

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

    private bool isAsyncBuiltinCall(CallExpr callExpr, string name) {
        auto ident = cast(Identifier)callExpr.callee;
        return ident !is null && ident.name == name;
    }

    private FunctionDecl resolveAsyncCallTarget(CallExpr asyncCall, out string resolvedName) {
        FunctionDecl[] candidates;
        if (auto ident = cast(Identifier)asyncCall.callee) {
            resolvedName = resolveName(ident.name, (n) => (n in functionCandidates) !is null);
            if (isSymbolVisibleFromCurrentModule(resolvedName)) {
                if (auto c = resolvedName in functionCandidates) candidates = *c;
            }
        } else if (auto member = cast(MemberExpr)asyncCall.callee) {
            resolvedName = tryResolveQualifiedPath(member, (n) => (n in functionCandidates) !is null);
            if (resolvedName.length > 0) {
                candidates = functionCandidates[resolvedName];
            }
        }
        if (candidates.length == 0) {
            throw new CompileError("async_start/async_run expects a direct async function call",
                currentModulePath, asyncCall.line, asyncCall.column);
        }
        auto fn = resolveOverload(candidates, asyncCall.args, asyncCall.argNames,
            format("function '%s'", resolvedName), asyncCall.line, asyncCall.column);
        if (!fn.isAsync) {
            throw new CompileError("async_start/async_run expects an async function call",
                currentModulePath, asyncCall.line, asyncCall.column);
        }
        return fn;
    }

    private AsyncCallInfo resolveAsyncCallInfo(CallExpr asyncCall) {
        AsyncCallInfo info;
        if (auto member = cast(MemberExpr)asyncCall.callee) {
            Type receiverType = inferType(member.object);
            resolveType(receiverType);
            string className = mangleTypeArg(receiverType);
            if (receiverType.pointerDepth > 0) {
                Type pointeeType = cloneType(receiverType);
                pointeeType.pointerDepth--;
                string pointeeName = mangleTypeArg(pointeeType);
                if (className !in classRegistry && pointeeName in classRegistry) {
                    className = pointeeName;
                }
            }
            if (className in classRegistry) {
                ClassDecl owner;
                FunctionDecl[] candidates = resolveMethodOnHierarchy(classRegistry[className], member.member, owner);
                if (candidates.length > 0) {
                    string calleeDescription = format("async method '%s.%s'", className, member.member);
                    FunctionDecl methodDecl = resolveOverload(candidates, asyncCall.args, asyncCall.argNames,
                        calleeDescription, asyncCall.line, asyncCall.column);
                    checkMemberAccess(methodDecl.isPrivate, methodDecl.isProtected, mangledClass(owner), calleeDescription,
                        asyncCall.line, asyncCall.column);
                    if (!methodDecl.isAsync) {
                        throw new CompileError("async_start/async_run expects an async function or method call",
                            currentModulePath, asyncCall.line, asyncCall.column);
                    }
                    if (methodDecl.isStatic || methodDecl.isVirtual || methodDecl.isOverride) {
                        throw new CompileError("async_start/async_run currently supports ordinary async instance methods only",
                            currentModulePath, asyncCall.line, asyncCall.column);
                    }
                    ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(methodDecl.params, false, asyncCall.args,
                            asyncCall.argNames, calleeDescription, asyncCall.line, asyncCall.column),
                        methodDecl.params);
                    info.fn = methodDecl;
                    info.baseName = mangleMethodName(owner, mangledClass(owner), methodDecl);
                    info.usageName = className ~ "." ~ member.member;
                    info.usageNode = member;
                    info.argsWithReceiver = [member.object] ~ resolvedArgs;
                    return info;
                }
            }
        }

        string resolvedName;
        FunctionDecl fn = resolveAsyncCallTarget(asyncCall, resolvedName);
        ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
            resolveCallArguments(fn.params, fn.isVariadic, asyncCall.args, asyncCall.argNames,
                format("function '%s'", resolvedName), asyncCall.line, asyncCall.column),
            fn.params);
        info.fn = fn;
        info.baseName = mangleFreeFunctionName(fn);
        info.usageName = info.baseName;
        info.usageNode = asyncCall.callee;
        info.argsWithReceiver = resolvedArgs;
        return info;
    }

    private string generateAsyncTaskCreate(AsyncCallInfo info) {
        string args = "";
        foreach (arg; info.argsWithReceiver) {
            args ~= ", " ~ generateExpression(arg);
        }

        int id = tempVarCounter++;
        string task = format("__llpl_async_task%d", id);
        return format(
            "({ char* %s = llpl_async_create((uint64_t)%s_async_frame_size(), (void*)%s_async_poll_erased); " ~
            "%s_async_start_into((void*)llpl_async_frame(%s)%s); %s; })",
            task, info.baseName, info.baseName, info.baseName, task, args, task);
    }

    private string generateAsyncBuiltin(CallExpr callExpr, bool runToCompletion) {
        if (callExpr.args.length != 1) {
            throw new CompileError(runToCompletion
                    ? "async_run expects exactly one async function call"
                    : "async_start expects exactly one async function call",
                currentModulePath, callExpr.line, callExpr.column);
        }
        auto asyncCall = cast(CallExpr)callExpr.args[0];
        if (asyncCall is null) {
            throw new CompileError("async_start/async_run expects a direct async function call",
                currentModulePath, callExpr.args[0].line, callExpr.args[0].column);
        }

        AsyncCallInfo info = resolveAsyncCallInfo(asyncCall);
        recordUsage(info.usageName, info.usageNode.line, info.usageNode.column);
        string createExpr = generateAsyncTaskCreate(info);
        if (!runToCompletion) {
            return createExpr;
        }

        int id = tempVarCounter++;
        string task = format("__llpl_async_run_task%d", id);
        Type returnType = cloneType(info.fn.returnType);
        resolveType(returnType);
        bool returnsVoid = returnType.name == "void" && !returnType.isPointer;
        if (returnsVoid) {
            return format("({ char* %s = %s; llpl_async_block_on(%s, (char*)0); llpl_async_destroy(%s); })",
                task, createExpr, task, task);
        }
        string outVar = format("__llpl_async_run_out%d", id);
        return format("({ char* %s = %s; %s %s; llpl_async_block_on(%s, (char*)&%s); " ~
            "llpl_async_destroy(%s); %s; })",
            task, createExpr, typeToC(returnType), outVar, task, outVar, task, outVar);
    }

    // Thin wrapper over the real dispatcher below: every expression in the
    // program funnels through here, which is the one place that can spot an
    // owned RC temporary regardless of what kind of expression contains it.
    // See rcTempScope for why capturing happens in place rather than by
    // hoisting the call out of the expression.
    private string generateExpression(ASTNode node) {
        // Snapshot before descending: generateExpressionInner clears the flag
        // for a call's own arguments, and this node's eligibility is its
        // caller's business, not its children's.
        bool eligible = rcTempEligible;
        string code = generateExpressionInner(node);
        rcTempEligible = eligible;
        if (!rcTempActive || !eligible || node is rcTempExcludedRoot ||
                !producesOwnedRcTemp(node, code)) {
            return code;
        }
        Type t = tryInferType(node);
        if (t is null || !isRcManagedType(t)) {
            return code;
        }
        return captureRcTemp(code, t);
    }

    private string generateExpressionInner(ASTNode node) {
        // Propagate temp-capture eligibility one level down: a comparison
        // hands it to both operands (neither is stored anywhere), while a
        // call or a `new` withholds it from everything it generates, which
        // is what keeps an argument from being freed out from under a callee
        // that kept it. See rcTempEligible.
        if (auto opNode = cast(BinaryExpr)node) {
            if (opNode.op == "==" || opNode.op == "!=" || opNode.op == "<" ||
                    opNode.op == ">" || opNode.op == "<=" || opNode.op == ">=") {
                rcTempEligible = true;
            }
        } else if (cast(CallExpr)node !is null || cast(NewExpr)node !is null) {
            rcTempEligible = false;
        }

        if (auto binExpr = cast(BinaryExpr)node) {
            if (binExpr.op == "=") {
                checkNotConstAssignment(binExpr.left);
                // RAII: reassigning a tracked rc-managed local (see
                // rcLocalNames) must release whatever it currently holds
                // before taking on the new value, or the old target leaks
                // (a plain `x = y` used to just overwrite the pointer with
                // no release at all) - and retain the new value first if
                // it's only an alias of an existing reference (see
                // isAliasingRcExpr), or that reference ends up
                // double-released once this and its original owner each
                // release their own copy independently. Only applies to a
                // bare-identifier LHS that's actually tracked - an
                // untracked class variable (e.g. a `let` with no
                // initializer, left uninitialized) can't be safely
                // `if (ptr) rc_release`d, since C leaves it as garbage
                // stack memory, not NULL.
                if (auto leftIdent = cast(Identifier)binExpr.left) {
                    string leftEmitName = generateExpression(leftIdent);
                    Type identType = null;
                    try {
                        identType = inferType(leftIdent);
                    } catch (Exception e) {
                        identType = null;
                    }
                    if (identType !is null && isRcManagedType(identType) &&
                            rcLocalNames.canFind(leftEmitName)) {
                        string tmp = format("__llpl_assign_tmp%d", rcAssignTmpCounter++);
                        string retain = isAliasingRcExpr(binExpr.right)
                            ? format("rc_retain((char*)%s); ", tmp) : "";
                        return format("({ %s %s = %s; %sif (%s) rc_release(%s, %s); %s = %s; %s; })",
                            typeToC(identType), tmp, generateExpression(binExpr.right),
                            retain, leftEmitName, leftEmitName, fieldDestructorSymbol(identType),
                            leftEmitName, tmp, leftEmitName);
                    }
                }
                if (auto indexExpr = cast(IndexExpr)binExpr.left) {
                    string setterCall = tryIndexSetOperatorOverloadCall(indexExpr, binExpr.right);
                    if (setterCall.length > 0) {
                        return setterCall;
                    }
                }
                if (auto memberExpr = cast(MemberExpr)binExpr.left) {
                    string setterCall = tryPropertySetterCall(memberExpr, binExpr.right);
                    if (setterCall.length > 0) {
                        return setterCall;
                    }
                }
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
                    // `arr = [1, 2, 3]` - a plain array literal as a
                    // standalone assignment target, not just a `let`
                    // initializer (checkArrayLiteralInit's original spot).
                    // C arrays aren't assignable as a whole (`arr = ...`
                    // isn't real C), so this compiles to a memcpy from a
                    // GCC compound literal instead - `memcpy(arr, (T[N]){
                    // ... }, sizeof(arr))` - which already indexes/nests
                    // correctly for a multi-dim array (ast.Type.extraDims).
                    if (auto arrLit = cast(ArrayLiteral)binExpr.right) {
                        return generateArrayLiteralAssignment(binExpr, arrLit, leftType);
                    }
                    if (auto structLit = cast(StructLiteral)binExpr.right) {
                        return generateExpression(binExpr.left) ~ " = " ~
                            generateStructLiteralValue(structLit, leftType);
                    }
                    if (auto tupleLit = cast(TupleLiteral)binExpr.right) {
                        return generateExpression(binExpr.left) ~ " = " ~
                            generateTupleLiteral(tupleLit, leftType);
                    }
                    // See tryImplicitConversionCall's own comment - e.g.
                    // `s = someYamlValue` (s already declared `string`)
                    // calling YamlValue.as_string() automatically.
                    string converted = tryImplicitConversionCall(binExpr.right, leftType);
                    if (converted.length > 0) {
                        return generateExpression(binExpr.left) ~ " = " ~ converted;
                    }
                    ASTNode coerced = insertNumericCoercionIfNeeded(binExpr.right, leftType);
                    if (coerced !is binExpr.right) {
                        return generateExpression(binExpr.left) ~ " = " ~ generateExpression(coerced);
                    }
                }
                return generateExpression(binExpr.left) ~ " = " ~ generateExpression(binExpr.right);
            }
            if (binExpr.op == "in") {
                return generateInExpr(binExpr);
            }
            string overloadCall = tryBinaryOperatorOverloadCall(binExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            Type binaryResult = null;
            try {
                Type leftType = inferType(binExpr.left);
                Type rightType = inferType(binExpr.right);
                resolveType(leftType);
                resolveType(rightType);
                binaryResult = numericBinaryResultType(leftType, rightType);
            } catch (Exception e) {
                binaryResult = null;
            }
            if (binaryResult !is null) {
                return "(" ~ generateNumericCoercedExpression(binExpr.left, binaryResult) ~ " " ~
                    binExpr.op ~ " " ~ generateNumericCoercedExpression(binExpr.right, binaryResult) ~ ")";
            }
            return "(" ~ generateExpression(binExpr.left) ~ " " ~ binExpr.op ~ " " ~
                   generateExpression(binExpr.right) ~ ")";
        } else if (auto unaryExpr = cast(UnaryExpr)node) {
            string overloadCall = tryUnaryOperatorOverloadCall(unaryExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            if (unaryExpr.op == "++" || unaryExpr.op == "--") {
                if (unaryExpr.isPostfix) {
                    string incDecOp = unaryExpr.op == "++" ? "+" : "-";
                    ASTNode one = new IntLiteral(1, unaryExpr.line, unaryExpr.column);
                    ASTNode combined = new BinaryExpr(incDecOp, unaryExpr.operand, one, unaryExpr.line, unaryExpr.column);
                    return "(" ~ generateExpression(new BinaryExpr("=", unaryExpr.operand, combined,
                        unaryExpr.line, unaryExpr.column)) ~ ")";
                }
                return unaryExpr.op ~ generateExpression(unaryExpr.operand);
            }
            return unaryExpr.op ~ generateExpression(unaryExpr.operand);
        } else if (auto awaitExpr = cast(AwaitExpr)node) {
            throw new CompileError("'await' can only be generated after async state-machine lowering",
                currentModulePath, awaitExpr.line, awaitExpr.column);
        } else if (auto lambdaExpr = cast(LambdaExpr)node) {
            rejectInInterrupt(lambdaExpr, "Lambda allocation");
            return generateLambdaExpr(lambdaExpr);
        } else if (auto sizeofExpr = cast(SizeofExpr)node) {
            // `sizeof(name)` is ambiguous in the parser: a bare identifier
            // is valid in a type position and in a value position. Resolve
            // value names first so arrays and other variables get C's native
            // expression-size semantics; if it is not a variable, retain the
            // existing `sizeof(Type)` path below.
            string valueName = resolveName(sizeofExpr.type.name,
                (n) => (n in variableTypes) !is null || (n in globalVarRegistry) !is null);
            if ((valueName in variableTypes) !is null || (valueName in globalVarRegistry) !is null) {
                return format("sizeof(%s)", generateExpression(
                    new Identifier(sizeofExpr.type.name, sizeofExpr.line, sizeofExpr.column)));
            }
            resolveType(sizeofExpr.type);
            // Not typeToC: that auto-adds a `*` for a bare class type
            // (classes are always accessed by pointer), but `sizeof(Foo)`
            // here is a real type reference used for manual allocation
            // sizing (e.g. `llpl_alloc(sizeof(ListNode<T>))`) - callers
            // want the underlying struct's size, not a pointer's. An
            // explicit `sizeof(Foo*)` still gets its stars via
            // pointerStars below.
            string sizeofCType = primitiveToC(sizeofExpr.type.name) ~ pointerStars(sizeofExpr.type);
            return format("sizeof(%s)", sizeofCType);
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
            checkInterruptSafeCall(callExpr);
            if (isEmbedCall(callExpr)) {
                return generateEmbedCall(callExpr);
            }
            if (isAsyncBuiltinCall(callExpr, "async_start")) {
                return generateAsyncBuiltin(callExpr, false);
            }
            if (isAsyncBuiltinCall(callExpr, "async_run")) {
                return generateAsyncBuiltin(callExpr, true);
            }
            if (auto panicIdent = cast(Identifier)callExpr.callee) {
                if (panicIdent.name == "panic" && callExpr.args.length == 1) {
                    string file = escapeCString(shortSourcePath(currentModulePath));
                    return format("llpl_panic_at(%s, \"%s\", %d)",
                        generateExpression(callExpr.args[0]), file, callExpr.line);
                }
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
                ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
                    resolveCallArguments(closureType.closureParams, false,
                        callExpr.args, callExpr.argNames, "this closure", callExpr.line, callExpr.column),
                    closureType.closureParams);
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
                auto resolution = resolveGenericFunctionCall(genericTemplateKey, callExpr.args,
                    callExpr.argNames, callExpr.typeArgs);
                recordUsage(genericTemplateKey, callExpr.line, callExpr.column);
                string gargs = "";
                foreach (i, arg; resolution.resolvedArgs) {
                    if (i > 0) gargs ~= ", ";
                    gargs ~= generateExpression(arg);
                }
                return format("%s(%s)", resolution.mangledName, gargs);
            }
            if (callExpr.typeArgs.length > 0) {
                throw new CompileError(
                    "Explicit type arguments can only be used when calling a generic function",
                    currentModulePath, callExpr.line, callExpr.column);
            }
            // Check if this is a method call
            if (auto memberExpr = cast(MemberExpr)callExpr.callee) {
                if (auto ctorType = resolveQualifiedConstructorType(memberExpr)) {
                    auto newExpr = new NewExpr(ctorType, callExpr.args,
                        callExpr.line, callExpr.column, callExpr.argNames);
                    return generateExpression(newExpr);
                }

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
                    ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(qualifiedDecl.params, qualifiedDecl.isVariadic,
                            callExpr.args, callExpr.argNames, format("function '%s'", qualifiedName),
                            callExpr.line, callExpr.column),
                        qualifiedDecl.params);
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
                    ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(qualifiedDecl.params, qualifiedDecl.isVariadic,
                            callExpr.args, callExpr.argNames, format("function '%s'", externFunc),
                            callExpr.line, callExpr.column),
                        qualifiedDecl.params);
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

                // Check for static method call (ClassName.staticMethod)
                if (auto classNameIdent = cast(Identifier)memberExpr.object) {
                    string resolvedClassName = resolveName(classNameIdent.name, (n) => (n in classRegistry) !is null);
                    if (resolvedClassName in classRegistry) {
                        ClassDecl cd = classRegistry[resolvedClassName];
                        ClassDecl staticOwner;
                        FunctionDecl[] candidates = resolveMethodOnHierarchy(cd, memberExpr.member, staticOwner);
                        // Filter for static methods only
                        FunctionDecl[] staticCandidates;
                        foreach (candidate; candidates) {
                            if (candidate.isStatic) {
                                staticCandidates ~= candidate;
                            }
                        }
                        if (staticCandidates.length > 0) {
                            string calleeDescription = format("static method '%s.%s'", resolvedClassName, memberExpr.member);
                            FunctionDecl methodDecl = resolveOverload(staticCandidates, callExpr.args, callExpr.argNames,
                                calleeDescription, callExpr.line, callExpr.column);
                            string ownerName = mangledClass(staticOwner);
                            checkMemberAccess(methodDecl.isPrivate, methodDecl.isProtected, ownerName, calleeDescription,
                                callExpr.line, callExpr.column);
                            ASTNode[] resolvedArgs = applyImplicitArgumentConversions(
                                resolveCallArguments(methodDecl.params, false, callExpr.args,
                                    callExpr.argNames, calleeDescription, callExpr.line, callExpr.column),
                                methodDecl.params);
                            string methodSymbol = mangleMethodName(staticOwner, ownerName, methodDecl);

                            // Static methods don't receive 'self' parameter
                            string args = "";
                            foreach (i, arg; resolvedArgs) {
                                if (i > 0) args ~= ", ";
                                args ~= generateExpression(arg);
                            }
                            recordUsage(resolvedClassName ~ "." ~ memberExpr.member, memberExpr.line, memberExpr.column);
                            return format("%s(%s)", methodSymbol, args);
                        }
                    }
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

                Type receiverType = inferType(memberExpr.object);
                resolveType(receiverType);
                bool structPointerReceiver = false;
                bool unionPointerReceiver = false;
                // Struct and union methods receive pointer self parameters.
                // A pointer receiver dispatches directly; a value receiver
                // is passed by address so mutations affect the original.
                if (receiverType.pointerDepth > 0) {
                    Type pointeeType = cloneType(receiverType);
                    pointeeType.pointerDepth--;
                    string pointeeName = mangleTypeArg(pointeeType);
                    if (className !in classRegistry && pointeeName in classRegistry) {
                        className = pointeeName;
                    } else if (className !in structRegistry && pointeeName in structRegistry) {
                        className = pointeeName;
                        structPointerReceiver = true;
                    } else if (className !in unionRegistry && pointeeName in unionRegistry) {
                        className = pointeeName;
                        unionPointerReceiver = true;
                    }
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
                ClassDecl owner;
                FunctionDecl[] candidates = cd !is null ? resolveMethodOnHierarchy(cd, methodName, owner) : [];
                // A struct has no base/derived types to walk - just its own
                // flat methods list (ast.StructDecl.methods). Only tried
                // once cd itself came up empty, same "class takes priority"
                // stance a struct and class could never share a name under
                // anyway (mangleTypeArg gives each its own registry key).
                StructDecl sd = (cd is null && className.length > 0 && className in structRegistry)
                    ? structRegistry[className] : null;
                FunctionDecl[] structCandidates = sd !is null ? methodCandidatesNamed(sd, methodName) : [];
                UnionDecl ud = (cd is null && sd is null && className.length > 0 && className in unionRegistry)
                    ? unionRegistry[className] : null;
                FunctionDecl[] unionCandidates = ud !is null ? methodCandidatesNamed(ud, methodName) : [];
                string calleeDescription = format("method '%s.%s'", className, methodName);
                ASTNode[] resolvedArgs;
                FunctionDecl methodDecl = null;
                // Blind fallback for a method that isn't found anywhere in
                // cd's own hierarchy (e.g. impl-block-provided trait
                // methods, generated separately by processImplBlock under
                // this exact name) - matches this compiler's existing
                // behavior of trusting that mechanism rather than requiring
                // every method to be registered here.
                string methodSymbol = className.length > 0 ? format("%s_%s", className, methodName) : "";
                if (candidates.length == 0 && structCandidates.length == 0 && unionCandidates.length == 0) {
                    if (hasNamedArgs(callExpr.argNames)) {
                        throw new CompileError(
                            format("Cannot resolve named arguments for '%s' - its target method " ~
                                "couldn't be determined at compile time", methodName),
                            currentModulePath, callExpr.line, callExpr.column);
                    }
                    resolvedArgs = callExpr.args;
                } else if (candidates.length > 0) {
                    methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        calleeDescription, callExpr.line, callExpr.column);
                    checkMemberAccess(methodDecl.isPrivate, methodDecl.isProtected, mangledClass(owner), calleeDescription,
                        callExpr.line, callExpr.column);
                    resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(methodDecl.params, false, callExpr.args,
                            callExpr.argNames, calleeDescription, callExpr.line, callExpr.column),
                        methodDecl.params);
                    methodSymbol = mangleMethodName(owner, mangledClass(owner), methodDecl);
                } else if (structCandidates.length > 0) {
                    // Struct methods receive a pointer to self; structs have
                    // no `private` concept yet, so no checkMemberAccess call
                    // is needed here.
                    methodDecl = resolveOverload(structCandidates, callExpr.args, callExpr.argNames,
                        calleeDescription, callExpr.line, callExpr.column);
                    resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(methodDecl.params, false, callExpr.args,
                            callExpr.argNames, calleeDescription, callExpr.line, callExpr.column),
                        methodDecl.params);
                    methodSymbol = mangleMethodName(sd, className, methodDecl);
                    structPointerReceiver = true;
                } else {
                    // Union methods use the same pointer receiver convention
                    // as struct methods.
                    methodDecl = resolveOverload(unionCandidates, callExpr.args, callExpr.argNames,
                        calleeDescription, callExpr.line, callExpr.column);
                    resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(methodDecl.params, false, callExpr.args,
                            callExpr.argNames, calleeDescription, callExpr.line, callExpr.column),
                        methodDecl.params);
                    methodSymbol = mangleMethodName(ud, className, methodDecl);
                    unionPointerReceiver = true;
                }

                // A virtual/overridden method dispatches through the
                // hierarchy's vtable instead of calling methodSymbol
                // directly - the receiver's *static* type (className/cd)
                // might not be its actual runtime type (e.g. a Widget*
                // holding a Button), so only the vtable, filled in at
                // construction time with each concrete class's own
                // resolveMethodOnHierarchy result (see the vtable-instance
                // construction comment), knows which override to run.
                // Reading `->__vtable` needs no cast (same flattened offset
                // for every class in the hierarchy - see generateClassLayout);
                // casting the vtable pointer itself and the `self` argument
                // to the hierarchy root's type is the same explicit-cast
                // trick `super(...)` chaining and __destroy_impl cascading
                // already use for this exact prefix-compatible-but-nominally-
                // different-types situation.
                if (methodDecl !is null && (methodDecl.isVirtual || methodDecl.isOverride)) {
                    string rootName = mangledClass(hierarchyRoot(cd));
                    string vtableExpr = format("((%s_VTable*)(%s)->__vtable)", rootName, objectExpr);
                    string vArgs = format("(%s*)(%s)", rootName, objectExpr);
                    foreach (arg; resolvedArgs) {
                        vArgs ~= ", " ~ generateExpression(arg);
                    }
                    recordUsage(className ~ "." ~ methodName, memberExpr.line, memberExpr.column);
                    return format("%s->%s(%s)", vtableExpr, methodName, vArgs);
                }

                // Generate method call with object as first parameter (except for static methods)
                string args = "";
                if (methodDecl is null || !methodDecl.isStatic) {
                    string receiverExpr = objectExpr;
                    if (structPointerReceiver || unionPointerReceiver) {
                        receiverExpr = receiverType.pointerDepth > 0
                            ? objectExpr : format("&(%s)", objectExpr);
                    }
                    if (methodDecl !is null && cd !is null) {
                        string ownerName = mangledClass(owner);
                        if (ownerName != className) {
                            receiverExpr = format("((%s*)%s)", ownerName, objectExpr);
                        }
                    }
                    args = receiverExpr;
                }
                foreach (i, arg; resolvedArgs) {
                    if (args.length > 0) args ~= ", ";
                    args ~= generateExpression(arg);
                }

                if (className.length > 0) {
                    recordUsage(className ~ "." ~ methodName, memberExpr.line, memberExpr.column);
                    return format("%s(%s)", methodSymbol, args);
                } else {
                    // Every real path above (qualified namespace call, extern
                    // member, resolved method) already returned. Reaching
                    // here means `objectExpr.methodName(...)` isn't a
                    // recognized namespace function, extern binding, or
                    // method of any inferrable type - almost always a typo'd
                    // or renamed callee. This used to silently emit an
                    // undefined `CLASS_methodName(...)` call instead, which
                    // only ever failed later at the C-compile stage with a
                    // confusing "implicit declaration" error far from the
                    // actual mistake (see eventlog.llpl's old
                    // `HAL.disable_i64errupts()` and console.llpl's old
                    // `Framebuffer.draw_char` - both real, silently-accepted
                    // typos this exact fallback was masking).
                    throw new CompileError(
                        format("Cannot resolve call '%s' - no matching namespace function, " ~
                            "extern binding, or method was found", methodName),
                        currentModulePath, memberExpr.line, memberExpr.column);
                }
            } else {
                // `Calc(text)` - calling a `grammar Calc { ... }`-generated
                // class's own name directly, with no `new` and no method
                // call - desugars to `(new Calc(text)).parse_<firstRule>()`.
                // Checked before the ordinary functionCandidates lookup
                // below since a grammar-generated class is never itself a
                // function; synthesizing the equivalent MemberExpr/NewExpr
                // and recursing through the ordinary codegen path (rather
                // than hand-emitting C here) reuses all of `new`'s and a
                // method call's own existing argument-resolution/mangling
                // logic for free.
                if (auto calleeIdent = cast(Identifier)callExpr.callee) {
                    string grammarClass = resolveName(calleeIdent.name,
                        (n) => (n in grammar.grammarStartRule) !is null);
                    if (auto startMethod = grammarClass in grammar.grammarStartRule) {
                        auto newExpr = new NewExpr(new Type(calleeIdent.name), callExpr.args,
                            callExpr.line, callExpr.column, callExpr.argNames);
                        auto startCall = new CallExpr(new MemberExpr(newExpr, *startMethod,
                            callExpr.line, callExpr.column), [], callExpr.line, callExpr.column);
                        return generateExpression(startCall);
                    }
                    if (resolveDirectConstructorType(calleeIdent.name) !is null) {
                        auto newExpr = new NewExpr(new Type(calleeIdent.name), callExpr.args,
                            callExpr.line, callExpr.column, callExpr.argNames);
                        return generateExpression(newExpr);
                    }
                }

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
                    if (isSymbolVisibleFromCurrentModule(resolvedName)) {
                        if (auto c = resolvedName in functionCandidates) candidates = *c;
                    }
                }

                string callee;
                FunctionDecl calleeDecl;
                ASTNode[] resolvedArgs;
                if (candidates.length > 0) {
                    calleeDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                        format("function '%s'", resolvedName), callExpr.line, callExpr.column);
                    callee = mangleFreeFunctionName(calleeDecl);
                    recordUsage(callee, callExpr.callee.line, callExpr.callee.column);
                    resolvedArgs = applyImplicitArgumentConversions(
                        resolveCallArguments(calleeDecl.params, calleeDecl.isVariadic,
                            callExpr.args, callExpr.argNames, format("function '%s'", resolvedName),
                            callExpr.line, callExpr.column),
                        calleeDecl.params);
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
                        resolvedArgs = applyImplicitArgumentConversions(
                            resolveCallArguments(calleeDecl.params, calleeDecl.isVariadic,
                                callExpr.args, callExpr.argNames, format("function '%s'", calleeDecl.name),
                                callExpr.line, callExpr.column),
                            calleeDecl.params);
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
            // `.as_string` (no call parens - `x.as_string()` already
            // works as an ordinary method call without any special-casing
            // here) - see generateAsStringValue's own comment.
            if (memberExpr.member == "as_string") {
                Type objType;
                try {
                    objType = inferType(memberExpr.object);
                } catch (Exception e) {
                    throw new CompileError("'.as_string' needs a typed value",
                        currentModulePath, memberExpr.line, memberExpr.column);
                }
                return generateAsStringValue(objType, memberExpr.object, memberExpr.line, memberExpr.column);
            }
            // `.sizeof` - unlike the existing `sizeof(TypeName)` (a real
            // type reference only), this works on any typed *value*
            // (`x.sizeof`), inferring its type the same way `.as_string`
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
            string qualifiedVar = tryResolveQualifiedPath(memberExpr,
                (n) => (n in variableTypes) !is null || (n in globalVarRegistry) !is null);
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
                    ClassDecl fieldOwner;
                    VarDecl matchedField = findFieldOnHierarchy(*classDecl, memberExpr.member, fieldOwner);
                    if (matchedField !is null) {
                        checkMemberAccess(matchedField.isPrivate, matchedField.isProtected, mangledClass(fieldOwner),
                            format("field '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                    } else {
                        ClassDecl methodOwner;
                        auto candidates = resolveMethodOnHierarchy(*classDecl, memberExpr.member, methodOwner);
                        auto properties = propertyMethodCandidates(candidates, 0);
                        if (properties.length > 1) {
                            throw new CompileError(
                                format("'%s' is ambiguous - %s has %d property methods named '%s'",
                                    memberExpr.member, classDecl.name, properties.length, memberExpr.member),
                                currentModulePath, memberExpr.line, memberExpr.column);
                        }
                        if (properties.length == 1) {
                            string methodOwnerName = mangledClass(methodOwner);
                            checkMemberAccess(properties[0].isPrivate, properties[0].isProtected, methodOwnerName,
                                format("method '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                            return generateExpression(new CallExpr(
                                new MemberExpr(memberExpr.object, memberExpr.member,
                                    memberExpr.line, memberExpr.column),
                                [], memberExpr.line, memberExpr.column));
                        }
                        if (candidates.length > 1) {
                            throw new CompileError(
                                format("'%s' is ambiguous - %s has %d overloads named '%s'; a bare " ~
                                    "method reference (no call parens) can't disambiguate them",
                                    memberExpr.member, classDecl.name, candidates.length, memberExpr.member),
                                currentModulePath, memberExpr.line, memberExpr.column);
                        }
                        if (candidates.length == 1) {
                            string methodOwnerName = mangledClass(methodOwner);
                            checkMemberAccess(candidates[0].isPrivate, candidates[0].isProtected, methodOwnerName,
                                format("method '%s'", memberExpr.member), memberExpr.line, memberExpr.column);
                            return mangleMethodName(methodOwner, methodOwnerName, candidates[0]);
                        }
                        string implKey = ownerClassName ~ "_" ~ memberExpr.member;
                        if (implKey in functionRegistry) {
                            return implKey;
                        }
                    }
                } else if (auto structDecl = memberObjType.name in structRegistry) {
                    bool hasField = false;
                    foreach (field; structDecl.fields) {
                        if (field.name == memberExpr.member) {
                            hasField = true;
                            break;
                        }
                    }
                    if (!hasField) {
                        auto properties = propertyMethodCandidates(methodCandidatesNamed(*structDecl, memberExpr.member), 0);
                        if (properties.length > 1) {
                            throw new CompileError(
                                format("'%s' is ambiguous - %s has %d property methods named '%s'",
                                    memberExpr.member, structDecl.name, properties.length, memberExpr.member),
                                currentModulePath, memberExpr.line, memberExpr.column);
                        }
                        if (properties.length == 1) {
                            return generateExpression(new CallExpr(
                                new MemberExpr(memberExpr.object, memberExpr.member,
                                    memberExpr.line, memberExpr.column),
                                [], memberExpr.line, memberExpr.column));
                        }
                    }
                } else if (auto unionDecl = memberObjType.name in unionRegistry) {
                    bool hasField = false;
                    foreach (field; unionDecl.fields) {
                        if (field.name == memberExpr.member) {
                            hasField = true;
                            break;
                        }
                    }
                    if (!hasField) {
                        auto properties = propertyMethodCandidates(methodCandidatesNamed(*unionDecl, memberExpr.member), 0);
                        if (properties.length > 1) {
                            throw new CompileError(
                                format("'%s' is ambiguous - %s has %d property methods named '%s'",
                                    memberExpr.member, unionDecl.name, properties.length, memberExpr.member),
                                currentModulePath, memberExpr.line, memberExpr.column);
                        }
                        if (properties.length == 1) {
                            return generateExpression(new CallExpr(
                                new MemberExpr(memberExpr.object, memberExpr.member,
                                    memberExpr.line, memberExpr.column),
                                [], memberExpr.line, memberExpr.column));
                        }
                    }
                }
            }

            string accessor = memberAccessor(memberExpr.object);
            string objectCode = generateExpression(memberExpr.object);
            // C's `.`/`->` bind tighter than a prefix unary/binary/cast
            // operator - `(*p).field`/`(a+b).field` need to keep their
            // explicit grouping in the generated C, or `*p.field` parses
            // as `*(p.field)` instead of `(*p).field`.
            if (cast(UnaryExpr)memberExpr.object || cast(BinaryExpr)memberExpr.object ||
                    cast(CastExpr)memberExpr.object || cast(IfExpr)memberExpr.object) {
                objectCode = format("(%s)", objectCode);
            }
            return format("%s%s%s", objectCode, accessor, memberExpr.member);
        } else if (auto indexExpr = cast(IndexExpr)node) {
            string overloadCall = tryIndexOperatorOverloadCall(indexExpr);
            if (overloadCall.length > 0) {
                return overloadCall;
            }
            if (safeMode) {
                return generateCheckedIndexExpr(indexExpr);
            }
            return format("%s[%s]", generateExpression(indexExpr.array),
                         generateExpression(indexExpr.index));
        } else if (auto ident = cast(Identifier)node) {
            if (auto ctx = ident.name in currentLambdaCaptures) {
                return ctx.useExpr;
            }
            // A `let`-declared local (see variableCNames' own comment) -
            // checked ahead of resolveName/namespace resolution, which
            // never applies to a plain local variable anyway, so this
            // never changes behavior for a name that was never shadowed
            // (variableCNames[name] == name in that case).
            if (auto cName = ident.name in variableCNames) {
                recordUsage(*cName, ident.line, ident.column);
                return *cName;
            }
            string resolved;
            try {
                resolved = resolveName(ident.name,
                    (n) => (n in variableTypes) !is null || (n in functionRegistry) !is null ||
                           (n in globalVarRegistry) !is null);
            } catch (CompileError e) {
                string fieldAccess = tryGenerateBareFieldAccess(ident);
                if (fieldAccess.length > 0) return fieldAccess;
                throw e;
            }
            if ((resolved in variableTypes) is null && (resolved in functionRegistry) is null &&
                    (resolved in globalVarRegistry) is null) {
                string fieldAccess = tryGenerateBareFieldAccess(ident);
                if (fieldAccess.length > 0) return fieldAccess;
            }
            if ((resolved in variableTypes) is null &&
                    symbolModulePath(resolved).length > 0 &&
                    !isSymbolVisibleFromCurrentModule(resolved)) {
                throw new CompileError(format("Cannot access private symbol '%s'", ident.name),
                    currentModulePath, ident.line, ident.column);
            }
            recordUsage(resolved, ident.line, ident.column);
            return resolved;
        } else if (auto intLit = cast(IntLiteral)node) {
            return to!string(intLit.value);
        } else if (auto floatLit = cast(FloatLiteral)node) {
            return floatLit.value;
        } else if (auto charLit = cast(CharLiteral)node) {
            return to!string(charLit.value);
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
            return "((void*)0)";
        } else if (auto newExpr = cast(NewExpr)node) {
            rejectInInterrupt(newExpr, "'new'");
            checkNotGenericFunctionConstruction(newExpr);
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            recordUsage(newExpr.type.name, newExpr.line, newExpr.column);
            ClassDecl cd = newExpr.type.name in classRegistry ? classRegistry[newExpr.type.name] : null;
            StructDecl sd = newExpr.type.name in structRegistry ? structRegistry[newExpr.type.name] : null;
            UnionDecl ud = newExpr.type.name in unionRegistry ? unionRegistry[newExpr.type.name] : null;
            FunctionDecl[] ctors = cd !is null ? cd.constructors :
                (sd !is null ? sd.constructors : (ud !is null ? ud.constructors : []));
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
                resolvedArgs = applyImplicitArgumentConversions(
                    resolveCallArguments(ctor.params, false, newExpr.args, newExpr.argNames,
                        calleeDescription, newExpr.line, newExpr.column),
                    ctor.params);
                ctorSymbol = cd !is null ? mangleConstructorName(cd, newExpr.type.name, ctor)
                    : (sd !is null ? mangleConstructorName(sd, newExpr.type.name, ctor)
                                   : mangleConstructorName(ud, newExpr.type.name, ctor));
            }
            string args = "";
            foreach (i, arg; resolvedArgs) {
                if (i > 0) args ~= ", ";
                args ~= generateExpression(arg);
            }
            return format("%s(%s)", ctorSymbol, args);
        } else if (auto castExpr = cast(CastExpr)node) {
            // Casting a class/struct value `as string`/`as int`/`as
            // float`/`as bool` resolves the same way `.as_string`/`let s:
            // string = value` do (a custom as_string()/as_int()/etc.
            // method, or - for "string" specifically - the type's own
            // name) instead of reinterpreting the object as a raw
            // pointer/int - see tryImplicitConversionCall. Parser-written
            // `as char*` leaves useImplicitConversion false, so it remains
            // a raw pointer cast even though `string` resolves to char*.
            if (castExpr.useImplicitConversion) {
                string converted = tryImplicitConversionCall(castExpr.expression, castExpr.type);
                if (converted.length > 0) {
                    return converted;
                }
            }
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
        } else if (auto floatLit = cast(FloatLiteral)expr) {
            // Check suffix to determine float vs double
            string val = floatLit.value;
            if (val.length > 0 && (val[$-1] == 'f' || val[$-1] == 'F')) {
                return new Type("f32");
            }
            return new Type("f64"); // default to f64
        } else if (cast(CharLiteral)expr) {
            return new Type("char");
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
        } else if (auto arrLit = cast(ArrayLiteral)expr) {
            return inferArrayLiteralType(arrLit);
        } else if (auto newExpr = cast(NewExpr)expr) {
            checkNotGenericFunctionConstruction(newExpr);
            resolveType(newExpr.type);
            checkNotStruct(newExpr);
            return new Type(newExpr.type.name);
        } else if (cast(SizeofExpr)expr) {
            return new Type("u64");
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
            try {
                string resolved = resolveName(ident.name, (n) => (n in variableTypes) !is null);
                if (resolved in variableTypes) {
                    return variableTypes[resolved];
                }
            } catch (CompileError e) {
            }
            if (auto field = findFieldOnCurrentAggregate(ident.name)) {
                if (field.type is null) {
                    field.type = inferType(field.initializer);
                }
                return field.type;
            }
            throw inferError(expr, format("Cannot infer type: unknown variable '%s'", ident.name));
        } else if (auto memberExpr = cast(MemberExpr)expr) {
            if (memberExpr.member == "as_string") {
                return new Type("char", true);
            }
            if (memberExpr.member == "sizeof") {
                return new Type("u64");
            }
            string qualifiedVar = tryResolveQualifiedPath(memberExpr,
                (n) => (n in variableTypes) !is null || (n in globalVarRegistry) !is null);
            if (qualifiedVar.length > 0) {
                if (auto vt = qualifiedVar in variableTypes) {
                    return *vt;
                }
                if (auto gv = qualifiedVar in globalVarRegistry) {
                    return gv.type;
                }
            }

            Type objType = inferType(memberExpr.object);
            if (auto classDecl = objType.name in classRegistry) {
                auto field = findFieldOnHierarchy(*classDecl, memberExpr.member);
                if (field !is null) {
                    if (field.type is null) {
                        field.type = inferType(field.initializer);
                    }
                    return field.type;
                }
                ClassDecl methodOwner;
                auto properties = propertyMethodCandidates(
                    resolveMethodOnHierarchy(*classDecl, memberExpr.member, methodOwner), 0);
                if (properties.length > 1) {
                    throw inferError(expr, format("Cannot infer type: property '%s' is ambiguous", memberExpr.member));
                }
                if (properties.length == 1) {
                    return properties[0].returnType;
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
                auto properties = propertyMethodCandidates(methodCandidatesNamed(*structDecl, memberExpr.member), 0);
                if (properties.length > 1) {
                    throw inferError(expr, format("Cannot infer type: property '%s' is ambiguous", memberExpr.member));
                }
                if (properties.length == 1) {
                    return properties[0].returnType;
                }
            }
            if (auto unionDecl = objType.name in unionRegistry) {
                foreach (field; unionDecl.fields) {
                    if (field.name == memberExpr.member) {
                        if (field.type is null) {
                            field.type = inferType(field.initializer);
                        }
                        return field.type;
                    }
                }
                auto properties = propertyMethodCandidates(methodCandidatesNamed(*unionDecl, memberExpr.member), 0);
                if (properties.length > 1) {
                    throw inferError(expr, format("Cannot infer type: property '%s' is ambiguous", memberExpr.member));
                }
                if (properties.length == 1) {
                    return properties[0].returnType;
                }
            }
            throw inferError(expr, format("Cannot infer type of field '%s'", memberExpr.member));
        } else if (auto callExpr = cast(CallExpr)expr) {
            if (isEmbedCall(callExpr)) {
                return new Type("EmbeddedFile");
            }
            if (isAsyncBuiltinCall(callExpr, "async_start")) {
                if (callExpr.args.length != 1 || cast(CallExpr)callExpr.args[0] is null) {
                    throw inferError(expr, "async_start expects exactly one async function call");
                }
                resolveAsyncCallInfo(cast(CallExpr)callExpr.args[0]);
                return new Type("char", true);
            }
            if (isAsyncBuiltinCall(callExpr, "async_run")) {
                if (callExpr.args.length != 1 || cast(CallExpr)callExpr.args[0] is null) {
                    throw inferError(expr, "async_run expects exactly one async function call");
                }
                AsyncCallInfo info = resolveAsyncCallInfo(cast(CallExpr)callExpr.args[0]);
                return info.fn.returnType;
            }
            if (auto memberCallee = cast(MemberExpr)callExpr.callee) {
                if (auto ctorType = resolveQualifiedConstructorType(memberCallee)) {
                    return new Type(ctorType.name);
                }
                string genericKey = tryResolveQualifiedPath(memberCallee,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    auto resolution = resolveGenericFunctionCall(genericKey, callExpr.args,
                        callExpr.argNames, callExpr.typeArgs);
                    return functionRegistry[resolution.mangledName].returnType;
                }
                if (callExpr.typeArgs.length > 0) {
                    throw inferError(expr,
                        "Explicit type arguments can only be used when calling a generic function");
                }

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

                Type objType = inferType(memberCallee.object);
                if (auto classDecl = objType.name in classRegistry) {
                    ClassDecl unusedOwner;
                    auto candidates = resolveMethodOnHierarchy(*classDecl, memberCallee.member, unusedOwner);
                    if (candidates.length > 0) {
                        auto methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                            format("method '%s.%s'", objType.name, memberCallee.member),
                            callExpr.line, callExpr.column);
                        return methodDecl.returnType;
                    }
                } else if (auto structDecl = objType.name in structRegistry) {
                    auto candidates = methodCandidatesNamed(*structDecl, memberCallee.member);
                    if (candidates.length > 0) {
                        auto methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                            format("method '%s.%s'", objType.name, memberCallee.member),
                            callExpr.line, callExpr.column);
                        return methodDecl.returnType;
                    }
                } else if (auto unionDecl = objType.name in unionRegistry) {
                    auto candidates = methodCandidatesNamed(*unionDecl, memberCallee.member);
                    if (candidates.length > 0) {
                        auto methodDecl = resolveOverload(candidates, callExpr.args, callExpr.argNames,
                            format("method '%s.%s'", objType.name, memberCallee.member),
                            callExpr.line, callExpr.column);
                        return methodDecl.returnType;
                    }
                }
                throw inferError(expr, format("Cannot infer type: unknown method '%s'", memberCallee.member));
            } else if (auto calleeIdent = cast(Identifier)callExpr.callee) {
                // `Calc(text)` - see generateExpression's own identical
                // check/comment. Every grammar-generated rule method
                // returns ParseNode (see grammar.d's codegen), so that's
                // always the right answer here without needing to look up
                // the actual (synthesized) method declaration.
                string grammarClass = resolveName(calleeIdent.name,
                    (n) => (n in grammar.grammarStartRule) !is null);
                if (grammarClass in grammar.grammarStartRule) {
                    return new Type("ParseNode");
                }
                if (auto ctorType = resolveDirectConstructorType(calleeIdent.name)) {
                    return new Type(ctorType.name);
                }
                string resolvedVar = resolveName(calleeIdent.name, (n) => (n in variableTypes) !is null);
                if (resolvedVar in variableTypes && variableTypes[resolvedVar].closureReturnType !is null) {
                    return variableTypes[resolvedVar].closureReturnType;
                }
                string genericKey = findGenericTemplateKey(calleeIdent.name,
                    (n) => (n in genericFunctionTemplates) !is null);
                if (genericKey.length > 0) {
                    auto resolution = resolveGenericFunctionCall(genericKey, callExpr.args,
                        callExpr.argNames, callExpr.typeArgs);
                    return functionRegistry[resolution.mangledName].returnType;
                }
                if (callExpr.typeArgs.length > 0) {
                    throw inferError(expr,
                        "Explicit type arguments can only be used when calling a generic function");
                }

                string resolved = resolveName(calleeIdent.name, (n) => (n in functionCandidates) !is null);
                if (isSymbolVisibleFromCurrentModule(resolved)) {
                    if (auto candidates = resolved in functionCandidates) {
                        auto decl = resolveOverload(*candidates, callExpr.args, callExpr.argNames,
                            format("function '%s'", resolved), callExpr.line, callExpr.column);
                        return decl.returnType;
                    }
                }
                // Extern functions are excluded from functionCandidates
                // (see mangleFreeFunctionName) - still registered in
                // functionRegistry directly under their fixed bare name.
                string externResolved = resolveName(calleeIdent.name, (n) => (n in functionRegistry) !is null);
                if (isSymbolVisibleFromCurrentModule(externResolved)) {
                    if (auto funcDecl = externResolved in functionRegistry) {
                        return funcDecl.returnType;
                    }
                }
                throw inferError(expr, format("Cannot infer type: unknown function '%s'", calleeIdent.name));
            }
            throw inferError(expr, "Cannot infer type of call expression");
        } else if (auto binExpr = cast(BinaryExpr)expr) {
            FunctionDecl binOpMethod = findOperatorMethodDecl(binExpr.left, binExpr.op, false, binExpr.right);
            if (binOpMethod !is null) {
                return binOpMethod.returnType;
            }
            switch (binExpr.op) {
                case "==": case "!=": case "<": case ">": case "<=": case ">=":
                case "&&": case "||": case "in":
                    return new Type("bool");
                default:
                    Type leftType = inferType(binExpr.left);
                    Type rightType = inferType(binExpr.right);
                    resolveType(leftType);
                    resolveType(rightType);
                    Type numericResult = numericBinaryResultType(leftType, rightType);
                    if (numericResult !is null) return numericResult;
                    return leftType;
            }
        } else if (auto unaryExpr = cast(UnaryExpr)expr) {
            FunctionDecl unaryOpMethod = findOperatorMethodDecl(unaryExpr.operand, unaryExpr.op, true);
            if (unaryOpMethod !is null) {
                return unaryOpMethod.returnType;
            }
            if (unaryExpr.op == "++" || unaryExpr.op == "--") {
                return inferType(unaryExpr.operand);
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
        } else if (auto awaitExpr = cast(AwaitExpr)expr) {
            Type futureType = inferType(awaitExpr.expression);
            Type valueType = futureValueType(futureType);
            if (valueType !is null) return valueType;
            resolveType(futureType);
            valueType = futureValueType(futureType);
            if (valueType !is null) return valueType;
            throw inferError(expr, format("Cannot infer await result type from '%s'; expected Future<T>",
                futureType.toString()));
        } else if (auto indexExpr = cast(IndexExpr)expr) {
            Type arrType = inferType(indexExpr.array);
            // Indexing consumes exactly one level of indirection: an
            // array's element keeps whatever pointer depth it already had
            // (int*[5] indexed gives int*, not int); a pointer's pointee
            // drops one level (int** indexed/dereferenced gives int*).
            if (arrType.isArray) {
                return arrayElementType(arrType);
            }
            if (arrType.pointerDepth > 0) {
                return new Type(arrType.name, arrType.pointerDepth - 1, false, 0);
            }
            if (auto classDecl = arrType.name in classRegistry) {
                string methodName = operatorMethodName("[]", 1);
                foreach (method; classDecl.methods) {
                    if (method.name == methodName) return method.returnType;
                }
            } else if (auto structDecl = arrType.name in structRegistry) {
                string methodName = operatorMethodName("[]", 1);
                foreach (method; structDecl.methods) {
                    if (method.name == methodName) return method.returnType;
                }
            } else if (auto unionDecl = arrType.name in unionRegistry) {
                string methodName = operatorMethodName("[]", 1);
                foreach (method; unionDecl.methods) {
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

    private Type inferArrayLiteralType(ArrayLiteral lit) {
        if (lit.elements.length == 0) {
            throw inferError(lit,
                "Cannot infer type of an empty array literal; add an explicit array type annotation");
        }

        Type elemType = inferType(lit.elements[0]);
        resolveType(elemType);
        foreach (i, elem; lit.elements[1 .. $]) {
            Type current = inferType(elem);
            resolveType(current);
            if (!sameInferredArrayElementType(elemType, current)) {
                throw inferError(elem, format(
                    "Cannot infer array literal type: element %d has type '%s', expected '%s'",
                    i + 2, current.toString(), elemType.toString()));
            }
        }

        Type arrayType = cloneType(elemType);
        if (arrayType.isArray) {
            arrayType.extraDims = [arrayType.arraySize] ~ arrayType.extraDims;
        }
        arrayType.isArray = true;
        arrayType.arraySize = cast(int)lit.elements.length;
        return arrayType;
    }

    private bool sameInferredArrayElementType(Type a, Type b) {
        if (a is null || b is null) return a is b;
        if (a.name != b.name || a.pointerDepth != b.pointerDepth ||
                a.isArray != b.isArray || a.arraySize != b.arraySize) {
            return false;
        }
        if (a.extraDims != b.extraDims || a.typeArgs.length != b.typeArgs.length) return false;
        foreach (i; 0 .. a.typeArgs.length) {
            if (!sameInferredArrayElementType(a.typeArgs[i], b.typeArgs[i])) return false;
        }
        return true;
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

    // `[2][3]`-style suffix for a fixed array's *extra* nested dimensions
    // (see ast.Type.extraDims) - the outer `[N]` is emitted by each call
    // site itself (arraySize), this is just what comes after it.
    private string extraDimsSuffix(Type t) {
        string s = "";
        foreach (dim; t.extraDims) s ~= format("[%d]", dim);
        return s;
    }

    private Type arrayElementType(Type arrType) {
        auto elemType = new Type(arrType.name, arrType.pointerDepth, false, 0);
        if (arrType.extraDims.length > 0) {
            elemType.isArray = true;
            elemType.arraySize = arrType.extraDims[0];
            elemType.extraDims = arrType.extraDims[1 .. $].dup;
        }
        return elemType;
    }

    private string fixedArrayElementCType(Type type) {
        string baseType = primitiveToC(type.name);

        // A fixed array of class-typed values is an array of object
        // references, not inline class structs: `Thing slots[4]` must become
        // `Thing* slots[4]`. An explicit `Thing*[4]` already contributes the
        // same single star through pointerStars(), matching typeToC's
        // class-pointer collapse for scalar values.
        if (!type.isPointer && isClassTypeName(type.name)) {
            baseType ~= "*";
        }

        baseType ~= pointerStars(type);
        return baseType;
    }

    private string typedParameterDeclaration(Type type, string name) {
        if (type.isArray && type.arraySize > 0) {
            string baseType = fixedArrayElementCType(type);
            return format("%s %s[%d]%s", baseType, name, type.arraySize, extraDimsSuffix(type));
        }
        return format("%s %s", typeToC(type), name);
    }

    private string parameterDeclaration(Parameter param) {
        return typedParameterDeclaration(param.type, param.name);
    }

    private string primitiveToC(string name) {
        switch (name) {
            case "i64": return "int64_t";    // 64-bit signed
            case "u64": return "uint64_t";   // 64-bit unsigned
            case "i8": case "int8": return "int8_t";
            // u8 is a genuinely numeric unsigned byte (matching every other
            // sized unsigned integer's mapping to a real C integer type) -
            // distinct from `char`, which is the text/string byte type (see
            // primitiveToC's caller comments and interpFormatSpecifier/
            // generateMatch/implicitConversionKind, all of which key off the
            // literal name "char" for string semantics, not "u8").
            case "u8": case "uint8": return "uint8_t";
            case "char": return "char";
            // A third, separate integer family from the fixed-width ones
            // above - native machine-word-sized (4 bytes on i386, 8 on
            // x86_64), matching C's own `intptr_t`/`uintptr_t` exactly by
            // construction (unlike C's plain `int`, which stays 32-bit even
            // on 64-bit Linux/macOS - intptr_t/uintptr_t are what's
            // guaranteed pointer/word-sized on every target, including
            // Windows' LLP64 model where plain `long` isn't). See
            // integerRank's own comment on why these don't participate in
            // the same-signedness width-widening coercion.
            case "int": return "intptr_t";
            case "uint": return "uintptr_t";
            case "i16": case "int16": return "int16_t";
            case "u16": case "uint16": return "uint16_t";
            case "i32": case "int32": return "int32_t";
            case "u32": case "uint32": return "uint32_t";
            // "int64"/"uint64" (unlike the u8/u16/.../i64 short forms,
            // which the parser always rewrites to a long form before
            // codegen ever sees them - see isPrimitiveTypeName's own
            // comment) were never a recognized type at all before: this
            // fell through to the `default: return name` case below,
            // silently emitting the literal, meaningless C type name
            // "int64"/"uint64" - a real bug, not just an unsupported
            // alias, since `func f() -> uint64 {...}` compiled at the
            // LLPL level but produced invalid C (see this file's own
            // git history for the exact "uint64*" garbage this produced
            // in a generated SDL binding).
            case "int64": return "int64_t";
            case "uint64": return "uint64_t";
            case "string": return "char*";
            case "bool": return "bool"; // real C99 boolean (<stdbool.h>,
                                        // included below in generateMultiple) -
                                        // not "int", so an `extern func ... ->
                                        // bool` binding to a real C library
                                        // (e.g. SDL3, which returns actual
                                        // bool from many of its own functions)
                                        // doesn't conflict with that library's
                                        // own header declaration - see the SDL
                                        // stdlib bindings (stdlib/sdl/*.llpl)
            case "void": return "void";
            // f32/f64 (see canonicalIntTypeName) are what a parsed type
            // annotation actually is by the time it gets here; float/double
            // stay recognized too, for any Type built with the pre-rewrite
            // spelling directly.
            case "f32": case "float": return "float";
            case "f64": case "double": return "double";
            default: return name;
        }
    }

    private Type futureValueType(Type futureType) {
        if (futureType.typeArgs.length == 1 &&
                (futureType.name == "Future" || futureType.name == "AsyncFuture")) {
            return cloneType(futureType.typeArgs[0]);
        }
        if (futureType.name == "SleepFuture") {
            return new Type("int");
        }
        string suffix = "";
        if (futureType.name.startsWith("Future_")) {
            suffix = futureType.name["Future_".length .. $];
        } else if (futureType.name.startsWith("AsyncFuture_")) {
            suffix = futureType.name["AsyncFuture_".length .. $];
        }
        if (suffix.length > 0) {
            switch (suffix) {
                case "int": return new Type("int");
                case "uint": return new Type("uint");
                case "i64": return new Type("i64");
                case "u64": return new Type("u64");
                case "i32": return new Type("i32");
                case "u32": return new Type("u32");
                case "i16": return new Type("i16");
                case "u16": return new Type("u16");
                case "i8": return new Type("i8");
                case "u8": return new Type("u8");
                case "char": return new Type("char");
                case "bool": return new Type("bool");
                case "f32": return new Type("f32");
                case "f64": return new Type("f64");
                default: return new Type(suffix);
            }
        }
        return null;
    }

    private string typeToC(Type type) {
        string cType = primitiveToC(type.name);

        // A "dynamic array" (`T[]`, isArray with no fixed arraySize - see
        // Type's own field comments) is the growable-buffer shape Vector<T>
        // and Slice<T> use for their raw backing storage: unlike a
        // fixed-size `T[N]` field (handled entirely differently, in
        // fieldDeclaration, and never reaching here), a dynamic array has
        // no size to declare inline in C, so it's always a genuine
        // pointer - and unlike an ordinary `T*` (ast.d's own "classes are
        // always pointers" rule collapses a class's implicit pointer and
        // an explicit `*` into the same single star - see e.g. trie.llpl's
        // `TrieNode*`, which relies on exactly that collapse to manage its
        // own memory by hand), a dynamic array of a class T genuinely
        // needs *two* levels: one for the array itself, one because each
        // element is its own separate heap object (`String**`, not
        // `String*`) - so the class-pointer rule below must NOT be
        // suppressed for it the way it is for a fixed-size array.
        bool isDynamicArray = type.isArray && type.arraySize == 0;

        // Classes are always heap-allocated and accessed by pointer; structs
        // and unions are plain value types with no such auto-pointering.
        if (!isPrimitiveTypeName(type.name) && !isStructTypeName(type.name) && !isUnionTypeName(type.name)) {
            if ((!type.isPointer && !type.isArray) || isDynamicArray) {
                cType ~= "*"; // Classes are always pointers
            }
        }

        // The dynamic array itself is a raw, growable C pointer - one
        // more star on top of whatever the element type just contributed.
        if (isDynamicArray) {
            cType ~= "*";
        }

        cType ~= pointerStars(type);

        // Don't add array notation here - it's handled specially in var declarations
        // because C requires array size after variable name

        return cType;
    }
}
