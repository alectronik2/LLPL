module ast;

import std.variant;
import std.conv;
import std.array : replicate;

enum NodeType {
    Program,
    ImportStmt,
    NamespaceDecl,
    AliasDecl,
    FunctionDecl,
    ClassDecl,
    StructDecl,
    EnumDecl,
    VarDecl,
    IfStmt,
    WhileStmt,
    ForStmt,
    ForeachStmt,
    ReturnStmt,
    DeferStmt,
    AsmStmt,
    MatchStmt,
    Block,
    ExprStmt,
    BinaryExpr,
    UnaryExpr,
    CallExpr,
    MemberExpr,
    IndexExpr,
    Identifier,
    IntLiteral,
    StringLiteral,
    RegexLiteral,
    BoolLiteral,
    NullLiteral,
    NewExpr,
    CastExpr,
    MacroDecl,
    MacroInvocation,
    QuoteExpr,
    UnquoteExpr,
    InterpolatedStringLiteral,
    ArrayLiteral,
    LambdaExpr,
    SizeofExpr,
    StructLiteral,
    TupleLiteral,
    PropagateExpr,
    TraitDecl,
    ImplDecl,
    DestructuringStmt,
    PatternExpr,
    TryStmt,
    ThrowStmt,
    IfExpr
}

abstract class ASTNode {
    NodeType type;
    int line;
    int column;

    this(NodeType type, int line = 0, int column = 0) {
        this.type = type;
        this.line = line;
        this.column = column;
    }
}

class Program : ASTNode {
    ASTNode[] declarations;
    string modulePath;  // Path of this module

    this(ASTNode[] declarations, string modulePath = "") {
        super(NodeType.Program);
        this.declarations = declarations;
        this.modulePath = modulePath;
    }
}

struct ImportedName {
    string original;
    string alias_;  // empty means no local alias

    this(string original, string alias_ = "") {
        this.original = original;
        this.alias_ = alias_;
    }
}

class ImportStmt : ASTNode {
    string modulePath;
    string alias_;       // Optional module alias
    string resolvedPath; // Absolute path, filled in by ModuleResolver
    ImportedName[] names;
    bool isSelective;

    this(string modulePath, string alias_ = "", ImportedName[] names = [], bool isSelective = false, int line = 0, int column = 0) {
        super(NodeType.ImportStmt, line, column);
        this.modulePath = modulePath;
        this.alias_ = alias_;
        this.names = names;
        this.isSelective = isSelective;
    }
}

// A `namespace Name { ... }` block. Resolved away by the code generator,
// which flattens its declarations into the top level with mangled names.
class NamespaceDecl : ASTNode {
    string name;
    ASTNode[] declarations;

    this(string name, ASTNode[] declarations, int line = 0, int column = 0) {
        super(NodeType.NamespaceDecl, line, column);
        this.name = name;
        this.declarations = declarations;
    }
}

// `alias name = a.b.c` - a new name for an existing (possibly
// namespace-qualified) function, global, class or struct. Resolved by the
// code generator to a `#define`, since it needs to work for variadic
// functions too (which can't be wrapped by an ordinary forwarding function
// without va_list plumbing).
//
// Also doubles as a *type* alias when the target has a `*`/`[...]` suffix
// or is a bare primitive name (`alias string = char*`, `alias Bytes =
// char[256]`, `alias Cell = int`): there's no symbol to point a #define
// at, so the code generator instead registers `name` to substitute for
// `targetPath`/`targetPointerDepth`/`targetIsArray`/`targetArraySize`
// wherever it's resolved as a *type* (see CodeGenerator.resolveType and
// the `typeAliases` map). `targetPath` a dotted class/struct name with no
// such suffix still goes through the plain symbol-alias path above,
// unchanged - that already works via the class/struct registry copy.
class AliasDecl : ASTNode {
    string name;
    string[] targetPath;
    int targetPointerDepth;
    bool targetIsArray;
    int targetArraySize;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, string[] targetPath, int targetPointerDepth = 0, bool targetIsArray = false,
         int targetArraySize = 0, int line = 0, int column = 0) {
        super(NodeType.AliasDecl, line, column);
        this.name = name;
        this.targetPath = targetPath;
        this.targetPointerDepth = targetPointerDepth;
        this.targetIsArray = targetIsArray;
        this.targetArraySize = targetArraySize;
    }
}

// `macro NAME(params) { statements }` - a block of statements with named
// placeholders, expanded inline at each `NAME!(args)` call site by the code
// generator (see CodeGenerator.generateMacroExpansion). Purely a
// compile-time template: it never becomes a real C function, so there's no
// forward declaration, no type-checked signature, and no call overhead -
// each invocation just splices a fresh, argument-substituted copy of the
// body into place, wrapped in its own `{ }` block for scoping.
class MacroDecl : ASTNode {
    string name;
    string[] params;
    Block body_;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, string[] params, Block body_, int line = 0, int column = 0) {
        super(NodeType.MacroDecl, line, column);
        this.name = name;
        this.params = params;
        this.body_ = body_;
    }
}

