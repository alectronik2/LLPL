module lexer;

import std.string;
import std.ascii;
import std.conv;
import std.stdio;

enum TokenType {
    // Literals
    Integer,
    String,
    Identifier,

    // Keywords
    Import,
    Namespace,
    Function,
    Class,
    Struct,
    Packed,
    Interrupt,
    Constructor,
    Destructor,
    Let,
    Const,
    If,
    Else,
    While,
    For,
    Return,
    Defer,
    Asm,
    New,
    True,
    False,
    Null,
    Extern,
    As,
    Match,
    Case,
    Default,
    Alias,
    Operator,
    Enum,

    // Operators
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Assign,
    Equal,
    NotEqual,
    Less,
    Greater,
    LessEqual,
    GreaterEqual,
    And,
    Or,
    Not,
    BitwiseAnd,
    BitwiseOr,
    BitwiseXor,
    BitwiseNot,
    LeftShift,
    RightShift,
    Arrow,
    FatArrow,

    // Delimiters
    LeftParen,
    RightParen,
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    Comma,
    Dot,
    Ellipsis,
    Colon,

    // Special
    Newline,
    EOF
}

struct Token {
    TokenType type;
    string value;
    int line;
    int column;

    string toString() const {
        return format("Token(%s, '%s', %d:%d)", type, value, line, column);
    }
}

class Lexer {
    private string source;
    private size_t pos;
    private int line;
    private int column;
    private char current;

    private static string[string] keywords;

    static this() {
        keywords = [
            "import": "Import",
            "namespace": "Namespace",
            "func": "Function",
            "class": "Class",
            "struct": "Struct",
            "packed": "Packed",
            "interrupt": "Interrupt",
            "constructor": "Constructor",
            "destructor": "Destructor",
            "let": "Let",
            "const": "Const",
            "if": "If",
            "else": "Else",
            "while": "While",
            "for": "For",
            "return": "Return",
            "defer": "Defer",
            "asm": "Asm",
            "new": "New",
            "true": "True",
            "false": "False",
            "null": "Null",
            "extern": "Extern",
            "as": "As",
            "match": "Match",
            "case": "Case",
            "default": "Default",
            "alias": "Alias",
            "operator": "Operator",
            "enum": "Enum"
        ];
    }

    this(string source) {
        this.source = source;
        this.pos = 0;
        this.line = 1;
        this.column = 1;
        this.current = source.length > 0 ? source[0] : '\0';
    }

    private void advance() {
        if (current == '\n') {
            line++;
            column = 1;
        } else {
            column++;
        }

        pos++;
        if (pos < source.length) {
            current = source[pos];
        } else {
            current = '\0';
        }
    }

    private char peek(int offset = 1) {
        size_t peekPos = pos + offset;
        if (peekPos < source.length) {
            return source[peekPos];
        }
        return '\0';
    }

    private int hexDigitValue(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return 0;
    }

    private void skipWhitespace() {
        while (current != '\0' && (current == ' ' || current == '\t' || current == '\r')) {
            advance();
        }
    }

    private void skipComment() {
        if (current == '/' && peek() == '/') {
            while (current != '\0' && current != '\n') {
                advance();
            }
        } else if (current == '/' && peek() == '*') {
            advance(); // skip /
            advance(); // skip *
            while (current != '\0') {
                if (current == '*' && peek() == '/') {
                    advance(); // skip *
                    advance(); // skip /
                    break;
                }
                advance();
            }
        }
    }

    private Token number() {
        int startLine = line;
        int startColumn = column;
        string num = "";

        // Radix-prefixed literals: 0x/0X (hex), 0b/0B (binary), 0o/0O (octal)
        if (current == '0' && (peek() == 'x' || peek() == 'X' ||
                                peek() == 'b' || peek() == 'B' ||
                                peek() == 'o' || peek() == 'O')) {
            num ~= current; advance(); // '0'
            num ~= current; advance(); // radix marker

            while (current != '\0' && (isDigit(current) ||
                   (current >= 'a' && current <= 'f') || (current >= 'A' && current <= 'F'))) {
                num ~= current;
                advance();
            }

            return Token(TokenType.Integer, num, startLine, startColumn);
        }

        while (current != '\0' && isDigit(current)) {
            num ~= current;
            advance();
        }

        return Token(TokenType.Integer, num, startLine, startColumn);
    }

