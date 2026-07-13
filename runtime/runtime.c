#include "runtime.h"

#if __STDC_HOSTED__
#include <stdio.h>
#include <stdlib.h>
#endif

#define LLPL_EH_MAX_ERROR_SIZE 256

static __LLPL_EH_Frame* llpl_eh_top = NULL;
static char* llpl_eh_pending_type = NULL;
static uint64_t llpl_eh_pending_size = 0;
static uint8_t llpl_eh_pending_error[LLPL_EH_MAX_ERROR_SIZE];

#if defined(__x86_64__)
__asm__(
".global llpl_eh_setjmp\n"
"llpl_eh_setjmp:\n"
"    movq %rbx, 0(%rdi)\n"
"    movq %rbp, 8(%rdi)\n"
"    movq %r12, 16(%rdi)\n"
"    movq %r13, 24(%rdi)\n"
"    movq %r14, 32(%rdi)\n"
"    movq %r15, 40(%rdi)\n"
"    leaq 8(%rsp), %rax\n"
"    movq %rax, 48(%rdi)\n"
"    movq (%rsp), %rax\n"
"    movq %rax, 56(%rdi)\n"
"    xorl %eax, %eax\n"
"    ret\n"
".global llpl_eh_longjmp\n"
"llpl_eh_longjmp:\n"
"    movq 0(%rdi), %rbx\n"
"    movq 8(%rdi), %rbp\n"
"    movq 16(%rdi), %r12\n"
"    movq 24(%rdi), %r13\n"
"    movq 32(%rdi), %r14\n"
"    movq 40(%rdi), %r15\n"
"    movq 48(%rdi), %rsp\n"
"    movq 56(%rdi), %rdx\n"
"    movl %esi, %eax\n"
"    testl %eax, %eax\n"
"    jne 1f\n"
"    movl $1, %eax\n"
"1:\n"
"    jmp *%rdx\n"
);
#else
int llpl_eh_setjmp(__LLPL_EH_JumpBuf* env) {
    (void)env;
    llpl_panic("llpl_eh_setjmp is only implemented for x86_64");
    return 0;
}

void llpl_eh_longjmp(__LLPL_EH_JumpBuf* env, int value) {
    (void)env;
    (void)value;
    llpl_panic("llpl_eh_longjmp is only implemented for x86_64");
}
#endif

void llpl_eh_push(__LLPL_EH_Frame* frame) {
    frame->prev = llpl_eh_top;
    llpl_eh_top = frame;
}

void llpl_eh_pop(__LLPL_EH_Frame* frame) {
    if (llpl_eh_top == frame) {
        llpl_eh_top = frame->prev;
    }
}

static void llpl_eh_deliver_pending(void) {
    __LLPL_EH_Frame* frame = llpl_eh_top;
    while (frame) {
        llpl_eh_top = frame->prev;
        if (frame->kind == LLPL_EH_FRAME_CLEANUP) {
            llpl_eh_longjmp(&frame->env, 1);
        }
        if (frame->kind == LLPL_EH_FRAME_CATCH &&
                strcmp(frame->type_id, llpl_eh_pending_type) == 0) {
            uint64_t copy_size = llpl_eh_pending_size;
            if (copy_size > frame->error_size) {
                copy_size = frame->error_size;
            }
            memcpy(frame->error_slot, llpl_eh_pending_error, (size_t)copy_size);
            llpl_eh_longjmp(&frame->env, 1);
        }
        frame = llpl_eh_top;
    }
    llpl_panic("uncaught LLPL exception");
}

void llpl_eh_throw(char* type_id, void* error, uint64_t error_size) {
    if (error_size > LLPL_EH_MAX_ERROR_SIZE) {
        llpl_panic("LLPL exception payload too large");
    }
    llpl_eh_pending_type = type_id;
    llpl_eh_pending_size = error_size;
    memcpy(llpl_eh_pending_error, error, (size_t)error_size);
    llpl_eh_deliver_pending();
}

