module grammar;

// Compiles a `grammar Name { rule : alt | alt ; ... }` declaration (see
// ast.d's GrammarDecl/GrammarRule/GrammarAlt/GrammarElement/GrammarAtom)
// into a real ClassDecl + FunctionDecls, fed into codegen.d's ordinary
// generateMultiple pipeline exactly like desugarTaggedEnum's EnumDecl ->
// StructDecl+FunctionDecl[] desugaring does - see desugarGrammar's own
// comment, and codegen.d's call site.
//
// Pipeline: flatten `( ... )` groups into their own synthetic rules ->
// per-rule direct-left-recursion partition (primary vs recursive
// alternatives, precedence by listing order) -> nullable/FIRST/FOLLOW
// fixed-point computation (as *character* interval sets, not a discrete
// token alphabet, since every rule - however it's named - is matched the
// same character-level way) -> ambiguity checking (every decision point
// must have pairwise-disjoint FIRST sets, extended with FOLLOW where
// nullable) -> AST synthesis of a real recursive-descent parser class,
// entirely lookahead-dispatched (no backtracking/position-restore appears
// anywhere in generated code - an unambiguous grammar, once analyzed,
// never needs it).

import std.format;
import std.algorithm;
import std.array;
import ast;
import errors;

// ===================== Character interval sets =====================

private alias CharSet = CharRange[];

private CharSet csNormalize(CharSet s) {
    if (s.length == 0) return s;
    auto sorted = s.dup;
    sort!((a, b) => a.lo < b.lo)(sorted);
    CharSet result;
    CharRange cur = sorted[0];
    foreach (r; sorted[1 .. $]) {
        if (cast(int)r.lo <= cast(int)cur.hi + 1) {
            if (cast(int)r.hi > cast(int)cur.hi) cur.hi = r.hi;
        } else {
            result ~= cur;
            cur = r;
        }
    }
    result ~= cur;
    return result;
}

private CharSet csUnion(CharSet a, CharSet b) {
    return csNormalize(a ~ b);
}

private CharSet csSingle(char c) {
    return [CharRange(c, c)];
}

private CharSet csFull() {
    return [CharRange(cast(char)0, cast(char)255)];
}

private CharSet csNegate(CharSet s) {
    auto normalized = csNormalize(s);
    CharSet result;
    int next = 0;
    foreach (r; normalized) {
        if (cast(int)r.lo > next) {
            result ~= CharRange(cast(char)next, cast(char)(cast(int)r.lo - 1));
        }
        next = cast(int)r.hi + 1;
    }
    if (next <= 0xFF) {
        result ~= CharRange(cast(char)next, cast(char)0xFF);
    }
    return result;
}

private bool csOverlaps(CharSet a, CharSet b) {
    foreach (ra; a) {
        foreach (rb; b) {
            if (cast(int)ra.lo <= cast(int)rb.hi && cast(int)rb.lo <= cast(int)ra.hi) return true;
        }
    }
    return false;
}

private bool csEquals(CharSet a, CharSet b) {
    auto na = csNormalize(a);
    auto nb = csNormalize(b);
    if (na.length != nb.length) return false;
    foreach (i; 0 .. na.length) {
        if (na[i].lo != nb[i].lo || na[i].hi != nb[i].hi) return false;
    }
    return true;
}

// ===================== Analysis IR =====================

private struct RecursiveAlt {
    GrammarAlt tail; // original alternative with its leading self-reference stripped
    int precedence;  // higher binds tighter; assigned by listing order among recursive alts only
}

private final class RuleInfo {
    string name;
    GrammarAlt[] primaryAlts;     // alternatives NOT starting with a self-reference
    RecursiveAlt[] recursiveAlts; // alternatives that DO, highest precedence first
    bool isLeftRecursive;
    bool nullable;
    CharSet first;
    CharSet follow;
}

private GrammarAlt[] allSequences(RuleInfo info) {
    GrammarAlt[] result = info.primaryAlts.dup;
    foreach (ra; info.recursiveAlts) result ~= ra.tail;
    return result;
}

// ===================== Group flattening =====================

