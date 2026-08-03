module comptime;

import std.conv : to;
import std.string : replace;
import std.format : format;
import errors;

private bool isIdentStart(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdentPart(char c) {
    return isIdentStart(c) || (c >= '0' && c <= '9');
}

private void locationAt(string source, size_t idx, out int line, out int column) {
    line = 1;
    column = 1;
    foreach (i, c; source) {
        if (i >= idx) break;
        if (c == '\n') {
            line++;
            column = 1;
        } else {
            column++;
        }
    }
}

private bool wordAt(string source, size_t idx, string word) {
    if (idx + word.length > source.length) return false;
    if (source[idx .. idx + word.length] != word) return false;
    if (idx > 0 && isIdentPart(source[idx - 1])) return false;
    if (idx + word.length < source.length && isIdentPart(source[idx + word.length])) return false;
    return true;
}

private void skipWhitespace(string source, ref size_t idx) {
    while (idx < source.length && (source[idx] == ' ' || source[idx] == '\t' ||
            source[idx] == '\r' || source[idx] == '\n')) {
        idx++;
    }
}

private bool consumeWord(string source, ref size_t idx, string word) {
    skipWhitespace(source, idx);
    if (!wordAt(source, idx, word)) return false;
    idx += word.length;
    return true;
}

private string comptimeTraceMarker(string filePath, int line, int column, string detail) {
    return format("// llpl:comptime %s:%d:%d %s\n", filePath, line, column, detail);
}

private string parseIdentifier(string source, ref size_t idx, string filePath) {
    skipWhitespace(source, idx);
    if (idx >= source.length || !isIdentStart(source[idx])) {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected identifier in comptime for", filePath, line, column);
    }
    size_t start = idx;
    idx++;
    while (idx < source.length && isIdentPart(source[idx])) idx++;
    return source[start .. idx];
}

private long parseInteger(string source, ref size_t idx, string filePath) {
    skipWhitespace(source, idx);
    size_t start = idx;
    if (idx < source.length && (source[idx] == '-' || source[idx] == '+')) idx++;
    while (idx < source.length && source[idx] >= '0' && source[idx] <= '9') idx++;
    if (idx == start || (idx == start + 1 && (source[start] == '-' || source[start] == '+'))) {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected integer bound in comptime for range", filePath, line, column);
    }
    return to!long(source[start .. idx]);
}

private long parseRangeBound(string source, ref size_t idx, string filePath,
        long[string] numericConsts) {
    skipWhitespace(source, idx);
    if (idx < source.length && ((source[idx] >= '0' && source[idx] <= '9') ||
            source[idx] == '-' || source[idx] == '+')) {
        return parseInteger(source, idx, filePath);
    }
    if (idx < source.length && isIdentStart(source[idx])) {
        string name = parseIdentifier(source, idx, filePath);
        if (auto value = name in numericConsts) return *value;
        int line, column;
        locationAt(source, idx - name.length, line, column);
        throw new CompileError("Unknown numeric const '" ~ name ~ "' in comptime for range",
            filePath, line, column);
    }

    int line, column;
    locationAt(source, idx, line, column);
    throw new CompileError("Expected integer bound in comptime for range", filePath, line, column);
}

private bool parseComptimeCondition(string source, ref size_t idx, string filePath,
        long[string] numericConsts) {
    skipWhitespace(source, idx);
    bool negated = false;
    if (idx < source.length && source[idx] == '!') {
        negated = true;
        idx++;
        skipWhitespace(source, idx);
    }

    bool value;
    if (wordAt(source, idx, "true")) {
        idx += "true".length;
        value = true;
    } else if (wordAt(source, idx, "false")) {
        idx += "false".length;
        value = false;
    } else if (idx < source.length && ((source[idx] >= '0' && source[idx] <= '9') ||
            source[idx] == '-' || source[idx] == '+')) {
        value = parseInteger(source, idx, filePath) != 0;
    } else if (idx < source.length && isIdentStart(source[idx])) {
        string name = parseIdentifier(source, idx, filePath);
        if (auto constValue = name in numericConsts) {
            value = *constValue != 0;
        } else {
            int line, column;
            locationAt(source, idx - name.length, line, column);
            throw new CompileError("Unknown const '" ~ name ~ "' in comptime if condition",
                filePath, line, column);
        }
    } else {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected boolean or integer condition in comptime if",
            filePath, line, column);
    }

    return negated ? !value : value;
}