// `NAME!(args)` or `Ns.NAME!(args)` - invokes a macro. `name` is already
// flattened to its underscore-joined form by the parser (mirroring how
// parseType flattens dotted type names), so the code generator can resolve
// it exactly like any other namespaced declaration: exact match first, then
// each enclosing namespace scope.
class MacroInvocation : ASTNode {
    string name;
    ASTNode[] args;

    this(string name, ASTNode[] args, int line = 0, int column = 0) {
        super(NodeType.MacroInvocation, line, column);
        this.name = name;
        this.args = args;
    }
}

// `quote(expr)` or `quote { statements }` inside a macro. Quoted syntax is
// copied literally at expansion time; macro parameters only splice into it
// through explicit `unquote(...)` nodes.
class QuoteExpr : ASTNode {
    ASTNode body;
    bool isBlock;

    this(ASTNode body, bool isBlock, int line = 0, int column = 0) {
        super(NodeType.QuoteExpr, line, column);
        this.body = body;
        this.isBlock = isBlock;
    }
}

// `unquote(expr)` inside quoted macro syntax. The compiler supports the
// useful compile-time subset today: `expr` may be a macro parameter (splices
// that argument AST) or an expression built from parameters/literals, which
// is cloned with normal macro-parameter substitution.
class UnquoteExpr : ASTNode {
    ASTNode expression;

    this(ASTNode expression, int line = 0, int column = 0) {
        super(NodeType.UnquoteExpr, line, column);
        this.expression = expression;
    }
}

class Type {
    string name;
    // Levels of indirection: 0 = not a pointer, 1 = `T*`, 2 = `T**`, ...
    int pointerDepth;
    bool isArray;
    int arraySize;

    // Read-only on purpose (no setter) - lets every existing simple
    // boolean check ("is this a pointer at all") keep working unchanged,
    // while the D compiler flags any attempted *assignment* to `isPointer`
    // as a compile error: those are exactly the call sites that need to
    // be upgraded to real depth arithmetic (`pointerDepth`) instead,
    // rather than silently collapsing back down to a single flag - see
    // codegen.d's resolveType/cloneType for the two places that used to
    // do exactly that (documented there as "no way to represent pointer
    // to pointer in this single-flag Type model").
    @property bool isPointer() const {
        return pointerDepth > 0;
    }

    // Parsed `<T1, T2, ...>` type arguments, e.g. `Vector<int>` parses to
    // Type("Vector", typeArgs: [Type("int")]). Empty for every ordinary,
    // non-generic type. See codegen.d's resolveType: once the instantiation
    // this refers to has been monomorphized, `name` is rewritten in place
    // to the concrete mangled name (e.g. "Vector_int") and typeArgs is
    // cleared, so every other pass (typeToC, isStructTypeName, ...) never
    // needs to know generics exist at all.
    Type[] typeArgs;

    // Set only when `name == "__LLPL_Closure"` (see parser.d's closure-type
    // syntax `(T1, T2) -> R` and codegen.d's generateLambdaExpr): the actual
    // parameter/return types of the closure, since every closure otherwise
    // shares the same two-word `__LLPL_Closure { fn, env }` runtime shape.
    // `closureParams` only ever uses each Parameter's `type` field - there
    // are no real parameter names to carry, since a closure *type* (as
    // opposed to a lambda literal) never names its parameters.
    Parameter[] closureParams;
    Type closureReturnType;

    // Set only by parser.d's trailing `T?` sugar (never by writing
    // `Optional<T>` out directly) - `T?` parses to the exact same
    // Type("Optional", typeArgs: [T]) that spelling it out would, plus
    // this flag. codegen.d's generateStatement/generateExpression check it
    // to auto-wrap a plain value (or `null`) into a real Optional<T> at a
    // `let`/assignment site, which is what makes `T?` "sugar" rather than
    // just a shorter way to spell the same explicit new+set() dance.
    bool isNullableSugar;

    this(string name, int pointerDepth = 0, bool isArray = false, int arraySize = 0) {
        this.name = name;
        this.pointerDepth = pointerDepth;
        this.isArray = isArray;
        this.arraySize = arraySize;
    }

    override string toString() const {
        if (closureReturnType !is null) {
            string result = "(";
            foreach (i, p; closureParams) {
                if (i > 0) result ~= ", ";
                result ~= p.type.toString();
            }
            result ~= ") -> " ~ closureReturnType.toString();
            return result;
        }
        // Pretty-print compiler-internal tuple types as (T, U, ...).
        if (name.length > 13 && name[0 .. 13] == "__LLPL_Tuple" && typeArgs.length > 0) {
            string result = "(";
            foreach (i, arg; typeArgs) {
                if (i > 0) result ~= ", ";
                result ~= arg.toString();
            }
            result ~= ")";
            result ~= "*".replicate(pointerDepth);
            if (isArray) result ~= "[]";
            return result;
        }
        string result = name;
        if (typeArgs.length > 0) {
            result ~= "<";
            foreach (i, arg; typeArgs) {
                if (i > 0) result ~= ", ";
                result ~= arg.toString();
            }
            result ~= ">";
        }
        result ~= "*".replicate(pointerDepth);
        if (isArray) result ~= "[]";
        return result;
    }
}

