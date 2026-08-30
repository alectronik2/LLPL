#include "llpl_sys.h"

u64 str_len(const char *s) {
    u64 n = 0;
    while (s[n]) ++n;
    return n;
}

void write_n(const char *s, u64 n) {
    call2(SYS_WRITE, n, (u64)s);
}

void write_c(char c) {
    call2(SYS_WRITE, 1, (u64)&c);
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