    private Token string_() {
        int startLine = line;
        int startColumn = column;
        advance(); // skip opening quote

        string str = "";
        while (current != '\0' && current != '"') {
            if (current == '\\') {
                advance();
                switch (current) {
                    case 'n': str ~= '\n'; break;
                    case 't': str ~= '\t'; break;
                    case 'r': str ~= '\r'; break;
                    case '\\': str ~= '\\'; break;
                    case '"': str ~= '"'; break;
                    case '0': str ~= '\0'; break;
                    case 'e': str ~= '\x1b'; break; // ESC, e.g. for ANSI color codes
                    case 'x': {
                        // \xHH - exactly two hex digits.
                        advance();
                        int value = 0;
                        int digits = 0;
                        while (digits < 2 && isHexDigit(current)) {
                            value = value * 16 + hexDigitValue(current);
                            advance();
                            digits++;
                        }
                        str ~= cast(char)value;
                        continue; // already advanced past the digits
                    }
                    default: str ~= current; break;
                }
            } else {
                str ~= current;
            }
            advance();
        }

        if (current == '"') {
            advance(); // skip closing quote
        }

        return Token(TokenType.String, str, startLine, startColumn);
    }

    private Token identifier() {
        int startLine = line;
        int startColumn = column;
        string id = "";

        while (current != '\0' && (isAlphaNum(current) || current == '_')) {
            id ~= current;
            advance();
        }

        if (id in keywords) {
            string keywordStr = keywords[id];
            TokenType type;
            switch (keywordStr) {
                case "Import": type = TokenType.Import; break;
                case "Namespace": type = TokenType.Namespace; break;
                case "Function": type = TokenType.Function; break;
                case "Class": type = TokenType.Class; break;
                case "Struct": type = TokenType.Struct; break;
                case "Packed": type = TokenType.Packed; break;
                case "Interrupt": type = TokenType.Interrupt; break;
                case "Constructor": type = TokenType.Constructor; break;
                case "Destructor": type = TokenType.Destructor; break;
                case "Let": type = TokenType.Let; break;
                case "Const": type = TokenType.Const; break;
                case "If": type = TokenType.If; break;
                case "Else": type = TokenType.Else; break;
                case "While": type = TokenType.While; break;
                case "For": type = TokenType.For; break;
                case "Return": type = TokenType.Return; break;
                case "Defer": type = TokenType.Defer; break;
                case "Asm": type = TokenType.Asm; break;
                case "New": type = TokenType.New; break;
                case "True": type = TokenType.True; break;
                case "False": type = TokenType.False; break;
                case "Null": type = TokenType.Null; break;
                case "Extern": type = TokenType.Extern; break;
                case "As": type = TokenType.As; break;
                case "Match": type = TokenType.Match; break;
                case "Case": type = TokenType.Case; break;
                case "Default": type = TokenType.Default; break;
                case "Alias": type = TokenType.Alias; break;
                case "Operator": type = TokenType.Operator; break;
                case "Enum": type = TokenType.Enum; break;
                default: type = TokenType.Identifier; break;
            }
            return Token(type, id, startLine, startColumn);
        }

        return Token(TokenType.Identifier, id, startLine, startColumn);
    }

