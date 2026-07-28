module terminal;

import std.stdio;
import std.format;
import std.algorithm : min;
import std.array : replicate;
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

private bool progressActive;
private size_t progressLineLen;

private string truncateProgressMessage(string message) {
    enum maxMessageLen = 48;
    if (message.length <= maxMessageLen) return message;
    if (maxMessageLen <= 3) return message[0 .. maxMessageLen];
    return message[0 .. maxMessageLen - 3] ~ "...";
}

private void clearProgressLine() {
    if (!progressActive || !colorEnabled()) return;
    writef("\r%*s\r", cast(int)progressLineLen, "");
    stdout.flush();
}

void progressStart(size_t total) {
    if (!colorEnabled() || total == 0) return;
    progressActive = true;
    progressLineLen = 0;
    progressStep(0, total, "starting");
}

void progressStep(size_t completed, size_t total, string message) {
    if (!colorEnabled() || total == 0) return;

    enum barWidth = 28;
    size_t clamped = min(completed, total);
    size_t filled = clamped * barWidth / total;
    int percent = cast(int)(clamped * 100 / total);
    string bar = replicate("#", filled) ~ replicate("-", barWidth - filled);
    string line = format("%3d%% [%s] %s/%s %s",
        percent, bar, clamped, total, truncateProgressMessage(message));

    writef("\r%s", line);
    if (progressLineLen > line.length) {
        writef("%*s", cast(int)(progressLineLen - line.length), "");
    }
    progressLineLen = line.length;
    stdout.flush();
}

void progressFinish() {
    if (!progressActive || !colorEnabled()) return;
    writeln();
    stdout.flush();
    progressActive = false;
    progressLineLen = 0;
}

// Cargo's own line shape: a bold, right-aligned 12-char verb field, a
// space, then the rest of the message - e.g. "   Compiling kernel.llpl",
// "    Finished final target(s) in 1.23s". `color` lets a caller use the
// failure color for a verb like "error" without a separate helper.
void cargoLine(string verb, string message, string color = Color.green) {
    clearProgressLine();
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
