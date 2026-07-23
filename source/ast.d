module ast;

import std.variant;
import std.conv;
import std.array : replicate;

enum NodeType {
    Program,
    ImportStmt,
    UsingNamespaceStmt,
    NamespaceDecl,
    AliasDecl,
    ArrayAliasDecl,
    FunctionDecl,
    ClassDecl,
    StructDecl,
    UnionDecl,
    LinkDecl,
    FlagsDecl,
    AbiAssertDecl,
    DeviceDecl,
    EnumDecl,
    GrammarDecl,
    VarDecl,
    IfStmt,
    WhileStmt,
    ForStmt,
    ForeachStmt,
    ReturnStmt,
    ContinueStmt,
    BreakStmt,
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
    FloatLiteral,
    CharLiteral,
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
    IfExpr,
    DeleteStmt,
    AssertStmt,
    RangeExpr
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

// A `using namespace Foo.Bar` statement. Brings all symbols from the specified
// namespace into scope, allowing unqualified access.
class UsingNamespaceStmt : ASTNode {
    string namespacePath; // e.g., "HAL.Serial" for `using namespace HAL.Serial`

    this(string namespacePath, int line = 0, int column = 0) {
        super(NodeType.UsingNamespaceStmt, line, column);
        this.namespacePath = namespacePath;
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

// `alias NAME = [ expr, expr, ... ]` - a compile-time-only named array
// literal, distinct from AliasDecl's symbol/type aliasing above (which
// always starts with an identifier, never a bracket, right after `=`).
// `NAME` never becomes its own C symbol; wherever it's referenced it's
// expanded back into these same element expressions - either as a whole
// array-typed initializer, or spliced into a *larger* array literal it
// appears as one element of (see codegen.d's arrayLiteralAliases and
// expandArrayAliasesShallow). Meant for grouping repeated magic-number
// sequences (e.g. a bootloader protocol's request IDs) under a name
// without needing them to live at a real, addressable memory location.
class ArrayAliasDecl : ASTNode {
    string name;
    ASTNode[] elements;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, ASTNode[] elements, int line = 0, int column = 0) {
        super(NodeType.ArrayAliasDecl, line, column);
        this.name = name;
        this.elements = elements;
    }
}

// `#link "NAME"` - a compiler directive requesting the final binary be
// linked against a shared/static library named `NAME` (e.g. `#link "SDL3"`
// for `-lSDL3`), rather than any construct with its own C representation -
// it produces no code of its own; the code generator just collects it into
// a flat list of requested link libraries (see CodeGenerator.linkLibraries)
// that `--binary` mode (main.d's compileToBinary) passes to the system C
// compiler as `-l<name>` flags. A two-step build (`llpl foo.llpl -o foo.c`
// then a hand-written `cc`/linker invocation) has no such automatic step -
// the caller still has to pass `-lSDL3` themselves in that mode, the same
// as any other library dependency C code doesn't embed.
class LinkDecl : ASTNode {
    string libraryName;

    this(string libraryName, int line = 0, int column = 0) {
        super(NodeType.LinkDecl, line, column);
        this.libraryName = libraryName;
    }
}

// `#flags "-O2"` - same shape and purpose as LinkDecl just above, but for
// arbitrary extra C compiler flags instead of a library name (e.g. an
// optimization level, `-Wall`, or a `-D` define a binding needs). Also
// produces no code of its own; collected into CodeGenerator.compilerFlags
// and passed to the system C compiler by `--binary` mode.
class FlagsDecl : ASTNode {
    string flags;

    this(string flags, int line = 0, int column = 0) {
        super(NodeType.FlagsDecl, line, column);
        this.flags = flags;
    }
}

enum AbiAssertKind {
    Size,
    Align,
    Offset
}

// Compile-time ABI/layout checks, emitted as C11 `_Static_assert`s:
//   #assert_size Type 16
//   #assert_align Type 8
//   #assert_offset Type.field 4
class AbiAssertDecl : ASTNode {
    AbiAssertKind kind;
    Type targetType;
    string fieldName;
    long expected;

    this(AbiAssertKind kind, Type targetType, long expected, string fieldName = "",
         int line = 0, int column = 0) {
        super(NodeType.AbiAssertDecl, line, column);
        this.kind = kind;
        this.targetType = targetType;
        this.fieldName = fieldName;
        this.expected = expected;
    }
}

// `#device "path.lldev"` - imports a small hardware descriptor file and
// expands it into namespace constants for base address, IRQs, register
// offsets/widths, and DMA resource requirements.
class DeviceDecl : ASTNode {
    string descriptorPath;

