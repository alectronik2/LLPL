#include "llpl_sys.h"

u64 str_len(const char *s) {
    u64 n = 0;
    while (s[n]) ++n;
    return n;
}

// stdout for a program like the shell can be a pipe read asynchronously by
// a whole separate renderer (kern/mu_term.llpl's terminal window, which
// drains and repaints whatever's arrived so far on its own ~33Hz cadence),
// not just the real framebuffer console this used to be written against
// exclusively (where every write lands synchronously with nothing else
// ever observing a half-finished screen). A single logical screen update
// like the shell's line-redraw echo (kern/../user/shell.c's redraw_line)
// used to go out as a dozen-plus separate SYS_WRITE calls - erase, then
// prompt, then each highlighted token, then the line again for cursor
// positioning - and mu_term_pump_io could (and, once the window's own
// redraw cadence got faster, reliably did) run in the gap between two of
// those calls, briefly painting the erased-but-not-yet-retyped state to
// the screen: a visible flicker on every keystroke. Buffering everything
// written between write_buf_begin/write_buf_end into one buffer and
// flushing it as a single SYS_WRITE makes the pipe (or the real console -
// this changes nothing observable there) only ever see a complete redraw,
// never a partial one.
#define WRITE_BUF_CAP 4096
static char write_buf[WRITE_BUF_CAP];
static u64 write_buf_len = 0;
static int write_buffering = 0;

void write_buf_begin(void) {
    write_buffering = 1;
    write_buf_len = 0;
}

void write_buf_end(void) {
    if (write_buf_len > 0) {
        call2(SYS_WRITE, write_buf_len, (u64)write_buf);
    }
    write_buffering = 0;
    write_buf_len = 0;
}

void write_n(const char *s, u64 n) {
    if (write_buffering) {
        u64 room = WRITE_BUF_CAP - write_buf_len;
        u64 take = n < room ? n : room;
        for (u64 i = 0; i < take; i++) write_buf[write_buf_len + i] = s[i];
        write_buf_len += take;
        return;
    }
    call2(SYS_WRITE, n, (u64)s);
}

void write_c(char c) {
    write_n(&c, 1);
}

void write_s(const char *s) {
    write_n(s, str_len(s));
}

void write_u64(u64 value) {
    char digits[21];
    u64 at = sizeof(digits);
    do {
        digits[--at] = '0' + (char)(value % 10);
        value /= 10;
    } while (value);
    write_n(digits + at, sizeof(digits) - at);
}

void write_i64(i64 value) {
    char digits[21];
    u64 at = sizeof(digits);
    int negative = value < 0;
    u64 magnitude = negative ? (u64)(-value) : (u64)value;
    do {
        digits[--at] = '0' + (char)(magnitude % 10);
        magnitude /= 10;
    } while (magnitude);
    if (negative) digits[--at] = '-';
    write_n(digits + at, sizeof(digits) - at);
}