// Replaces every `( alt | alt | ... )` Group atom (however deeply nested)
// with a RuleRef to a freshly synthesized rule holding that group's own
// alternatives - mutating the atom in place (GrammarAtom is a class, so
// this is visible through every other reference to the same node) - so
// every later analysis/codegen pass only ever needs to handle
// Literal/CharClass/Wildcard/RuleRef, never Group.
private GrammarRule[] flattenGroups(GrammarRule[] rules) {
    GrammarRule[] synthetic;
    int counter = 0;

    void flattenAtom(GrammarAtom atom, string ownerName) {
        if (atom.kind != GrammarAtomKind.Group) return;
        foreach (alt; atom.group) {
            foreach (elem; alt.elements) {
                flattenAtom(elem.atom, ownerName);
            }
        }
        counter++;
        string synthName = format("__%s_g%d", ownerName, counter);
        synthetic ~= new GrammarRule(synthName, atom.group);
        atom.kind = GrammarAtomKind.RuleRef;
        atom.ruleRef = synthName;
        atom.group = [];
    }

    foreach (r; rules) {
        foreach (alt; r.alternatives) {
            foreach (elem; alt.elements) {
                flattenAtom(elem.atom, r.name);
            }
        }
    }

    return rules ~ synthetic;
}

// ===================== Left-recursion partition =====================

private void splitLeftRecursion(RuleInfo info, GrammarAlt[] alternatives, string modulePath, int line, int column) {
    GrammarAlt[] primary;
    RecursiveAlt[] recursive;
    foreach (alt; alternatives) {
        if (alt.elements.length > 0) {
            auto first = alt.elements[0];
            if (first.quantifier == GrammarQuantifier.None &&
                    first.atom.kind == GrammarAtomKind.RuleRef && first.atom.ruleRef == info.name) {
                recursive ~= RecursiveAlt(new GrammarAlt(alt.elements[1 .. $]), 0);
                continue;
            }
        }
        primary ~= alt;
    }
    foreach (i, ref ra; recursive) {
        ra.precedence = cast(int)(recursive.length - i);
    }
    if (recursive.length > 0 && primary.length == 0) {
        throw new CompileError(
            format("Grammar rule '%s' is left-recursive but has no non-recursive alternative to use as its base case",
                info.name),
            modulePath, line, column);
    }
    info.primaryAlts = primary;
    info.recursiveAlts = recursive;
    info.isLeftRecursive = recursive.length > 0;
}

// ===================== Nullable / FIRST / FOLLOW =====================

private bool atomNullable(GrammarAtom atom, RuleInfo[string] infos) {
    final switch (atom.kind) {
        case GrammarAtomKind.Literal: return atom.literal.length == 0;
        case GrammarAtomKind.CharClass: return false;
        case GrammarAtomKind.Wildcard: return false;
        case GrammarAtomKind.RuleRef: return infos[atom.ruleRef].nullable;
        case GrammarAtomKind.Group: assert(false, "Group atoms must be flattened before analysis");
    }
}

private CharSet atomFirst(GrammarAtom atom, RuleInfo[string] infos) {
    final switch (atom.kind) {
        case GrammarAtomKind.Literal:
            return atom.literal.length > 0 ? csSingle(atom.literal[0]) : [];
        case GrammarAtomKind.CharClass:
            auto normalized = csNormalize(atom.ranges.dup);
            return atom.negated ? csNegate(normalized) : normalized;
        case GrammarAtomKind.Wildcard:
            return csFull();
        case GrammarAtomKind.RuleRef:
            return infos[atom.ruleRef].first;
        case GrammarAtomKind.Group:
            assert(false, "Group atoms must be flattened before analysis");
    }
}

private bool elementNullable(GrammarElement elem, RuleInfo[string] infos) {
    if (elem.quantifier == GrammarQuantifier.Star || elem.quantifier == GrammarQuantifier.Question) {
        return true;
    }
    return atomNullable(elem.atom, infos);
}

// Nullable + FIRST of a sequence of elements (e.g. an alternative, or the
// "rest" of one starting partway through) - cascades past a nullable
// leading element into the next one, since either could legitimately be
// what actually starts the match.
private bool sequenceNullable(GrammarElement[] elements, RuleInfo[string] infos) {
    foreach (elem; elements) {
        if (!elementNullable(elem, infos)) return false;
    }
    return true;
}

private CharSet sequenceFirst(GrammarElement[] elements, RuleInfo[string] infos) {
    CharSet result;
    foreach (elem; elements) {
        result = csUnion(result, atomFirst(elem.atom, infos));
        if (!elementNullable(elem, infos)) break;
    }
    return result;
}

