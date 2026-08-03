module astprint;

import std.array : join;
import std.conv : to;
import std.format : format;
import ast;

private string indent(int depth) {
    string result;
    foreach (_; 0 .. depth) result ~= "  ";
    return result;
}

private string typeText(Type t) {
    return t is null ? "<inferred>" : t.toString();
}

private string paramsText(Parameter[] params) {
    string[] parts;
    foreach (p; params) {
        string prefix = p.initializesField ? "@" : "";
        string constPart = p.isConst ? "const " : "";
        string defaultPart = p.defaultValue is null ? "" : " = ...";
        parts ~= format("%s%s: %s%s", prefix, p.name, constPart ~ typeText(p.type), defaultPart);
    }
    return parts.join(", ");
}

private string methodKind(FunctionDecl fn) {
    if (fn.isProperty) {
        return fn.params.length == 0 ? "PropertyGetter" : "PropertySetter";
    }
    return fn.isStatic ? "StaticMethod" : "Method";
}

private final class AstPrinter {
    string out_;

    void line(int depth, string text) {
        out_ ~= indent(depth) ~ text ~ "\n";
    }

    void printNode(ASTNode node, int depth = 0) {
        if (node is null) {
            line(depth, "<null>");
            return;
        }

        if (auto program = cast(Program)node) {
            line(depth, "Program");
            foreach (decl; program.declarations) printNode(decl, depth + 1);
        } else if (auto cls = cast(ClassDecl)node) {
            string suffix = cls.typeParams.length > 0 ? "<" ~ cls.typeParams.join(", ") ~ ">" : "";
            if (cls.baseClassName.length > 0) suffix ~= " : " ~ cls.baseClassName;
            line(depth, "Class " ~ cls.name ~ suffix);
            foreach (field; cls.fields) printField(field, depth + 1);
            foreach (ctor; cls.constructors) printFunction("Constructor", ctor, depth + 1);
            if (cls.destructor !is null) printFunction("Destructor", cls.destructor, depth + 1);
            foreach (method; cls.methods) printFunction(methodKind(method), method, depth + 1);
        } else if (auto st = cast(StructDecl)node) {
            string suffix = st.typeParams.length > 0 ? "<" ~ st.typeParams.join(", ") ~ ">" : "";
            line(depth, (st.packed ? "PackedStruct " : "Struct ") ~ st.name ~ suffix);
            foreach (field; st.fields) printField(field, depth + 1);
            foreach (ctor; st.constructors) printFunction("Constructor", ctor, depth + 1);
            foreach (method; st.methods) printFunction(methodKind(method), method, depth + 1);
        } else if (auto un = cast(UnionDecl)node) {
            line(depth, (un.packed ? "PackedUnion " : "Union ") ~ un.name);
            foreach (field; un.fields) printField(field, depth + 1);
            foreach (ctor; un.constructors) printFunction("Constructor", ctor, depth + 1);
            foreach (method; un.methods) printFunction(methodKind(method), method, depth + 1);
        } else if (auto fn = cast(FunctionDecl)node) {
            printFunction("Function", fn, depth);
        } else if (auto var = cast(VarDecl)node) {
            printField(var, depth);
        } else if (auto ns = cast(NamespaceDecl)node) {
            line(depth, "Namespace " ~ ns.name);
            foreach (decl; ns.declarations) printNode(decl, depth + 1);
        } else if (auto imp = cast(ImportStmt)node) {
            line(depth, "Import " ~ imp.modulePath);
        } else if (auto aliasDecl = cast(AliasDecl)node) {
            line(depth, "Alias " ~ aliasDecl.name ~ " = " ~ aliasDecl.targetPath.join("."));
        } else if (auto arrAlias = cast(ArrayAliasDecl)node) {
            line(depth, format("ArrayAlias %s[%d]", arrAlias.name, arrAlias.elements.length));
        } else if (auto unit = cast(UnitTestDecl)node) {
            line(depth, "UnitTest");
            printBlock(unit.body_, depth + 1);
        } else if (auto withStmt = cast(WithStmt)node) {
            line(depth, "With " ~ withStmt.contextName);
            printExpr(withStmt.object, depth + 1);
            printBlock(withStmt.body_, depth + 1);
        } else {
            printStmtOrExpr(node, depth);
        }
    }

    void printField(VarDecl field, int depth) {
        string prefix = field.isConst ? "Const " : field.isVolatile ? "Volatile " : "Field ";
        string suffix = field.bitWidth >= 0 ? format(" : %d", field.bitWidth) : "";
        line(depth, prefix ~ field.name ~ ": " ~ typeText(field.type) ~ suffix);
        if (field.initializer !is null) printExpr(field.initializer, depth + 1);
    }

