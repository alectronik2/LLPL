module async_layout;

import std.array : join;
import std.conv : to;
import std.format : format;
import ast;

private string typeText(Type t) {
    return t is null ? "<inferred>" : t.toString();
}

private string qualifiedName(string[] segments, string name) {
    return segments.length == 0 ? name : segments.join(".") ~ "." ~ name;
}

private string exprText(ASTNode node) {
    if (node is null) return "<none>";
    if (auto ident = cast(Identifier)node) return ident.name;
    if (auto i = cast(IntLiteral)node) return to!string(i.value);
    if (auto f = cast(FloatLiteral)node) return f.value;
    if (auto s = cast(StringLiteral)node) return "\"" ~ s.value ~ "\"";
    if (auto b = cast(BoolLiteral)node) return b.value ? "true" : "false";
    if (cast(NullLiteral)node) return "null";
    if (auto member = cast(MemberExpr)node) return exprText(member.object) ~ "." ~ member.member;
    if (auto call = cast(CallExpr)node) {
        string[] args;
        foreach (arg; call.args) args ~= exprText(arg);
        return exprText(call.callee) ~ "(" ~ args.join(", ") ~ ")";
    }
    if (auto awaitExpr = cast(AwaitExpr)node) return "await " ~ exprText(awaitExpr.expression);
    if (auto bin = cast(BinaryExpr)node) return exprText(bin.left) ~ " " ~ bin.op ~ " " ~ exprText(bin.right);
    if (auto un = cast(UnaryExpr)node) {
        return un.isPostfix ? exprText(un.operand) ~ un.op : un.op ~ exprText(un.operand);
    }
    if (auto idx = cast(IndexExpr)node) return exprText(idx.array) ~ "[" ~ exprText(idx.index) ~ "]";
    if (auto castExpr = cast(CastExpr)node) return exprText(castExpr.expression) ~ " as " ~ castExpr.type.toString();
    if (auto newExpr = cast(NewExpr)node) {
        string[] args;
        foreach (arg; newExpr.args) args ~= exprText(arg);
        return "new " ~ newExpr.type.toString() ~ "(" ~ args.join(", ") ~ ")";
    }
    if (auto prop = cast(PropagateExpr)node) return exprText(prop.operand) ~ "?";
    return "<expr>";
}