private void computeNullableFirst(RuleInfo[string] infos, string[] order) {
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (name; order) {
            auto info = infos[name];
            bool newNullable = sequenceNullable([], infos); // placeholder, overwritten below
            newNullable = false;
            CharSet newFirst;
            foreach (alt; info.primaryAlts) {
                if (sequenceNullable(alt.elements, infos)) newNullable = true;
                newFirst = csUnion(newFirst, sequenceFirst(alt.elements, infos));
            }
            if (newNullable != info.nullable) { info.nullable = newNullable; changed = true; }
            if (!csEquals(newFirst, info.first)) { info.first = newFirst; changed = true; }
        }
    }
}

private void computeFollow(RuleInfo[string] infos, string[] order) {
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (name; order) {
            auto info = infos[name];
            foreach (alt; allSequences(info)) {
                foreach (i, elem; alt.elements) {
                    if (elem.atom.kind != GrammarAtomKind.RuleRef) continue;
                    auto refInfo = infos[elem.atom.ruleRef];

                    // Self-loop: a `*`/`+`-quantified rule reference can be
                    // immediately followed by another instance of itself.
                    if (elem.quantifier == GrammarQuantifier.Star || elem.quantifier == GrammarQuantifier.Plus) {
                        auto withSelf = csUnion(refInfo.follow, refInfo.first);
                        if (!csEquals(withSelf, refInfo.follow)) { refInfo.follow = withSelf; changed = true; }
                    }

                    auto rest = alt.elements[i + 1 .. $];
                    auto newFollow = csUnion(refInfo.follow, sequenceFirst(rest, infos));
                    if (rest.length == 0 || sequenceNullable(rest, infos)) {
                        newFollow = csUnion(newFollow, info.follow);
                    }
                    if (!csEquals(newFollow, refInfo.follow)) { refInfo.follow = newFollow; changed = true; }
                }
            }
        }
    }
}

// ===================== Ambiguity checking =====================

private void checkAltsDisjoint(GrammarAlt[] alts, RuleInfo info, RuleInfo[string] infos,
        string modulePath, int line, int column, string context) {
    CharSet[] sets;
    foreach (alt; alts) {
        auto f = sequenceFirst(alt.elements, infos);
        if (sequenceNullable(alt.elements, infos)) {
            f = csUnion(f, info.follow);
        }
        sets ~= f;
    }
    foreach (i; 0 .. sets.length) {
        foreach (j; i + 1 .. sets.length) {
            if (csOverlaps(sets[i], sets[j])) {
                throw new CompileError(
                    format("Grammar %s is ambiguous: alternatives %d and %d can both start with the same character - " ~
                        "predictive (lookahead-only) parsing can't tell them apart", context, i + 1, j + 1),
                    modulePath, line, column);
            }
        }
    }
}

private void checkAmbiguity(RuleInfo[string] infos, string[] order, string modulePath, int line, int column) {
    foreach (name; order) {
        auto info = infos[name];
        checkAltsDisjoint(info.primaryAlts, info, infos, modulePath, line, column,
            format("rule '%s'", name));
        if (info.isLeftRecursive) {
            GrammarAlt[] tails;
            foreach (ra; info.recursiveAlts) tails ~= ra.tail;
            checkAltsDisjoint(tails, info, infos, modulePath, line, column,
                format("rule '%s' (its left-recursive operators)", name));
        }
        foreach (alt; allSequences(info)) {
            foreach (i, elem; alt.elements) {
                if (elem.quantifier != GrammarQuantifier.Star && elem.quantifier != GrammarQuantifier.Plus) continue;
                auto elemFirst = atomFirst(elem.atom, infos);
                auto rest = alt.elements[i + 1 .. $];
                auto after = sequenceFirst(rest, infos);
                if (rest.length == 0 || sequenceNullable(rest, infos)) {
                    after = csUnion(after, info.follow);
                }
                if (csOverlaps(elemFirst, after)) {
                    throw new CompileError(
                        format("Grammar rule '%s' is ambiguous: a repeated element can't be told apart from " ~
                            "what follows it (both can start with the same character)", name),
                        modulePath, line, column);
                }
            }
        }
    }
}

// A rule name with no lowercase letters (NUMBER, IDENT, ...) is a "lexer-
// style" rule: matched character-by-character with no whitespace skipped
// between its own elements, so e.g. `NUMBER : [0-9]+ ;` can't have a
// space in the middle of a number. Anything else (expr, term, factor,
// ...) is a "parser-style" rule: whitespace is skipped before every
// element it matches (see currentRuleSkipsWs/generateElementMatch), the
// way real hand-written recursive-descent parsers (this codebase's own
// JSON/YAML ones included) always do between tokens. A synthetic group
// rule's name always contains its owning rule's (lowercase-containing)
// name, so groups are always treated as parser-style - a reasonable
// default given groups almost always appear within parser-rule contexts.
private bool isLexerRuleName(string name) {
    bool sawLetter = false;
    foreach (c; name) {
        if (c >= 'a' && c <= 'z') return false;
        if (c >= 'A' && c <= 'Z') sawLetter = true;
    }
    return sawLetter;
}