    this(string descriptorPath, int line = 0, int column = 0) {
        super(NodeType.DeviceDecl, line, column);
        this.descriptorPath = descriptorPath;
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
    // `private func` - a method only callable/referenceable from within
    // the same class's own body (any of its own methods/constructors,
    // not just via `self`) - see codegen.d's checkMemberAccess. Only
    // meaningful for a method (set by classDecl() in parser.d); a plain
    // top-level function is never marked private.
    bool isPrivate;
    // `static func` - a class method that doesn't receive a `self` parameter
    // and can be called on the class itself rather than on instances.
    bool isStatic;
    // `virtual func` - establishes a new dispatchable vtable slot (only
    // meaningful on a class with no base, or one introducing a method its
    // own subclasses may override); `override func` - provides this
    // class's implementation of a slot a base class already declared
    // `virtual`/`override`. Both false (the default) means "resolved as
    // an ordinary, statically-bound call, exactly like before inheritance
    // existed" - dispatch overhead is opt-in per method, not automatic
    // just because a class participates in a hierarchy. Only meaningful
    // for a method (set by classDecl() in parser.d).
    bool isVirtual;
    bool isOverride;

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
    // Empty means "no constructor" (matches the old nullable field's
    // null case) - 2+ entries are overloads of each other, disambiguated
    // by argument types at each `new Foo(...)` call site (see codegen.d's
    // resolveOverload).
    FunctionDecl[] constructors;
    FunctionDecl destructor;
    FunctionDecl[] methods;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    string[] typeParams; // `<T, U>` after the class name - see FunctionDecl.typeParams
    string[] typeParamBounds; // parallel to typeParams - see FunctionDecl.typeParamBounds
    VarAttribute[] attributes;
    // `class Derived : Base { ... }` - "" means no base class. Set by the
    // parser to the raw, as-written name; canonicalized in place (e.g.
    // namespace-qualified) by a resolution pass in codegen.d the same way
    // an ordinary type name gets resolved via resolveType, before
    // anything else looks at it. Single inheritance only, and mutually
    // exclusive with generics (see codegen.d's resolution pass) - a
    // generic ClassDecl's manual, non-reflective cloning
    // (cloneClassDeclWithTypeSubs) would otherwise need to also
    // remember to thread this field through by hand.
    string baseClassName = "";

    this(string name, VarDecl[] fields, FunctionDecl[] constructors, FunctionDecl destructor, FunctionDecl[] methods,
         int line = 0, int column = 0, string[] typeParams = [], string[] typeParamBounds = [],
         VarAttribute[] attributes = []) {
        super(NodeType.ClassDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.constructors = constructors;
        this.destructor = destructor;
        this.methods = methods;
        this.typeParams = typeParams;
        this.typeParamBounds = typeParamBounds;
        this.attributes = attributes;
    }
}

// A plain value-type aggregate: no ref-counting header, no heap allocation,
// no destructor. Compiles to a bare C struct, usable as a stack/global
// value, array element, or (with `packed`) a hardware-layout descriptor
// like a GDT/IDT entry. Can't declare methods *inline* the way a class
// can, but can still gain real methods from an external `impl Trait for
// StructName { ... }` block (see codegen.d's processImplBlock) - those
// are generated as ordinary top-level functions taking this struct by
// value as an explicit first parameter, not stored anywhere on
// StructDecl itself.
//
// A struct *can* declare one or more `constructor(...)` blocks (see
// FunctionDecl parity with ClassDecl.constructors, same "empty means no
// constructor, 2+ are overloads" convention) - unlike a class
// constructor, a struct one never heap-allocates: it builds a local
// value of the struct's own type and returns it by value (see
// codegen.d's generateStructConstructor), matching `new StructName(...)`
// evaluating to a plain StructName, not a StructName* - useful for a
// plain-data FFI type (e.g. an SDL3 struct bound via `extern func`) that
// still wants constructor-call ergonomics without paying for a class's
// ref-counted heap box, which would silently corrupt its ABI-mandated
// flat layout.
class StructDecl : ASTNode {
    string name;
    VarDecl[] fields;
    FunctionDecl[] constructors;
    bool packed;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator
    string[] typeParams; // `<T, U>` after the struct name - see FunctionDecl.typeParams
    string[] typeParamBounds; // parallel to typeParams - see FunctionDecl.typeParamBounds
    VarAttribute[] attributes;

    this(string name, VarDecl[] fields, bool packed = false, int line = 0, int column = 0,
         string[] typeParams = [], string[] typeParamBounds = [], VarAttribute[] attributes = [],
         FunctionDecl[] constructors = []) {
        super(NodeType.StructDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.packed = packed;
        this.typeParams = typeParams;
        this.typeParamBounds = typeParamBounds;
        this.attributes = attributes;
        this.constructors = constructors;
    }
}

// A C-style union: every field overlaps the same storage (size is the
// largest field's, not the sum), no field-liveness tracking of any kind -
// same "plain value type, no ref-counting" shape as StructDecl (see its
// own comment), just with overlapping instead of sequential field
// layout. Exists mainly for binding a real C library's own union type
// exactly (e.g. SDL3's `SDL_Event`, whose leading discriminant field can
// then be read/written through *any* of the union's members without a
// pointer-cast trick), not something ordinary LLPL code is expected to
// reach for often. Same "empty means no constructor" convention as
// ClassDecl.constructors; a union constructor's body still just assigns
// through `self.field = ...` like a struct's, understanding that doing
// so for more than one field overwrites the same bytes repeatedly rather
// than storing them all - that's what a union *is*, not a bug in this
// type's own codegen.
class UnionDecl : ASTNode {
    string name;
    VarDecl[] fields;
    FunctionDecl[] constructors;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, VarDecl[] fields, int line = 0, int column = 0, FunctionDecl[] constructors = []) {
        super(NodeType.UnionDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.constructors = constructors;
    }
}

// `grammar Name { rule : alt | alt ; ... }` - an ANTLR-like grammar DSL,
// desugared at codegen time (see codegen.d's desugarGrammar) into a real
// ClassDecl + FunctionDecls (one generated recursive-descent method per
// rule), fed through the ordinary class-codegen pipeline exactly like any
// hand-written class - see grammar.d for the analysis (left-recursion
// elimination, FIRST/FOLLOW computation, ambiguity checking) that turns
// these rules into that ClassDecl. GrammarRule/GrammarAlt/GrammarElement/
// GrammarAtom below are this DSL's own parsed IR, entirely separate from
// the ordinary LLPL expression/statement AST - grammar-rule syntax
// (`'+' | '-'`, `[0-9]`, postfix `* + ?`) is a genuinely different concrete
// syntax, not sugar over expressions/statements (see parser.d's
// grammarDecl() family, which parses it directly rather than reusing
// expression()/block()).
class GrammarDecl : ASTNode {
    string name;
    GrammarRule[] rules;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, GrammarRule[] rules, int line = 0, int column = 0) {
        super(NodeType.GrammarDecl, line, column);
        this.name = name;
        this.rules = rules;
    }
}

// One `name : alt1 | alt2 | ... ;` rule. An ALL-CAPS rule name is a common
// convention for a "lexer-style" rule (e.g. NUMBER, IDENT) versus a
// lowercase "parser-style" one - purely a naming convention grammar
// authors use to organize their own rules, not a distinction this compiler
// enforces or treats differently: unlike ANTLR's real separate lexer/
// parser phases, every rule here - whatever it's named - is matched the
// same character-level way, by the same generated recursive-descent code.
class GrammarRule {
    string name;
    GrammarAlt[] alternatives;
    int line;
    int column;

    this(string name, GrammarAlt[] alternatives, int line = 0, int column = 0) {
        this.name = name;
        this.alternatives = alternatives;
        this.line = line;
        this.column = column;
    }
}

// One `|`-separated alternative: a sequence of elements matched in order.
class GrammarAlt {
    GrammarElement[] elements;

    this(GrammarElement[] elements) {
        this.elements = elements;
    }
}

enum GrammarQuantifier {
    None,
    Star,     // `*` - zero or more
    Plus,     // `+` - one or more
    Question  // `?` - zero or one
}

// One atom plus its postfix quantifier, e.g. `[0-9]+` or `expr?`.
class GrammarElement {
    GrammarAtom atom;
    GrammarQuantifier quantifier;

    this(GrammarAtom atom, GrammarQuantifier quantifier = GrammarQuantifier.None) {
        this.atom = atom;
        this.quantifier = quantifier;
    }
}

enum GrammarAtomKind {
    Literal,    // a quoted string, matched verbatim: 'if', "+="
    CharClass,  // [0-9], [a-zA-Z_], negated [^\n] - see CharRange/`negated`
    Wildcard,   // `.` - matches any single character
    End,        // `<EOF>` - succeeds only at the end of the parser input
    RuleRef,    // a reference to another rule by name
    Group       // `( alt | alt | ... )` - a parenthesized sub-choice
}

// One inclusive character range within a `[...]` class - a single
// character `c` is just `CharRange(c, c)`.
struct CharRange {
    char lo;
    char hi;
}

// A single terminal/nonterminal atom - exactly one field group below is
// meaningful, selected by `kind` (see GrammarAtomKind's own per-variant
// comment). Modeled as one class with a kind tag - this compiler's own
// YamlValue/JsonValue "manual tagged tree" convention - rather than a D
// `Algebraic`/tagged union, since `Group` is self-referential (GrammarAlt[]
// containing more GrammarElements containing more GrammarAtoms) the exact
// same way those runtime types are.
class GrammarAtom {
    GrammarAtomKind kind;
    string literal;       // Literal
    CharRange[] ranges;   // CharClass
    bool negated;         // CharClass: true for `[^...]`
    string ruleRef;       // RuleRef
    GrammarAlt[] group;   // Group

    static GrammarAtom makeLiteral(string s) {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.Literal;
        a.literal = s;
        return a;
    }

    static GrammarAtom makeCharClass(CharRange[] ranges, bool negated) {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.CharClass;
        a.ranges = ranges;
        a.negated = negated;
        return a;
    }

    static GrammarAtom makeWildcard() {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.Wildcard;
        return a;
    }

    static GrammarAtom makeEnd() {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.End;
        return a;
    }

    static GrammarAtom makeRuleRef(string name) {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.RuleRef;
        a.ruleRef = name;
        return a;
    }

    static GrammarAtom makeGroup(GrammarAlt[] alts) {
        auto a = new GrammarAtom();
        a.kind = GrammarAtomKind.Group;
        a.group = alts;
        return a;
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

    // `<T, U>` after the trait name, e.g. `trait Iterator<T> { func
    // iter_next() -> T }` - purely a signature-writing/display convenience
    // (functionSignature/traitSignature render them via toString(), and a
    // trait method's return/param types are never resolveType'd or codegen'd
    // - traits are signature-only). Not substituted or verified against an
    // `impl TraitName for Target { ... }` block's concrete types the way a
    // generic class/function's type params are at monomorphization time;
    // an impl just needs matching method names/arity, same as a
    // non-generic trait (see processImplBlock).
    string[] typeParams;

    this(string name, FunctionDecl[] methods, int line = 0, int column = 0, string[] typeParams = []) {
        super(NodeType.TraitDecl, line, column);
        this.name = name;
        this.methods = methods;
        this.typeParams = typeParams;
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
    // `private let`/`private const` - a field only readable/writable from
    // within the same class's own body (see codegen.d's checkMemberAccess).
    // Only meaningful for a class field (set by classDecl() in parser.d);
    // a local variable or global is never marked private.
    bool isPrivate;

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

    this(ASTNode value = null, int line = 0, int column = 0) {
        super(NodeType.ReturnStmt, line, column);
        this.value = value;
    }
}

class ContinueStmt : ASTNode {
    this(int line = 0, int column = 0) {
        super(NodeType.ContinueStmt, line, column);
    }
}

class BreakStmt : ASTNode {
    this(int line = 0, int column = 0) {
        super(NodeType.BreakStmt, line, column);
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

// `delete expr` - releases this reference to a class instance (only
// classes: they're the only reference-counted, heap-allocated type;
// structs are plain values with no such lifetime to manage). Exactly the
// same rc_release(ptr, ClassName_destroy) call generateDestructor already
// emits to release a reference-counted *field* when its owning object is
// destroyed (see codegen.d) - `delete` just gives a way to trigger that
// same release explicitly, on demand, for an object that was never
// stored as anyone's field (e.g. a `new Foo()` a container never took
// ownership of). Decrements the refcount rather than unconditionally
// freeing: if this was the last reference, the destructor runs and the
// memory is freed; if other references to the same object still exist,
// it survives, exactly like every other release point in this model.
class DeleteStmt : ASTNode {
    ASTNode value;

    this(ASTNode value, int line = 0, int column = 0) {
        super(NodeType.DeleteStmt, line, column);
        this.value = value;
    }
}

// `assert(condition)` or `assert(condition, "message")` - built-in statement
// that aborts with a panic if the condition is false. Lowered to an
// `if (!(condition)) llpl_panic(...)` by the code generator.
class AssertStmt : ASTNode {
    ASTNode condition;
    ASTNode message; // optional string expression

    this(ASTNode condition, ASTNode message = null, int line = 0, int column = 0) {
        super(NodeType.AssertStmt, line, column);
        this.condition = condition;
        this.message = message;
    }
}

// `start..end` (exclusive of `end`, like Rust) - only ever meaningful as
// `for i in start..end { ... }`'s iterable (see ForeachStmt and
// codegen.d's generateRangeForeach); not a first-class value usable
// anywhere else an expression is (no range variables, no range
// arithmetic) - it's control-flow sugar, not a runtime type.
class RangeExpr : ASTNode {
    ASTNode start;
    ASTNode end;

    this(ASTNode start, ASTNode end, int line = 0, int column = 0) {
        super(NodeType.RangeExpr, line, column);
        this.start = start;
        this.end = end;
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

class FloatLiteral : ASTNode {
    string value; // Store as string to preserve exact representation

    this(string value, int line = 0, int column = 0) {
        super(NodeType.FloatLiteral, line, column);
        this.value = value;
    }
}

class CharLiteral : ASTNode {
    int value; // ASCII value of the character

    this(int value, int line = 0, int column = 0) {
        super(NodeType.CharLiteral, line, column);
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