class Parameter {
    string name;
    Type type;
    // null if this parameter is required; otherwise the expression spliced
    // into a call's generated argument list whenever the caller omits it -
    // see codegen.d's resolveCallArguments. Resolved entirely at each call
    // site, at compile time - the callee's own generated C signature never
    // changes, so this works uniformly for extern functions too.
    ASTNode defaultValue;

    this(string name, Type type, ASTNode defaultValue = null) {
        this.name = name;
        this.type = type;
        this.defaultValue = defaultValue;
    }
}

class FunctionDecl : ASTNode {
    string name;
    Parameter[] params;
    Type returnType;
    Block body_;
    bool isExtern;
    bool isInterrupt; // `interrupt func` - emitted as a GCC interrupt handler
    bool isVariadic; // Trailing `...` in the parameter list
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    // `<T, U>` after the function name - see codegen.d's monomorphization
    // engine. Empty for an ordinary, non-generic function; a non-empty
    // FunctionDecl is never generated directly, only its type-substituted
    // clones are (see instantiateGenericFunction).
    string[] typeParams;
    // Parallel to typeParams (same length): `<T: TraitName, U>`'s optional
    // per-parameter trait bound, "" when a parameter is unbounded. Checked
    // at monomorphization time against codegen.d's traitImplemented
    // registry - see processImplBlock. A separate parallel array, not a
    // richer TypeParam[] replacing typeParams itself, so every existing
    // reader of .typeParams (LSP signatures, cloning, mangling) needed no
    // changes when trait bounds were added.
    string[] typeParamBounds;

    this(string name, Parameter[] params, Type returnType, Block body_, bool isExtern = false,
         bool isInterrupt = false, bool isVariadic = false, int line = 0, int column = 0,
         string[] typeParams = [], string[] typeParamBounds = []) {
        super(NodeType.FunctionDecl, line, column);
        this.name = name;
        this.params = params;
        this.returnType = returnType;
        this.body_ = body_;
        this.isExtern = isExtern;
        this.isInterrupt = isInterrupt;
        this.isVariadic = isVariadic;
        this.typeParams = typeParams;
        this.typeParamBounds = typeParamBounds;
    }
}

class ClassDecl : ASTNode {
    string name;
    VarDecl[] fields;
    FunctionDecl constructor;
    FunctionDecl destructor;
    FunctionDecl[] methods;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    string[] typeParams; // `<T, U>` after the class name - see FunctionDecl.typeParams
    string[] typeParamBounds; // parallel to typeParams - see FunctionDecl.typeParamBounds
    VarAttribute[] attributes;

    this(string name, VarDecl[] fields, FunctionDecl constructor, FunctionDecl destructor, FunctionDecl[] methods,
         int line = 0, int column = 0, string[] typeParams = [], string[] typeParamBounds = [],
         VarAttribute[] attributes = []) {
        super(NodeType.ClassDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.constructor = constructor;
        this.destructor = destructor;
        this.methods = methods;
        this.typeParams = typeParams;
        this.typeParamBounds = typeParamBounds;
        this.attributes = attributes;
    }
}

// A plain value-type aggregate: no ref-counting header, no heap allocation,
// no constructor/destructor. Compiles to a bare C struct, usable as a
// stack/global value, array element, or (with `packed`) a hardware-layout
// descriptor like a GDT/IDT entry. Can't declare methods *inline* the way
// a class can, but can still gain real methods from an external
// `impl Trait for StructName { ... }` block (see codegen.d's
// processImplBlock) - those are generated as ordinary top-level functions
// taking this struct by value as an explicit first parameter, not stored
// anywhere on StructDecl itself.
class StructDecl : ASTNode {
    string name;
    VarDecl[] fields;
    bool packed;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    string[] typeParams; // `<T, U>` after the struct name - see FunctionDecl.typeParams
    string[] typeParamBounds; // parallel to typeParams - see FunctionDecl.typeParamBounds
    VarAttribute[] attributes;