private void expectText(string source, ref size_t idx, string text, string message, string filePath) {
    skipWhitespace(source, idx);
    if (idx + text.length > source.length || source[idx .. idx + text.length] != text) {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError(message, filePath, line, column);
    }
    idx += text.length;
}

private string replaceShortPlaceholder(string source, string placeholder, string value) {
    string result;
    size_t idx = 0;
    while (idx < source.length) {
        if (idx + placeholder.length <= source.length &&
                source[idx .. idx + placeholder.length] == placeholder &&
                (idx + placeholder.length >= source.length ||
                 !isIdentPart(source[idx + placeholder.length]))) {
            result ~= value;
            idx += placeholder.length;
        } else {
            result ~= source[idx];
            idx++;
        }
    }
    return result;
}

private string replaceIdentifierPlaceholder(string source, string name, string value) {
    string result;
    size_t idx = 0;
    while (idx < source.length) {
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '/') {
            size_t start = idx;
            idx += 2;
            while (idx < source.length && source[idx] != '\n') idx++;
            result ~= source[start .. idx];
            continue;
        }
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '*') {
            size_t start = idx;
            idx += 2;
            while (idx + 1 < source.length && !(source[idx] == '*' && source[idx + 1] == '/')) idx++;
            idx = idx + 1 < source.length ? idx + 2 : idx;
            result ~= source[start .. idx];
            continue;
        }
        if (source[idx] == '"' || source[idx] == '\'') {
            size_t start = idx;
            char quote = source[idx++];
            while (idx < source.length) {
                if (source[idx] == '\\' && idx + 1 < source.length) {
                    idx += 2;
                    continue;
                }
                if (source[idx] == quote) {
                    idx++;
                    break;
                }
                idx++;
            }
            result ~= replaceIdentifierInInterpolations(source[start .. idx], name, value);
            continue;
        }
        if (wordAt(source, idx, name)) {
            result ~= value;
            idx += name.length;
            continue;
        }
        result ~= source[idx];
        idx++;
    }
    return result;
}

private string replaceIdentifierInInterpolations(string quoted, string name, string value) {
    if (quoted.length < 2 || quoted[0] != '"') return quoted;

    string result;
    size_t idx = 0;
    while (idx < quoted.length) {
        if (quoted[idx] == '\\' && idx + 1 < quoted.length && quoted[idx + 1] == '(') {
            result ~= quoted[idx .. idx + 2];
            idx += 2;
            size_t exprStart = idx;
            int depth = 1;
            while (idx < quoted.length && depth > 0) {
                if (quoted[idx] == '\\' && idx + 1 < quoted.length) {
                    idx += 2;
                    continue;
                }
                if (quoted[idx] == '(') {
                    depth++;
                    idx++;
                    continue;
                }
                if (quoted[idx] == ')') {
                    depth--;
                    if (depth == 0) break;
                    idx++;
                    continue;
                }
                idx++;
            }
            string expr = quoted[exprStart .. idx];
            result ~= replaceIdentifierPlaceholder(expr, name, value);
            if (idx < quoted.length && quoted[idx] == ')') {
                result ~= ")";
                idx++;
            }
            continue;
        }

        result ~= quoted[idx];
        idx++;
    }
    return result;
}