    Token nextToken() {
        while (current != '\0') {
            skipWhitespace();

            if (current == '\0') break;

            // Comments
            if (current == '/' && (peek() == '/' || peek() == '*')) {
                skipComment();
                continue;
            }

            int startLine = line;
            int startColumn = column;

            // Newlines
            if (current == '\n') {
                advance();
                return Token(TokenType.Newline, "\\n", startLine, startColumn);
            }

            // Numbers
            if (isDigit(current)) {
                return number();
            }

            // Strings
            if (current == '"') {
                return string_();
            }

            // Identifiers and keywords
            if (isAlpha(current) || current == '_') {
                return identifier();
            }

            // Two-character operators
            if (current == '=' && peek() == '=') {
                advance(); advance();
                return Token(TokenType.Equal, "==", startLine, startColumn);
            }
            if (current == '!' && peek() == '=') {
                advance(); advance();
                return Token(TokenType.NotEqual, "!=", startLine, startColumn);
            }
            if (current == '<' && peek() == '=') {
                advance(); advance();
                return Token(TokenType.LessEqual, "<=", startLine, startColumn);
            }
            if (current == '>' && peek() == '=') {
                advance(); advance();
                return Token(TokenType.GreaterEqual, ">=", startLine, startColumn);
            }
            if (current == '&' && peek() == '&') {
                advance(); advance();
                return Token(TokenType.And, "&&", startLine, startColumn);
            }
            if (current == '|' && peek() == '|') {
                advance(); advance();
                return Token(TokenType.Or, "||", startLine, startColumn);
            }
            if (current == '<' && peek() == '<') {
                advance(); advance();
                return Token(TokenType.LeftShift, "<<", startLine, startColumn);
            }
            if (current == '>' && peek() == '>') {
                advance(); advance();
                return Token(TokenType.RightShift, ">>", startLine, startColumn);
            }
            if (current == '-' && peek() == '>') {
                advance(); advance();
                return Token(TokenType.Arrow, "->", startLine, startColumn);
            }
            if (current == '=' && peek() == '>') {
                advance(); advance();
                return Token(TokenType.FatArrow, "=>", startLine, startColumn);
            }
            if (current == '.' && peek(1) == '.' && peek(2) == '.') {
                advance(); advance(); advance();
                return Token(TokenType.Ellipsis, "...", startLine, startColumn);
            }

            // Single-character tokens
            switch (current) {
                case '+':
                    advance();
                    return Token(TokenType.Plus, "+", startLine, startColumn);
                case '-':
                    advance();
                    return Token(TokenType.Minus, "-", startLine, startColumn);
                case '*':
                    advance();
                    return Token(TokenType.Star, "*", startLine, startColumn);
                case '/':
                    advance();
                    return Token(TokenType.Slash, "/", startLine, startColumn);
                case '%':
                    advance();
                    return Token(TokenType.Percent, "%", startLine, startColumn);
                case '=':
                    advance();
                    return Token(TokenType.Assign, "=", startLine, startColumn);
                case '<':
                    advance();
                    return Token(TokenType.Less, "<", startLine, startColumn);
                case '>':
                    advance();
                    return Token(TokenType.Greater, ">", startLine, startColumn);
                case '!':
                    advance();
                    return Token(TokenType.Not, "!", startLine, startColumn);
                case '&':
                    advance();
                    return Token(TokenType.BitwiseAnd, "&", startLine, startColumn);
                case '|':
                    advance();
                    return Token(TokenType.BitwiseOr, "|", startLine, startColumn);
                case '^':
                    advance();
                    return Token(TokenType.BitwiseXor, "^", startLine, startColumn);
                case '~':
                    advance();
                    return Token(TokenType.BitwiseNot, "~", startLine, startColumn);
                case '(':
                    advance();
                    return Token(TokenType.LeftParen, "(", startLine, startColumn);
                case ')':
                    advance();
                    return Token(TokenType.RightParen, ")", startLine, startColumn);
                case '{':
                    advance();
                    return Token(TokenType.LeftBrace, "{", startLine, startColumn);
                case '}':
                    advance();
                    return Token(TokenType.RightBrace, "}", startLine, startColumn);
                case '[':
                    advance();
                    return Token(TokenType.LeftBracket, "[", startLine, startColumn);
                case ']':
                    advance();
                    return Token(TokenType.RightBracket, "]", startLine, startColumn);
                case ',':
                    advance();
                    return Token(TokenType.Comma, ",", startLine, startColumn);
                case '.':
                    advance();
                    return Token(TokenType.Dot, ".", startLine, startColumn);
                case ':':
                    advance();
                    return Token(TokenType.Colon, ":", startLine, startColumn);
                default:
                    stderr.writefln("Unexpected character: '%s' at %d:%d", current, line, column);
                    advance();
                    continue;
            }
        }

        return Token(TokenType.EOF, "", line, column);
    }

    Token[] tokenize() {
        Token[] tokens;
        while (true) {
            Token tok = nextToken();
            if (tok.type != TokenType.Newline) { // Skip newlines for now
                tokens ~= tok;
            }
            if (tok.type == TokenType.EOF) break;
        }
        return tokens;
    }
}