void llpl_eh_resume(void) {
    llpl_eh_deliver_pending();
}

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
    rc->weak_count = 0;
}

void rc_retain(char* ptr) {
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
        // Only the memory backing a still-outstanding Weak<T> is kept
        // around past this point (so it can safely observe "count == 0"
        // instead of reading freed/reused memory) - the value itself is
        // already gone, same as before weak references existed.
        if (rc->weak_count == 0) {
            rc_free(ptr);
        }
    }
}

void rc_weak_retain(char* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    rc->weak_count++;
}

void rc_weak_release(char* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    rc->weak_count--;
    if (rc->weak_count == 0 && rc->count == 0) {
        rc_free((void*)ptr);
    }
}

int rc_is_alive(char* ptr) {
    if (!ptr) return 0;
    RefCount* rc = (RefCount*)ptr;
    return rc->count > 0;
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

static uint32_t llpl_utf8_decode_one(const unsigned char* s, size_t remaining, size_t* width, int* valid) {
    unsigned char b0 = s[0];
    *valid = 1;

    if (b0 < 0x80) {
        *width = 1;
        return b0;
    }

    if (b0 >= 0xC2 && b0 <= 0xDF) {
        if (remaining < 2 || (s[1] & 0xC0) != 0x80) goto invalid;
        *width = 2;
        return ((uint32_t)(b0 & 0x1F) << 6) | (uint32_t)(s[1] & 0x3F);
    }

    if (b0 >= 0xE0 && b0 <= 0xEF) {
        if (remaining < 3 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80) goto invalid;
        if (b0 == 0xE0 && s[1] < 0xA0) goto invalid; // overlong
        if (b0 == 0xED && s[1] >= 0xA0) goto invalid; // surrogate
        *width = 3;
        return ((uint32_t)(b0 & 0x0F) << 12) |
               ((uint32_t)(s[1] & 0x3F) << 6) |
               (uint32_t)(s[2] & 0x3F);
    }

    if (b0 >= 0xF0 && b0 <= 0xF4) {
        if (remaining < 4 || (s[1] & 0xC0) != 0x80 ||
                (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80) goto invalid;
        if (b0 == 0xF0 && s[1] < 0x90) goto invalid; // overlong
        if (b0 == 0xF4 && s[1] > 0x8F) goto invalid; // > U+10FFFF
        *width = 4;
        return ((uint32_t)(b0 & 0x07) << 18) |
               ((uint32_t)(s[1] & 0x3F) << 12) |
               ((uint32_t)(s[2] & 0x3F) << 6) |
               (uint32_t)(s[3] & 0x3F);
    }

invalid:
    *valid = 0;
    *width = 1;
    return 0xFFFD;
}

int llpl_utf8_valid(char* s) {
    if (!s) return 0;
    const unsigned char* p = (const unsigned char*)s;
    size_t remaining = strlen(s);
    while (remaining > 0) {
        size_t width = 0;
        int valid = 0;
        llpl_utf8_decode_one(p, remaining, &width, &valid);
        if (!valid) return 0;
        p += width;
        remaining -= width;
    }
    return 1;
}

uint64_t llpl_utf8_len(char* s) {
    if (!s) return 0;
    const unsigned char* p = (const unsigned char*)s;
    size_t remaining = strlen(s);
    uint64_t count = 0;
    while (remaining > 0) {
        size_t width = 0;
        int valid = 0;
        llpl_utf8_decode_one(p, remaining, &width, &valid);
        p += width;
        remaining -= width;
        count++;
    }
    return count;
}

uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index) {
    if (!s) return 0;
    const unsigned char* start = (const unsigned char*)s;
    const unsigned char* p = start;
    size_t remaining = strlen(s);
    uint64_t count = 0;
    while (remaining > 0 && count < char_index) {
        size_t width = 0;
        int valid = 0;
        llpl_utf8_decode_one(p, remaining, &width, &valid);
        p += width;
        remaining -= width;
        count++;
    }
    return (uint64_t)(p - start);
}

uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset) {
    if (!s) return 0;
    const unsigned char* p = (const unsigned char*)s;
    size_t remaining = strlen(s);
    uint64_t chars = 0;
    uint64_t offset = 0;
    while (remaining > 0 && offset < byte_offset) {
        size_t width = 0;
        int valid = 0;
        llpl_utf8_decode_one(p, remaining, &width, &valid);
        if (offset + width > byte_offset) break;
        p += width;
        remaining -= width;
        offset += (uint64_t)width;
        chars++;
    }
    return chars;
}

uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index) {
    if (!s) return 0;
    const unsigned char* p = (const unsigned char*)s;
    size_t remaining = strlen(s);
    uint64_t count = 0;
    while (remaining > 0) {
        size_t width = 0;
        int valid = 0;
        uint32_t cp = llpl_utf8_decode_one(p, remaining, &width, &valid);
        if (count == char_index) return (uint64_t)cp;
        p += width;
        remaining -= width;
        count++;
    }
    return 0;
}

static const char* llpl_regex_find_group_end(const char* p, const char* end) {
    int depth = 1;
    int in_class = 0;
    int escaped = 0;
    while (p < end) {
        char c = *p;
        if (escaped) {
            escaped = 0;
        } else if (c == '\\') {
            escaped = 1;
        } else if (c == '[') {
            in_class = 1;
        } else if (c == ']' && in_class) {
            in_class = 0;
        } else if (!in_class && c == '(') {
            depth++;
        } else if (!in_class && c == ')') {
            depth--;
            if (depth == 0) return p;
        }
        p++;
    }
    return end;
}

static const char* llpl_regex_find_class_end(const char* p, const char* end) {
    int escaped = 0;
    while (p < end) {
        char c = *p;
        if (escaped) {
            escaped = 0;
        } else if (c == '\\') {
            escaped = 1;
        } else if (c == ']') {
            return p;
        }
        p++;
    }
    return end;
}

typedef struct {
    const char* pattern_base;
    const char* text_base;
    int64_t* starts;
    int64_t* ends;
    uint64_t max_groups;
} LLPL_RegexCtx;

static int llpl_regex_match_expr(LLPL_RegexCtx* ctx, const char* p, const char* end, const char* text, const char** out);

static void llpl_regex_caps_save(LLPL_RegexCtx* ctx, int64_t* starts, int64_t* ends) {
    for (uint64_t i = 0; i < ctx->max_groups; i++) {
        starts[i] = ctx->starts[i];
        ends[i] = ctx->ends[i];
    }
}

static void llpl_regex_caps_restore(LLPL_RegexCtx* ctx, int64_t* starts, int64_t* ends) {
    for (uint64_t i = 0; i < ctx->max_groups; i++) {
        ctx->starts[i] = starts[i];
        ctx->ends[i] = ends[i];
    }
}

static uint64_t llpl_regex_group_number(const char* pattern_base, const char* group_start) {
    uint64_t n = 0;
    int in_class = 0;
    int escaped = 0;
    for (const char* p = pattern_base; p <= group_start; p++) {
        char c = *p;
        if (escaped) {
            escaped = 0;
        } else if (c == '\\') {
            escaped = 1;
        } else if (c == '[') {
            in_class = 1;
        } else if (c == ']' && in_class) {
            in_class = 0;
        } else if (!in_class && c == '(') {
            n++;
        }
    }
    return n;
}

static int llpl_regex_escape_matches(char esc, char c) {
    unsigned char uc = (unsigned char)c;
    switch (esc) {
        case 'd': return uc >= '0' && uc <= '9';
        case 'w': return (uc >= 'a' && uc <= 'z') || (uc >= 'A' && uc <= 'Z') ||
                         (uc >= '0' && uc <= '9') || uc == '_';
        case 's': return c == ' ' || c == '\t' || c == '\n' || c == '\r';
        case 'n': return c == '\n';
        case 't': return c == '\t';
        case 'r': return c == '\r';
        default: return c == esc;
    }
}