private bool containsAwait(ASTNode node) {
    if (node is null) return false;
    if (cast(AwaitExpr)node) return true;
    if (auto block = cast(Block)node) {
        foreach (stmt; block.statements) if (containsAwait(stmt)) return true;
    } else if (auto v = cast(VarDecl)node) {
        return containsAwait(v.initializer);
    } else if (auto e = cast(ExprStmt)node) {
        return containsAwait(e.expression);
    } else if (auto r = cast(ReturnStmt)node) {
        return containsAwait(r.value);
    } else if (auto i = cast(IfStmt)node) {
        return containsAwait(i.condition) || containsAwait(i.thenBlock) || containsAwait(i.elseBlock);
    } else if (auto w = cast(WhileStmt)node) {
        return containsAwait(w.condition) || containsAwait(w.body_);
    } else if (auto dw = cast(DoWhileStmt)node) {
        return containsAwait(dw.body_) || containsAwait(dw.condition);
    } else if (auto f = cast(ForStmt)node) {
        foreach (init; f.initializers) if (containsAwait(init)) return true;
        return containsAwait(f.condition) || containsAwait(f.update) || containsAwait(f.body_);
    } else if (auto fe = cast(ForeachStmt)node) {
        return containsAwait(fe.iterable) || containsAwait(fe.body_);
    } else if (auto m = cast(MatchStmt)node) {
        if (containsAwait(m.subject)) return true;
        foreach (c; m.cases) if (containsAwait(c.body_)) return true;
    } else if (auto t = cast(TryStmt)node) {
        return containsAwait(t.tryBlock) || containsAwait(t.catchBlock) || containsAwait(t.finallyBlock);
    } else if (auto t = cast(ThrowStmt)node) {
        return containsAwait(t.value);
    } else if (auto d = cast(DeleteStmt)node) {
        return containsAwait(d.value);
    } else if (auto a = cast(AssertStmt)node) {
        return containsAwait(a.condition) || containsAwait(a.message);
    } else if (auto b = cast(BinaryExpr)node) {
        return containsAwait(b.left) || containsAwait(b.right);
    } else if (auto u = cast(UnaryExpr)node) {
        return containsAwait(u.operand);
    } else if (auto c = cast(CallExpr)node) {
        if (containsAwait(c.callee)) return true;
        foreach (arg; c.args) if (containsAwait(arg)) return true;
    } else if (auto m = cast(MemberExpr)node) {
        return containsAwait(m.object);
    } else if (auto idx = cast(IndexExpr)node) {
        return containsAwait(idx.array) || containsAwait(idx.index);
    } else if (auto n = cast(NewExpr)node) {
        foreach (arg; n.args) if (containsAwait(arg)) return true;
    } else if (auto c = cast(CastExpr)node) {
        return containsAwait(c.expression);
    } else if (auto p = cast(PropagateExpr)node) {
        return containsAwait(p.operand);
    } else if (auto ie = cast(IfExpr)node) {
        return containsAwait(ie.condition) || containsAwait(ie.thenBlock) || containsAwait(ie.elseBlock);
    } else if (auto a = cast(ArrayLiteral)node) {
        foreach (elem; a.elements) if (containsAwait(elem)) return true;
    } else if (auto t = cast(TupleLiteral)node) {
        foreach (elem; t.elements) if (containsAwait(elem)) return true;
    } else if (auto s = cast(StructLiteral)node) {
        foreach (value; s.fieldValues) if (containsAwait(value)) return true;
    }
    return false;
}

private bool isDirectAwait(ASTNode node) {
    return cast(AwaitExpr)node !is null;
}

private bool isAllowedRestrictedStatement(ASTNode stmt) {
    if (cast(VarDecl)stmt) {
        auto v = cast(VarDecl)stmt;
        return v.initializer is null || !containsAwait(v.initializer) || isDirectAwait(v.initializer);
    }
    if (cast(ReturnStmt)stmt) {
        auto r = cast(ReturnStmt)stmt;
        return !containsAwait(r.value);
    }
    if (cast(ExprStmt)stmt) {
        auto e = cast(ExprStmt)stmt;
        return !containsAwait(e.expression) || isDirectAwait(e.expression);
    }
    return !containsAwait(stmt);
}

private void collectAwaitExprs(ASTNode node, ref AwaitExpr[] awaits) {
    if (node is null) return;
    if (auto awaitExpr = cast(AwaitExpr)node) {
        awaits ~= awaitExpr;
        collectAwaitExprs(awaitExpr.expression, awaits);
        return;
    }
    if (auto block = cast(Block)node) {
        foreach (stmt; block.statements) collectAwaitExprs(stmt, awaits);
    } else if (auto v = cast(VarDecl)node) {
        collectAwaitExprs(v.initializer, awaits);
    } else if (auto e = cast(ExprStmt)node) {
        collectAwaitExprs(e.expression, awaits);
    } else if (auto r = cast(ReturnStmt)node) {
        collectAwaitExprs(r.value, awaits);
    } else if (auto b = cast(BinaryExpr)node) {
        collectAwaitExprs(b.left, awaits);
        collectAwaitExprs(b.right, awaits);
    } else if (auto u = cast(UnaryExpr)node) {
        collectAwaitExprs(u.operand, awaits);
    } else if (auto c = cast(CallExpr)node) {
        collectAwaitExprs(c.callee, awaits);
        foreach (arg; c.args) collectAwaitExprs(arg, awaits);
    } else if (auto m = cast(MemberExpr)node) {
        collectAwaitExprs(m.object, awaits);
    } else if (auto idx = cast(IndexExpr)node) {
        collectAwaitExprs(idx.array, awaits);
        collectAwaitExprs(idx.index, awaits);
    } else if (auto n = cast(NewExpr)node) {
        foreach (arg; n.args) collectAwaitExprs(arg, awaits);
    } else if (auto c = cast(CastExpr)node) {
        collectAwaitExprs(c.expression, awaits);
    }
}