    this(string name, VarDecl[] fields, bool packed = false, int line = 0, int column = 0,
         string[] typeParams = [], string[] typeParamBounds = [], VarAttribute[] attributes = []) {
        super(NodeType.StructDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.packed = packed;
        this.typeParams = typeParams;
        this.typeParamBounds = typeParamBounds;
        this.attributes = attributes;
    }
}

// `trait Name { func sig(...) -> T  ... }` - a compile-time-only contract:
// a list of required method signatures, never generated as code itself
// (each method's `body_` is always null, the same way ClassDecl's
// constructor/destructor are nullable). Only ever used to validate that an
// `impl TraitName for SomeType { ... }` block (see ImplDecl) actually
// provides every required method, and to gate a bounded generic type
// parameter (`<T: Name>`) at monomorphization time - see codegen.d's
// traitRegistry/traitImplemented and processImplBlock. `Self`, when used
// in a trait method's own parameter/return types, refers to whatever
// concrete type ends up implementing this trait - it isn't a reserved
// keyword, just a name resolved by string comparison wherever a type is
// being substituted (the same mechanism generic type parameters already
// use), so it needs no lexer support of its own.
class TraitDecl : ASTNode {
    string name;
    FunctionDecl[] methods;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, FunctionDecl[] methods, int line = 0, int column = 0) {
        super(NodeType.TraitDecl, line, column);
        this.name = name;
        this.methods = methods;
    }
}

// `impl TraitName for TargetType { func method(...) -> T { body } ... }` -
// gives `targetType` (a primitive, class, or plain struct - never a
// generic type; see codegen.d's processImplBlock for that restriction)
// real methods with real bodies, satisfying `traitName`'s contract.
// codegen.d desugars each method into an ordinary top-level function
// (`TargetType_methodName`, with an explicit `self: TargetType` parameter
// prepended) rather than storing these anywhere on a ClassDecl/StructDecl -
// this is the only way a *struct* or *primitive* type can ever gain a
// method at all, since neither has an inline method-declaration syntax.
class ImplDecl : ASTNode {
    string traitName;
    Type targetType;
    FunctionDecl[] methods;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string traitName, Type targetType, FunctionDecl[] methods, int line = 0, int column = 0) {
        super(NodeType.ImplDecl, line, column);
        this.traitName = traitName;
        this.targetType = targetType;
        this.methods = methods;
    }
}

// One `Name(field: type, ...)` (or bare `Name`, zero fields) variant of a
// tagged enum. Reuses `Parameter` for fields - a variant's field list is
// parsed exactly like a function's parameter list (see parser.d's
// enumDecl(), which calls the same paramList() a function declaration
// does).
class EnumVariant {
    string name;
    Parameter[] fields;
    int line;
    int column;

    this(string name, Parameter[] fields, int line = 0, int column = 0) {
        this.name = name;
        this.fields = fields;
        this.line = line;
        this.column = column;
    }
}

// `enum Name { Variant(field: type, ...), Other, ... }` - a tagged union
// (sum type): each variant can carry its own, independently-typed data,
// unlike a plain `enum` (still just a namespace of int consts, sugar
// resolved entirely in the parser - this node never appears for that
// form). codegen.d desugars this into a struct (a `tag` field plus every
// variant's fields, flattened and name-prefixed to avoid clashes between
// variants) and one constructor function per variant, then `match`
// recognizes `case EnumName.Variant(binding, ...)` as a destructuring
// pattern against that same encoding - see codegen.d's desugarTaggedEnum
// and generateMatch.
class EnumDecl : ASTNode {
    string name;
    EnumVariant[] variants;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, EnumVariant[] variants, int line = 0, int column = 0) {
        super(NodeType.EnumDecl, line, column);
        this.name = name;
        this.variants = variants;
    }
}

class VarDecl : ASTNode {
    string name;
    Type type;
    ASTNode initializer;
    bool isConst;
    // Forces every read/write of this variable to actually touch memory,
    // instead of letting the optimizer cache it in a register indefinitely
    // (e.g. across loop iterations) - needed for anything another
    // execution context (an interrupt handler, a preempted task) can
    // observe or modify without this code's knowledge, since from the
    // optimizer's single-threaded viewpoint such a store looks dead. Maps
    // straight to C's `volatile`.
    bool isVolatile;
    int bitWidth = -1; // -1 means "not a bit-field"; only meaningful for class fields
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    VarAttribute[] attributes;

    this(string name, Type type, ASTNode initializer = null, bool isConst = false, int line = 0, int column = 0,
         int bitWidth = -1, bool isVolatile = false, VarAttribute[] attributes = []) {
        super(NodeType.VarDecl, line, column);
        this.name = name;
        this.type = type;
        this.initializer = initializer;
        this.isConst = isConst;
        this.bitWidth = bitWidth;
        this.isVolatile = isVolatile;
        this.attributes = attributes;
    }
}

class VarAttribute {
    string name;
    string stringValue;
    long intValue;
    bool hasStringValue;
    bool hasIntValue;
    int line;
    int column;

    this(string name, int line = 0, int column = 0) {
        this.name = name;
        this.line = line;
        this.column = column;
    }
}

// Patterns are used only by DestructuringStmt; they are not ASTNodes
// themselves but refer to source locations and names.
abstract class Pattern {
    int line;
    int column;

    this(int line = 0, int column = 0) {
        this.line = line;
        this.column = column;
    }
}

class BindingPattern : Pattern {
    string name;

    this(string name, int line = 0, int column = 0) {
        super(line, column);
        this.name = name;
    }
}

