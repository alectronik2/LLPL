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
    CastExpr
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
class AliasDecl : ASTNode {
    string name;
    string[] targetPath;
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, string[] targetPath, int line = 0, int column = 0) {
        super(NodeType.AliasDecl, line, column);
        this.name = name;
        this.targetPath = targetPath;
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
         bool isInterrupt = false, bool isVariadic = false) {
        super(NodeType.FunctionDecl);
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

    this(string name, VarDecl[] fields, FunctionDecl constructor, FunctionDecl destructor, FunctionDecl[] methods) {
        super(NodeType.ClassDecl);
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

    this(string name, VarDecl[] fields, bool packed = false) {
        super(NodeType.StructDecl);
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
    int bitWidth = -1; // -1 means "not a bit-field"; only meaningful for class fields
    string[] namespaceSegments; // Enclosing namespace path, set by the code generator

    this(string name, Type type, ASTNode initializer = null, bool isConst = false, int line = 0, int column = 0,
         int bitWidth = -1) {
        super(NodeType.VarDecl, line, column);
        this.name = name;
        this.type = type;
        this.initializer = initializer;
        this.isConst = isConst;
        this.bitWidth = bitWidth;
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

// Maps a raw operator symbol ("+", "-", "==", "!", ...) plus arity to the
// C-safe method name a class defines to overload it (`func operator+(other: T)`
// -> "op_add"). Returns "" for combinations that don't exist (e.g. a unary
// "+", or a binary "!") - shared by the parser (to validate/name the method
// declaration) and the code generator (to look one up at a use site).
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
        default: return "";
    }
}