static int llpl_regex_class_matches(const char* p, const char* end, char c) {
    int negate = 0;
    if (p < end && *p == '^') {
        negate = 1;
        p++;
    }

    int matched = 0;
    while (p < end) {
        char first;
        if (*p == '\\' && p + 1 < end) {
            if (llpl_regex_escape_matches(*(p + 1), c)) matched = 1;
            first = *(p + 1);
            p += 2;
        } else {
            first = *p;
            p++;
        }

        if (p + 1 < end && *p == '-') {
            char last;
            p++;
            if (*p == '\\' && p + 1 < end) {
                last = *(p + 1);
                p += 2;
            } else {
                last = *p;
                p++;
            }
            if ((unsigned char)c >= (unsigned char)first &&
                    (unsigned char)c <= (unsigned char)last) {
                matched = 1;
            }
        } else if (c == first) {
            matched = 1;
        }
    }
    return negate ? !matched : matched;
}

static const char* llpl_regex_atom_end(const char* p, const char* end) {
    if (p >= end) return p;
    if (*p == '\\') return p + ((p + 1 < end) ? 2 : 1);
    if (*p == '[') {
        const char* close = llpl_regex_find_class_end(p + 1, end);
        return close < end ? close + 1 : end;
    }
    if (*p == '(') {
        const char* close = llpl_regex_find_group_end(p + 1, end);
        return close < end ? close + 1 : end;
    }
    return p + 1;
}

static int llpl_regex_match_atom(LLPL_RegexCtx* ctx, const char* p, const char* atom_end, const char* text, const char** out) {
    if (*p == '.') {
        if (!*text) return 0;
        *out = text + 1;
        return 1;
    }
    if (*p == '\\') {
        if (!*text) return 0;
        if (p + 1 >= atom_end) return 0;
        if (!llpl_regex_escape_matches(*(p + 1), *text)) return 0;
        *out = text + 1;
        return 1;
    }
    if (*p == '[') {
        if (!*text) return 0;
        const char* close = atom_end - 1;
        if (close <= p || *close != ']') return 0;
        if (!llpl_regex_class_matches(p + 1, close, *text)) return 0;
        *out = text + 1;
        return 1;
    }
    if (*p == '(') {
        const char* close = atom_end - 1;
        if (close <= p || *close != ')') return 0;
        uint64_t group = llpl_regex_group_number(ctx->pattern_base, p);
        int64_t* saved_starts = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
        int64_t* saved_ends = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
        if (!saved_starts || !saved_ends) return 0;
        llpl_regex_caps_save(ctx, saved_starts, saved_ends);
        const char* next_text = NULL;
        int matched = llpl_regex_match_expr(ctx, p + 1, close, text, &next_text);
        if (matched) {
            if (group < ctx->max_groups) {
                ctx->starts[group] = (int64_t)(text - ctx->text_base);
                ctx->ends[group] = (int64_t)(next_text - ctx->text_base);
            }
            *out = next_text;
        } else {
            llpl_regex_caps_restore(ctx, saved_starts, saved_ends);
        }
        rc_free((void*)saved_starts);
        rc_free((void*)saved_ends);
        return matched;
    }

    if (!*text) return 0;
    if (*p != *text) return 0;
    *out = text + 1;
    return 1;
}