class WildcardPattern : Pattern {
    this(int line = 0, int column = 0) {
        super(line, column);
    }
}

class TuplePattern : Pattern {
    Pattern[] elements;

    this(Pattern[] elements, int line = 0, int column = 0) {
        super(line, column);
        this.elements = elements;
    }
}

class StructPattern : Pattern {
    Type type;
    string[] fieldNames;

    this(Type type, string[] fieldNames, int line = 0, int column = 0) {
        super(line, column);
        this.type = type;
        this.fieldNames = fieldNames;
    }
}

// `let (a, b) = expr` or `let Point { x, y } = expr`.
// Simple single-name bindings are still represented as VarDecl; this node
// is only produced for non-trivial patterns.
class DestructuringStmt : ASTNode {
    Pattern pattern;
    Type type;            // optional explicit annotation for the RHS
    ASTNode initializer;
    bool isConst;
    bool isVolatile;

    this(Pattern pattern, Type type, ASTNode initializer, bool isConst, bool isVolatile,
         int line = 0, int column = 0) {
        super(NodeType.DestructuringStmt, line, column);
        this.pattern = pattern;
        this.type = type;
        this.initializer = initializer;
        this.isConst = isConst;
        this.isVolatile = isVolatile;
    }
}

class Block : ASTNode {
    ASTNode[] statements;

    this(ASTNode[] statements) {
        super(NodeType.Block);
        this.statements = statements;
    }
}

class IfStmt : ASTNode {
    ASTNode condition;
    Block thenBlock;
    Block elseBlock;

    this(ASTNode condition, Block thenBlock, Block elseBlock = null) {
        super(NodeType.IfStmt);
        this.condition = condition;
        this.thenBlock = thenBlock;
        this.elseBlock = elseBlock;
    }
}

// `if <cond> { ...; expr } else { ...; expr }` used as an expression, not
// a statement - e.g. `let x = if cond { 128 } else { 256 }`. Distinct from
// IfStmt in two ways: `else` is mandatory (there's no sensible value for a
// branch that was never taken), and each block's *last* statement must be
// an expression (an ExprStmt) - that trailing expression supplies this
// construct's value (earlier statements in the same branch still run for
// their side effects/bindings, they just can't supply the value
// themselves; see codegen.d's ifExprBranchValue). Both branches' trailing
// expressions must resolve to the same type (see codegen.d's
// inferIfExprType) - there's no implicit widening, matching the rest of
// this compiler's "nominal, single-type" simplifications.
class IfExpr : ASTNode {
    ASTNode condition;
    Block thenBlock;
    Block elseBlock;

    this(ASTNode condition, Block thenBlock, Block elseBlock, int line = 0, int column = 0) {
        super(NodeType.IfExpr, line, column);
        this.condition = condition;
        this.thenBlock = thenBlock;
        this.elseBlock = elseBlock;
    }
}

class WhileStmt : ASTNode {
    ASTNode condition;
    Block body_;

    this(ASTNode condition, Block body_) {
        super(NodeType.WhileStmt);
        this.condition = condition;
        this.body_ = body_;
    }
}

class ForStmt : ASTNode {
    ASTNode initializer;
    ASTNode condition;
    ASTNode update;
    Block body_;

    this(ASTNode initializer, ASTNode condition, ASTNode update, Block body_) {
        super(NodeType.ForStmt);
        this.initializer = initializer;
        this.condition = condition;
        this.update = update;
        this.body_ = body_;
    }
}

// `foreach let varName in iterable { body }` - iterable is either a
// fixed-size array (`T[N]`, N known at compile time) or a class instance
// implementing the iterator protocol (see codegen.d's ITER_HAS_NEXT/
// ITER_NEXT/ITER_RESET method names). varName's type is inferred, never
// explicitly annotated - from the array's element type, or from
// iter_next()'s return type.
class ForeachStmt : ASTNode {
    string varName;
    ASTNode iterable;
    Block body_;

    this(string varName, ASTNode iterable, Block body_, int line = 0, int column = 0) {
        super(NodeType.ForeachStmt, line, column);
        this.varName = varName;
        this.iterable = iterable;
        this.body_ = body_;
    }
}

class ReturnStmt : ASTNode {
    ASTNode value;

    this(ASTNode value = null) {
        super(NodeType.ReturnStmt);
        this.value = value;
    }
}

class DeferStmt : ASTNode {
    ASTNode statement;

    this(ASTNode statement) {
        super(NodeType.DeferStmt);
        this.statement = statement;
    }
}

