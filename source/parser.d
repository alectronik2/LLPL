module parser;

import std.stdio;
import std.format;
import std.conv;
import std.string : strip, endsWith;
import lexer;
import ast;
import errors;

class Parser {
    private Token[] tokens;
    private size_t pos;
    private Token current;
    private string filePath;

    // Suppresses struct-literal parsing (`Name { ... }`) while parsing an
    // if/while/for/match/foreach construct's own condition/subject/iterable
    // expression, since a `{` there would otherwise be ambiguous between
    // "start of a struct literal" and "start of this construct's body
    // block" (the same classic ambiguity Rust/Go's struct literals have,
    // solved the same way: forbid it there, but re-allow it as soon as
    // we're inside an enclosing `(...)`/`[...]`/argument list, where the
    // matching close token removes the ambiguity regardless of the outer
    // context - see argumentList() and primary()'s parenthesized/array
    // cases, which reset this around their own contents).
    private bool noStructLiteral = false;

    this(Token[] tokens, string filePath = "") {
        this.tokens = tokens;
        this.pos = 0;
        this.current = tokens.length > 0 ? tokens[0] : Token(TokenType.EOF, "", 0, 0);
        this.filePath = filePath;
    }

    private void advance() {
        if (pos + 1 < tokens.length) {
            pos++;
            current = tokens[pos];
        }
    }

    private bool check(TokenType type) {
        return current.type == type;
    }

    // Token at `pos + offset`, clamped to the last token (EOF) if out of range.
    private Token peek(int offset) {
        size_t idx = pos + offset;
        return idx < tokens.length ? tokens[idx] : tokens[$ - 1];
    }

    // A macro invocation (`NAME!(...)` or `Ns.NAME!(...)`) is the only
    // construct where `!` follows an identifier/dotted-path directly, so
    // spotting it just means scanning past the dotted path and checking
    // for `! (` - no ambiguity with unary `!`, which never follows a name
    // like that (there's no postfix operator in the grammar).
    private bool isMacroInvocationAhead() {
        if (!check(TokenType.Identifier)) return false;
        int offset = 1;
        while (peek(offset).type == TokenType.Dot && peek(offset + 1).type == TokenType.Identifier) {
            offset += 2;
        }
        return peek(offset).type == TokenType.Not && peek(offset + 1).type == TokenType.LeftParen;
    }

    // True when `current` starts a new source line relative to the last
    // consumed token. `*`, `-`, and `&` each double as both a unary prefix
    // operator (deref, negate, address-of) and a binary infix one
    // (multiply, subtract, bitwise-and), so a statement that legitimately
    // starts with one of these right after a preceding statement (e.g.
    // `foo()` then `*p = 1` on the next line) is grammatically ambiguous -
    // without this check it's greedily read as one continued expression
    // (`foo() * p = 1`). Resolved the same way Go/Kotlin's newline-
    // sensitive parsing does: one of these operators only continues the
    // previous expression if it stays on the same line as what precedes
    // it; on a new line, it's instead read as the start of a fresh unary
    // expression/statement. `+`, `/`, `%` have no unary form in this
    // grammar, so they're never ambiguous and are unaffected - they keep
    // continuing across a line break exactly as before.
    private bool newlineBeforeCurrent() {
        return pos > 0 && current.line > tokens[pos - 1].line;
    }

    private bool match(TokenType[] types...) {
        foreach (type; types) {
            if (check(type)) {
                advance();
                return true;
            }
        }
        return false;
    }

    private Token expect(TokenType type, string message = "") {
        if (!check(type)) {
            string msg = message.length > 0 ? message : format("Expected %s, got %s", type, current.type);
            error(msg);
        }
        Token tok = current;
        advance();
        return tok;
    }

    private Token expectName(string message = "Expected identifier") {
        // `match` and `sizeof` are reserved keywords everywhere else, but
        // still need to work as a member name after `.` - `x.match` (a
        // field/method literally named "match") and `x.sizeof` (see
        // codegen.d's `.sizeof` property) are both unambiguous in that
        // position, so allow them there specifically.
        if (check(TokenType.Identifier) || check(TokenType.Match) || check(TokenType.Sizeof)) {
            Token tok = current;
            advance();
            return tok;
        }
        error(message);
        return current;
    }

    private void error(string message) {
        throw new CompileError(message, filePath, current.line, current.column);
    }

    private void errorAt(int line, int column, string message) {
        throw new CompileError(message, filePath, line, column);
    }

    // Strips a trailing `:radix` and/or `:width` format hint off one
    // interpolation's raw captured source, e.g. "n:hex" -> ("n", hex),
    // "n:016" -> ("n", width 16, zero-padded), "n:016:hex" -> ("n", width
    // 16 zero-padded, hex). Order is fixed (width before radix, as
    // written) since a bare digit run is unambiguous - it can't also be
    // "hex"/"oct"/"bin" - so this just peels the radix off the end first,
    // then the width off whatever's left. Colon is safe as the delimiter
    // here (unlike, say, a comma) because it never otherwise appears at
    // the tail of a bare LLPL expression - no ternary, no slicing, no
    // trailing type ascription - so this can't misfire on a real
    // expression that happens to end in a name like "hex" or in digits.
    private void splitInterpolationFormat(string raw, out string exprSource, out InterpFormat spec) {
        string trimmed = raw.strip();

        static immutable string[3] kinds = ["hex", "oct", "bin"];
        foreach (kind; kinds) {
            string suffix = ":" ~ kind;
            if (trimmed.endsWith(suffix)) {
                spec.radix = kind;
                trimmed = trimmed[0 .. $ - suffix.length];
                break;
            }
        }

        ptrdiff_t lastColon = -1;
        foreach_reverse (i, c; trimmed) {
            if (c == ':') { lastColon = i; break; }
        }
        if (lastColon >= 0) {
            string candidate = trimmed[lastColon + 1 .. $];
            bool allDigits = candidate.length > 0;
            foreach (c; candidate) {
                if (c < '0' || c > '9') { allDigits = false; break; }
            }
            if (allDigits) {
                spec.zeroPad = candidate.length > 1 && candidate[0] == '0';
                spec.width = to!int(candidate);
                trimmed = trimmed[0 .. lastColon];
            }
        }

        exprSource = trimmed;
    }

    // Parses one `\(...)` interpolation's raw captured source (see
    // Lexer.captureInterpolationExpr) as a standalone expression, by
    // re-lexing and re-parsing just that substring. The sub-lexer's own
    // line/column numbering restarts at 1:1 within the substring rather
    // than the enclosing file, so the result is re-stamped to the position
    // of the string literal itself - not perfectly precise for an error
    // deep inside a multi-part interpolated expression, but close enough
    // to find, and far better than losing the position entirely.
    private ASTNode parseInterpolationExpr(string raw, int line, int column) {
        auto subLexer = new Lexer(raw);
        Token[] subTokens = subLexer.tokenize();
        auto subParser = new Parser(subTokens, filePath);
        ASTNode expr = subParser.expression();
        expr.line = line;
        expr.column = column;
        return expr;
    }

    // Converts the raw text of an Integer token (as produced by the lexer,
    // radix prefix and all) to its value. Shared by primary() and enum
    // member value parsing. IntLiteral.value is a `long`, but that's just
    // this compiler's 64-bit bit-container for integer literals, not a
    // claim that literals are signed - `uint`'s full range (up to
    // 2^64 - 1, e.g. 0xFFFFFFFFFFFFFFFF or the decimal 18446744073709551615)
    // doesn't fit `long.max`, so parsing as `ulong` first and reinterpreting
    // the bit pattern via a cast (not `to!long`, which throws on exactly
    // these values) is required to accept them at all.
    private long parseIntegerValue(string numStr) {
        string prefix = numStr.length > 2 ? numStr[0..2] : "";
        if (prefix == "0x" || prefix == "0X") {
            return cast(long) to!ulong(numStr[2..$], 16);
        } else if (prefix == "0b" || prefix == "0B") {
            return cast(long) to!ulong(numStr[2..$], 2);
        } else if (prefix == "0o" || prefix == "0O") {
            return cast(long) to!ulong(numStr[2..$], 8);
        }
        return cast(long) to!ulong(numStr);
    }

    Program parse() {
        ASTNode[] declarations;
        while (!check(TokenType.EOF)) {
            declarations ~= declaration();
        }
        return new Program(declarations);
    }