static int llpl_regex_match_sequence(LLPL_RegexCtx* ctx, const char* p, const char* end, const char* text, const char** out) {
    if (p >= end) {
        *out = text;
        return 1;
    }

    const char* atom_end = llpl_regex_atom_end(p, end);
    char quant = 0;
    if (atom_end < end && (*atom_end == '*' || *atom_end == '+' || *atom_end == '?')) {
        quant = *atom_end;
    }
    const char* rest = atom_end + (quant ? 1 : 0);

    if (!quant) {
        const char* next_text = NULL;
        if (!llpl_regex_match_atom(ctx, p, atom_end, text, &next_text)) return 0;
        return llpl_regex_match_sequence(ctx, rest, end, next_text, out);
    }

    if (quant == '?') {
        int64_t* saved_starts = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
        int64_t* saved_ends = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
        if (!saved_starts || !saved_ends) return 0;
        llpl_regex_caps_save(ctx, saved_starts, saved_ends);
        const char* next_text = NULL;
        if (llpl_regex_match_atom(ctx, p, atom_end, text, &next_text) &&
                llpl_regex_match_sequence(ctx, rest, end, next_text, out)) {
            rc_free((void*)saved_starts);
            rc_free((void*)saved_ends);
            return 1;
        }
        llpl_regex_caps_restore(ctx, saved_starts, saved_ends);
        int matched = llpl_regex_match_sequence(ctx, rest, end, text, out);
        rc_free((void*)saved_starts);
        rc_free((void*)saved_ends);
        return matched;
    }

    size_t text_len = strlen(text);
    const char** positions = (const char**)rc_alloc((text_len + 2) * sizeof(const char*));
    int64_t* start_snaps = (int64_t*)rc_alloc((text_len + 2) * ctx->max_groups * sizeof(int64_t));
    int64_t* end_snaps = (int64_t*)rc_alloc((text_len + 2) * ctx->max_groups * sizeof(int64_t));
    if (!positions || !start_snaps || !end_snaps) return 0;

    size_t count = 0;
    positions[count++] = text;
    llpl_regex_caps_save(ctx, &start_snaps[0], &end_snaps[0]);
    const char* cur = text;
    while (*cur) {
        const char* next_text = NULL;
        if (!llpl_regex_match_atom(ctx, p, atom_end, cur, &next_text)) break;
        if (next_text == cur) break;
        positions[count++] = next_text;
        llpl_regex_caps_save(ctx, &start_snaps[(count - 1) * ctx->max_groups],
            &end_snaps[(count - 1) * ctx->max_groups]);
        cur = next_text;
    }

    size_t min_count = quant == '+' ? 1 : 0;
    int matched = 0;
    for (size_t i = count; i-- > min_count;) {
        llpl_regex_caps_restore(ctx, &start_snaps[i * ctx->max_groups], &end_snaps[i * ctx->max_groups]);
        if (llpl_regex_match_sequence(ctx, rest, end, positions[i], out)) {
            matched = 1;
            break;
        }
    }
    rc_free((void*)positions);
    rc_free((void*)start_snaps);
    rc_free((void*)end_snaps);
    return matched;
}

static int llpl_regex_match_expr(LLPL_RegexCtx* ctx, const char* p, const char* end, const char* text, const char** out) {
    const char* alt_start = p;
    int depth = 0;
    int in_class = 0;
    int escaped = 0;

    for (const char* cur = p; cur <= end; cur++) {
        char c = cur < end ? *cur : '|';
        if (escaped) {
            escaped = 0;
        } else if (cur < end && c == '\\') {
            escaped = 1;
        } else if (cur < end && c == '[') {
            in_class = 1;
        } else if (cur < end && c == ']' && in_class) {
            in_class = 0;
        } else if (!in_class && cur < end && c == '(') {
            depth++;
        } else if (!in_class && cur < end && c == ')' && depth > 0) {
            depth--;
        } else if (!in_class && depth == 0 && c == '|') {
            int64_t* saved_starts = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
            int64_t* saved_ends = (int64_t*)rc_alloc(ctx->max_groups * sizeof(int64_t));
            if (!saved_starts || !saved_ends) return 0;
            llpl_regex_caps_save(ctx, saved_starts, saved_ends);
            if (llpl_regex_match_sequence(ctx, alt_start, cur, text, out)) {
                rc_free((void*)saved_starts);
                rc_free((void*)saved_ends);
                return 1;
            }
            llpl_regex_caps_restore(ctx, saved_starts, saved_ends);
            rc_free((void*)saved_starts);
            rc_free((void*)saved_ends);
            alt_start = cur + 1;
        }
    }
    return 0;
}

