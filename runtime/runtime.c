#include "runtime.h"

#if __STDC_HOSTED__
#include <stdio.h>
#include <stdlib.h>
#endif

// Free-list allocator over a static 1MB heap. Supports allocation, freeing,
// and coalescing of adjacent free blocks. Works for both hosted binaries and
// bare-metal targets because it never calls the system malloc.
#define HEAP_SIZE (1024 * 1024)
static uint8_t heap[HEAP_SIZE];

#define ALLOC_FLAG 1
#define ALIGNMENT 8

typedef struct BlockHeader {
    size_t size;              // total block size including header; LSB = allocated flag
    struct BlockHeader* next; // valid only when the block is free
    struct BlockHeader* prev; // valid only when the block is free
} BlockHeader;

static BlockHeader* free_list = NULL;

static size_t block_size(BlockHeader* b) { return b->size & ~ALLOC_FLAG; }
static int block_allocated(BlockHeader* b) { return b->size & ALLOC_FLAG; }
static void mark_allocated(BlockHeader* b) { b->size |= ALLOC_FLAG; }
static void mark_free(BlockHeader* b) { b->size &= ~ALLOC_FLAG; }

static size_t align_up(size_t n) {
    return (n + ALIGNMENT - 1) & ~(ALIGNMENT - 1);
}

static void heap_init(void) {
    if (free_list) return;
    free_list = (BlockHeader*)heap;
    free_list->size = HEAP_SIZE;
    free_list->next = NULL;
    free_list->prev = NULL;
}

static void remove_from_free_list(BlockHeader* b) {
    if (b->prev) b->prev->next = b->next;
    else free_list = b->next;
    if (b->next) b->next->prev = b->prev;
    b->next = NULL;
    b->prev = NULL;
}

static void insert_into_free_list(BlockHeader* b) {
    b->next = free_list;
    b->prev = NULL;
    if (free_list) free_list->prev = b;
    free_list = b;
}

static BlockHeader* header_from_ptr(void* ptr) {
    return (BlockHeader*)((uint8_t*)ptr - sizeof(BlockHeader));
}

void* rc_alloc(size_t size) {
    heap_init();

    if (size == 0) size = ALIGNMENT;
    size = align_up(size);

    size_t total_size = size + sizeof(BlockHeader);
    size_t min_block = sizeof(BlockHeader) + 2 * sizeof(BlockHeader*);
    if (total_size < min_block) total_size = min_block;
    total_size = align_up(total_size);

    BlockHeader* best = NULL;
    for (BlockHeader* cur = free_list; cur; cur = cur->next) {
        if (block_size(cur) >= total_size) {
            best = cur;
            break; // first fit
        }
    }
    if (!best) return NULL; // Out of memory

    remove_from_free_list(best);

    size_t best_size = block_size(best);
    if (best_size >= total_size + min_block) {
        BlockHeader* remainder = (BlockHeader*)((uint8_t*)best + total_size);
        remainder->size = best_size - total_size;
        insert_into_free_list(remainder);
        best->size = total_size;
    }

    mark_allocated(best);
    return (uint8_t*)best + sizeof(BlockHeader);
}

void rc_free(void* ptr) {
    if (!ptr) return;

    BlockHeader* b = header_from_ptr(ptr);
    if (!block_allocated(b)) return; // double-free guard

    mark_free(b);
    insert_into_free_list(b);

    // Coalesce with next block if it is free and adjacent.
    BlockHeader* next = (BlockHeader*)((uint8_t*)b + block_size(b));
    if ((uint8_t*)next < heap + HEAP_SIZE && !block_allocated(next)) {
        remove_from_free_list(next);
        b->size += block_size(next);
    }

    // Coalesce with previous free block if adjacent.
    if ((uint8_t*)b > heap) {
        for (BlockHeader* cur = free_list; cur; cur = cur->next) {
            if ((uint8_t*)cur + block_size(cur) == (uint8_t*)b) {
                remove_from_free_list(b);
                cur->size += block_size(b);
                break;
            }
        }
    }
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

// Panic support. On hosted targets the default prints to stderr and aborts.
// On freestanding targets the default weak hooks do nothing / loop forever,
// allowing a kernel/port to override llpl_panic_putc/llpl_panic_halt with its
// own serial-output and halt routines.
__attribute__((weak)) void llpl_panic_putc(char c) {
    (void)c;
}

__attribute__((weak)) void llpl_panic_halt(void) {
    while (1) { }
}

static void (*llpl_panic_handler)(char*) = NULL;

void llpl_set_panic_handler(void (*handler)(char*)) {
    llpl_panic_handler = handler;
}

void llpl_panic(char* msg) {
    if (llpl_panic_handler) {
        llpl_panic_handler(msg);
    }

    char buf[512];
    ksnprintf(buf, sizeof(buf), "PANIC: %s\n", msg);

#if __STDC_HOSTED__
    fputs(buf, stderr);
    abort();
#else
    for (char* p = buf; *p; p++) {
        llpl_panic_putc(*p);
    }
    llpl_panic_halt();
#endif
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