// Set once per rule, right before generating its method(s) - read by
// generateElementMatch/generateAltCore to decide whether to emit a
// leading `self.__skip_ws()` before each dispatch/element match. Global,
// mutable, single-threaded state, matching tempCounter's own convention
// below - desugarGrammar only ever runs synchronously within the D
// compiler itself.
private bool currentRuleSkipsWs = true;

private ASTNode skipWsStmt() {
    return new ExprStmt(selfMethodCall("__skip_ws", []));
}

// ===================== AST synthesis =====================

private ASTNode ident(string name) { return new Identifier(name); }
private ASTNode selfIdent() { return ident("self"); }
private ASTNode member(ASTNode obj, string name) { return new MemberExpr(obj, name); }
private ASTNode selfField(string name) { return member(selfIdent(), name); }
private ASTNode call(ASTNode callee, ASTNode[] args) { return new CallExpr(callee, args); }
private ASTNode methodCall(ASTNode obj, string name, ASTNode[] args) { return call(member(obj, name), args); }
private ASTNode selfMethodCall(string name, ASTNode[] args) { return methodCall(selfIdent(), name, args); }
private ASTNode intLit(long v) { return new IntLiteral(v); }
private ASTNode strLit(string s) { return new StringLiteral(s); }
private ASTNode boolLit(bool b) { return new BoolLiteral(b); }
private Block blk(ASTNode[] stmts) { return new Block(stmts); }
private ASTNode assign(ASTNode target, ASTNode value) { return new ExprStmt(new BinaryExpr("=", target, value)); }
private ASTNode[] single(ASTNode n) { return [n]; }
private ASTNode selfAssign(string field, ASTNode value) { return assign(selfField(field), value); }

private ASTNode peekCharExpr() {
    return methodCall(selfField("text"), "byte_at", [selfField("pos")]);
}

private ASTNode posInBoundsExpr() {
    return new BinaryExpr("<", selfField("pos"), selfField("len"));
}

private ASTNode charInSet(ASTNode chExpr, CharSet set) {
    if (set.length == 0) return boolLit(false);
    ASTNode result;
    foreach (r; set) {
        ASTNode rangeCheck;
        if (r.lo == r.hi) {
            rangeCheck = new BinaryExpr("==", chExpr, intLit(cast(int)r.lo));
        } else {
            rangeCheck = new BinaryExpr("&&",
                new BinaryExpr(">=", chExpr, intLit(cast(int)r.lo)),
                new BinaryExpr("<=", chExpr, intLit(cast(int)r.hi)));
        }
        result = (result is null) ? rangeCheck : new BinaryExpr("||", result, rangeCheck);
    }
    return result;
}

private ASTNode firstSetCondition(GrammarAtom atom, RuleInfo[string] infos) {
    if (atom.kind == GrammarAtomKind.Wildcard) {
        return posInBoundsExpr();
    }
    return new BinaryExpr("&&", posInBoundsExpr(), charInSet(peekCharExpr(), atomFirst(atom, infos)));
}

private ASTNode sequenceFirstCondition(GrammarElement[] elements, RuleInfo[string] infos) {
    ASTNode result;
    foreach (elem; elements) {
        auto c = firstSetCondition(elem.atom, infos);
        result = (result is null) ? c : new BinaryExpr("||", result, c);
        if (!elementNullable(elem, infos)) break;
    }
    return result is null ? boolLit(true) : result;
}

private string describeAtom(GrammarAtom atom) {
    final switch (atom.kind) {
        case GrammarAtomKind.Literal: return atom.literal;
        case GrammarAtomKind.CharClass: return "a matching character";
        case GrammarAtomKind.Wildcard: return "any character";
        case GrammarAtomKind.RuleRef: return atom.ruleRef;
        case GrammarAtomKind.Group: return "(...)";
    }
}

