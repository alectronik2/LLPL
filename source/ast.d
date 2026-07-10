module ast;

import std.variant;
import std.conv;

enum NodeType {
    Program,
    ImportStmt,
    NamespaceDecl,
    AliasDecl,
    FunctionDecl,
    ClassDecl,
    StructDecl,
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
    BoolLiteral,
    NullLiteral,
    NewExpr,
    CastExpr,
    MacroDecl,
    MacroInvocation,
    QuoteExpr,
    UnquoteExpr,
    InterpolatedStringLiteral,
    ArrayLiteral
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

class ImportStmt : ASTNode {
    string modulePath;
    string alias_;  // Optional alias

    this(string modulePath, string alias_ = "") {
        super(NodeType.ImportStmt);
        this.modulePath = modulePath;
        this.alias_ = alias_;
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
// `targetPath`/`targetIsPointer`/`targetIsArray`/`targetArraySize`
// wherever it's resolved as a *type* (see CodeGenerator.resolveType and
// the `typeAliases` map). `targetPath` a dotted class/struct name with no
// such suffix still goes through the plain symbol-alias path above,
// unchanged - that already works via the class/struct registry copy.
class AliasDecl : ASTNode {
    string name;
    string[] targetPath;
    bool targetIsPointer;
    bool targetIsArray;
    int targetArraySize;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, string[] targetPath, bool targetIsPointer = false, bool targetIsArray = false,
         int targetArraySize = 0, int line = 0, int column = 0) {
        super(NodeType.AliasDecl, line, column);
        this.name = name;
        this.targetPath = targetPath;
        this.targetIsPointer = targetIsPointer;
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
    bool isPointer;
    bool isArray;
    int arraySize;
    Type[] genericArgs;

    this(string name, bool isPointer = false, bool isArray = false, int arraySize = 0) {
        this.name = name;
        this.isPointer = isPointer;
        this.isArray = isArray;
        this.arraySize = arraySize;
    }

    override string toString() const {
        string result = name;
        if (isPointer) result ~= "*";
        if (isArray) result ~= "[]";
        return result;
    }
}

class Parameter {
    string name;
    Type type;

    this(string name, Type type) {
        this.name = name;
        this.type = type;
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

    this(string name, Parameter[] params, Type returnType, Block body_, bool isExtern = false,
         bool isInterrupt = false, bool isVariadic = false, int line = 0, int column = 0) {
        super(NodeType.FunctionDecl, line, column);
        this.name = name;
        this.params = params;
        this.returnType = returnType;
        this.body_ = body_;
        this.isExtern = isExtern;
        this.isInterrupt = isInterrupt;
        this.isVariadic = isVariadic;
    }
}

class ClassDecl : ASTNode {
    string name;
    VarDecl[] fields;
    FunctionDecl constructor;
    FunctionDecl destructor;
    FunctionDecl[] methods;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, VarDecl[] fields, FunctionDecl constructor, FunctionDecl destructor, FunctionDecl[] methods,
         int line = 0, int column = 0) {
        super(NodeType.ClassDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.constructor = constructor;
        this.destructor = destructor;
        this.methods = methods;
    }
}

// A plain value-type aggregate: no ref-counting header, no heap allocation,
// no constructor/destructor/methods. Compiles to a bare C struct, usable as
// a stack/global value, array element, or (with `packed`) a hardware-layout
// descriptor like a GDT/IDT entry.
class StructDecl : ASTNode {
    string name;
    VarDecl[] fields;
    bool packed;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, VarDecl[] fields, bool packed = false, int line = 0, int column = 0) {
        super(NodeType.StructDecl, line, column);
        this.name = name;
        this.fields = fields;
        this.packed = packed;
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

    this(string name, Type type, ASTNode initializer = null, bool isConst = false, int line = 0, int column = 0,
         int bitWidth = -1, bool isVolatile = false) {
        super(NodeType.VarDecl, line, column);
        this.name = name;
        this.type = type;
        this.initializer = initializer;
        this.isConst = isConst;
        this.bitWidth = bitWidth;
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

    this(ASTNode callee, ASTNode[] args, int line = 0, int column = 0) {
        super(NodeType.CallExpr, line, column);
        this.callee = callee;
        this.args = args;
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

    this(Type type, ASTNode[] args, int line = 0, int column = 0) {
        super(NodeType.NewExpr, line, column);
        this.type = type;
        this.args = args;
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