// `try { ... } catch (e: T) { ... } finally { ... }` and `throw value`
// lower to LLPL's small SJLJ runtime, not platform ABI/DWARF unwinding.
// The runtime keeps an explicit handler stack and uses an x86_64 register
// save/restore jump buffer, so throws can cross LLPL function boundaries on
// hosted and freestanding targets without libc. A failed Result<T, E>? inside
// the same function's try block still uses the cheaper local redirect path.
//
// `catchBlock`/`finallyBlock` are each independently optional, but at
// least one must be present (enforced by the parser) - a bare `try { }`
// with neither would do nothing. `catchVar`'s type is inferred from
// Cross-function throws need an explicit catch type (`catch (e: int)`) because
// the parser cannot infer a callee's possible thrown values from a plain call.
// Local throw/? paths can still infer the catch type when no annotation is
// present. One try block catches one error type, since LLPL has no error-union
// type.
// Deliberately scoped to `Result<T, E>` only, not `Optional<T>` - `None`
// carries no error *value* to bind `catchVar` to; a plain `?`/`is_none()`
// on an Optional still works fine inside a `try`, it just isn't caught by
// that try's `catch` (propagates out of the enclosing function exactly
// like it does today, unaffected by an enclosing try aimed at a Result).
class TryStmt : ASTNode {
    Block tryBlock;
    string catchVar;    // "" if there's no catch clause
    Type catchType;     // Optional explicit `catch (e: T)` type
    Block catchBlock;   // null if there's no catch clause
    Block finallyBlock; // null if there's no finally clause

    this(Block tryBlock, string catchVar, Type catchType, Block catchBlock, Block finallyBlock,
            int line = 0, int column = 0) {
        super(NodeType.TryStmt, line, column);
        this.tryBlock = tryBlock;
        this.catchVar = catchVar;
        this.catchType = catchType;
        this.catchBlock = catchBlock;
        this.finallyBlock = finallyBlock;
    }
}

class ThrowStmt : ASTNode {
    ASTNode value;

    this(ASTNode value, int line = 0, int column = 0) {
        super(NodeType.ThrowStmt, line, column);
        this.value = value;
    }
}

// A single GCC-style extended-asm operand: "constraint"(expression).
class AsmOperand {
    string constraint;
    ASTNode expr;

    this(string constraint, ASTNode expr) {
        this.constraint = constraint;
        this.expr = expr;
    }
}

// `asm("template" : outputs : inputs : clobbers)`. Any of the operand/clobber
// lists may be empty; trailing empty sections may be omitted entirely.
class AsmStmt : ASTNode {
    string[] templateLines;
    AsmOperand[] outputs;
    AsmOperand[] inputs;
    string[] clobbers;

    this(string[] templateLines, AsmOperand[] outputs, AsmOperand[] inputs, string[] clobbers,
         int line = 0, int column = 0) {
        super(NodeType.AsmStmt, line, column);
        this.templateLines = templateLines;
        this.outputs = outputs;
        this.inputs = inputs;
        this.clobbers = clobbers;
    }
}

// One `case P1, P2 => { ... }` arm. An empty `patterns` array marks the
// `default => { ... }` catch-all arm.
class MatchCase {
    ASTNode[] patterns;
    Block body_;

    this(ASTNode[] patterns, Block body_) {
        this.patterns = patterns;
        this.body_ = body_;
    }
}

// `match <subject> { case P => B ... default => B }`. Patterns are compared
// against the subject with content equality (strcmp for char*, == for
// everything else); there's no C-style fallthrough between arms.
class MatchStmt : ASTNode {
    ASTNode subject;
    MatchCase[] cases;

    this(ASTNode subject, MatchCase[] cases, int line = 0, int column = 0) {
        super(NodeType.MatchStmt, line, column);
        this.subject = subject;
        this.cases = cases;
    }
}

class ExprStmt : ASTNode {
    ASTNode expression;

    this(ASTNode expression) {
        super(NodeType.ExprStmt);
        this.expression = expression;
    }
}

class BinaryExpr : ASTNode {
    string op;
    ASTNode left;
    ASTNode right;

    this(string op, ASTNode left, ASTNode right, int line = 0, int column = 0) {
        super(NodeType.BinaryExpr, line, column);
        this.op = op;
        this.left = left;
        this.right = right;
    }
}

class UnaryExpr : ASTNode {
    string op;
    ASTNode operand;

    this(string op, ASTNode operand, int line = 0, int column = 0) {
        super(NodeType.UnaryExpr, line, column);
        this.op = op;
        this.operand = operand;
    }
}

class CallExpr : ASTNode {
    ASTNode callee;
    ASTNode[] args;
    // Parallel to args: "" for a positional argument, the parameter name
    // for a `name: value` named argument - see codegen.d's
    // resolveCallArguments. Empty (never indexed) when every argument is
    // positional, the only shape this had before named arguments existed.
    string[] argNames;

    this(ASTNode callee, ASTNode[] args, int line = 0, int column = 0, string[] argNames = null) {
        super(NodeType.CallExpr, line, column);
        this.callee = callee;
        this.args = args;
        this.argNames = argNames;
    }
}

class MemberExpr : ASTNode {
    ASTNode object;
    string member;

    this(ASTNode object, string member, int line = 0, int column = 0) {
        super(NodeType.MemberExpr, line, column);
        this.object = object;
        this.member = member;
    }
}

