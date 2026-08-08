module errors;

import std.stdio;
import std.string;
import std.format;
import std.file;
import std.algorithm : min;
import std.path : baseName, dirName, buildNormalizedPath;

private string[string] expandedSourcesByFile;

void registerExpandedSource(string filePath, string source) {
    if (filePath.length > 0) {
        expandedSourcesByFile[filePath] = source;
    }
}

// A compiler error with enough context to render a source citation:
// the file it occurred in and the 1-based line/column of the offending token.
class CompileError : Exception {
    string filePath;
    int line;
    int column;
    int endLine;
    int endColumn;
    string[] notes;
    string suggestion;

    this(string message, string filePath, int line, int column,
         int endLine = 0, int endColumn = 0, string[] notes = [], string suggestion = "") {
        super(message);
        this.filePath = filePath;
        this.line = line;
        this.column = column;
        this.endLine = endLine > 0 ? endLine : line;
        this.endColumn = endColumn > 0 ? endColumn : column + 1;
        this.notes = notes;
        this.suggestion = suggestion;
    }
}

// Carries every CompileError collected across an entire compile, instead
// of stopping at the first one - see codegen.d's collectedErrors
// (populated per top-level declaration in generateMultiple's main
// declCode loop, the point past which one declaration's own error can't
// cascade into a false one anywhere else - every registry/field/generic-
// template resolution earlier declarations might depend on has already
// happened by then). Thrown once, at the very end of generateMultiple, so
// a file with bugs in several independent functions reports all of them
// in one compile instead of needing one fix-and-rerun cycle per bug.
class MultiCompileError : Exception {
    CompileError[] errors;

    this(CompileError[] errors) {
        super(format("%d error(s)", errors.length));
        this.errors = errors;
    }
}

private string spaces(size_t n) {
    string result;
    foreach (i; 0 .. n) result ~= " ";
    return result;
}

// Keep terminal diagnostics readable while retaining the source directory
// that identifies a module, e.g. `mm/heap.llpl` instead of an absolute path.
private string displaySourcePath(string path) {
    if (path.length == 0) return path;
    string file = baseName(path);
    string directory = baseName(dirName(path));
    if (directory.length == 0 || directory == ".") return file;
    return buildNormalizedPath(directory, file);
}

// ANSI color codes
private enum Colors {
    RESET = "\033[0m",
    RED = "\033[31m",
    YELLOW = "\033[33m",
    BLUE = "\033[34m",
    BOLD = "\033[1m",
    DIM = "\033[2m",
}

private bool shouldUseColor() {
    import std.process : environment;
    string noColor = environment.get("NO_COLOR");
    string forceColor = environment.get("FORCE_COLOR");
    if (forceColor.length > 0) return true;
    if (noColor.length > 0) return false;
    // Default to color if stderr is a terminal
    return true;
}