private size_t findMatchingBrace(string source, size_t openIdx, string filePath) {
    size_t idx = openIdx + 1;
    int depth = 1;
    while (idx < source.length) {
        char c = source[idx];
        if (c == '/' && idx + 1 < source.length && source[idx + 1] == '/') {
            idx += 2;
            while (idx < source.length && source[idx] != '\n') idx++;
            continue;
        }
        if (c == '/' && idx + 1 < source.length && source[idx + 1] == '*') {
            idx += 2;
            while (idx + 1 < source.length && !(source[idx] == '*' && source[idx + 1] == '/')) idx++;
            idx = idx + 1 < source.length ? idx + 2 : idx;
            continue;
        }
        if (c == '"' || c == '\'') {
            char quote = c;
            idx++;
            while (idx < source.length) {
                if (source[idx] == '\\' && idx + 1 < source.length) {
                    idx += 2;
                    continue;
                }
                if (source[idx] == quote) {
                    idx++;
                    break;
                }
                idx++;
            }
            continue;
        }
        if (c == '{') depth++;
        if (c == '}') {
            depth--;
            if (depth == 0) return idx;
        }
        idx++;
    }

    int line, column;
    locationAt(source, openIdx, line, column);
    throw new CompileError("Unterminated comptime for block", filePath, line, column);
}

private size_t parseComptimeFor(string source, size_t start, string filePath,
        long[string] numericConsts,
        out string expanded) {
    size_t idx = start + "comptime".length;
    if (!consumeWord(source, idx, "for")) return 0;

    string varName = parseIdentifier(source, idx, filePath);
    if (!consumeWord(source, idx, "in")) {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected 'in' in comptime for", filePath, line, column);
    }

    long rangeStart = parseRangeBound(source, idx, filePath, numericConsts);
    expectText(source, idx, "..", "Expected '..' in comptime for range", filePath);
    long rangeEnd = parseRangeBound(source, idx, filePath, numericConsts);
    skipWhitespace(source, idx);
    if (idx >= source.length || source[idx] != '{') {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected '{' after comptime for range", filePath, line, column);
    }

    size_t bodyStart = idx + 1;
    size_t closeIdx = findMatchingBrace(source, idx, filePath);
    string body = source[bodyStart .. closeIdx];
    string placeholder = "${" ~ varName ~ "}";
    string shortPlaceholder = "$" ~ varName;
    int forLine, forColumn;
    locationAt(source, start, forLine, forColumn);

    for (long value = rangeStart; value < rangeEnd; value++) {
        string valueText = to!string(value);
        string iterBody = replaceShortPlaceholder(body.replace(placeholder, valueText),
            shortPlaceholder, valueText);
        expanded ~= comptimeTraceMarker(filePath, forLine, forColumn,
            format("for %s = %s", varName, valueText));
        expanded ~= replaceIdentifierPlaceholder(iterBody, varName, valueText);
        if (expanded.length == 0 || expanded[$ - 1] != '\n') expanded ~= "\n";
    }

    return closeIdx + 1;
}

private size_t parseComptimeIf(string source, size_t start, string filePath,
        long[string] numericConsts,
        out string expanded) {
    size_t idx = start + "comptime".length;
    if (!consumeWord(source, idx, "if")) return 0;

    bool condition = parseComptimeCondition(source, idx, filePath, numericConsts);
    skipWhitespace(source, idx);
    if (idx >= source.length || source[idx] != '{') {
        int line, column;
        locationAt(source, idx, line, column);
        throw new CompileError("Expected '{' after comptime if condition", filePath, line, column);
    }

    size_t thenStart = idx + 1;
    size_t thenClose = findMatchingBrace(source, idx, filePath);
    string thenBody = source[thenStart .. thenClose];
    idx = thenClose + 1;

    string elseBody;
    size_t afterIf = idx;
    if (consumeWord(source, idx, "else")) {
        skipWhitespace(source, idx);
        if (idx >= source.length || source[idx] != '{') {
            int line, column;
            locationAt(source, idx, line, column);
            throw new CompileError("Expected '{' after comptime if else", filePath, line, column);
        }
        size_t elseStart = idx + 1;
        size_t elseClose = findMatchingBrace(source, idx, filePath);
        elseBody = source[elseStart .. elseClose];
        afterIf = elseClose + 1;
    }

    int ifLine, ifColumn;
    locationAt(source, start, ifLine, ifColumn);
    expanded = comptimeTraceMarker(filePath, ifLine, ifColumn,
        format("if branch = %s", condition ? "then" : "else"));
    expanded ~= (condition ? thenBody : elseBody);
    if (expanded.length > 0 && expanded[$ - 1] != '\n') expanded ~= "\n";
    return afterIf;
}