// Resolves one atom into a statement producing `childVar: ParseNode`. A
// RuleRef back to `selfRefName` (only ever set while generating a left-
// recursive rule's recursive-alternative tail) routes through the
// internal `_prec` method at `selfRefPrec` instead of the plain zero-arg
// entry point - this is what enforces left-associativity/precedence for
// an operator's right-hand operand.
private ASTNode[] generateAtomConsume(GrammarAtom atom, string childVar, string selfRefName, int selfRefPrec) {
    final switch (atom.kind) {
        case GrammarAtomKind.Literal:
            return [new VarDecl(childVar, new Type("ParseNode"),
                selfMethodCall("__match_literal", [strLit(atom.literal), intLit(atom.literal.length)]))];
        case GrammarAtomKind.CharClass:
        case GrammarAtomKind.Wildcard:
            return [new VarDecl(childVar, new Type("ParseNode"), selfMethodCall("__match_one_char", []))];
        case GrammarAtomKind.RuleRef:
            if (selfRefName.length > 0 && atom.ruleRef == selfRefName) {
                return [new VarDecl(childVar, new Type("ParseNode"),
                    selfMethodCall("parse_" ~ selfRefName ~ "_prec", [intLit(selfRefPrec)]))];
            }
            return [new VarDecl(childVar, new Type("ParseNode"), selfMethodCall("parse_" ~ atom.ruleRef, []))];
        case GrammarAtomKind.Group:
            assert(false, "Group atoms must be flattened before codegen");
    }
}

private int tempCounter = 0;

// Statements to run right before checking whether upcoming input matches
// an element/alternative - just `self.__skip_ws()` for a parser-style
// rule (see currentRuleSkipsWs), nothing at all for a lexer-style one.
private ASTNode[] wsPrefix() {
    return currentRuleSkipsWs ? [skipWsStmt()] : [];
}

private ASTNode[] generateElementMatch(GrammarElement elem, string nodeVar, RuleInfo[string] infos,
        string selfRefName, int selfRefPrec) {
    string childVar = format("__c%d", tempCounter++);
    ASTNode pushChild(string var) {
        return new ExprStmt(methodCall(member(ident(nodeVar), "children"), "push", [ident(var)]));
    }
    ASTNode errStmt() {
        return new ExprStmt(selfMethodCall("__parse_error", [strLit(describeAtom(elem.atom))]));
    }

    final switch (elem.quantifier) {
        case GrammarQuantifier.None: {
            auto cond = firstSetCondition(elem.atom, infos);
            auto consume = generateAtomConsume(elem.atom, childVar, selfRefName, selfRefPrec);
            return wsPrefix() ~ single(new IfStmt(cond, blk(consume ~ pushChild(childVar)), blk(single(errStmt()))));
        }
        case GrammarQuantifier.Question: {
            auto cond = firstSetCondition(elem.atom, infos);
            auto consume = generateAtomConsume(elem.atom, childVar, selfRefName, selfRefPrec);
            return wsPrefix() ~ single(new IfStmt(cond, blk(consume ~ pushChild(childVar))));
        }
        case GrammarQuantifier.Star: {
            // `while (cond) { ... }` can't run __skip_ws() before each
            // condition re-check by itself (WhileStmt's condition is a
            // bare expression, no statement slot) - loop-and-a-half
            // instead: `while true { skip_ws(); if !cond { break }; ... }`.
            auto cond = firstSetCondition(elem.atom, infos);
            auto consume = generateAtomConsume(elem.atom, childVar, selfRefName, selfRefPrec);
            ASTNode[] loopBody = wsPrefix() ~
                single(new IfStmt(new UnaryExpr("!", cond), blk(single(new BreakStmt())))) ~
                consume ~ single(pushChild(childVar));
            return single(new WhileStmt(boolLit(true), blk(loopBody)));
        }
        case GrammarQuantifier.Plus: {
            auto firstCond = firstSetCondition(elem.atom, infos);
            auto firstConsume = generateAtomConsume(elem.atom, childVar, selfRefName, selfRefPrec);
            string loopChildVar = format("__c%d", tempCounter++);
            auto loopCond = firstSetCondition(elem.atom, infos);
            auto loopConsume = generateAtomConsume(elem.atom, loopChildVar, selfRefName, selfRefPrec);
            ASTNode[] loopBody = wsPrefix() ~
                single(new IfStmt(new UnaryExpr("!", loopCond), blk(single(new BreakStmt())))) ~
                loopConsume ~ single(pushChild(loopChildVar));
            return wsPrefix() ~ [
                new IfStmt(firstCond, blk(firstConsume ~ pushChild(childVar)), blk(single(errStmt()))),
                new WhileStmt(boolLit(true), blk(loopBody)),
            ];
        }
    }
}

