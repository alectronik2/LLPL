#include "runtime.h"

// Simple bump allocator for bare metal
#define HEAP_SIZE (1024 * 1024) // 1MB heap
static uint8_t heap[HEAP_SIZE];
static size_t heap_offset = 0;

void* rc_alloc(size_t size) {
    // Align to 8 bytes
    size = (size + 7) & ~7;

    if (heap_offset + size > HEAP_SIZE) {
        return NULL; // Out of memory
    }

    void* ptr = &heap[heap_offset];
    heap_offset += size;
    return ptr;
}

void rc_free(void* ptr) {
    // Simple allocator doesn't support free
    // In a real implementation, you'd use a proper allocator
    (void)ptr;
}

void rc_init(RefCount* rc) {
    rc->count = 1;
}

void rc_retain(void* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    rc->count++;
}

void rc_release(void* ptr, void (*destructor)(void*)) {
    if (!ptr) return;

    RefCount* rc = (RefCount*)ptr;
    rc->count--;

    if (rc->count == 0) {
        if (destructor) {
            destructor(ptr);
        }
        rc_free(ptr);
    }
}

void* memset(void* dest, int val, size_t count) {
    uint8_t* d = (uint8_t*)dest;
    for (size_t i = 0; i < count; i++) {
        d[i] = (uint8_t)val;
    }
    return dest;
}

void* memcpy(void* dest, const void* src, size_t count) {
    uint8_t* d = (uint8_t*)dest;
    const uint8_t* s = (const uint8_t*)src;
    for (size_t i = 0; i < count; i++) {
        d[i] = s[i];
    }
    return dest;
}

size_t strlen(const char* str) {
    size_t len = 0;
    while (str[len]) {
        len++;
    }
    return len;
}

int strcmp(const char* a, const char* b) {
    while (*a && (*a == *b)) {
        a++;
        b++;
    }
    return (int)(unsigned char)(*a) - (int)(unsigned char)(*b);
}

uint64_t llpl_strlen(char* s) {
    return (uint64_t)strlen(s);
}

int64_t llpl_strcmp(char* a, char* b) {
    return (int64_t)strcmp(a, b);
}

char* llpl_alloc(uint64_t size) {
    return (char*)rc_alloc((size_t)size);
}

void llpl_free(char* ptr) {
    rc_free((void*)ptr);
}

void llpl_memcpy(char* dest, char* src, uint64_t count) {
    memcpy(dest, src, (size_t)count);
}

// Appends one character, tracking how many characters the *unclamped*
// output would need in *pos while only actually writing while there's room.
static void kfmt_putc(char* buf, size_t size, size_t* pos, char c) {
    if (*pos + 1 < size) {
        buf[*pos] = c;
    }
    (*pos)++;
}

static void kfmt_puts(char* buf, size_t size, size_t* pos, const char* s) {
    while (*s) {
        kfmt_putc(buf, size, pos, *s);
        s++;
    }
}

static void kfmt_pad(char* buf, size_t size, size_t* pos, char c, int count) {
    for (int i = 0; i < count; i++) {
        kfmt_putc(buf, size, pos, c);
    }
}

// `width`/`zero_pad` implement printf's minimum-field-width flag, e.g.
// %08x: if the rendered digits are shorter than `width`, left-pad with
// '0' (zero_pad) or ' ' first. `width` <= 0 means no padding.
static void kfmt_putuint(char* buf, size_t size, size_t* pos, uint64_t value, int base, int uppercase,
                          int width, int zero_pad) {
    static const char lower[] = "0123456789abcdef";
    static const char upper[] = "0123456789ABCDEF";
    const char* digits = uppercase ? upper : lower;
    char tmp[32];
    int n = 0;

    if (value == 0) {
        tmp[n++] = '0';
    } else {
        while (value > 0) {
            tmp[n++] = digits[value % (uint64_t)base];
            value /= (uint64_t)base;
        }
    }

    if (n < width) {
        kfmt_pad(buf, size, pos, zero_pad ? '0' : ' ', width - n);
    }
    while (n > 0) {
        kfmt_putc(buf, size, pos, tmp[--n]);
    }
}