private void collectNumericConstAt(string source, size_t start, string filePath,
        ref long[string] numericConsts) {
    size_t idx = start + "const".length;
    skipWhitespace(source, idx);
    if (idx >= source.length || !isIdentStart(source[idx])) return;
    string name = parseIdentifier(source, idx, filePath);
    skipWhitespace(source, idx);
    if (idx < source.length && source[idx] == ':') {
        idx++;
        while (idx < source.length && source[idx] != '=' && source[idx] != '\n' &&
                source[idx] != '{' && source[idx] != '}') {
            idx++;
        }
    }
    skipWhitespace(source, idx);
    if (idx >= source.length || source[idx] != '=') return;
    idx++;
    skipWhitespace(source, idx);
    if (idx >= source.length || !((source[idx] >= '0' && source[idx] <= '9') ||
            source[idx] == '-' || source[idx] == '+')) {
        return;
    }
    numericConsts[name] = parseInteger(source, idx, filePath);
}

private long[string] collectNumericConsts(string source, string filePath) {
    long[string] numericConsts;
    size_t idx = 0;
    while (idx < source.length) {
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '/') {
            idx += 2;
            while (idx < source.length && source[idx] != '\n') idx++;
            continue;
        }
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '*') {
            idx += 2;
            while (idx + 1 < source.length && !(source[idx] == '*' && source[idx + 1] == '/')) idx++;
            idx = idx + 1 < source.length ? idx + 2 : idx;
            continue;
        }
        if (source[idx] == '"' || source[idx] == '\'') {
            char quote = source[idx++];
            while (idx < source.length) {
                if (source[idx] == '\\' && idx + 1 < source.length) {
                    idx += 2;
                    continue;
                }
                if (source[idx] == quote) {
                    idx++;
                    break;
                }
                idx++;
            }
            continue;
        }
        if (wordAt(source, idx, "const")) {
            collectNumericConstAt(source, idx, filePath, numericConsts);
            idx += "const".length;
            continue;
        }
        idx++;
    }
    return numericConsts;
}

private string expandComptimeForWithConsts(string source, string filePath,
        long[string] numericConsts) {
    string result;
    size_t idx = 0;
    while (idx < source.length) {
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '/') {
            size_t start = idx;
            idx += 2;
            while (idx < source.length && source[idx] != '\n') idx++;
            result ~= source[start .. idx];
            continue;
        }
        if (source[idx] == '/' && idx + 1 < source.length && source[idx + 1] == '*') {
            size_t start = idx;
            idx += 2;
            while (idx + 1 < source.length && !(source[idx] == '*' && source[idx + 1] == '/')) idx++;
            idx = idx + 1 < source.length ? idx + 2 : idx;
            result ~= source[start .. idx];
            continue;
        }
        if (source[idx] == '"' || source[idx] == '\'') {
            size_t start = idx;
            char quote = source[idx++];
            while (idx < source.length) {
                if (source[idx] == '\\' && idx + 1 < source.length) {
                    idx += 2;
                    continue;
                }
                if (source[idx] == quote) {
                    idx++;
                    break;
                }
                idx++;
            }
            result ~= source[start .. idx];
            continue;
        }
        if (wordAt(source, idx, "comptime")) {
            string expanded;
            size_t after = parseComptimeFor(source, idx, filePath, numericConsts, expanded);
            if (after == 0) {
                after = parseComptimeIf(source, idx, filePath, numericConsts, expanded);
            }
            if (after != 0) {
                result ~= expandComptimeForWithConsts(expanded, filePath, numericConsts);
                idx = after;
                continue;
            }
        }
        result ~= source[idx];
        idx++;
    }
    return result;
}

string expandComptimeFor(string source, string filePath = "") {
    auto numericConsts = collectNumericConsts(source, filePath);
    return expandComptimeForWithConsts(source, filePath, numericConsts);
}