class IndexExpr : ASTNode {
    ASTNode array;
    ASTNode index;

    this(ASTNode array, ASTNode index, int line = 0, int column = 0) {
        super(NodeType.IndexExpr, line, column);
        this.array = array;
        this.index = index;
    }
}

// `[e1, e2, ...]` - only meaningful as a `let`/`const` array initializer
// (`let font: char[8] = [0, 24, 60, ...]`); the code generator rejects it
// anywhere else, since C only allows brace-init syntax in a declaration,
// not as a general expression.
class ArrayLiteral : ASTNode {
    ASTNode[] elements;

    this(ASTNode[] elements, int line = 0, int column = 0) {
        super(NodeType.ArrayLiteral, line, column);
        this.elements = elements;
    }
}

class Identifier : ASTNode {
    string name;

    this(string name, int line = 0, int column = 0) {
        super(NodeType.Identifier, line, column);
        this.name = name;
    }
}

// One named capture in a lambda literal's `[...]` list. `byRef` stores the
// variable by address so the lambda sees later mutations (and can mutate the
// original); otherwise the variable's current value is copied into the
// environment at lambda-creation time, exactly like the original behaviour.
class Capture {
    string name;
    bool byRef;

    this(string name, bool byRef = false) {
        this.name = name;
        this.byRef = byRef;
    }
}

// `func[cap1, cap2](params) -> T { ... }` - a lambda literal. `captures`
// names existing variables (from the enclosing scope); by default each
// capture's *current value* is snapshotted by value into a heap-allocated
// environment struct at the point the lambda expression is evaluated. A
// capture prefixed with `&` is stored by reference instead, so the lambda
// sees later mutations and can mutate the original variable. The lambda body
// reads captures from that environment, never from the enclosing scope
// directly (see codegen.d's generateLambdaExpr). Capture lists are explicit,
// not inferred, so a capture that's missing is a compile error ("Unknown
// capture") rather than a silently-wrong closure.
class LambdaExpr : ASTNode {
    Capture[] captures;
    Parameter[] params;
    Type returnType;
    Block body_;

    this(Capture[] captures, Parameter[] params, Type returnType, Block body_, int line = 0, int column = 0) {
        super(NodeType.LambdaExpr, line, column);
        this.captures = captures;
        this.params = params;
        this.returnType = returnType;
        this.body_ = body_;
    }
}

class IntLiteral : ASTNode {
    long value;

    this(long value, int line = 0, int column = 0) {
        super(NodeType.IntLiteral, line, column);
        this.value = value;
    }
}

// One `\(expr[:width][:radix])` interpolation's optional formatting:
// `radix` is "" (plain decimal, the default), "hex", "oct", or "bin";
// `width` is 0 (no minimum width) or a minimum field width; `zeroPad`
// selects '0' vs ' ' as the pad character when the rendered value is
// shorter than `width` (set when the width digits were written with a
// leading zero, e.g. the "016" in `\(n:016:hex)`, matching printf's own
// `%016x` convention). Set by Parser.splitInterpolationFormat.
struct InterpFormat {
    string radix;
    int width;
    bool zeroPad;
}

// `"literal \(expr) literal \(expr) literal"` - `literalParts` always has
// one more element than `expressions` (the text before the first `\(`,
// between each pair, and after the last `)`, in that order). `specs`
// parallels `expressions`, one InterpFormat per interpolation. Built by
// the code generator into a printf-style format string plus arguments;
// see CodeGenerator.generateInterpolatedString.
class InterpolatedStringLiteral : ASTNode {
    string[] literalParts;
    ASTNode[] expressions;
    InterpFormat[] specs;

    this(string[] literalParts, ASTNode[] expressions, InterpFormat[] specs, int line = 0, int column = 0) {
        super(NodeType.InterpolatedStringLiteral, line, column);
        this.literalParts = literalParts;
        this.expressions = expressions;
        this.specs = specs;
    }
}

class StringLiteral : ASTNode {
    string value;

    this(string value, int line = 0, int column = 0) {
        super(NodeType.StringLiteral, line, column);
        this.value = value;
    }
}

class RegexLiteral : ASTNode {
    string pattern;

    this(string pattern, int line = 0, int column = 0) {
        super(NodeType.RegexLiteral, line, column);
        this.pattern = pattern;
    }
}

class BoolLiteral : ASTNode {
    bool value;

    this(bool value, int line = 0, int column = 0) {
        super(NodeType.BoolLiteral, line, column);
        this.value = value;
    }
}

class NullLiteral : ASTNode {
    this(int line = 0, int column = 0) {
        super(NodeType.NullLiteral, line, column);
    }
}

class NewExpr : ASTNode {
    Type type;
    ASTNode[] args;
    string[] argNames; // parallel to args - see CallExpr.argNames

    this(Type type, ASTNode[] args, int line = 0, int column = 0, string[] argNames = null) {
        super(NodeType.NewExpr, line, column);
        this.type = type;
        this.args = args;
        this.argNames = argNames;
    }
}

