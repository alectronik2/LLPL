module errors;

import std.stdio;
import std.string;
import std.format;
import std.file;

// A compiler error with enough context to render a source citation:
// the file it occurred in and the 1-based line/column of the offending token.
class CompileError : Exception {
    string filePath;
    int line;
    int column;

    this(string message, string filePath, int line, int column) {
        super(message);
        this.filePath = filePath;
        this.line = line;
        this.column = column;
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

    string location = format("  %s %s:%d:%d\n", blue("-->"), err.filePath, err.line, err.column);

    string[] lines;
    bool haveSource = false;
    if (exists(err.filePath)) {
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

            // Add caret pointer
            int caretPos = err.column > 0 ? err.column - 1 : 0;
            result ~= format(" %s %s %s%s\n", gutter, red("|"), spaces(caretPos), red("^"));
        } else {
            // Context lines in dim color
            string sourceLine = lines[i - 1];
            result ~= format(" %s %s %s\n", dim(paddedNum), dim("|"), dim(sourceLine));
        }
    }

    return result;
}
