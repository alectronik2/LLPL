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
    green = "\x1b[32m",
    red = "\x1b[31m",
    yellow = "\x1b[33m",
    bold = "\x1b[1m",
}

private string paint(string s, string color) {
    return colorEnabled() ? (color ~ s ~ Color.reset) : s;
}

// Tracks "[N/total]" step numbering across one pipeline run.
struct StepCounter {
    int total;
    int current;

    void step(string message) {
        current++;
        writefln("%s %s", paint(format("[%d/%d]", current, total), Color.bold), message);
        stdout.flush();
    }

    void skipped(string message) {
        current++;
        writefln("%s %s %s", paint(format("[%d/%d]", current, total), Color.bold),
            message, paint("(up to date)", Color.gray));
        stdout.flush();
    }
}

void logOk(string message) {
    writefln("%s %s", paint("✓", Color.green), message);
    stdout.flush();
}

void logFail(string message) {
    stderr.writefln("%s %s", paint("✗", Color.red), message);
    stderr.flush();
}

void logInfo(string message) {
    writeln(paint(message, Color.gray));
    stdout.flush();
}

void logWarn(string message) {
    stderr.writefln("%s %s", paint("warning:", Color.yellow), message);
    stderr.flush();
}