uint64_t llpl_regex_group_count(char* pattern) {
    if (!pattern) return 0;
    uint64_t n = 0;
    int in_class = 0;
    int escaped = 0;
    for (char* p = pattern; *p; p++) {
        char c = *p;
        if (escaped) {
            escaped = 0;
        } else if (c == '\\') {
            escaped = 1;
        } else if (c == '[') {
            in_class = 1;
        } else if (c == ']' && in_class) {
            in_class = 0;
        } else if (!in_class && c == '(') {
            n++;
        }
    }
    return n;
}

static int llpl_regex_match_internal(char* pattern, char* text, int64_t* starts, int64_t* ends, uint64_t max_groups) {
    if (!pattern || !text) return 0;
    if (max_groups == 0) return 0;
    for (uint64_t i = 0; i < max_groups; i++) {
        starts[i] = -1;
        ends[i] = -1;
    }

    const char* p = pattern;
    const char* end = pattern + strlen(pattern);
    LLPL_RegexCtx ctx;
    ctx.pattern_base = pattern;
    ctx.text_base = text;
    ctx.starts = starts;
    ctx.ends = ends;
    ctx.max_groups = max_groups;

    if (p < end && *p == '^') {
        const char* out = NULL;
        p++;
        if (end > p && *(end - 1) == '$') end--;
        if (!llpl_regex_match_expr(&ctx, p, end, text, &out)) return 0;
        if (*(pattern + strlen(pattern) - 1) == '$' && *out != '\0') return 0;
        starts[0] = 0;
        ends[0] = (int64_t)(out - text);
        return 1;
    }

    int anchored_end = end > p && *(end - 1) == '$';
    if (anchored_end) end--;

    for (const char* start = text;; start++) {
        const char* out = NULL;
        if (llpl_regex_match_expr(&ctx, p, end, start, &out)) {
            if (!anchored_end || *out == '\0') {
                starts[0] = (int64_t)(start - text);
                ends[0] = (int64_t)(out - text);
                return 1;
            }
        }
        if (*start == '\0') break;
    }
    return 0;
}

int llpl_regex_match(char* pattern, char* text) {
    uint64_t groups = llpl_regex_group_count(pattern) + 1;
    int64_t* starts = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    int64_t* ends = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    if (!starts || !ends) return 0;
    int matched = llpl_regex_match_internal(pattern, text, starts, ends, groups);
    rc_free((void*)starts);
    rc_free((void*)ends);
    return matched;
}

int llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end) {
    uint64_t groups = llpl_regex_group_count(pattern) + 1;
    if (group >= groups) {
        if (start) *start = -1;
        if (end) *end = -1;
        return 0;
    }
    int64_t* starts = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    int64_t* ends = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    if (!starts || !ends) return 0;
    int matched = llpl_regex_match_internal(pattern, text, starts, ends, groups);
    if (matched && starts[group] >= 0) {
        if (start) *start = starts[group];
        if (end) *end = ends[group];
    } else {
        if (start) *start = -1;
        if (end) *end = -1;
        matched = 0;
    }
    rc_free((void*)starts);
    rc_free((void*)ends);
    return matched;
}