static void kfmt_putint(char* buf, size_t size, size_t* pos, int64_t value, int width, int zero_pad) {
    // Negate via uint64_t so INT64_MIN doesn't overflow.
    uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;

    if (value < 0 && zero_pad) {
        // "-0000005", not "000000-5": the sign comes first, then the
        // magnitude is padded into whatever width is left.
        kfmt_putc(buf, size, pos, '-');
        kfmt_putuint(buf, size, pos, magnitude, 10, 0, width > 0 ? width - 1 : 0, 1);
        return;
    }

    if (value < 0 && width > 0) {
        // Space-padded: the sign is part of the field, so measure the
        // whole "-NNN" before deciding how much padding it needs.
        char tmp[32];
        int n = 0;
        uint64_t v = magnitude;
        if (v == 0) {
            tmp[n++] = '0';
        } else {
            while (v > 0) {
                tmp[n++] = (char)('0' + (v % 10));
                v /= 10;
            }
        }
        int total = n + 1; // + the '-'
        if (total < width) {
            kfmt_pad(buf, size, pos, ' ', width - total);
        }
        kfmt_putc(buf, size, pos, '-');
        while (n > 0) {
            kfmt_putc(buf, size, pos, tmp[--n]);
        }
        return;
    }

    if (value < 0) {
        kfmt_putc(buf, size, pos, '-');
        kfmt_putuint(buf, size, pos, magnitude, 10, 0, 0, 0);
        return;
    }

    kfmt_putuint(buf, size, pos, (uint64_t)value, 10, 0, width, zero_pad);
}

int64_t kvsnprintf(char* buf, uint64_t size, char* fmt, va_list args) {
    size_t pos = 0;

    while (*fmt) {
        if (*fmt != '%') {
            kfmt_putc(buf, size, &pos, *fmt);
            fmt++;
            continue;
        }

        fmt++; // skip '%'
        if (*fmt == '\0') {
            break; // trailing '%' at end of the format string
        }

        // Optional minimum-field-width prefix, e.g. %08x or %4d: a leading
        // '0' selects zero-padding (vs the default space-padding), followed
        // by decimal digits giving the width. Feeds LLPL's string
        // interpolation width/zero-pad hints (`\(n:016:hex)`); see
        // CodeGenerator.interpFormatSpecifier.
        int zero_pad = 0;
        int width = 0;
        if (*fmt == '0') {
            zero_pad = 1;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        switch (*fmt) {
            case 'd':
            case 'i':
                kfmt_putint(buf, size, &pos, va_arg(args, int64_t), width, zero_pad);
                break;
            case 'u':
                kfmt_putuint(buf, size, &pos, va_arg(args, uint64_t), 10, 0, width, zero_pad);
                break;
            case 'x':
                kfmt_putuint(buf, size, &pos, va_arg(args, uint64_t), 16, 0, width, zero_pad);
                break;
            case 'X':
                kfmt_putuint(buf, size, &pos, va_arg(args, uint64_t), 16, 1, width, zero_pad);
                break;
            case 'o':
                kfmt_putuint(buf, size, &pos, va_arg(args, uint64_t), 8, 0, width, zero_pad);
                break;
            case 'b':
                kfmt_putuint(buf, size, &pos, va_arg(args, uint64_t), 2, 0, width, zero_pad);
                break;
            case 's': {
                const char* s = va_arg(args, const char*);
                kfmt_puts(buf, size, &pos, s ? s : "(null)");
                break;
            }
            case 'c':
                // Matches every other non-pointer specifier: read a full
                // 8-byte slot (see the call-site promotion in codegen.d)
                // and narrow it here, rather than the C-standard `int`.
                kfmt_putc(buf, size, &pos, (char)va_arg(args, int64_t));
                break;
            case 'p':
                kfmt_puts(buf, size, &pos, "0x");
                kfmt_putuint(buf, size, &pos, (uint64_t)(uintptr_t)va_arg(args, void*), 16, 0, 0, 0);
                break;
            case '%':
                kfmt_putc(buf, size, &pos, '%');
                break;
            default:
                // Unknown specifier: emit literally so mistakes are visible
                // instead of silently eating an argument.
                kfmt_putc(buf, size, &pos, '%');
                kfmt_putc(buf, size, &pos, *fmt);
                break;
        }
        fmt++;
    }

    if (size > 0) {
        buf[pos < size ? pos : size - 1] = '\0';
    }
    return (int64_t)pos;
}

int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int64_t result = kvsnprintf(buf, size, fmt, args);
    va_end(args);
    return result;
}