    void printFunction(string kind, FunctionDecl fn, int depth) {
        string flags;
        if (fn.isPrivate) flags ~= " private";
        if (fn.isInline) flags ~= " inline";
        if (fn.isVirtual) flags ~= " virtual";
        if (fn.isOverride) flags ~= " override";
        line(depth, format("%s %s(%s) -> %s%s", kind, fn.name, paramsText(fn.params),
            typeText(fn.returnType), flags));
        if (fn.body_ !is null) printBlock(fn.body_, depth + 1);
    }

    void printBlock(Block block, int depth) {
        line(depth, "Block");
        foreach (stmt; block.statements) printStmtOrExpr(stmt, depth + 1);
    }

    void printStmtOrExpr(ASTNode node, int depth) {
        if (auto block = cast(Block)node) {
            printBlock(block, depth);
        } else if (auto var = cast(VarDecl)node) {
            printField(var, depth);
        } else if (auto exprStmt = cast(ExprStmt)node) {
            line(depth, "ExprStmt");
            printExpr(exprStmt.expression, depth + 1);
        } else if (auto ret = cast(ReturnStmt)node) {
            line(depth, "Return");
            if (ret.value !is null) printExpr(ret.value, depth + 1);
        } else if (auto ifs = cast(IfStmt)node) {
            line(depth, "If");
            printExpr(ifs.condition, depth + 1);
            printBlock(ifs.thenBlock, depth + 1);
            if (ifs.elseBlock !is null) printBlock(ifs.elseBlock, depth + 1);
        } else if (auto wh = cast(WhileStmt)node) {
            line(depth, "While");
            printExpr(wh.condition, depth + 1);
            printBlock(wh.body_, depth + 1);
        } else if (auto withStmt = cast(WithStmt)node) {
            line(depth, "With " ~ withStmt.contextName);
            printExpr(withStmt.object, depth + 1);
            printBlock(withStmt.body_, depth + 1);
        } else {
            printExpr(node, depth);
        }
    }

    void printExpr(ASTNode node, int depth) {
        if (node is null) {
            line(depth, "<null>");
        } else if (auto id = cast(Identifier)node) {
            line(depth, "Identifier " ~ id.name);
        } else if (auto i = cast(IntLiteral)node) {
            line(depth, "Int " ~ to!string(i.value));
        } else if (auto f = cast(FloatLiteral)node) {
            line(depth, "Float " ~ f.value);
        } else if (auto s = cast(StringLiteral)node) {
            line(depth, "String \"" ~ s.value ~ "\"");
        } else if (auto b = cast(BoolLiteral)node) {
            line(depth, b.value ? "Bool true" : "Bool false");
        } else if (cast(NullLiteral)node !is null) {
            line(depth, "Null");
        } else if (auto bin = cast(BinaryExpr)node) {
            line(depth, "Binary " ~ bin.op);
            printExpr(bin.left, depth + 1);
            printExpr(bin.right, depth + 1);
        } else if (auto un = cast(UnaryExpr)node) {
            line(depth, (un.isPostfix ? "Postfix " : "Unary ") ~ un.op);
            printExpr(un.operand, depth + 1);
        } else if (auto member = cast(MemberExpr)node) {
            line(depth, "Member " ~ member.member);
            printExpr(member.object, depth + 1);
        } else if (auto call = cast(CallExpr)node) {
            line(depth, "Call");
            printExpr(call.callee, depth + 1);
            foreach (arg; call.args) printExpr(arg, depth + 1);
        } else if (auto idx = cast(IndexExpr)node) {
            line(depth, "Index");
            printExpr(idx.array, depth + 1);
            printExpr(idx.index, depth + 1);
        } else if (auto n = cast(NewExpr)node) {
            line(depth, "New " ~ typeText(n.type));
            foreach (arg; n.args) printExpr(arg, depth + 1);
        } else if (auto castExpr = cast(CastExpr)node) {
            line(depth, "Cast " ~ typeText(castExpr.type));
            printExpr(castExpr.expression, depth + 1);
        } else if (auto arr = cast(ArrayLiteral)node) {
            line(depth, format("ArrayLiteral %d", arr.elements.length));
            foreach (elem; arr.elements) printExpr(elem, depth + 1);
        } else if (auto tup = cast(TupleLiteral)node) {
            line(depth, format("TupleLiteral %d", tup.elements.length));
            foreach (elem; tup.elements) printExpr(elem, depth + 1);
        } else {
            line(depth, to!string(node.type));
        }
    }
}

string printAst(Program program) {
    auto printer = new AstPrinter();
    printer.printNode(program);
    return printer.out_;
}
