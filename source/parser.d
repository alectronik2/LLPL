module parser;

import std.stdio;
import std.format;
import std.conv;
import lexer;
import ast;
import errors;

class Parser {
    private Token[] tokens;
    private size_t pos;
    private Token current;
    private string filePath;

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

    private void error(string message) {
        throw new CompileError(message, filePath, current.line, current.column);
    }

    private void errorAt(int line, int column, string message) {
        throw new CompileError(message, filePath, line, column);
    }

    // Converts the raw text of an Integer token (as produced by the lexer,
    // radix prefix and all) to its value. Shared by primary() and enum
    // member value parsing.
    private long parseIntegerValue(string numStr) {
        string prefix = numStr.length > 2 ? numStr[0..2] : "";
        if (prefix == "0x" || prefix == "0X") {
            return to!long(numStr[2..$], 16);
        } else if (prefix == "0b" || prefix == "0B") {
            return to!long(numStr[2..$], 2);
        } else if (prefix == "0o" || prefix == "0O") {
            return to!long(numStr[2..$], 8);
        }
        return to!long(numStr);
    }

    Program parse() {
        ASTNode[] declarations;
        while (!check(TokenType.EOF)) {
            declarations ~= declaration();
        }
        return new Program(declarations);
    }

    private ASTNode declaration() {
        if (check(TokenType.Import)) {
            return importStmt();
        } else if (check(TokenType.Namespace)) {
            return namespaceDecl();
        } else if (check(TokenType.Enum)) {
            return enumDecl();
        } else if (check(TokenType.Alias)) {
            return aliasDecl();
        } else if (check(TokenType.Interrupt) || check(TokenType.Function)) {
            return functionDecl();
        } else if (check(TokenType.Class)) {
            return classDecl();
        } else if (check(TokenType.Struct) || check(TokenType.Packed)) {
            return structDecl();
        } else if (check(TokenType.Extern)) {
            return externDecl();
        } else if (check(TokenType.Let) || check(TokenType.Const)) {
            return varDecl();
        } else {
            error("Expected declaration");
            return null;
        }
    }