    private ASTNode declaration() {
        if (check(TokenType.Hash)) {
            return hashDirective();
        }
        VarAttribute[] attrs = parseAttributes();
        if (attrs.length > 0 && !(check(TokenType.Let) || check(TokenType.Const) ||
                check(TokenType.Volatile) || check(TokenType.Class) ||
                check(TokenType.Struct) || check(TokenType.Packed))) {
            error("Attributes are currently only supported on global variables, classes, and structs");
        }
        if (check(TokenType.Import)) {
            return importStmt();
        } else if (check(TokenType.Using)) {
            return usingNamespaceStmt();
        } else if (check(TokenType.Namespace)) {
            return namespaceDecl();
        } else if (check(TokenType.Enum)) {
            return enumDecl();
        } else if (check(TokenType.Macro)) {
            return macroDecl();
        } else if (check(TokenType.Alias)) {
            return aliasDecl();
        } else if (check(TokenType.Interrupt) || check(TokenType.Function)) {
            return functionDecl();
        } else if (check(TokenType.Class)) {
            return classDecl(attrs);
        } else if (check(TokenType.Struct) || check(TokenType.Packed)) {
            return structDecl(attrs);
        } else if (check(TokenType.Union)) {
            return unionDecl();
        } else if (check(TokenType.Extern)) {
            return externDecl();
        } else if (check(TokenType.Trait)) {
            return traitDecl();
        } else if (check(TokenType.Impl)) {
            return implDecl();
        } else if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
            auto decl = letDecl();
            if (auto varDecl = cast(VarDecl)decl) {
                varDecl.attributes = attrs;
            }
            return decl;
        } else {
            error("Expected declaration");
            return null;
        }
    }

    private VarAttribute[] parseAttributes() {
        VarAttribute[] attrs;
        while (match(TokenType.At)) {
            Token nameTok = expect(TokenType.Identifier, "Expected attribute name after '@'");
            auto attr = new VarAttribute(nameTok.value, nameTok.line, nameTok.column);
            if (match(TokenType.LeftParen)) {
                if (check(TokenType.String)) {
                    attr.stringValue = current.value;
                    attr.hasStringValue = true;
                    advance();
                } else if (check(TokenType.Integer)) {
                    attr.intValue = parseIntegerValue(current.value);
                    attr.hasIntValue = true;
                    advance();
                } else {
                    error("Expected string or integer attribute argument");
                }
                expect(TokenType.RightParen);
            }
            attrs ~= attr;
        }
        return attrs;
    }

    // `#link "NAME"` / `#flags "..."` - see ast.d's LinkDecl/FlagsDecl for
    // what these actually do. Both are standalone directives (not attached
    // to any other declaration), so this is checked for and parsed before
    // parseAttributes()/the rest of declaration() ever runs, the same way
    // import/using are. Both share the same `# IDENT STRING` shape, so one
    // function parses either, dispatching on the identifier.
    private ASTNode hashDirective() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Hash);
        Token nameTok = expect(TokenType.Identifier, "Expected a directive name after '#'");
        if (nameTok.value == "link") {
            Token libTok = expect(TokenType.String, "Expected a string library name after '#link'");
            return new LinkDecl(libTok.value, startLine, startColumn);
        } else if (nameTok.value == "flags") {
            Token flagsTok = expect(TokenType.String, "Expected a string of compiler flags after '#flags'");
            return new FlagsDecl(flagsTok.value, startLine, startColumn);
        }
        error(format("Unknown compiler directive '#%s'", nameTok.value));
        return null;
    }

    private NamespaceDecl namespaceDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Namespace);
        string[] segments = [expect(TokenType.Identifier).value];
        while (match(TokenType.Dot)) {
            segments ~= expect(TokenType.Identifier).value;
        }
        expect(TokenType.LeftBrace);

        ASTNode[] declarations;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            declarations ~= declaration();
        }

        expect(TokenType.RightBrace);

        // `namespace Foo.Bar { ... }` is sugar for `namespace Foo {
        // namespace Bar { ... } }` - build the nesting from the innermost
        // segment outward, so codegen.d's flattenNamespaces (which
        // already recurses through nested NamespaceDecl nodes to support
        // that written-out form) handles this with no changes at all.
        NamespaceDecl result = new NamespaceDecl(segments[$ - 1], declarations, startLine, startColumn);
        foreach_reverse (i; 0 .. segments.length - 1) {
            result = new NamespaceDecl(segments[i], [result], startLine, startColumn);
        }
        return result;
    }

    // Two forms share the `enum` keyword, disambiguated by whether *any*
    // member uses `Name(field: type, ...)`:
    //
    //   - Plain: `enum Name[: Type] { A[, B = value]*, }` desugars straight
    //     into a NamespaceDecl of const VarDecls with auto-incrementing
    //     IntLiteral values (C enum semantics: an explicit value resumes
    //     auto-increment from there). This reuses every bit of the existing
    //     namespace/const machinery in the code generator, so plain enums
    //     need zero codegen of their own - `EnumName.MEMBER` resolves
    //     exactly like any other namespaced const, unchanged since before
    //     tagged enums existed.
    //   - Tagged: `enum Name { Variant(field: type, ...), Other, ... }` - a
    //     real sum type, where each variant can carry its own data. Parses
    //     into an EnumDecl (variant field lists reuse paramList(), the same
    //     parser a function's parameter list uses); codegen.d's
    //     desugarTaggedEnum does the actual work of turning that into a
    //     struct and per-variant constructor functions, and generateMatch
    //     recognizes `case Name.Variant(binding, ...)` as a destructuring
    //     pattern against that encoding.
    //
    // Every member is parsed the same way up front regardless of which
    // form this turns out to be - only once the whole member list is in
    // hand (specifically, only once *a* member's parens are seen) does it
    // become clear which desugaring applies, so an early member can't
    // commit to being a plain int constant before a later one reveals this
    // is actually a tagged enum.
    private ASTNode enumDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Enum);
        string name = expect(TokenType.Identifier).value;

        Type backingType = new Type("int");
        bool hasExplicitBackingType = false;
        if (match(TokenType.Colon)) {
            backingType = parseType();
            hasExplicitBackingType = true;
        }

        expect(TokenType.LeftBrace);

        string[] memberNames;
        int[] memberLines;
        int[] memberColumns;
        Parameter[][] memberFields; // empty (not null) when a member has no `(...)`
        bool[] memberHasFields;
        bool[] memberHasValue;
        long[] memberValues;
        bool isTagged = false;

        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            int memberLine = current.line;
            int memberColumn = current.column;
            string memberName = expect(TokenType.Identifier).value;

            Parameter[] fields;
            bool hasFields = false;
            bool hasValue = false;
            long value = 0;

            if (match(TokenType.LeftParen)) {
                isTagged = true;
                hasFields = true;
                bool isVariadic;
                fields = paramList(isVariadic);
                if (isVariadic) {
                    error("Tagged enum variants can't be variadic");
                }
                expect(TokenType.RightParen);
            } else if (match(TokenType.Assign)) {
                bool negative = match(TokenType.Minus);
                hasValue = true;
                value = parseIntegerValue(expect(TokenType.Integer).value);
                if (negative) value = -value;
            }

            memberNames ~= memberName;
            memberLines ~= memberLine;
            memberColumns ~= memberColumn;
            memberFields ~= fields;
            memberHasFields ~= hasFields;
            memberHasValue ~= hasValue;
            memberValues ~= value;

            if (!match(TokenType.Comma)) break;
        }

        expect(TokenType.RightBrace);

        if (isTagged) {
            if (hasExplicitBackingType) {
                errorAt(startLine, startColumn,
                    "Tagged enum variants can't have an explicit backing type (':Type') - " ~
                    "the discriminant is always a plain int");
            }
            EnumVariant[] variants;
            foreach (i, memberName; memberNames) {
                if (memberHasValue[i]) {
                    errorAt(memberLines[i], memberColumns[i],
                        "Tagged enum variants can't have an explicit '= value' - tags are " ~
                        "assigned automatically in declaration order");
                }
                variants ~= new EnumVariant(memberName, memberFields[i], memberLines[i], memberColumns[i]);
            }
            return new EnumDecl(name, variants, startLine, startColumn);
        }

        ASTNode[] members;
        long nextValue = 0;
        foreach (i, memberName; memberNames) {
            long value = memberHasValue[i] ? memberValues[i] : nextValue;
            nextValue = value + 1;
            Type memberType = new Type(backingType.name, backingType.pointerDepth,
                backingType.isArray, backingType.arraySize);
            members ~= new VarDecl(memberName, memberType, new IntLiteral(value, memberLines[i], memberColumns[i]),
                true, memberLines[i], memberColumns[i]);
        }
        return new NamespaceDecl(name, members, startLine, startColumn);
    }

    // `macro NAME(param, ...) { statements }` - params are plain names (no
    // types: substitution is purely syntactic, so whatever's inferred at
    // each call site applies). The body is parsed like any other block;
    // expansion happens later, in the code generator.
    private MacroDecl macroDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Macro);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftParen);

        string[] params;
        if (!check(TokenType.RightParen)) {
            do {
                params ~= expect(TokenType.Identifier).value;
            } while (match(TokenType.Comma));
        }
        expect(TokenType.RightParen);

        Block body_ = block();
        return new MacroDecl(name, params, body_, startLine, startColumn);
    }

    private ASTNode aliasDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Alias);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.Assign);

        // `alias NAME = [ ... ]` - a named array literal (see
        // ArrayAliasDecl's own comment), not the symbol/type alias
        // grammar below (which always starts with an identifier - a
        // bracket here is unambiguous). Reuses the ordinary expression
        // parser rather than hand-rolling bracket/comma parsing again -
        // primary()'s own array-literal case already does exactly that.
        if (check(TokenType.LeftBracket)) {
            ASTNode literal = expression();
            auto arrayLit = cast(ArrayLiteral)literal;
            if (arrayLit is null) {
                errorAt(startLine, startColumn, "Expected an array literal ('[ ... ]') after '='");
            }
            return new ArrayAliasDecl(name, arrayLit.elements, startLine, startColumn);
        }

        string[] targetPath = [expect(TokenType.Identifier).value];
        while (match(TokenType.Dot)) {
            targetPath ~= expect(TokenType.Identifier).value;
        }

        // A trailing `*`/`[...]` (or a bare primitive name with neither)
        // marks this as a *type* alias rather than a symbol alias - see
        // the AliasDecl doc comment.
        int pointerDepth = 0;
        bool isArray = false;
        int arraySize = 0;
        while (match(TokenType.Star)) {
            pointerDepth++;
        }
        if (match(TokenType.LeftBracket)) {
            isArray = true;
            if (check(TokenType.Integer)) {
                arraySize = to!int(current.value);
                advance();
            }
            expect(TokenType.RightBracket);
        }

        return new AliasDecl(name, targetPath, pointerDepth, isArray, arraySize, startLine, startColumn);
    }

    private ImportStmt importStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Import);

        ImportedName[] names;
        bool isSelective = false;

        // Selective import: import { Foo, Bar as Baz } from "path"
        if (match(TokenType.LeftBrace)) {
            isSelective = true;
            if (!check(TokenType.RightBrace)) {
                do {
                    string original = expect(TokenType.Identifier).value;
                    string localAlias = "";
                    if (match(TokenType.As)) {
                        localAlias = expect(TokenType.Identifier).value;
                    }
                    names ~= ImportedName(original, localAlias);
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightBrace);
            expect(TokenType.From);
        }

        // Canonical form: `import hal` or `import hal.serial` (dotted path
        // segments become directory separators). The quoted form is still
        // accepted for paths that aren't valid identifiers.
        string modulePath;
        if (check(TokenType.String)) {
            modulePath = expect(TokenType.String).value;
        } else {
            modulePath = expect(TokenType.Identifier).value;
            while (match(TokenType.Dot)) {
                modulePath ~= "/" ~ expect(TokenType.Identifier).value;
            }
        }

        string alias_ = "";
        if (match(TokenType.As)) {
            alias_ = expect(TokenType.Identifier).value;
        }

        return new ImportStmt(modulePath, alias_, names, isSelective, startLine, startColumn);
    }

    private UsingNamespaceStmt usingNamespaceStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Using);
        expect(TokenType.Namespace);

        // Parse the namespace path: Foo or Foo.Bar.Baz
        string namespacePath = expect(TokenType.Identifier).value;
        while (match(TokenType.Dot)) {
            namespacePath ~= "." ~ expect(TokenType.Identifier).value;
        }

        return new UsingNamespaceStmt(namespacePath, startLine, startColumn);
    }

    // Parses a comma-separated `name: Type` parameter list, with an optional
    // trailing `...` marking the function as variadic (used to bind to a C
    // vararg function like the runtime's `snprintf`). ISO C requires at
    // least one named parameter before `...`, so this does too. A
    // parameter can also declare `= expression` as a default value (see
    // ast.Parameter.defaultValue/codegen.d's resolveCallArguments) - once
    // one parameter has a default, every parameter after it must too, so a
    // purely positional call always unambiguously fills left-to-right.
    private Parameter[] paramList(out bool isVariadic) {
        Parameter[] params;
        isVariadic = false;
        bool sawDefault = false;
        if (!check(TokenType.RightParen)) {
            do {
                if (match(TokenType.Ellipsis)) {
                    isVariadic = true;
                    break;
                }
                string paramName = expect(TokenType.Identifier).value;
                expect(TokenType.Colon);
                Type paramType = parseType();
                ASTNode defaultValue = null;
                if (match(TokenType.Assign)) {
                    defaultValue = expression();
                    sawDefault = true;
                } else if (sawDefault) {
                    error(format(
                        "Parameter '%s' has no default value, but appears after a parameter that does",
                        paramName));
                }
                params ~= new Parameter(paramName, paramType, defaultValue);
            } while (match(TokenType.Comma));
        }
        if (isVariadic && params.length == 0) {
            error("A variadic function needs at least one named parameter before '...'");
        }
        return params;
    }

    private FunctionDecl externDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Extern);
        expect(TokenType.Function);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftParen);

        bool isVariadic;
        Parameter[] params = paramList(isVariadic);
        expect(TokenType.RightParen);

        Type returnType = new Type("void");
        if (match(TokenType.Arrow)) {
            returnType = parseType();
        }

        return new FunctionDecl(name, params, returnType, null, true, false, isVariadic, startLine, startColumn);
    }

    // Operator tokens that can appear after `operator` in a method
    // declaration (`func operator+(other: T) -> T`). Arity (0 vs 1
    // parameters) disambiguates the unary/binary form of "-" once the
    // parameter list is known; see ast.operatorMethodName.
    private bool isOverloadableOperatorToken() {
        switch (current.type) {
            case TokenType.Plus: case TokenType.Minus: case TokenType.Star: case TokenType.Slash:
            case TokenType.Percent: case TokenType.Equal: case TokenType.NotEqual: case TokenType.Less:
            case TokenType.Greater: case TokenType.LessEqual: case TokenType.GreaterEqual:
            case TokenType.BitwiseAnd: case TokenType.BitwiseOr: case TokenType.BitwiseXor:
            case TokenType.LeftShift: case TokenType.RightShift: case TokenType.Not: case TokenType.BitwiseNot:
                return true;
            default:
                return false;
        }
    }

    // `<T, U>` after a class/struct/(non-operator) function name - see
    // ast.d's typeParams fields. Optional; an empty return means the
    // declaration is ordinary (non-generic). Not offered after `operator`
    // (operators stay non-generic - keeps codegen's operator-overload
    // lookup simple, and there's no real use case for a generic operator).
    //
    // Each parameter may carry a single trait bound (`T: TraitName`) -
    // `bounds` is parallel to the returned array (same length; "" for an
    // unbounded parameter), checked at monomorphization time against
    // codegen.d's traitImplemented registry. No `T: A + B` (multiple
    // bounds) in v1 - not needed for anything this language's standard
    // library actually requires yet, and a straightforward extension of
    // this same loop later if it is.
    private string[] typeParamList(out string[] bounds) {
        string[] params;
        if (match(TokenType.Less)) {
            do {
                params ~= expect(TokenType.Identifier).value;
                string bound = "";
                if (match(TokenType.Colon)) {
                    bound = expect(TokenType.Identifier).value;
                }
                bounds ~= bound;
            } while (match(TokenType.Comma));
            expect(TokenType.Greater);
        }
        return params;
    }

    private FunctionDecl functionDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        bool isInterrupt = match(TokenType.Interrupt);
        expect(TokenType.Function);

        string name;
        string[] typeParams;
        string[] typeParamBounds;
        bool isOperator = false;
        int operatorLine = current.line;
        int operatorColumn = current.column;
        string rawOp;
        if (match(TokenType.Operator)) {
            isOperator = true;
            if (match(TokenType.LeftBracket)) {
                // `operator[]` (subscript) - the only overloadable operator
                // that's a token pair rather than a single token, so it
                // can't go through isOverloadableOperatorToken.
                expect(TokenType.RightBracket);
                rawOp = "[]";
            } else if (isOverloadableOperatorToken()) {
                rawOp = current.value;
                advance();
            } else {
                error("Expected an overloadable operator after 'operator'");
            }
            name = rawOp; // placeholder; resolved to its C-safe name below
        } else {
            name = expectName("Expected function name").value;
            typeParams = typeParamList(typeParamBounds);
        }

        expect(TokenType.LeftParen);

        bool isVariadic;
        Parameter[] params = paramList(isVariadic);
        expect(TokenType.RightParen);

        Type returnType = new Type("void");
        if (match(TokenType.Arrow)) {
            returnType = parseType();
        }

        Block body_ = block();

        if (isOperator) {
            string resolved = operatorMethodName(rawOp, params.length == 0);
            if (resolved.length == 0) {
                errorAt(operatorLine, operatorColumn,
                    format("'%s' isn't an overloadable %s operator", rawOp,
                        params.length == 0 ? "unary" : "binary"));
            }
            name = resolved;
        }

        return new FunctionDecl(name, params, returnType, body_, false, isInterrupt, isVariadic,
            startLine, startColumn, typeParams, typeParamBounds);
    }

    private ClassDecl classDecl(VarAttribute[] attrs = []) {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Class);
        string name = expect(TokenType.Identifier).value;
        string[] typeParamBounds;
        string[] typeParams = typeParamList(typeParamBounds);
        expect(TokenType.LeftBrace);

        VarDecl[] fields;
        FunctionDecl[] constructors;
        FunctionDecl destructor = null;
        FunctionDecl[] methods;

        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            // `private func`/`private let`/`private x: T` - only a method
            // or field can be private (see FunctionDecl/VarDecl.isPrivate);
            // a constructor/destructor always needs to be reachable via
            // `new`/automatic cleanup, so `private` isn't offered there.
            bool isPrivateMember = match(TokenType.Private);
            bool isStaticMember = match(TokenType.Static);
            if (check(TokenType.Constructor)) {
                constructors ~= constructorDecl(name);
            } else if (check(TokenType.Destructor)) {
                destructor = destructorDecl(name);
            } else if (check(TokenType.Function)) {
                auto method = functionDecl();
                method.isPrivate = isPrivateMember;
                method.isStatic = isStaticMember;
                methods ~= method;
            } else if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
                auto field = varDecl();
                field.isPrivate = isPrivateMember;
                fields ~= field;
            } else if (check(TokenType.Identifier) && peek(1).type == TokenType.Colon) {
                int declLine = current.line;
                int declColumn = current.column;
                auto field = varDeclBody(declLine, declColumn, false, false);
                field.isPrivate = isPrivateMember;
                fields ~= field;
            } else {
                error("Expected field or method declaration");
            }
        }

        expect(TokenType.RightBrace);
        return new ClassDecl(name, fields, constructors, destructor, methods, startLine, startColumn,
            typeParams, typeParamBounds, attrs);
    }

    private StructDecl structDecl(VarAttribute[] attrs = []) {
        int startLine = current.line;
        int startColumn = current.column;
        bool packed = match(TokenType.Packed);
        expect(TokenType.Struct);
        string name = expect(TokenType.Identifier).value;
        string[] typeParamBounds;
        string[] typeParams = typeParamList(typeParamBounds);
        expect(TokenType.LeftBrace);

        VarDecl[] fields;
        FunctionDecl[] constructors;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
                fields ~= varDecl();
            } else if (check(TokenType.Constructor)) {
                constructors ~= constructorDecl(name);
            } else {
                error("Expected field or constructor declaration");
            }
        }

        expect(TokenType.RightBrace);
        return new StructDecl(name, fields, packed, startLine, startColumn, typeParams, typeParamBounds, attrs,
            constructors);
    }

    // `union Name { let field: T  ...  constructor(...) { ... } }` - same
    // shape as structDecl just above, minus `packed`/generics/attributes
    // (a union's overlapping layout makes `packed` meaningless, and this
    // type exists mainly to bind a real C library's own union exactly -
    // see UnionDecl's own doc comment - not to be a fully general type).
    private UnionDecl unionDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Union);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftBrace);

        VarDecl[] fields;
        FunctionDecl[] constructors;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
                fields ~= varDecl();
            } else if (check(TokenType.Constructor)) {
                constructors ~= constructorDecl(name);
            } else {
                error("Expected field or constructor declaration");
            }
        }

        expect(TokenType.RightBrace);
        return new UnionDecl(name, fields, startLine, startColumn, constructors);
    }

    // `trait Name { func sig(...) -> T  func sig2(...) -> T  ... }` -
    // method *signatures* only, no bodies, no braces per signature (see
    // ast.TraitDecl's doc comment on why - these never get generated as
    // code, only used to validate an `impl` block).
    private TraitDecl traitDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Trait);
        string name = expect(TokenType.Identifier).value;
        string[] typeParamBounds;
        string[] typeParams = typeParamList(typeParamBounds);
        expect(TokenType.LeftBrace);

        FunctionDecl[] methods;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            int sigLine = current.line;
            int sigColumn = current.column;
            expect(TokenType.Function);

            // `func operator+(other: Self) -> Self` - same operator-token
            // recognition functionDecl() uses for an impl's real method
            // bodies, so a trait can require an overloadable operator by its
            // source-level spelling. Resolved to its C-safe name (e.g.
            // "op_add") once the parameter list (and so arity) is known,
            // exactly like functionDecl() does - this is what
            // processImplBlock's nominal name-matching compares an impl's
            // own (identically-resolved) operator method names against.
            bool isOperator = false;
            string rawOp;
            string methodName;
            if (match(TokenType.Operator)) {
                isOperator = true;
                if (match(TokenType.LeftBracket)) {
                    expect(TokenType.RightBracket);
                    rawOp = "[]";
                } else if (isOverloadableOperatorToken()) {
                    rawOp = current.value;
                    advance();
                } else {
                    error("Expected an overloadable operator after 'operator'");
                }
            } else {
                methodName = expect(TokenType.Identifier).value;
            }

            expect(TokenType.LeftParen);
            bool isVariadic;
            Parameter[] params = paramList(isVariadic);
            expect(TokenType.RightParen);
            Type returnType = new Type("void");
            if (match(TokenType.Arrow)) {
                returnType = parseType();
            }

            if (isOperator) {
                methodName = operatorMethodName(rawOp, params.length == 0);
                if (methodName.length == 0) {
                    errorAt(sigLine, sigColumn,
                        format("'%s' isn't an overloadable %s operator", rawOp,
                            params.length == 0 ? "unary" : "binary"));
                }
            }

            methods ~= new FunctionDecl(methodName, params, returnType, null, false, false, isVariadic,
                sigLine, sigColumn);
        }

        expect(TokenType.RightBrace);
        return new TraitDecl(name, methods, startLine, startColumn, typeParams);
    }

    // `impl TraitName for TargetType { func method(...) -> T { body } ... }` -
    // unlike trait method signatures, these are ordinary functionDecl()s
    // with real bodies (see ast.ImplDecl's doc comment).
    private ImplDecl implDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Impl);
        string traitName = expect(TokenType.Identifier).value;
        // `impl Iterator<int> for Countdown { ... }` - type args on a
        // generic trait's name are parsed but discarded: like the trait's
        // own <T>, they're a signature-writing convenience only, never
        // substituted or verified against the impl's concrete method types
        // (see TraitDecl.typeParams and processImplBlock).
        if (match(TokenType.Less)) {
            do {
                parseType();
            } while (match(TokenType.Comma));
            expect(TokenType.Greater);
        }
        expect(TokenType.For);
        Type targetType = parseType();
        expect(TokenType.LeftBrace);

        FunctionDecl[] methods;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            methods ~= functionDecl();
        }

        expect(TokenType.RightBrace);
        return new ImplDecl(traitName, targetType, methods, startLine, startColumn);
    }

    private FunctionDecl constructorDecl(string className) {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Constructor);
        expect(TokenType.LeftParen);

        bool isVariadic;
        Parameter[] params = paramList(isVariadic);
        if (isVariadic) {
            error("A constructor cannot be variadic");
        }
        expect(TokenType.RightParen);

        Block body_ = block();
        return new FunctionDecl(className ~ "_constructor", params, new Type("void"), body_,
            false, false, false, startLine, startColumn);
    }

    private FunctionDecl destructorDecl(string className) {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Destructor);
        expect(TokenType.LeftParen);
        expect(TokenType.RightParen);

        Block body_ = block();
        return new FunctionDecl(className ~ "_destructor", [], new Type("void"), body_,
            false, false, false, startLine, startColumn);
    }

    private VarDecl varDecl() {
        int declLine = current.line;
        int declColumn = current.column;

        bool isVolatile = match(TokenType.Volatile);

        bool isConst = false;
        if (match(TokenType.Const)) {
            isConst = true;
        } else {
            expect(TokenType.Let);
        }

        return varDeclBody(declLine, declColumn, isConst, isVolatile);
    }

    // Parses `name: Type [: bitWidth] [= initializer]` - shared by
    // varDecl (after it's consumed a leading `let`/`const`/`volatile`)
    // and a class field written with no keyword at all (classDecl below):
    // `x: int` inside a class body means exactly what `let x: int` does.
    // Unambiguous there - no other class-body construct starts with a
    // bare identifier immediately followed by `:`.
    private VarDecl varDeclBody(int declLine, int declColumn, bool isConst, bool isVolatile) {
        Token nameToken = expect(TokenType.Identifier);
        string name = nameToken.value;

        Type type = null;
        if (match(TokenType.Colon)) {
            type = parseType();
        }

        // Bit-field width, e.g. `let flags: uint : 3`. Only meaningful on
        // class fields; the code generator rejects it anywhere else.
        int bitWidth = -1;
        if (match(TokenType.Colon)) {
            Token widthToken = expect(TokenType.Integer, "Expected bit-field width");
            bitWidth = to!int(widthToken.value);
        }

        ASTNode initializer = null;
        if (match(TokenType.Assign)) {
            initializer = expression();
        }

        if (type is null && initializer is null) {
            errorAt(nameToken.line, nameToken.column,
                format("Cannot infer type of '%s': declare a type or provide an initializer", name));
        }

        return new VarDecl(name, type, initializer, isConst, declLine, declColumn, bitWidth, isVolatile);
    }

    // Parses a destructuring pattern: a plain name, a tuple of patterns, or
    // `TypeName { field, field, ... }`. Does not consume the optional `: Type`
    // annotation or `= initializer` that follow the pattern.
    private Pattern parsePattern() {
        int startLine = current.line;
        int startColumn = current.column;

        if (check(TokenType.Identifier) && current.value == "_") {
            advance();
            return new WildcardPattern(startLine, startColumn);
        }

        if (match(TokenType.LeftParen)) {
            Pattern[] elements;
            if (!check(TokenType.RightParen)) {
                do {
                    elements ~= parsePattern();
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightParen);
            if (elements.length < 2) {
                errorAt(startLine, startColumn,
                    "Tuple pattern must contain at least two elements");
            }
            return new TuplePattern(elements, startLine, startColumn);
        }

        Token nameToken = expect(TokenType.Identifier);
        string name = nameToken.value;

        if (check(TokenType.LeftBrace)) {
            // Struct pattern: TypeName { field, field, ... }
            expect(TokenType.LeftBrace);
            string[] fieldNames;
            if (!check(TokenType.RightBrace)) {
                do {
                    fieldNames ~= expect(TokenType.Identifier).value;
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightBrace);
            if (fieldNames.length == 0) {
                errorAt(startLine, startColumn, "Struct pattern must name at least one field");
            }
            Type type = new Type(name);
            return new StructPattern(type, fieldNames, startLine, startColumn);
        }

        return new BindingPattern(name, nameToken.line, nameToken.column);
    }

    // `let`/`const`/`volatile` statement or for-init. Returns either a plain
    // VarDecl (for a single-name binding) or a DestructuringStmt.
    private ASTNode letDecl() {
        int declLine = current.line;
        int declColumn = current.column;

        bool isVolatile = match(TokenType.Volatile);

        bool isConst = false;
        if (match(TokenType.Const)) {
            isConst = true;
        } else {
            expect(TokenType.Let);
        }

        Pattern pattern = parsePattern();

        // A simple binding can follow the existing VarDecl path, which handles
        // bit-fields and keeps all existing codegen unchanged.
        if (auto bind = cast(BindingPattern)pattern) {
            Type type = null;
            if (match(TokenType.Colon)) {
                type = parseType();
            }
            int bitWidth = -1;
            if (match(TokenType.Colon)) {
                Token widthToken = expect(TokenType.Integer, "Expected bit-field width");
                bitWidth = to!int(widthToken.value);
            }
            ASTNode initializer = null;
            if (match(TokenType.Assign)) {
                initializer = expression();
            }
            if (type is null && initializer is null) {
                errorAt(bind.line, bind.column,
                    format("Cannot infer type of '%s': declare a type or provide an initializer", bind.name));
            }
            return new VarDecl(bind.name, type, initializer, isConst, declLine, declColumn,
                bitWidth, isVolatile);
        }

        Type type = null;
        if (match(TokenType.Colon)) {
            type = parseType();
        }
        ASTNode initializer = null;
        if (match(TokenType.Assign)) {
            initializer = expression();
        }
        if (initializer is null) {
            errorAt(declLine, declColumn, "Destructuring declaration requires an initializer");
        }
        return new DestructuringStmt(pattern, type, initializer, isConst, isVolatile,
            declLine, declColumn);
    }

    // Parenthesized type syntax covers three things:
    //   - `(T1, T2) -> R` / `() -> R` / `(T) -> R`  closure types
    //   - `(T, U)` and nested variants               tuple types
    //   - `(T)`                                      parenthesized type
    private Type parseParenType() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.LeftParen);

        if (check(TokenType.RightParen)) {
            expect(TokenType.RightParen);
            expect(TokenType.Arrow);
            Type ret = parseType();
            Type t = new Type("__LLPL_Closure");
            t.closureReturnType = ret;
            return t;
        }

        Type first = parseType();
        if (match(TokenType.Comma)) {
            Type[] elems = [first];
            do {
                elems ~= parseType();
            } while (match(TokenType.Comma));
            expect(TokenType.RightParen);
            // `(T1, T2, ...) -> R` (2+ params) - checked here too, not just
            // after the single-param case below, so a multi-parameter
            // closure type annotation doesn't get misread as a tuple type
            // with the trailing `-> R` left dangling (a bug: this branch
            // used to always return the tuple immediately).
            if (match(TokenType.Arrow)) {
                Type ret = parseType();
                Type t = new Type("__LLPL_Closure");
                Parameter[] closureParams;
                foreach (elem; elems) closureParams ~= new Parameter("", elem);
                t.closureParams = closureParams;
                t.closureReturnType = ret;
                return t;
            }
            return makeTupleType(elems, startLine, startColumn);
        }

        expect(TokenType.RightParen);
        if (match(TokenType.Arrow)) {
            Type ret = parseType();
            Type t = new Type("__LLPL_Closure");
            t.closureParams = [new Parameter("", first)];
            t.closureReturnType = ret;
            return t;
        }

        return first;
    }

    // A closing `>` for a `<...>` type-argument list, tolerant of nested
    // generics: `Box<Box<int>>` lexes its last two characters as a single
    // RightShift token (`>>`), not two Greater tokens, since the lexer has
    // no idea it's looking at nested generics rather than a `>>` shift
    // operator. Split it in place instead: consume one closing `>` and
    // rewrite this same token slot to a lone Greater (without advancing),
    // so the next (outer) nesting level's own call sees an ordinary
    // Greater token to consume normally. Handles any nesting depth, since
    // each split only ever peels off one level at a time.
    private void expectGreaterOrSplit() {
        if (match(TokenType.Greater)) {
            return;
        }
        if (check(TokenType.RightShift)) {
            tokens[pos] = Token(TokenType.Greater, ">", current.line, current.column + 1);
            current = tokens[pos];
            return;
        }
        error(format("Expected Greater, got %s", current.type));
    }

    private Type makeTupleType(Type[] elems, int line, int column) {
        if (elems.length < 2 || elems.length > 8) {
            errorAt(line, column, format("Tuple arity %d is not supported (use 2..8)", elems.length));
        }
        string name = format("__LLPL_Tuple%d", elems.length);
        Type t = new Type(name);
        t.typeArgs = elems;
        return t;
    }

    // Short Rust-style spellings for the fixed-width integer types, resolved
    // to their existing canonical internal names right here so every other
    // type-name check in the parser and code generator (isPrimitiveTypeName,
    // primitiveToC, interpFormatSpecifier, ...) only ever has to know about
    // one spelling per width. u64/i64 alias the pre-existing "uint"/"int"
    // (already 64-bit); u8/i8 are the one genuinely new width, added
    // alongside them in the code generator as "uint8"/"int8".
    private static string canonicalIntTypeName(string name) {
        switch (name) {
            case "u8": return "uint8";
            case "u16": return "uint16";
            case "u32": return "uint32";
            case "u64": return "uint";
            case "i8": return "int8";
            case "i16": return "int16";
            case "i32": return "int32";
            case "i64": return "int";
            default: return name;
        }
    }

    private Type parseType() {
        if (check(TokenType.LeftParen)) {
            return parseParenType();
        }
        string name = canonicalIntTypeName(expect(TokenType.Identifier).value);
        // Namespace-qualified type name, e.g. Graphics.Point -> mangled as
        // Graphics_Point, matching how the code generator mangles namespaced
        // class declarations.
        while (match(TokenType.Dot)) {
            name ~= "_" ~ expect(TokenType.Identifier).value;
        }

        // `<T1, T2, ...>` type arguments, e.g. Vector<int>. Only ever
        // attempted here, inside a type position - never as a general
        // postfix on an arbitrary expression - so this never collides with
        // `<`/`>` as comparison operators (see relational(), which is only
        // reached from general expression parsing, never from parseType()).
        Type[] typeArgs;
        if (match(TokenType.Less)) {
            do {
                typeArgs ~= parseType();
            } while (match(TokenType.Comma));
            expectGreaterOrSplit();
        }

        int pointerDepth = 0;
        bool isArray = false;
        int arraySize = 0;

        while (match(TokenType.Star)) {
            pointerDepth++;
        }

        if (match(TokenType.LeftBracket)) {
            isArray = true;
            if (check(TokenType.Integer)) {
                arraySize = to!int(current.value);
                advance();
            }
            expect(TokenType.RightBracket);
        }

        Type t = new Type(name, pointerDepth, isArray, arraySize);
        t.typeArgs = typeArgs;

        // `T?` - sugar for `Optional<T>` (see ast.Type.isNullableSugar).
        // Always trailing, after everything else (`char*?` is
        // `Optional<char*>`, not `Optional<char>*`), and there's no
        // ternary operator in this language to make `?` ambiguous here.
        if (match(TokenType.Question)) {
            Type wrapped = new Type("Optional");
            wrapped.typeArgs = [t];
            wrapped.isNullableSugar = true;
            t = wrapped;
        }

        return t;
    }

    private Block block() {
        expect(TokenType.LeftBrace);
        ASTNode[] statements;

        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            statements ~= statement();
        }

        expect(TokenType.RightBrace);
        return new Block(statements);
    }

    // `<statement> unless <condition>` - a trailing modifier accepted after
    // any statement, desugaring to `if !(<condition>) { <statement> }`.
    // Checked after the statement is fully parsed (so it applies to the
    // whole thing, including e.g. an if/else chain's trailing else), which
    // keeps this a single check here rather than something every
    // statement-parsing function needs to know about.
    private ASTNode statement() {
        ASTNode stmt = statementInner();
        if (match(TokenType.Unless)) {
            int condLine = current.line;
            int condColumn = current.column;
            ASTNode condition = expression();
            ASTNode negated = new UnaryExpr("!", condition, condLine, condColumn);
            return new IfStmt(negated, new Block([stmt]));
        }
        return stmt;
    }

    private ASTNode statementInner() {
        if (check(TokenType.If)) {
            return ifStmt();
        } else if (check(TokenType.While)) {
            return whileStmt();
        } else if (check(TokenType.For)) {
            return forStmt();
        } else if (check(TokenType.Foreach)) {
            return foreachStmt();
        } else if (check(TokenType.Return)) {
            return returnStmt();
        } else if (check(TokenType.Continue)) {
            return continueStmt();
        } else if (check(TokenType.Break)) {
            return breakStmt();
        } else if (check(TokenType.Defer)) {
            return deferStmt();
        } else if (check(TokenType.Try)) {
            return tryStmt();
        } else if (check(TokenType.Throw)) {
            return throwStmt();
        } else if (check(TokenType.Delete)) {
            return deleteStmt();
        } else if (check(TokenType.Asm)) {
            return asmStmt();
        } else if (check(TokenType.Match)) {
            return matchStmt();
        } else if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
            return letDecl();
        } else if (check(TokenType.LeftBrace)) {
            return block();
        } else if (check(TokenType.Quote)) {
            return quoteExpr();
        } else if (isMacroInvocationAhead()) {
            return macroInvocationStmt();
        } else {
            return exprStmt();
        }
    }

    private MacroInvocation macroInvocationStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        string name = expect(TokenType.Identifier).value;
        while (match(TokenType.Dot)) {
            name ~= "_" ~ expect(TokenType.Identifier).value;
        }
        expect(TokenType.Not);
        expect(TokenType.LeftParen);

        ASTNode[] args;
        if (!check(TokenType.RightParen)) {
            do {
                args ~= expression();
            } while (match(TokenType.Comma));
        }
        expect(TokenType.RightParen);

        return new MacroInvocation(name, args, startLine, startColumn);
    }

    // Parses a call's `(...)` argument list - shared by ordinary function
    // calls, `new Foo(...)`, and macro invocations. An argument may be
    // named (`identifier ':' expression`, recognized by an unambiguous
    // one-token lookahead: an identifier immediately followed by ':' - a
    // call's `(...)` is already its own unambiguous terminator, the same
    // reasoning that lets struct literals appear again inside it even in a
    // suppressed if/while/for/match/foreach expression, see
    // noStructLiteral's comment). `argNames` is parallel to the returned
    // args: "" for a positional argument, the parameter name otherwise.
    // Once a named argument appears, a later positional one is a parse
    // error - see codegen.d's resolveCallArguments for why.
    private ASTNode[] argumentList(out string[] argNames) {
        bool savedNoStructLiteral = noStructLiteral;
        noStructLiteral = false;
        ASTNode[] args;
        string[] names;
        bool sawNamed = false;
        if (!check(TokenType.RightParen)) {
            do {
                string argName = "";
                if (check(TokenType.Identifier) && peek(1).type == TokenType.Colon) {
                    argName = current.value;
                    advance();
                    advance(); // consume ':'
                    sawNamed = true;
                } else if (sawNamed) {
                    error("A positional argument cannot follow a named argument");
                }
                names ~= argName;
                args ~= expression();
            } while (match(TokenType.Comma));
        }
        expect(TokenType.RightParen);
        noStructLiteral = savedNoStructLiteral;
        argNames = names;
        return args;
    }

    private QuoteExpr quoteExpr() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Quote);

        if (check(TokenType.LeftBrace)) {
            return new QuoteExpr(block(), true, startLine, startColumn);
        }

        expect(TokenType.LeftParen, "Expected '{' or '(' after quote");
        ASTNode expr = expression();
        expect(TokenType.RightParen);
        return new QuoteExpr(expr, false, startLine, startColumn);
    }

    private UnquoteExpr unquoteExpr() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Unquote);
        expect(TokenType.LeftParen);
        ASTNode expr = expression();
        expect(TokenType.RightParen);
        return new UnquoteExpr(expr, startLine, startColumn);
    }

    private AsmStmt asmStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Asm);
        expect(TokenType.LeftParen);

        string[] templateLines;
        templateLines ~= expect(TokenType.String).value;
        while (check(TokenType.String)) {
            templateLines ~= current.value;
            advance();
        }

        AsmOperand[] outputs;
        AsmOperand[] inputs;
        string[] clobbers;

        if (match(TokenType.Colon)) {
            outputs = asmOperandList();
            if (match(TokenType.Colon)) {
                inputs = asmOperandList();
                if (match(TokenType.Colon)) {
                    clobbers = asmClobberList();
                }
            }
        }

        expect(TokenType.RightParen);
        return new AsmStmt(templateLines, outputs, inputs, clobbers, startLine, startColumn);
    }

    private AsmOperand[] asmOperandList() {
        AsmOperand[] result;
        if (check(TokenType.Colon) || check(TokenType.RightParen)) {
            return result;
        }

        do {
            string constraint = expect(TokenType.String).value;
            expect(TokenType.LeftParen);
            ASTNode expr = expression();
            expect(TokenType.RightParen);
            result ~= new AsmOperand(constraint, expr);
        } while (match(TokenType.Comma));

        return result;
    }

    private string[] asmClobberList() {
        string[] result;
        if (check(TokenType.RightParen)) {
            return result;
        }

        do {
            result ~= expect(TokenType.String).value;
        } while (match(TokenType.Comma));

        return result;
    }

    private MatchStmt matchStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Match);
        ASTNode subject = expressionNoStructLiteral();
        expect(TokenType.LeftBrace);

        MatchCase[] cases;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            cases ~= matchCase();
        }

        expect(TokenType.RightBrace);
        return new MatchStmt(subject, cases, startLine, startColumn);
    }

    private ASTNode matchPattern() {
        int startLine = current.line;
        int startColumn = current.column;

        // Destructuring forms: '(' tuple pattern, 'Name { ... }' struct pattern,
        // or '_' wildcard.
        if (check(TokenType.LeftParen)) {
            return new PatternExpr(parsePattern(), startLine, startColumn);
        }
        if (check(TokenType.Identifier) && current.value == "_") {
            return new PatternExpr(parsePattern(), startLine, startColumn);
        }
        if (check(TokenType.Identifier) && peek(1).type == TokenType.LeftBrace) {
            return new PatternExpr(parsePattern(), startLine, startColumn);
        }

        // Ordinary expression pattern (literal, identifier, enum-variant call).
        return expression();
    }

    private MatchCase matchCase() {
        if (match(TokenType.Default)) {
            expect(TokenType.FatArrow);
            Block body_ = block();
            return new MatchCase([], body_);
        }

        expect(TokenType.Case);
        ASTNode[] patterns = [matchPattern()];
        while (match(TokenType.Comma)) {
            patterns ~= matchPattern();
        }
        expect(TokenType.FatArrow);
        Block body_ = block();
        return new MatchCase(patterns, body_);
    }

    private IfStmt ifStmt() {
        expect(TokenType.If);
        ASTNode condition = expressionNoStructLiteral();
        Block thenBlock = block();
        Block elseBlock = null;

        if (match(TokenType.Else)) {
            if (check(TokenType.If)) {
                // else if
                auto elseIfStmt = ifStmt();
                elseBlock = new Block([elseIfStmt]);
            } else {
                elseBlock = block();
            }
        }

        return new IfStmt(condition, thenBlock, elseBlock);
    }

    // `if <cond> { expr } else { expr }` as an expression - see
    // ast.IfExpr's doc comment. Unlike ifStmt(), `else` isn't optional
    // here: an if-expression with no else would have no value on the
    // untaken path.
    private IfExpr ifExpr() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.If);
        ASTNode condition = expressionNoStructLiteral();
        Block thenBlock = block();
        expect(TokenType.Else);
        Block elseBlock;
        if (check(TokenType.If)) {
            // `else if ... else ...` - the nested if-expression's own
            // value becomes this branch's value, so wrap it in a single
            // ExprStmt to satisfy the "last statement is an expression"
            // rule the same way an ordinary trailing expression does.
            elseBlock = new Block([new ExprStmt(ifExpr())]);
        } else {
            elseBlock = block();
        }
        return new IfExpr(condition, thenBlock, elseBlock, startLine, startColumn);
    }

    private WhileStmt whileStmt() {
        expect(TokenType.While);
        ASTNode condition = expressionNoStructLiteral();
        Block body_ = block();
        return new WhileStmt(condition, body_);
    }

    private ASTNode forStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.For);

        // `for i in <range-or-iterable> { ... }` - sugar for `foreach let
        // i in ... { ... }` (see ForeachStmt), spelled without `let` and
        // using `for` instead of `foreach`. Unambiguous via one token of
        // lookahead: the ordinary C-style for's own initializer can also
        // start with a bare identifier (`for i = 0, i < 5, i = i + 1 {
        // }`), but never one immediately followed by `in`.
        if (check(TokenType.Identifier) && peek(1).type == TokenType.In) {
            string varName = current.value;
            advance();
            expect(TokenType.In);
            ASTNode iterable = expressionNoStructLiteral();
            Block forInBody = block();
            return new ForeachStmt(varName, iterable, forInBody, startLine, startColumn);
        }

        ASTNode initializer = null;
        ASTNode condition = null;
        ASTNode update = null;

        // init
        if (!check(TokenType.Comma)) {
            if (check(TokenType.Let) || check(TokenType.Const) || check(TokenType.Volatile)) {
                initializer = letDecl();
            } else {
                initializer = new ExprStmt(expression());
            }
        }
        expect(TokenType.Comma);

        // condition
        if (!check(TokenType.Comma)) {
            condition = expression();
        }
        expect(TokenType.Comma);

        // update
        if (!check(TokenType.LeftBrace)) {
            update = expressionNoStructLiteral();
        }

        Block body_ = block();
        return new ForStmt(initializer, condition, update, body_);
    }

    // `foreach let x in iterable { ... }` - always `let` (no `const` form;
    // the loop variable is a fresh binding each iteration, not something
    // there's a meaningful "don't reassign" guarantee for) and never an
    // explicit type annotation - see ForeachStmt's doc comment for how
    // codegen infers it.
    private ForeachStmt foreachStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Foreach);
        expect(TokenType.Let);
        string varName = expect(TokenType.Identifier).value;
        expect(TokenType.In);
        ASTNode iterable = expressionNoStructLiteral();
        Block body_ = block();
        return new ForeachStmt(varName, iterable, body_, startLine, startColumn);
    }

    private ReturnStmt returnStmt() {
        expect(TokenType.Return);
        ASTNode value = null;
        if (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            value = expression();
        }
        return new ReturnStmt(value);
    }

    private ContinueStmt continueStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Continue);
        return new ContinueStmt(startLine, startColumn);
    }

    private BreakStmt breakStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Break);
        return new BreakStmt(startLine, startColumn);
    }

    private ThrowStmt throwStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Throw);
        if (check(TokenType.RightBrace) || check(TokenType.EOF)) {
            errorAt(startLine, startColumn, "'throw' requires a value");
        }
        return new ThrowStmt(expression(), startLine, startColumn);
    }

    private DeleteStmt deleteStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Delete);
        if (check(TokenType.RightBrace) || check(TokenType.EOF)) {
            errorAt(startLine, startColumn, "'delete' requires a value");
        }
        return new DeleteStmt(expression(), startLine, startColumn);
    }

    private DeferStmt deferStmt() {
        expect(TokenType.Defer);
        ASTNode stmt = statement();
        return new DeferStmt(stmt);
    }

    // `try { ... } [catch (e) { ... }] [finally { ... }]` - catch and
    // finally are each independently optional, but at least one must be
    // present (see ast.TryStmt's doc comment for why a bare `try` with
    // neither would do nothing).
    private TryStmt tryStmt() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Try);
        Block tryBlock = block();

        string catchVar = "";
        Type catchType = null;
        Block catchBlock = null;
        if (match(TokenType.Catch)) {
            // Parens are optional - `catch e` and `catch (e)` (and their
            // `: Type` variants) both work; only meaningful when present
            // is that the closing `)` is then required back.
            bool hasParen = match(TokenType.LeftParen);
            catchVar = expect(TokenType.Identifier).value;
            if (match(TokenType.Colon)) {
                catchType = parseType();
            }
            if (hasParen) {
                expect(TokenType.RightParen);
            }
            catchBlock = block();
        }

        Block finallyBlock = null;
        if (match(TokenType.Finally)) {
            finallyBlock = block();
        }

        if (catchBlock is null && finallyBlock is null) {
            errorAt(startLine, startColumn, "'try' needs at least a 'catch' or a 'finally'");
        }

        return new TryStmt(tryBlock, catchVar, catchType, catchBlock, finallyBlock, startLine, startColumn);
    }

    private ExprStmt exprStmt() {
        ASTNode expr = expression();
        return new ExprStmt(expr);
    }

    private ASTNode expression() {
        return assignment();
    }

    // Parses a full expression with struct-literal parsing suppressed -
    // for exactly the handful of spots (if/while/for-update/match-subject/
    // foreach-iterable) where the expression is immediately followed by
    // this construct's own `{ body }`, so `Name { ... }` right there would
    // be ambiguous. See noStructLiteral's own comment.
    private ASTNode expressionNoStructLiteral() {
        bool saved = noStructLiteral;
        noStructLiteral = true;
        ASTNode result = expression();
        noStructLiteral = saved;
        return result;
    }

    // Maps a compound-assignment token to the plain binary operator it
    // desugars around (`+=` -> "+", so `x += y` parses as `x = x + y`).
    // Returns "" for anything that isn't one.
    private string compoundAssignOp(TokenType type) {
        switch (type) {
            case TokenType.PlusEqual: return "+";
            case TokenType.MinusEqual: return "-";
            case TokenType.StarEqual: return "*";
            case TokenType.SlashEqual: return "/";
            case TokenType.PercentEqual: return "%";
            case TokenType.AmpEqual: return "&";
            case TokenType.PipeEqual: return "|";
            case TokenType.CaretEqual: return "^";
            case TokenType.ShlEqual: return "<<";
            case TokenType.ShrEqual: return ">>";
            default: return "";
        }
    }

    private ASTNode assignment() {
        ASTNode expr = pipe();

        if (match(TokenType.Assign)) {
            ASTNode value = assignment();
            return new BinaryExpr("=", expr, value, expr.line, expr.column);
        }

        string op = compoundAssignOp(current.type);
        if (op.length > 0) {
            advance();
            ASTNode value = assignment();
            // Desugars to `expr = expr op value` - reusing the same `expr`
            // node as both the assignment target and the left operand of
            // `op` (rather than parsing/allocating it twice) means a
            // side-effecting target - `arr[f()] += 1` - evaluates `f()`
            // twice in the generated C, once per occurrence. Harmless for
            // the common case (a plain variable, field, or index by a pure
            // expression); documented here rather than guarded against, in
            // keeping with this compiler's other simple-over-exhaustive
            // trade-offs (see e.g. codegen.d's memberAccessor).
            ASTNode combined = new BinaryExpr(op, expr, value, expr.line, expr.column);
            return new BinaryExpr("=", expr, combined, expr.line, expr.column);
        }

        // `i++`/`i--` - desugars to `i = i + 1`/`i = i - 1`, exactly like
        // `i += 1`/`i -= 1` just above (including that same "evaluates to
        // the new value, not the old one" simplification - a true C
        // postfix's old-value capture isn't offered). Only recognized
        // here (assignment's own precedence level), not at every
        // expression precedence, so `i++` works as its own statement or
        // parenthesized, but not spliced into a larger expression like
        // `i++ + 5` - the same restriction `i += 1` already has.
        if (check(TokenType.PlusPlus) || check(TokenType.MinusMinus)) {
            string incDecOp = current.type == TokenType.PlusPlus ? "+" : "-";
            advance();
            ASTNode one = new IntLiteral(1, expr.line, expr.column);
            ASTNode combined = new BinaryExpr(incDecOp, expr, one, expr.line, expr.column);
            return new BinaryExpr("=", expr, combined, expr.line, expr.column);
        }

        return expr;
    }

    // `x |> f` desugars to `f(x)`; `x |> f(a, b)` desugars to `f(x, a, b)` -
    // x is always inserted as the first argument. Left-associative, so
    // `x |> f |> g` is `g(f(x))`. Binds looser than every other binary
    // operator (parsed just above assignment, below everything else) so
    // `a + b |> f` means `f(a + b)`, not `a + (b |> f)`. The right-hand
    // side parses at postfix() level, not a full expression - it's always
    // "a callable reference, optionally already applied to its own
    // trailing args" (`f`, `f(a, b)`, `ns.f(a)`, ...), never a general
    // binary expression, so `x |> f + 1` is a parse error rather than the
    // ambiguous-looking `f(x) + 1` vs `f(x + 1)`.
    private ASTNode pipe() {
        ASTNode expr = rangeExpr();

        while (match(TokenType.PipeForward)) {
            int opLine = tokens[pos - 1].line;
            int opColumn = tokens[pos - 1].column;
            ASTNode callee = postfix();

            if (auto callExpr = cast(CallExpr)callee) {
                // The piped-in value is always a positional first argument,
                // regardless of whether the callee's own trailing args used
                // any names.
                expr = new CallExpr(callExpr.callee, expr ~ callExpr.args, opLine, opColumn,
                    [""] ~ callExpr.argNames);
            } else {
                expr = new CallExpr(callee, [expr], opLine, opColumn, [""]);
            }
        }

        return expr;
    }

    // `start..end` (exclusive of `end`) - only ever meaningful as a `for i
    // in start..end { ... }` iterable (see ast.RangeExpr's own comment).
    // Non-associative (no `a..b..c`); binds looser than every ordinary
    // binary operator but tighter than `|>`/assignment, so `0..n - 1`
    // means `0..(n - 1)`.
    private ASTNode rangeExpr() {
        ASTNode expr = logicalOr();
        if (match(TokenType.DotDot)) {
            ASTNode end = logicalOr();
            expr = new RangeExpr(expr, end, expr.line, expr.column);
        }
        return expr;
    }

    private ASTNode logicalOr() {
        ASTNode expr = logicalAnd();

        while (match(TokenType.Or)) {
            string op = "||";
            ASTNode right = logicalAnd();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode logicalAnd() {
        ASTNode expr = bitwiseOr();

        while (match(TokenType.And)) {
            string op = "&&";
            ASTNode right = bitwiseOr();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode bitwiseOr() {
        ASTNode expr = bitwiseXor();

        while (match(TokenType.BitwiseOr)) {
            string op = "|";
            ASTNode right = bitwiseXor();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode bitwiseXor() {
        ASTNode expr = bitwiseAnd();

        while (match(TokenType.BitwiseXor)) {
            string op = "^";
            ASTNode right = bitwiseAnd();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode bitwiseAnd() {
        ASTNode expr = equality();

        while (check(TokenType.BitwiseAnd) && !newlineBeforeCurrent()) {
            advance();
            string op = "&";
            ASTNode right = equality();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode equality() {
        ASTNode expr = relational();

        while (match(TokenType.Equal, TokenType.NotEqual)) {
            string op = tokens[pos - 1].value;
            ASTNode right = relational();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode relational() {
        ASTNode expr = shift();

        while (match(TokenType.Less, TokenType.Greater, TokenType.LessEqual, TokenType.GreaterEqual)) {
            string op = tokens[pos - 1].value;
            ASTNode right = shift();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode shift() {
        ASTNode expr = additive();

        while (match(TokenType.LeftShift, TokenType.RightShift)) {
            string op = tokens[pos - 1].value;
            ASTNode right = additive();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode additive() {
        ASTNode expr = multiplicative();

        while (check(TokenType.Plus) || (check(TokenType.Minus) && !newlineBeforeCurrent())) {
            advance();
            string op = tokens[pos - 1].value;
            ASTNode right = multiplicative();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode multiplicative() {
        ASTNode expr = cast_();

        while ((check(TokenType.Star) && !newlineBeforeCurrent()) ||
                check(TokenType.Slash) || check(TokenType.Percent)) {
            advance();
            string op = tokens[pos - 1].value;
            ASTNode right = cast_();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode cast_() {
        int startLine = current.line;
        int startColumn = current.column;
        ASTNode expr = unary();

        if (match(TokenType.As)) {
            Type type = parseType();
            expr = new CastExpr(type, expr, startLine, startColumn);
        }

        return expr;
    }

    private ASTNode unary() {
        if (match(TokenType.Not, TokenType.Minus, TokenType.BitwiseNot, TokenType.Star, TokenType.BitwiseAnd)) {
            int opLine = tokens[pos - 1].line;
            int opColumn = tokens[pos - 1].column;
            string op = tokens[pos - 1].value;
            ASTNode operand = unary();
            return new UnaryExpr(op, operand, opLine, opColumn);
        }

        return postfix();
    }

    private ASTNode postfix() {
        int startLine = current.line;
        int startColumn = current.column;
        ASTNode expr = primary();

        while (true) {
            if (match(TokenType.LeftParen)) {
                // Function call - see argumentList()'s own comment for the
                // named-argument/struct-literal-inside-suppressed-context
                // reasoning.
                string[] argNames;
                ASTNode[] args = argumentList(argNames);
                expr = new CallExpr(expr, args, startLine, startColumn, argNames);
            } else if (match(TokenType.Dot)) {
                // Member access
                int memberLine = current.line;
                int memberColumn = current.column;
                string member = expectName("Expected member name after '.'").value;
                expr = new MemberExpr(expr, member, memberLine, memberColumn);
            } else if (match(TokenType.LeftBracket)) {
                // Array indexing - same unambiguous-terminator reasoning as `(` above.
                bool savedNoStructLiteral = noStructLiteral;
                noStructLiteral = false;
                ASTNode index = expression();
                expect(TokenType.RightBracket);
                noStructLiteral = savedNoStructLiteral;
                expr = new IndexExpr(expr, index, startLine, startColumn);
            } else if (match(TokenType.Question)) {
                // `expr?` - propagate/unwrap an Optional<T>/Result<T, E> -
                // see ast.PropagateExpr.
                expr = new PropagateExpr(expr, startLine, startColumn);
            } else {
                break;
            }
        }

        return expr;
    }

    // `func[cap1, &cap2](params) -> T { ... }` - a lambda literal. The
    // capture list is optional (`func(params) -> T {...}` is a lambda that
    // captures nothing) but the parens and `{ }` body are always required,
    // even for an empty parameter list, so this can never be confused with
    // an ordinary parenthesized expression or array literal at this point
    // in primary() (both of those start with `(` / `[`, not `func`). A
    // capture prefixed with `&` is stored by reference; otherwise it is
    // copied by value.
    private ASTNode lambdaExpr() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Function);

        Capture[] captures;
        if (match(TokenType.LeftBracket)) {
            if (!check(TokenType.RightBracket)) {
                do {
                    bool byRef = match(TokenType.BitwiseAnd);
                    string name = expect(TokenType.Identifier).value;
                    captures ~= new Capture(name, byRef);
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightBracket);
        }

        expect(TokenType.LeftParen);
        bool isVariadic;
        Parameter[] params = paramList(isVariadic);
        expect(TokenType.RightParen);
        if (isVariadic) {
            error("A lambda cannot be variadic");
        }

        Type returnType = new Type("void");
        if (match(TokenType.Arrow)) {
            returnType = parseType();
        }

        Block body_ = block();
        return new LambdaExpr(captures, params, returnType, body_, startLine, startColumn);
    }

    private ASTNode primary() {
        int tokLine = current.line;
        int tokColumn = current.column;

        if (check(TokenType.Function)) {
            return lambdaExpr();
        }
        if (check(TokenType.If)) {
            return ifExpr();
        }
        if (match(TokenType.Sizeof)) {
            expect(TokenType.LeftParen);
            Type type = parseType();
            expect(TokenType.RightParen);
            return new SizeofExpr(type, tokLine, tokColumn);
        }
        if (match(TokenType.True)) {
            return new BoolLiteral(true, tokLine, tokColumn);
        }
        if (match(TokenType.False)) {
            return new BoolLiteral(false, tokLine, tokColumn);
        }
        if (match(TokenType.Null)) {
            return new NullLiteral(tokLine, tokColumn);
        }
        if (match(TokenType.Integer)) {
            long value = parseIntegerValue(tokens[pos - 1].value);
            return new IntLiteral(value, tokLine, tokColumn);
        }
        if (match(TokenType.Float)) {
            return new FloatLiteral(tokens[pos - 1].value, tokLine, tokColumn);
        }
        if (match(TokenType.Char)) {
            import std.conv : to;
            int value = to!int(tokens[pos - 1].value);
            return new CharLiteral(value, tokLine, tokColumn);
        }
        if (match(TokenType.String)) {
            return new StringLiteral(tokens[pos - 1].value, tokLine, tokColumn);
        }
        if (match(TokenType.Regex)) {
            return new RegexLiteral(tokens[pos - 1].value, tokLine, tokColumn);
        }
        if (match(TokenType.InterpolatedString)) {
            string[] interpParts = tokens[pos - 1].interpParts;
            string[] literalParts;
            ASTNode[] expressions;
            InterpFormat[] specs;
            foreach (i, part; interpParts) {
                if (i % 2 == 0) {
                    literalParts ~= part;
                } else {
                    string exprSource;
                    InterpFormat spec;
                    splitInterpolationFormat(part, exprSource, spec);
                    expressions ~= parseInterpolationExpr(exprSource, tokLine, tokColumn);
                    specs ~= spec;
                }
            }
            return new InterpolatedStringLiteral(literalParts, expressions, specs, tokLine, tokColumn);
        }
        if (match(TokenType.Identifier)) {
            string name = tokens[pos - 1].value;
            bool qualifiedMacro = false;
            int offset = 0;
            while (peek(offset).type == TokenType.Dot && peek(offset + 1).type == TokenType.Identifier) {
                offset += 2;
            }
            qualifiedMacro = peek(offset).type == TokenType.Not;

            if (qualifiedMacro) {
                while (match(TokenType.Dot)) {
                    name ~= "_" ~ expect(TokenType.Identifier).value;
                }
            }
            if (match(TokenType.Not)) {
                expect(TokenType.LeftParen);
                string[] macroArgNames;
                ASTNode[] macroArgs = argumentList(macroArgNames);
                foreach (n; macroArgNames) {
                    if (n.length > 0) error("Macro arguments must be positional");
                }
                return new MacroInvocation(name, macroArgs, tokLine, tokColumn);
            }
            if (!qualifiedMacro && !noStructLiteral && check(TokenType.LeftBrace)) {
                return structLiteral(name, tokLine, tokColumn);
            }
            return new Identifier(name, tokLine, tokColumn);
        }
        if (match(TokenType.New)) {
            Type type = parseType();
            expect(TokenType.LeftParen);
            string[] argNames;
            ASTNode[] args = argumentList(argNames);
            return new NewExpr(type, args, tokLine, tokColumn, argNames);
        }
        if (check(TokenType.Quote)) {
            return quoteExpr();
        }
        if (check(TokenType.Unquote)) {
            return unquoteExpr();
        }
        if (match(TokenType.LeftParen)) {
            // Own unambiguous terminator - see argumentList()'s matching comment.
            bool savedNoStructLiteral = noStructLiteral;
            noStructLiteral = false;
            ASTNode expr = expression();
            if (match(TokenType.Comma)) {
                // Tuple literal: (e1, e2, ...)
                ASTNode[] elements = [expr];
                do {
                    elements ~= expression();
                } while (match(TokenType.Comma));
                expect(TokenType.RightParen);
                noStructLiteral = savedNoStructLiteral;
                return new TupleLiteral(elements, tokLine, tokColumn);
            }
            expect(TokenType.RightParen);
            noStructLiteral = savedNoStructLiteral;
            return expr;
        }
        if (match(TokenType.LeftBracket)) {
            bool savedNoStructLiteral = noStructLiteral;
            noStructLiteral = false;
            ASTNode[] elements;
            if (!check(TokenType.RightBracket)) {
                do {
                    elements ~= expression();
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightBracket);
            noStructLiteral = savedNoStructLiteral;
            return new ArrayLiteral(elements, tokLine, tokColumn);
        }

        error(format("Unexpected token: %s", current.type));
        return null;
    }

    // `Name { field: value, ... }` - see ast.StructLiteral's doc comment.
    // `name` and its start position are already consumed/captured by the
    // caller (primary()'s Identifier branch); this just parses the
    // `{ field: value, ... }` tail.
    private ASTNode structLiteral(string name, int startLine, int startColumn) {
        expect(TokenType.LeftBrace);
        string[] fieldNames;
        ASTNode[] fieldValues;
        if (!check(TokenType.RightBrace)) {
            do {
                fieldNames ~= expect(TokenType.Identifier).value;
                expect(TokenType.Colon);
                fieldValues ~= expression();
            } while (match(TokenType.Comma));
        }
        expect(TokenType.RightBrace);
        return new StructLiteral(name, fieldNames, fieldValues, startLine, startColumn);
    }
}