// Builds `node`, matches every element of `alt` into it in order, but
// does NOT emit a final return/assignment - callers append that
// themselves (a plain rule returns it directly; a left-recursive rule's
// primary dispatch assigns it to `left` before falling into the
// precedence loop).
private ASTNode[] generateAltCore(string ruleName, GrammarAlt alt, RuleInfo[string] infos,
        string nodeVar, string selfRefName, int selfRefPrec) {
    string startVar = format("__s%d", tempCounter++);
    ASTNode[] stmts;
    stmts ~= wsPrefix();
    stmts ~= new VarDecl(startVar, new Type("i64"), selfField("pos"));
    stmts ~= new VarDecl(nodeVar, new Type("ParseNode"), new NewExpr(new Type("ParseNode"), []));
    stmts ~= assign(member(ident(nodeVar), "rule_name"), new NewExpr(new Type("String"), [strLit(ruleName)]));
    foreach (elem; alt.elements) {
        stmts ~= generateElementMatch(elem, nodeVar, infos, selfRefName, selfRefPrec);
    }
    // The full matched span, for convenience - every leaf/terminal already
    // gets its own text_val at match time (see __match_literal/
    // __match_one_char), but a rule-level node otherwise never would.
    stmts ~= assign(member(ident(nodeVar), "text_val"),
        methodCall(selfField("text"), "byte_substring",
            [ident(startVar), new BinaryExpr("-", selfField("pos"), ident(startVar))]));
    return stmts;
}

private FunctionDecl generateNonRecursiveMethod(RuleInfo info, RuleInfo[string] infos) {
    ASTNode[] body;
    foreach (alt; info.primaryAlts) {
        body ~= wsPrefix();
        auto cond = sequenceFirstCondition(alt.elements, infos);
        string nodeVar = format("__n%d", tempCounter++);
        auto core = generateAltCore(info.name, alt, infos, nodeVar, "", 0);
        body ~= new IfStmt(cond, blk(core ~ new ReturnStmt(ident(nodeVar))));
    }
    body ~= new ExprStmt(selfMethodCall("__parse_error", [strLit(info.name)]));
    body ~= new ReturnStmt(new NullLiteral());
    return new FunctionDecl("parse_" ~ info.name, [], new Type("ParseNode"), blk(body));
}

private FunctionDecl[] generateLeftRecursiveMethods(RuleInfo info, RuleInfo[string] infos) {
    ASTNode[] body;
    string spanStartVar = format("__s%d", tempCounter++);
    body ~= new VarDecl(spanStartVar, new Type("i64"), selfField("pos"));
    body ~= new VarDecl("left", new Type("ParseNode"), new NullLiteral());
    foreach (alt; info.primaryAlts) {
        body ~= wsPrefix();
        auto cond = sequenceFirstCondition(alt.elements, infos);
        string nodeVar = format("__n%d", tempCounter++);
        auto core = generateAltCore(info.name, alt, infos, nodeVar, "", 0);
        body ~= new IfStmt(cond, blk(core ~ assign(ident("left"), ident(nodeVar))));
    }
    body ~= new IfStmt(new BinaryExpr("==", ident("left"), new NullLiteral()),
        blk([new ExprStmt(selfMethodCall("__parse_error", [strLit(info.name)]))]));

    // Each recursive alternative must be tried as a proper if/else-if/.../
    // else{break} chain, NOT a sequence of independent `if (cond) {...}
    // else { break }` statements - since none of these branches return
    // (they loop back around to try again), independent ifs would
    // incorrectly break out on the *first* alternative whose operator
    // doesn't match, even if a *later* alternative's operator does (e.g.
    // checking '+' first against a '-' would wrongly stop the whole loop
    // rather than falling through to check '-' next). Built innermost-out:
    // the last alternative's "no match" case is the real loop-exit.
    ASTNode buildDispatch(size_t idx) {
        if (idx >= info.recursiveAlts.length) {
            return new BreakStmt();
        }
        auto ra = info.recursiveAlts[idx];
        auto matchCond = sequenceFirstCondition(ra.tail.elements, infos);
        auto precCond = new BinaryExpr(">=", intLit(ra.precedence), ident("min_prec"));
        auto fullCond = new BinaryExpr("&&", matchCond, precCond);

        string nodeVar = format("__n%d", tempCounter++);
        ASTNode[] stmts;
        stmts ~= new VarDecl(nodeVar, new Type("ParseNode"), new NewExpr(new Type("ParseNode"), []));
        stmts ~= assign(member(ident(nodeVar), "rule_name"), new NewExpr(new Type("String"), [strLit(info.name)]));
        stmts ~= new ExprStmt(methodCall(member(ident(nodeVar), "children"), "push", [ident("left")]));
        foreach (elem; ra.tail.elements) {
            stmts ~= generateElementMatch(elem, nodeVar, infos, info.name, ra.precedence + 1);
        }
        // The combined node's span always starts where the original left
        // operand did (spanStartVar, fixed for the whole loop), regardless
        // of how many operators have folded into `left` so far - only the
        // right edge (self.pos) grows with each iteration.
        stmts ~= assign(member(ident(nodeVar), "text_val"),
            methodCall(selfField("text"), "byte_substring",
                [ident(spanStartVar), new BinaryExpr("-", selfField("pos"), ident(spanStartVar))]));
        stmts ~= assign(ident("left"), ident(nodeVar));

        return new IfStmt(fullCond, blk(stmts), blk(single(buildDispatch(idx + 1))));
    }

    ASTNode[] loopBody = wsPrefix() ~ single(buildDispatch(0));
    body ~= new WhileStmt(boolLit(true), blk(loopBody));
    body ~= new ReturnStmt(ident("left"));

    auto precParam = [new Parameter("min_prec", new Type("i64"))];
    auto precMethod = new FunctionDecl("parse_" ~ info.name ~ "_prec", precParam, new Type("ParseNode"), blk(body));

    ASTNode[] entryBody = [new ReturnStmt(selfMethodCall("parse_" ~ info.name ~ "_prec", [intLit(0)]))];
    auto entryMethod = new FunctionDecl("parse_" ~ info.name, [], new Type("ParseNode"), blk(entryBody));

    return [precMethod, entryMethod];
}