char* llpl_regex_capture(char* pattern, char* text, uint64_t group) {
    int64_t start = -1;
    int64_t end = -1;
    if (!llpl_regex_capture_bounds(pattern, text, group, &start, &end) || end < start) {
        char* empty = (char*)rc_alloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    uint64_t len = (uint64_t)(end - start);
    char* out = (char*)rc_alloc((size_t)len + 1);
    if (!out) return NULL;
    memcpy(out, text + start, (size_t)len);
    out[len] = '\0';
    return out;
}

__attribute__((weak)) LLPL_TypeInfo __llpl_reflect_types[1] = {{0}};
__attribute__((weak)) uint64_t __llpl_reflect_type_count = 0;

char* llpl_reflect_type(char* name) {
    if (!name) return NULL;
    for (uint64_t i = 0; i < __llpl_reflect_type_count; i++) {
        if (strcmp(__llpl_reflect_types[i].name, name) == 0) {
            return (char*)&__llpl_reflect_types[i];
        }
    }
    return NULL;
}

char* llpl_reflect_type_name(char* type) {
    LLPL_TypeInfo* t = (LLPL_TypeInfo*)type;
    return t ? t->name : "";
}

char* llpl_reflect_type_kind(char* type) {
    LLPL_TypeInfo* t = (LLPL_TypeInfo*)type;
    return t ? t->kind : "";
}

uint64_t llpl_reflect_type_size(char* type) {
    LLPL_TypeInfo* t = (LLPL_TypeInfo*)type;
    return t ? t->size : 0;
}

uint64_t llpl_reflect_field_count(char* type) {
    LLPL_TypeInfo* t = (LLPL_TypeInfo*)type;
    return t ? t->field_count : 0;
}

char* llpl_reflect_field(char* type, uint64_t index) {
    LLPL_TypeInfo* t = (LLPL_TypeInfo*)type;
    if (!t || index >= t->field_count) return NULL;
    return (char*)&t->fields[index];
}

char* llpl_reflect_field_name(char* field) {
    LLPL_FieldInfo* f = (LLPL_FieldInfo*)field;
    return f ? f->name : "";
}

char* llpl_reflect_field_type_name(char* field) {
    LLPL_FieldInfo* f = (LLPL_FieldInfo*)field;
    return f ? f->type_name : "";
}

uint64_t llpl_reflect_field_offset(char* field) {
    LLPL_FieldInfo* f = (LLPL_FieldInfo*)field;
    return f ? f->offset : 0;
}

uint64_t llpl_reflect_field_size(char* field) {
    LLPL_FieldInfo* f = (LLPL_FieldInfo*)field;
    return f ? f->size : 0;
}

char* llpl_alloc(uint64_t size) {
    return (char*)rc_alloc((size_t)size);
}

void llpl_free(char* ptr) {
    rc_free((void*)ptr);
}

// Weak defaults, overridden by the compiler-generated definition in the
// actual program whenever it has at least one eligible declaration (see
// codegen.d's generateBacktraceSymbolTable) - mirrors __llpl_reflect_types'
// identical weak-default trick above, so a program with nothing to put in
// the table still links.
__attribute__((weak)) LLPL_Symbol llpl_symbol_table[1] = {{0}};
__attribute__((weak)) uint64_t llpl_symbol_table_count = 0;

char* llpl_resolve_symbol(uint64_t addr) {
    LLPL_Symbol* best = NULL;
    for (uint64_t i = 0; i < llpl_symbol_table_count; i++) {
        uint64_t candidate = (uint64_t)(uintptr_t)llpl_symbol_table[i].addr;
        if (candidate <= addr && (!best || candidate > (uint64_t)(uintptr_t)best->addr)) {
            best = &llpl_symbol_table[i];
        }
    }
    return (char*)best;
}

char* llpl_symbol_name(char* symbol) {
    LLPL_Symbol* s = (LLPL_Symbol*)symbol;
    return s ? s->name : "";
}

char* llpl_symbol_file(char* symbol) {
    LLPL_Symbol* s = (LLPL_Symbol*)symbol;
    return s ? s->file : "";
}

int64_t llpl_symbol_line(char* symbol) {
    LLPL_Symbol* s = (LLPL_Symbol*)symbol;
    return s ? s->line : 0;
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
