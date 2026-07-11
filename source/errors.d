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

// Renders an error with a source citation in the style of rustc/clang, e.g.:
//
//   error: Cannot infer type of 'x'
//     --> examples/kernel.llpl:3:9
//       |
//     3 |     let x
//       |         ^
string formatCompileError(CompileError err) {
    string header = format("error: %s\n", err.msg);

    if (err.filePath.length == 0 || err.line <= 0) {
        return header;
    }

    string location = format("  --> %s:%d:%d\n", err.filePath, err.line, err.column);

    string sourceLine = "";
    bool haveSource = false;
    if (exists(err.filePath)) {
        auto lines = readText(err.filePath).splitLines();
        if (err.line >= 1 && err.line <= lines.length) {
            sourceLine = lines[err.line - 1];
            haveSource = true;
        }
    }

    if (!haveSource) {
        return header ~ location;
    }

    string lineNumStr = format("%d", err.line);
    string gutter = spaces(lineNumStr.length);
    int caretPos = err.column > 0 ? err.column - 1 : 0;

    string result = header ~ location;
    result ~= format(" %s |\n", gutter);
    result ~= format(" %s | %s\n", lineNumStr, sourceLine);
    result ~= format(" %s | %s^\n", gutter, spaces(caretPos));

    return result;
}