// Shared helpers every generated grammar class carries, regardless of its
// own rules - the same four, every time, so per-rule codegen above can
// just call them by name.
private FunctionDecl[] sharedHelperMethods() {
    FunctionDecl[] result;

    // func __skip_ws() - advances past whitespace, called before every
    // element/alternative a "parser-style" rule matches (see
    // currentRuleSkipsWs/isLexerRuleName); never called at all for a
    // "lexer-style" one, so e.g. `NUMBER : [0-9]+ ;` can't have a space
    // in the middle of a number.
    CharSet wsSet = [CharRange(' ', ' '), CharRange('\t', '\t'), CharRange('\n', '\n'), CharRange('\r', '\r')];
    ASTNode[] skipWsBody = [
        new WhileStmt(new BinaryExpr("&&", posInBoundsExpr(), charInSet(peekCharExpr(), wsSet)),
            blk([selfAssign("pos", new BinaryExpr("+", selfField("pos"), intLit(1)))])),
    ];
    result ~= new FunctionDecl("__skip_ws", [], new Type("void"), blk(skipWsBody));

    // func __match_one_char() -> ParseNode
    ASTNode[] oneCharBody = [
        new VarDecl("node", new Type("ParseNode"), new NewExpr(new Type("ParseNode"), [])),
        assign(member(ident("node"), "text_val"),
            methodCall(selfField("text"), "byte_substring", [selfField("pos"), intLit(1)])),
        assign(member(ident("node"), "is_terminal"), boolLit(true)),
        selfAssign("pos", new BinaryExpr("+", selfField("pos"), intLit(1))),
        new ReturnStmt(ident("node")),
    ];
    result ~= new FunctionDecl("__match_one_char", [], new Type("ParseNode"), blk(oneCharBody));

    // func __match_literal(lit: u8*, lit_len: i64) -> ParseNode
    auto litParams = [new Parameter("lit", new Type("u8", 1)), new Parameter("lit_len", new Type("i64"))];
    ASTNode[] litBody = [
        new IfStmt(new UnaryExpr("!",
                new BinaryExpr("==",
                    methodCall(selfField("text"), "byte_substring", [selfField("pos"), ident("lit_len")]),
                    ident("lit"))),
            blk([new ExprStmt(selfMethodCall("__parse_error", [ident("lit")]))])),
        new VarDecl("node", new Type("ParseNode"), new NewExpr(new Type("ParseNode"), [])),
        assign(member(ident("node"), "text_val"),
            methodCall(selfField("text"), "byte_substring", [selfField("pos"), ident("lit_len")])),
        assign(member(ident("node"), "is_terminal"), boolLit(true)),
        selfAssign("pos", new BinaryExpr("+", selfField("pos"), ident("lit_len"))),
        new ReturnStmt(ident("node")),
    ];
    result ~= new FunctionDecl("__match_literal", litParams, new Type("ParseNode"), blk(litBody));

    // func __parse_error(expected: u8*)
    auto errParams = [new Parameter("expected", new Type("u8", 1))];
    ASTNode[] errBody = [
        new VarDecl("buf", new Type("u8", 0, true, 256)),
        new ExprStmt(call(ident("ksnprintf"), [
            new CastExpr(new Type("u8", 1), ident("buf")),
            intLit(256),
            strLit("Parse error at position %d: expected %s"),
            selfField("pos"),
            ident("expected"),
        ])),
        new ExprStmt(call(ident("llpl_panic"), [new CastExpr(new Type("u8", 1), ident("buf"))])),
    ];
    result ~= new FunctionDecl("__parse_error", errParams, new Type("void"), blk(errBody));

    return result;
}