// Renders an error with a source citation in the style of rustc/clang with colors:
//
//   error: Cannot infer type of 'x'
//     --> examples/kernel.llpl:3:9
//       |
//     3 |     let x
//       |         ^
string formatCompileError(CompileError err) {
    bool useColor = shouldUseColor();

    string red(string s) { return useColor ? Colors.RED ~ s ~ Colors.RESET : s; }
    string bold(string s) { return useColor ? Colors.BOLD ~ s ~ Colors.RESET : s; }
    string blue(string s) { return useColor ? Colors.BLUE ~ s ~ Colors.RESET : s; }
    string dim(string s) { return useColor ? Colors.DIM ~ s ~ Colors.RESET : s; }

    string header = format("%s: %s\n", red("error"), err.msg);

    if (err.filePath.length == 0 || err.line <= 0) {
        return header;
    }

    string location = format("  %s %s:%d:%d\n", blue("-->"), displaySourcePath(err.filePath),
        err.line, err.column);

    string[] lines;
    bool haveSource = false;
    if (auto expanded = err.filePath in expandedSourcesByFile) {
        lines = (*expanded).splitLines();
        haveSource = lines.length > 0;
    } else if (exists(err.filePath)) {
        lines = readText(err.filePath).splitLines();
        haveSource = lines.length > 0;
    }

    if (!haveSource) {
        return header ~ location;
    }

    int errorLine = err.line;
    int contextBefore = 1;
    int contextAfter = 1;
    int startLine = (errorLine - contextBefore > 1) ? errorLine - contextBefore : 1;
    int endLine = (errorLine + contextAfter <= lines.length) ? errorLine + contextAfter : cast(int)lines.length;

    string result = header ~ location;

    // Gutter width for line numbers
    string maxLineStr = format("%d", endLine);
    string gutter = spaces(maxLineStr.length);

    result ~= format(" %s |\n", gutter);

    for (int i = startLine; i <= endLine; i++) {
        string lineNumStr = format("%d", i);
        string paddedNum = spaces(maxLineStr.length - lineNumStr.length) ~ lineNumStr;

        if (i == errorLine) {
            // Highlight error line
            string sourceLine = lines[i - 1];
            result ~= format(" %s %s %s\n", red(paddedNum), red("|"), sourceLine);

            // Add a span pointer. Single-column diagnostics remain a single
            // caret; parsers can provide an end column for token spans.
            int caretPos = err.column > 0 ? err.column - 1 : 0;
            int spanEnd = err.endLine == errorLine ? err.endColumn : err.column + 1;
            int spanWidth = spanEnd > err.column ? spanEnd - err.column : 1;
            if (sourceLine.length > 0) {
                spanWidth = min(spanWidth, cast(int)sourceLine.length - caretPos);
                if (spanWidth < 1) spanWidth = 1;
            }
            string marker = "^" ~ (spanWidth > 1 ? spaces(spanWidth - 1).replace(" ", "~") : "");
            result ~= format(" %s %s %s%s\n", gutter, red("|"), spaces(caretPos), red(marker));
        } else {
            // Context lines in dim color
            string sourceLine = lines[i - 1];
            result ~= format(" %s %s %s\n", dim(paddedNum), dim("|"), dim(sourceLine));
        }
    }

    foreach (note; err.notes) {
        result ~= format(" %s %s %s\n", gutter, blue("="), note);
    }
    string suggestion = err.suggestion.length > 0 ? err.suggestion : diagnosticSuggestion(err.msg);
    if (suggestion.length > 0) {
        result ~= format(" %s %s %s\n", gutter, bold("help:"), suggestion);
    }

    string marker = findComptimeTraceMarker(lines, errorLine);
    if (marker.length > 0) {
        result ~= format(" %s %s expanded from %s\n", gutter, blue("="), marker);
    }

    return result;
}

private string diagnosticSuggestion(string message) {
    if (message.indexOf("Expected RightParen") >= 0) {
        return "check for a missing ')' or an unterminated argument list";
    }
    if (message.indexOf("Expected RightBrace") >= 0) {
        return "check for a missing '}' or an unterminated block";
    }
    if (message.indexOf("unknown variable") >= 0 || message.indexOf("undeclared") >= 0) {
        return "check the spelling, scope, and imports for this name";
    }
    if (message.indexOf("unknown function") >= 0) {
        return "check the function name and import the module that defines it";
    }
    if (message.indexOf("Cannot infer type") >= 0) {
        return "add an explicit type annotation or make the expression's type unambiguous";
    }
    return "";
}

private string findComptimeTraceMarker(string[] lines, int errorLine) {
    if (errorLine <= 0 || lines.length == 0) return "";
    int start = errorLine <= lines.length ? errorLine : cast(int)lines.length;
    for (int i = start; i >= 1 && i >= start - 80; i--) {
        string line = lines[i - 1].strip();
        enum prefix = "// llpl:comptime ";
        if (line.startsWith(prefix)) {
            return line[prefix.length .. $];
        }
    }
    return "";
}