    private NamespaceDecl namespaceDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Namespace);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftBrace);

        ASTNode[] declarations;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            declarations ~= declaration();
        }

        expect(TokenType.RightBrace);
        return new NamespaceDecl(name, declarations, startLine, startColumn);
    }

    // `enum Name[: Type] { A[, B = value]*, }` desugars straight into a
    // NamespaceDecl of const VarDecls with auto-incrementing IntLiteral
    // values (C enum semantics: an explicit value resumes auto-increment
    // from there). This reuses every bit of the existing namespace/const
    // machinery in the code generator, so enums need zero new codegen -
    // `EnumName.MEMBER` resolves exactly like any other namespaced const.
    private NamespaceDecl enumDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Enum);
        string name = expect(TokenType.Identifier).value;

        Type backingType = new Type("int");
        if (match(TokenType.Colon)) {
            backingType = parseType();
        }

        expect(TokenType.LeftBrace);

        ASTNode[] members;
        long nextValue = 0;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            int memberLine = current.line;
            int memberColumn = current.column;
            string memberName = expect(TokenType.Identifier).value;

            long value = nextValue;
            if (match(TokenType.Assign)) {
                bool negative = match(TokenType.Minus);
                value = parseIntegerValue(expect(TokenType.Integer).value);
                if (negative) value = -value;
            }
            nextValue = value + 1;

            Type memberType = new Type(backingType.name, backingType.isPointer,
                backingType.isArray, backingType.arraySize);
            members ~= new VarDecl(memberName, memberType, new IntLiteral(value, memberLine, memberColumn),
                true, memberLine, memberColumn);

            if (!match(TokenType.Comma)) break;
        }

        expect(TokenType.RightBrace);
        return new NamespaceDecl(name, members, startLine, startColumn);
    }

    private AliasDecl aliasDecl() {
        int startLine = current.line;
        int startColumn = current.column;
        expect(TokenType.Alias);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.Assign);

        string[] targetPath = [expect(TokenType.Identifier).value];
        while (match(TokenType.Dot)) {
            targetPath ~= expect(TokenType.Identifier).value;
        }

        return new AliasDecl(name, targetPath, startLine, startColumn);
    }

    private ImportStmt importStmt() {
        expect(TokenType.Import);

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

        return new ImportStmt(modulePath, alias_);
    }

    // Parses a comma-separated `name: Type` parameter list, with an optional
    // trailing `...` marking the function as variadic (used to bind to a C
    // vararg function like the runtime's `snprintf`). ISO C requires at
    // least one named parameter before `...`, so this does too.
    private Parameter[] paramList(out bool isVariadic) {
        Parameter[] params;
        isVariadic = false;
        if (!check(TokenType.RightParen)) {
            do {
                if (match(TokenType.Ellipsis)) {
                    isVariadic = true;
                    break;
                }
                string paramName = expect(TokenType.Identifier).value;
                expect(TokenType.Colon);
                Type paramType = parseType();
                params ~= new Parameter(paramName, paramType);
            } while (match(TokenType.Comma));
        }
        if (isVariadic && params.length == 0) {
            error("A variadic function needs at least one named parameter before '...'");
        }
        return params;
    }

    private FunctionDecl externDecl() {
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

        return new FunctionDecl(name, params, returnType, null, true, false, isVariadic);
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

    private FunctionDecl functionDecl() {
        bool isInterrupt = match(TokenType.Interrupt);
        expect(TokenType.Function);

        string name;
        bool isOperator = false;
        int operatorLine = current.line;
        int operatorColumn = current.column;
        string rawOp;
        if (match(TokenType.Operator)) {
            isOperator = true;
            if (!isOverloadableOperatorToken()) {
                error("Expected an overloadable operator after 'operator'");
            }
            rawOp = current.value;
            advance();
            name = rawOp; // placeholder; resolved to its C-safe name below
        } else {
            name = expect(TokenType.Identifier).value;
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

        return new FunctionDecl(name, params, returnType, body_, false, isInterrupt, isVariadic);
    }

    private ClassDecl classDecl() {
        expect(TokenType.Class);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftBrace);

        VarDecl[] fields;
        FunctionDecl constructor = null;
        FunctionDecl destructor = null;
        FunctionDecl[] methods;

        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            if (check(TokenType.Constructor)) {
                constructor = constructorDecl(name);
            } else if (check(TokenType.Destructor)) {
                destructor = destructorDecl(name);
            } else if (check(TokenType.Function)) {
                methods ~= functionDecl();
            } else if (check(TokenType.Let) || check(TokenType.Const)) {
                fields ~= varDecl();
            } else {
                error("Expected field or method declaration");
            }
        }

        expect(TokenType.RightBrace);
        return new ClassDecl(name, fields, constructor, destructor, methods);
    }

    private StructDecl structDecl() {
        bool packed = match(TokenType.Packed);
        expect(TokenType.Struct);
        string name = expect(TokenType.Identifier).value;
        expect(TokenType.LeftBrace);

        VarDecl[] fields;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            if (check(TokenType.Let) || check(TokenType.Const)) {
                fields ~= varDecl();
            } else {
                error("Expected field declaration");
            }
        }

        expect(TokenType.RightBrace);
        return new StructDecl(name, fields, packed);
    }

    private FunctionDecl constructorDecl(string className) {
        expect(TokenType.Constructor);
        expect(TokenType.LeftParen);

        Parameter[] params;
        if (!check(TokenType.RightParen)) {
            do {
                string paramName = expect(TokenType.Identifier).value;
                expect(TokenType.Colon);
                Type paramType = parseType();
                params ~= new Parameter(paramName, paramType);
            } while (match(TokenType.Comma));
        }
        expect(TokenType.RightParen);

        Block body_ = block();
        return new FunctionDecl(className ~ "_constructor", params, new Type("void"), body_);
    }

    private FunctionDecl destructorDecl(string className) {
        expect(TokenType.Destructor);
        expect(TokenType.LeftParen);
        expect(TokenType.RightParen);

        Block body_ = block();
        return new FunctionDecl(className ~ "_destructor", [], new Type("void"), body_);
    }

    private VarDecl varDecl() {
        int declLine = current.line;
        int declColumn = current.column;

        bool isConst = false;
        if (match(TokenType.Const)) {
            isConst = true;
        } else {
            expect(TokenType.Let);
        }

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

        return new VarDecl(name, type, initializer, isConst, declLine, declColumn, bitWidth);
    }

    private Type parseType() {
        string name = expect(TokenType.Identifier).value;
        // Namespace-qualified type name, e.g. Graphics.Point -> mangled as
        // Graphics_Point, matching how the code generator mangles namespaced
        // class declarations.
        while (match(TokenType.Dot)) {
            name ~= "_" ~ expect(TokenType.Identifier).value;
        }
        bool isPointer = false;
        bool isArray = false;
        int arraySize = 0;

        if (match(TokenType.Star)) {
            isPointer = true;
        }

        if (match(TokenType.LeftBracket)) {
            isArray = true;
            if (check(TokenType.Integer)) {
                arraySize = to!int(current.value);
                advance();
            }
            expect(TokenType.RightBracket);
        }

        return new Type(name, isPointer, isArray, arraySize);
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

    private ASTNode statement() {
        if (check(TokenType.If)) {
            return ifStmt();
        } else if (check(TokenType.While)) {
            return whileStmt();
        } else if (check(TokenType.For)) {
            return forStmt();
        } else if (check(TokenType.Return)) {
            return returnStmt();
        } else if (check(TokenType.Defer)) {
            return deferStmt();
        } else if (check(TokenType.Asm)) {
            return asmStmt();
        } else if (check(TokenType.Match)) {
            return matchStmt();
        } else if (check(TokenType.Let) || check(TokenType.Const)) {
            return varDecl();
        } else if (check(TokenType.LeftBrace)) {
            return block();
        } else {
            return exprStmt();
        }
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
        ASTNode subject = expression();
        expect(TokenType.LeftBrace);

        MatchCase[] cases;
        while (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            cases ~= matchCase();
        }

        expect(TokenType.RightBrace);
        return new MatchStmt(subject, cases, startLine, startColumn);
    }

    private MatchCase matchCase() {
        if (match(TokenType.Default)) {
            expect(TokenType.FatArrow);
            Block body_ = block();
            return new MatchCase([], body_);
        }

        expect(TokenType.Case);
        ASTNode[] patterns = [expression()];
        while (match(TokenType.Comma)) {
            patterns ~= expression();
        }
        expect(TokenType.FatArrow);
        Block body_ = block();
        return new MatchCase(patterns, body_);
    }

    private IfStmt ifStmt() {
        expect(TokenType.If);
        ASTNode condition = expression();
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

    private WhileStmt whileStmt() {
        expect(TokenType.While);
        ASTNode condition = expression();
        Block body_ = block();
        return new WhileStmt(condition, body_);
    }

    private ForStmt forStmt() {
        expect(TokenType.For);
        ASTNode initializer = null;
        ASTNode condition = null;
        ASTNode update = null;

        // init
        if (!check(TokenType.Comma)) {
            if (check(TokenType.Let) || check(TokenType.Const)) {
                initializer = varDecl();
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
            update = expression();
        }

        Block body_ = block();
        return new ForStmt(initializer, condition, update, body_);
    }

    private ReturnStmt returnStmt() {
        expect(TokenType.Return);
        ASTNode value = null;
        if (!check(TokenType.RightBrace) && !check(TokenType.EOF)) {
            value = expression();
        }
        return new ReturnStmt(value);
    }

    private DeferStmt deferStmt() {
        expect(TokenType.Defer);
        ASTNode stmt = statement();
        return new DeferStmt(stmt);
    }

    private ExprStmt exprStmt() {
        ASTNode expr = expression();
        return new ExprStmt(expr);
    }

    private ASTNode expression() {
        return assignment();
    }

    private ASTNode assignment() {
        ASTNode expr = logicalOr();

        if (match(TokenType.Assign)) {
            ASTNode value = assignment();
            return new BinaryExpr("=", expr, value, expr.line, expr.column);
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

        while (match(TokenType.BitwiseAnd)) {
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

        while (match(TokenType.Plus, TokenType.Minus)) {
            string op = tokens[pos - 1].value;
            ASTNode right = multiplicative();
            expr = new BinaryExpr(op, expr, right, expr.line, expr.column);
        }

        return expr;
    }

    private ASTNode multiplicative() {
        ASTNode expr = cast_();

        while (match(TokenType.Star, TokenType.Slash, TokenType.Percent)) {
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
                // Function call
                ASTNode[] args;
                if (!check(TokenType.RightParen)) {
                    do {
                        args ~= expression();
                    } while (match(TokenType.Comma));
                }
                expect(TokenType.RightParen);
                expr = new CallExpr(expr, args, startLine, startColumn);
            } else if (match(TokenType.Dot)) {
                // Member access
                int memberLine = current.line;
                int memberColumn = current.column;
                string member = expect(TokenType.Identifier).value;
                expr = new MemberExpr(expr, member, memberLine, memberColumn);
            } else if (match(TokenType.LeftBracket)) {
                // Array indexing
                ASTNode index = expression();
                expect(TokenType.RightBracket);
                expr = new IndexExpr(expr, index, startLine, startColumn);
            } else {
                break;
            }
        }

        return expr;
    }

    private ASTNode primary() {
        int tokLine = current.line;
        int tokColumn = current.column;

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
        if (match(TokenType.String)) {
            return new StringLiteral(tokens[pos - 1].value, tokLine, tokColumn);
        }
        if (match(TokenType.Identifier)) {
            return new Identifier(tokens[pos - 1].value, tokLine, tokColumn);
        }
        if (match(TokenType.New)) {
            Type type = parseType();
            expect(TokenType.LeftParen);
            ASTNode[] args;
            if (!check(TokenType.RightParen)) {
                do {
                    args ~= expression();
                } while (match(TokenType.Comma));
            }
            expect(TokenType.RightParen);
            return new NewExpr(type, args, tokLine, tokColumn);
        }
        if (match(TokenType.LeftParen)) {
            ASTNode expr = expression();
            expect(TokenType.RightParen);
            return expr;
        }

        error(format("Unexpected token: %s", current.type));
        return null;
    }
}