// Turns one `grammar Name { ... }` declaration into the ClassDecl it
// actually compiles to - a drop-in replacement for the GrammarDecl in
// `prog.declarations`, exactly like desugarTaggedEnum's EnumDecl ->
// StructDecl+FunctionDecl[] replacement, so every later pass (registries,
// forward declarations, generateClass) sees only an ordinary ClassDecl
// and needs no GrammarDecl-specific handling of its own.
ASTNode[] desugarGrammar(GrammarDecl decl, string modulePath) {
    if (decl.rules.length == 0) {
        throw new CompileError(format("Grammar '%s' has no rules", decl.name), modulePath, decl.line, decl.column);
    }

    string startRule = decl.rules[0].name;
    GrammarRule[] allRules = flattenGroups(decl.rules);

    RuleInfo[string] infos;
    string[] order;
    foreach (r; allRules) {
        auto info = new RuleInfo();
        info.name = r.name;
        splitLeftRecursion(info, r.alternatives, modulePath, decl.line, decl.column);
        infos[r.name] = info;
        order ~= r.name;
    }

    computeNullableFirst(infos, order);
    computeFollow(infos, order);
    checkAmbiguity(infos, order, modulePath, decl.line, decl.column);

    tempCounter = 0;
    FunctionDecl[] methods = sharedHelperMethods();
    foreach (name; order) {
        auto info = infos[name];
        currentRuleSkipsWs = !isLexerRuleName(name);
        if (info.isLeftRecursive) {
            methods ~= generateLeftRecursiveMethods(info, infos);
        } else {
            methods ~= generateNonRecursiveMethod(info, infos);
        }
    }

    VarDecl[] fields = [
        new VarDecl("text", new Type("String"), null, false, decl.line, decl.column),
        new VarDecl("pos", new Type("i64"), null, false, decl.line, decl.column),
        new VarDecl("len", new Type("i64"), null, false, decl.line, decl.column),
    ];

    auto ctorParams = [new Parameter("text", new Type("String"))];
    ASTNode[] ctorBody = [
        selfAssign("text", ident("text")),
        selfAssign("pos", intLit(0)),
        selfAssign("len", methodCall(ident("text"), "byte_len", [])),
    ];
    auto ctor = new FunctionDecl(decl.name ~ "_constructor", ctorParams, new Type("void"), blk(ctorBody),
        false, false, false, decl.line, decl.column);
    auto dtor = new FunctionDecl(decl.name ~ "_destructor", [], new Type("void"), blk([]),
        false, false, false, decl.line, decl.column);

    auto classDecl = new ClassDecl(decl.name, fields, [ctor], dtor, methods, decl.line, decl.column);
    classDecl.namespaceSegments = decl.namespaceSegments;

    grammarStartRule[mangled(decl.namespaceSegments, decl.name)] = "parse_" ~ startRule;

    return [classDecl];
}

// Mangled grammar-generated-class name -> its start rule's parse method
// name (`"parse_" ~ firstDeclaredRuleName`) - populated by desugarGrammar,
// read by codegen.d's two CallExpr choke points to desugar `Name(text)`
// into `(new Name(text)).parse_<start>()`. Keyed the same way
// codegen.d's own `mangled()` helper mangles any other namespaced
// declaration.
string[string] grammarStartRule;

private string mangled(string[] namespaceSegments, string name) {
    return namespaceSegments.length > 0 ? namespaceSegments.join("_") ~ "_" ~ name : name;
}
