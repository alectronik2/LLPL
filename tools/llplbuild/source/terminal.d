module terminal;

import std.stdio;
import std.format;
import core.stdc.stdio : fileno;

// Only colors when stdout is a real terminal - a redirected/piped build
// log shouldn't be full of escape codes.
private bool colorEnabled() {
    version (Posix) {
        import core.sys.posix.unistd : isatty;
        return isatty(fileno(stdout.getFP())) != 0;
    } else {
        return false;
    }
}

private enum Color : string {
    reset = "\x1b[0m",
    gray = "\x1b[90m",
    green = "\x1b[1;32m",  // bold green - Cargo's own verb color
    red = "\x1b[1;31m",    // bold red - Cargo's own failure color
    yellow = "\x1b[33m",
    bold = "\x1b[1m",
}

private string paint(string s, string color) {
    return colorEnabled() ? (color ~ s ~ Color.reset) : s;
}

// Cargo's own line shape: a bold, right-aligned 12-char verb field, a
// space, then the rest of the message - e.g. "   Compiling kernel.llpl",
// "    Finished final target(s) in 1.23s". `color` lets a caller use the
// failure color for a verb like "error" without a separate helper.
void cargoLine(string verb, string message, string color = Color.green) {
    writefln("%s %s", paint(format("%12s", verb), color), message);
    stdout.flush();
}

// Test-result coloring - "ok"/"FAILED" inline within a `test <name> ...`
// line, matching Cargo's own `cargo test` output exactly.
string paintOk(string s) { return paint(s, Color.green); }
string paintFail(string s) { return paint(s, Color.red); }

void logFail(string message) {
    stderr.writefln("%s %s", paint("✗", Color.red), message);
    stderr.flush();
}

void logWarn(string message) {
    stderr.writefln("%s %s", paint("warning:", Color.yellow), message);
    stderr.flush();
}