class CastExpr : ASTNode {
    Type type;
    ASTNode expression;

    this(Type type, ASTNode expression, int line = 0, int column = 0) {
        super(NodeType.CastExpr, line, column);
        this.type = type;
        this.expression = expression;
    }
}

// `sizeof(Type)` - a compile-time constant giving the C byte size of one
// value of that LLPL type (see codegen.d's generateExpression). Needed by
// generic containers (Vector<T>, ...) to compute allocation sizes for a
// type that's only concrete after monomorphization.
class SizeofExpr : ASTNode {
    Type type;

    this(Type type, int line = 0, int column = 0) {
        super(NodeType.SizeofExpr, line, column);
        this.type = type;
    }
}

// `TypeName { field: value, ... }` - constructs a struct value directly
// (structs only, never a class - see codegen.d's resolveStructLiteralTarget,
// which rejects a class name with a pointer to `new` instead). `typeName`
// is always a single, non-namespaced identifier with no `<...>` type
// arguments of its own (parser.d's structLiteral()) - a generic struct's
// type arguments, when needed, come entirely from context (the enclosing
// `let`/return's declared type) rather than being written in the literal
// itself, the same way `Optional<T>`'s `T` is always fixed by context
// before any of its methods run. Every field must be given, by name,
// though not necessarily in declaration order.
class StructLiteral : ASTNode {
    string typeName;
    string[] fieldNames;
    ASTNode[] fieldValues;

    this(string typeName, string[] fieldNames, ASTNode[] fieldValues, int line = 0, int column = 0) {
        super(NodeType.StructLiteral, line, column);
        this.typeName = typeName;
        this.fieldNames = fieldNames;
        this.fieldValues = fieldValues;
    }
}

// A destructuring pattern used as a `match` arm pattern. Wraps the
// non-AST `Pattern` hierarchy so it can sit alongside ordinary expression
// patterns in `MatchCase.patterns`.
class PatternExpr : ASTNode {
    Pattern pattern;

    this(Pattern pattern, int line = 0, int column = 0) {
        super(NodeType.PatternExpr, line, column);
        this.pattern = pattern;
    }
}

// `expr?` - unwraps an Optional<T>/Result<T, E> value, or returns early
// out of the enclosing function with an equivalent empty/error value if
// there isn't one to unwrap (see codegen.d's generatePropagateExpr). Only
// valid inside a function whose own return type is the same kind of
// Optional/Result (an empty Optional<T> carries no payload, so any T
// works there; a Result<T, E> needs a matching E to construct the
// propagated error).
class PropagateExpr : ASTNode {
    ASTNode operand;

    this(ASTNode operand, int line = 0, int column = 0) {
        super(NodeType.PropagateExpr, line, column);
        this.operand = operand;
    }
}

// `(e1, e2, ...)` - a tuple value literal. The arity is fixed at parse
// time and must be within the range of __LLPL_TupleN structs defined in
// prelude.llpl (currently 2..8).
class TupleLiteral : ASTNode {
    ASTNode[] elements;

    this(ASTNode[] elements, int line = 0, int column = 0) {
        super(NodeType.TupleLiteral, line, column);
        this.elements = elements;
    }
}

// Maps a raw operator symbol ("+", "-", "==", "!", "[]", ...) plus arity to
// the C-safe method name a class defines to overload it (`func operator+(other: T)`
// -> "op_add"). Returns "" for combinations that don't exist (e.g. a unary
// "+", or a binary "!") - shared by the parser (to validate/name the method
// declaration) and the code generator (to look one up at a use site).
//
// "[]" (subscript, `func operator[](index: T) -> U`) is read-only - there's
// no "op_index=" counterpart, so `s[i] = x` isn't supported on classes;
// String (prelude.llpl) offers a `set(index, value)` method instead. It's
// listed as a binary operator (arity 1: the index) even though there's no
// token-level "[]" operator elsewhere in the grammar - the parser recognizes
// the `[` `]` pair specially in functionDecl rather than via
// isOverloadableOperatorToken.
string operatorMethodName(string rawOp, bool isUnary) {
    if (isUnary) {
        switch (rawOp) {
            case "-": return "op_neg";
            case "!": return "op_not";
            case "~": return "op_bnot";
            default: return "";
        }
    }
    switch (rawOp) {
        case "+": return "op_add";
        case "-": return "op_sub";
        case "*": return "op_mul";
        case "/": return "op_div";
        case "%": return "op_mod";
        case "==": return "op_eq";
        case "!=": return "op_ne";
        case "<": return "op_lt";
        case ">": return "op_gt";
        case "<=": return "op_le";
        case ">=": return "op_ge";
        case "&": return "op_and";
        case "|": return "op_or";
        case "^": return "op_xor";
        case "<<": return "op_shl";
        case ">>": return "op_shr";
        case "[]": return "op_index";
        default: return "";
    }
}