private string classifyRestricted(FunctionDecl fn) {
    if (fn.body_ is null) return "unsupported: missing body";
    foreach (stmt; fn.body_.statements) {
        if (!isAllowedRestrictedStatement(stmt)) {
            return format("unsupported: await inside %s requires general expression/control-flow lowering",
                stmt.type);
        }
    }
    return "supported: straight-line restricted lowering";
}

private void appendFunctionLayout(ref string out_, FunctionDecl fn, string owner = "") {
    string name = owner.length > 0 ? owner ~ "." ~ fn.name : qualifiedName(fn.namespaceSegments, fn.name);
    AwaitExpr[] awaits;
    collectAwaitExprs(fn.body_, awaits);

    out_ ~= format("async %s -> %s\n", name, typeText(fn.returnType));
    out_ ~= format("  source: %d:%d\n", fn.line, fn.column);
    out_ ~= "  lowering: " ~ classifyRestricted(fn) ~ "\n";
    out_ ~= "  frame:\n";
    out_ ~= "    state: int\n";
    if (fn.returnType !is null && (fn.returnType.name != "void" || fn.returnType.isPointer)) {
        out_ ~= "    result: " ~ fn.returnType.toString() ~ "\n";
    }
    foreach (param; fn.params) {
        out_ ~= format("    param.%s: %s\n", param.name, typeText(param.type));
    }
    if (fn.body_ !is null) {
        foreach (stmt; fn.body_.statements) {
            if (auto v = cast(VarDecl)stmt) {
                out_ ~= format("    local.%s: %s\n", v.name, typeText(v.type));
            }
        }
    }
    foreach (i, awaitExpr; awaits) {
        out_ ~= format("    await%d: %s\n", i, exprText(awaitExpr.expression));
    }
    out_ ~= "  states:\n";
    out_ ~= "    0: entry\n";
    foreach (i, awaitExpr; awaits) {
        out_ ~= format("    %d: resume after await%d at %d:%d\n",
            cast(int)i + 1, i, awaitExpr.line, awaitExpr.column);
    }
    out_ ~= format("    %d: complete\n\n", cast(int)awaits.length + 1);
}

private void walkDecls(ASTNode[] decls, ref string out_, string[] namespaceSegments = []) {
    foreach (decl; decls) {
        if (auto fn = cast(FunctionDecl)decl) {
            if (fn.isAsync) appendFunctionLayout(out_, fn);
        } else if (auto ns = cast(NamespaceDecl)decl) {
            walkDecls(ns.declarations, out_, namespaceSegments ~ ns.name);
        } else if (auto cls = cast(ClassDecl)decl) {
            string owner = qualifiedName(cls.namespaceSegments, cls.name);
            foreach (m; cls.methods) if (m.isAsync) appendFunctionLayout(out_, m, owner);
        } else if (auto st = cast(StructDecl)decl) {
            string owner = qualifiedName(st.namespaceSegments, st.name);
            foreach (m; st.methods) if (m.isAsync) appendFunctionLayout(out_, m, owner);
        } else if (auto un = cast(UnionDecl)decl) {
            string owner = qualifiedName(un.namespaceSegments, un.name);
            foreach (m; un.methods) if (m.isAsync) appendFunctionLayout(out_, m, owner);
        }
    }
}

string emitAsyncLayout(Program[] programs) {
    string out_ = "Async layout report\n";
    bool found = false;
    foreach (prog; programs) {
        string before = out_;
        walkDecls(prog.declarations, out_);
        if (out_.length != before.length) found = true;
    }
    if (!found) out_ ~= "  <no async functions>\n";
    return out_;
}
