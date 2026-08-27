#include "runtime.h"

#if __STDC_HOSTED__
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#endif

#define LLPL_EH_MAX_ERROR_SIZE 256

static __LLPL_EH_Frame* llpl_eh_top = NULL;
static char* llpl_eh_pending_type = NULL;
static uint64_t llpl_eh_pending_size = 0;
static uint8_t llpl_eh_pending_error[LLPL_EH_MAX_ERROR_SIZE];
static char* llpl_eh_pending_file = NULL;
static int64_t llpl_eh_pending_line = 0;

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
    if (llpl_eh_pending_file) {
        char buf[256];
        ksnprintf(buf, sizeof(buf), "uncaught LLPL exception thrown at %s:%d",
            llpl_eh_pending_file, (long long)llpl_eh_pending_line);
        llpl_panic(buf);
    }
    llpl_panic("uncaught LLPL exception");
}

void llpl_eh_throw(char* type_id, void* error, uint64_t error_size, char* file, int64_t line) {
    if (error_size > LLPL_EH_MAX_ERROR_SIZE) {
        llpl_panic("LLPL exception payload too large");
    }
    llpl_eh_pending_type = type_id;
    llpl_eh_pending_size = error_size;
    llpl_eh_pending_file = file;
    llpl_eh_pending_line = line;
    memcpy(llpl_eh_pending_error, error, (size_t)error_size);
    llpl_eh_deliver_pending();
}

void llpl_eh_resume(void) {
    llpl_eh_deliver_pending();
}

// Free-list allocator over one or more heap segments. Hosted builds grow by
// requesting additional segments from malloc; freestanding builds keep the
// old static fallback because there is no system allocator to grow from.
#define INITIAL_HEAP_SEGMENT_SIZE (1024 * 1024)

#define ALLOC_FLAG 1
#define ALIGNMENT 8

typedef struct BlockHeader {
    size_t size;              // total block size including header; LSB = allocated flag
    struct BlockHeader* next; // valid only when the block is free
    struct BlockHeader* prev; // valid only when the block is free
} BlockHeader;

typedef struct HeapSegment {
    uint8_t* start;
    size_t size;
    struct HeapSegment* next;
} HeapSegment;

static BlockHeader* free_list = NULL;
static HeapSegment* heap_segments = NULL;
#if !__STDC_HOSTED__
static uint8_t fallback_heap[INITIAL_HEAP_SEGMENT_SIZE];
static HeapSegment fallback_segment = { fallback_heap, INITIAL_HEAP_SEGMENT_SIZE, NULL };
#endif
static __LLPL_Closure llpl_custom_alloc = {0};
static __LLPL_Closure llpl_custom_free = {0};
static LLPL_AllocFn llpl_custom_alloc_raw = NULL;
static LLPL_FreeFn llpl_custom_free_raw = NULL;
static int llpl_irq_depth = 0;

static size_t block_size(BlockHeader* b) { return b->size & ~ALLOC_FLAG; }
static int block_allocated(BlockHeader* b) { return b->size & ALLOC_FLAG; }
static void mark_allocated(BlockHeader* b) { b->size |= ALLOC_FLAG; }
static void mark_free(BlockHeader* b) { b->size &= ~ALLOC_FLAG; }

static size_t align_up(size_t n) {
    return (n + ALIGNMENT - 1) & ~(ALIGNMENT - 1);
}

static void insert_into_free_list(BlockHeader* b);

static uint8_t* align_ptr(uint8_t* p) {
    uintptr_t v = (uintptr_t)p;
    v = (v + ALIGNMENT - 1) & ~(uintptr_t)(ALIGNMENT - 1);
    return (uint8_t*)v;
}

static void add_free_segment(uint8_t* start, size_t size) {
    start = align_ptr(start);
    size = align_up(size);
    if (size <= sizeof(BlockHeader)) return;

    BlockHeader* block = (BlockHeader*)start;
    block->size = size;
    block->next = NULL;
    block->prev = NULL;
    insert_into_free_list(block);
}

static int grow_heap(size_t min_size) {
    size_t segment_size = INITIAL_HEAP_SEGMENT_SIZE;
    if (segment_size < min_size) segment_size = align_up(min_size);

#if __STDC_HOSTED__
    if (segment_size > ((size_t)-1) - sizeof(HeapSegment) - ALIGNMENT) {
        return 0;
    }
    size_t raw_size = sizeof(HeapSegment) + segment_size + ALIGNMENT;
    uint8_t* raw = (uint8_t*)malloc(raw_size);
    if (!raw) return 0;

    HeapSegment* segment = (HeapSegment*)raw;
    segment->start = align_ptr(raw + sizeof(HeapSegment));
    segment->size = segment_size;
    segment->next = heap_segments;
    heap_segments = segment;
    add_free_segment(segment->start, segment->size);
    return 1;
#else
    if (heap_segments) return 0;
    (void)segment_size;
    heap_segments = &fallback_segment;
    add_free_segment(fallback_segment.start, fallback_segment.size);
    return 1;
#endif
}

static void heap_init(void) {
    if (heap_segments) return;
    grow_heap(INITIAL_HEAP_SEGMENT_SIZE);
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

static HeapSegment* segment_for_ptr(void* ptr) {
    uint8_t* p = (uint8_t*)ptr;
    for (HeapSegment* segment = heap_segments; segment; segment = segment->next) {
        if (p >= segment->start && p < segment->start + segment->size) {
            return segment;
        }
    }
    return NULL;
}

// Every path below returns memory zeroed up to the caller's requested
// `size` - fields an LLPL constructor doesn't explicitly touch (an
// embedded struct field like SpinLock, left to whatever the language's
// implicit "unset = zero" convention assumes) must come back zeroed rather
// than holding whatever a previous, freed occupant of this address left
// behind. A free-list allocator recycles freed blocks, so unlike memory
// fresh from the OS/bootloader (typically already zero), a reused block's
// bytes are otherwise still whatever the last owner wrote - including,
// for example, a SpinLock's "locked" byte reading as permanently held.
void* rc_alloc(size_t size) {
    if (llpl_irq_depth > 0) {
        llpl_panic("heap allocation is not IRQ-safe");
    }
    if (llpl_custom_alloc.fn) {
        void* ptr = (void*)((char* (*)(void*, uint64_t))llpl_custom_alloc.fn)(
            llpl_custom_alloc.env, (uint64_t)size);
        if (ptr) memset(ptr, 0, size);
        return ptr;
    }
    if (llpl_custom_alloc_raw) {
        void* ptr = (void*)llpl_custom_alloc_raw((uint64_t)size);
        if (ptr) memset(ptr, 0, size);
        return ptr;
    }

    heap_init();

    size_t requested_size = size;
    if (size == 0) size = ALIGNMENT;
    size = align_up(size);

    size_t total_size = size + sizeof(BlockHeader);
    size_t min_block = sizeof(BlockHeader) + 2 * sizeof(BlockHeader*);
    if (total_size < min_block) total_size = min_block;
    total_size = align_up(total_size);

    BlockHeader* best = NULL;
    for (;;) {
        size_t scanned = 0;
        for (BlockHeader* cur = free_list; cur; cur = cur->next) {
            if (block_size(cur) >= total_size) {
                best = cur;
                break; // first fit
            }
            if (++scanned > 10000) {
                return NULL;
            }
        }
        if (best) break;
        if (!grow_heap(total_size)) return NULL; // Out of memory
    }

    remove_from_free_list(best);

    size_t best_size = block_size(best);
    if (best_size >= total_size + min_block) {
        BlockHeader* remainder = (BlockHeader*)((uint8_t*)best + total_size);
        remainder->size = best_size - total_size;
        insert_into_free_list(remainder);
        best->size = total_size;
    }

    mark_allocated(best);
    void* ptr = (uint8_t*)best + sizeof(BlockHeader);
    memset(ptr, 0, requested_size);
    return ptr;
}

void rc_free(void* ptr) {
    if (!ptr) return;
    if (llpl_custom_free.fn) {
        ((void (*)(void*, char*))llpl_custom_free.fn)(llpl_custom_free.env, (char*)ptr);
        return;
    }
    if (llpl_custom_alloc.fn) {
        return;
    }
    if (llpl_custom_free_raw) {
        llpl_custom_free_raw((char*)ptr);
        return;
    }
    if (llpl_custom_alloc_raw) {
        return;
    }

    BlockHeader* b = header_from_ptr(ptr);
    HeapSegment* segment = segment_for_ptr(b);
    if (!segment) return;
    if (!block_allocated(b)) return; // double-free guard

    mark_free(b);
    insert_into_free_list(b);

    // Coalesce with next block if it is free and adjacent.
    BlockHeader* next = (BlockHeader*)((uint8_t*)b + block_size(b));
    if ((uint8_t*)next < segment->start + segment->size && !block_allocated(next)) {
        remove_from_free_list(next);
        b->size += block_size(next);
    }

    // Coalesce with previous free block if adjacent.
    if ((uint8_t*)b > segment->start) {
        size_t scanned = 0;
        for (BlockHeader* cur = free_list; cur; cur = cur->next) {
            if ((uint8_t*)cur < segment->start ||
                    (uint8_t*)cur >= segment->start + segment->size) {
                if (++scanned > 10000) {
                    return;
                }
                continue;
            }
            if ((uint8_t*)cur + block_size(cur) == (uint8_t*)b) {
                remove_from_free_list(b);
                cur->size += block_size(b);
                break;
            }
            if (++scanned > 10000) {
                return;
            }
        }
    }
}

void llpl_set_allocator(__LLPL_Closure alloc_fn, __LLPL_Closure free_fn) {
    llpl_custom_alloc = alloc_fn;
    llpl_custom_free = free_fn;
    llpl_custom_alloc_raw = NULL;
    llpl_custom_free_raw = NULL;
}

void llpl_set_allocator_raw(LLPL_AllocFn alloc_fn, LLPL_FreeFn free_fn) {
    llpl_custom_alloc.fn = NULL;
    llpl_custom_alloc.env = NULL;
    llpl_custom_free.fn = NULL;
    llpl_custom_free.env = NULL;
    llpl_custom_alloc_raw = alloc_fn;
    llpl_custom_free_raw = free_fn;
}

void llpl_reset_allocator(void) {
    llpl_custom_alloc.fn = NULL;
    llpl_custom_alloc.env = NULL;
    llpl_custom_free.fn = NULL;
    llpl_custom_free.env = NULL;
    llpl_custom_alloc_raw = NULL;
    llpl_custom_free_raw = NULL;
}

void rc_init(RefCount* rc) {
    rc->count = 1;
    rc->weak_count = 0;
}

// count/weak_count are shared, preemptible state: any two threads holding
// a reference to the same object can retain/release it concurrently, and
// a timer IRQ can preempt either side mid-update. Plain ++/-- here is a
// lost-update race - two interleaved releases can under-count and free an
// object that's still referenced elsewhere (or, conversely, never reach
// zero and leak) - invisible under single-threaded/cooperative use, but a
// real, silent corruption source now that preemptive task switching exists
// for every ref-counted object in the language, not just this one type.
void rc_retain(char* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    llpl_atomic_i32_fetch_add((int32_t*)&rc->count, 1);
}

void rc_release(void* ptr, void (*destructor)(void*)) {
    if (!ptr) return;

    RefCount* rc = (RefCount*)ptr;
    int32_t previous = llpl_atomic_i32_fetch_add((int32_t*)&rc->count, -1);

    if (previous == 1) {
        if (destructor) {
            destructor(ptr);
        }
        // Only the memory backing a still-outstanding Weak<T> is kept
        // around past this point (so it can safely observe "count == 0"
        // instead of reading freed/reused memory) - the value itself is
        // already gone, same as before weak references existed.
        if (llpl_atomic_i32_load((int32_t*)&rc->weak_count) == 0) {
            rc_free(ptr);
        }
    }
}

void rc_weak_retain(char* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    llpl_atomic_i32_fetch_add((int32_t*)&rc->weak_count, 1);
}

void rc_weak_release(char* ptr) {
    if (!ptr) return;
    RefCount* rc = (RefCount*)ptr;
    int32_t previous = llpl_atomic_i32_fetch_add((int32_t*)&rc->weak_count, -1);
    if (previous == 1 && llpl_atomic_i32_load((int32_t*)&rc->count) == 0) {
        rc_free((void*)ptr);
    }
}

bool rc_is_alive(char* ptr) {
    if (!ptr) return false;
    RefCount* rc = (RefCount*)ptr;
    return llpl_atomic_i32_load((int32_t*)&rc->count) > 0;
}

int64_t rc_use_count(char* ptr) {
    if (!ptr) return 0;
    RefCount* rc = (RefCount*)ptr;
    return (int64_t)llpl_atomic_i32_load((int32_t*)&rc->count);
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

bool llpl_utf8_valid(char* s) {
    if (!s) return false;
    const unsigned char* p = (const unsigned char*)s;
    size_t remaining = strlen(s);
    while (remaining > 0) {
        size_t width = 0;
        int valid = 0;
        llpl_utf8_decode_one(p, remaining, &width, &valid);
        if (!valid) return false;
        p += width;
        remaining -= width;
    }
    return true;
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

bool llpl_regex_match(char* pattern, char* text) {
    uint64_t groups = llpl_regex_group_count(pattern) + 1;
    int64_t* starts = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    int64_t* ends = (int64_t*)rc_alloc(groups * sizeof(int64_t));
    if (!starts || !ends) return 0;
    int matched = llpl_regex_match_internal(pattern, text, starts, ends, groups);
    rc_free((void*)starts);
    rc_free((void*)ends);
    return matched;
}

bool llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end) {
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
    uint64_t best_addr = 0;
    uint64_t next_addr = 0;

    for (uint64_t i = 0; i < llpl_symbol_table_count; i++) {
        uint64_t candidate = (uint64_t)(uintptr_t)llpl_symbol_table[i].addr;
        if (candidate <= addr && (!best || candidate > best_addr)) {
            best = &llpl_symbol_table[i];
            best_addr = candidate;
        }
        if (candidate > addr && (next_addr == 0 || candidate < next_addr)) {
            next_addr = candidate;
        }
    }
    if (best && next_addr == 0 && addr - best_addr > 4096) {
        return NULL;
    }
    return (char*)best;
}

char* llpl_symbol_name(char* symbol) {
    LLPL_Symbol* s = (LLPL_Symbol*)symbol;
    return s ? s->name : "";
}

char* llpl_symbol_display_name(char* symbol) {
    LLPL_Symbol* s = (LLPL_Symbol*)symbol;
    if (!s) return "";
    return (s->display_name && s->display_name[0]) ? s->display_name : s->name;
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

char* llpl_async_create(uint64_t frame_size, void* poll_fn) {
    if (frame_size == 0 || !poll_fn) return NULL;
    LLPL_AsyncTask* task = (LLPL_AsyncTask*)rc_alloc(sizeof(LLPL_AsyncTask));
    if (!task) return NULL;
    task->frame = rc_alloc((size_t)frame_size);
    if (!task->frame) {
        rc_free(task);
        return NULL;
    }
    task->frame_size = frame_size;
    task->poll = (LLPL_AsyncPollFn)poll_fn;
    task->cancelled = 0;
    return (char*)task;
}

char* llpl_async_frame(char* task) {
    if (!task) return NULL;
    return (char*)((LLPL_AsyncTask*)task)->frame;
}

int64_t llpl_async_poll(char* task, char* out) {
    if (!task) return -1;
    LLPL_AsyncTask* t = (LLPL_AsyncTask*)task;
    if (t->cancelled) return -2;
    if (!t->poll || !t->frame) return -1;
    return (int64_t)t->poll(t->frame, out);
}

int64_t llpl_async_block_on(char* task, char* out) {
    int64_t state = 0;
    do {
        state = llpl_async_poll(task, out);
    } while (state == 0);
    return state;
}

int64_t llpl_async_block_on_timeout(char* task, char* out, uint64_t timeout_ms) {
    uint64_t deadline = llpl_async_now_ms() + timeout_ms;
    int64_t state = 0;
    do {
        state = llpl_async_poll(task, out);
        if (state != 0) return state;
        if (llpl_async_now_ms() >= deadline) return 0;
    } while (1);
}

int64_t llpl_async_cancel(char* task) {
    if (!task) return -1;
    LLPL_AsyncTask* t = (LLPL_AsyncTask*)task;
    t->cancelled = 1;
    return 1;
}

int64_t llpl_async_is_cancelled(char* task) {
    if (!task) return 0;
    return ((LLPL_AsyncTask*)task)->cancelled ? 1 : 0;
}

void llpl_async_destroy(char* task) {
    if (!task) return;
    LLPL_AsyncTask* t = (LLPL_AsyncTask*)task;
    if (t->frame) rc_free(t->frame);
    rc_free(t);
}

static uint64_t llpl_async_clock_ms = 0;
static int llpl_async_manual_clock = 0;

uint64_t llpl_async_now_ms(void) {
    if (llpl_async_manual_clock) {
        return llpl_async_clock_ms;
    }
#if __STDC_HOSTED__ && defined(CLOCK_MONOTONIC)
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return ((uint64_t)ts.tv_sec * 1000ULL) + ((uint64_t)ts.tv_nsec / 1000000ULL);
    }
#endif
    return llpl_async_clock_ms;
}

void llpl_async_set_now_ms(uint64_t now_ms) {
    llpl_async_manual_clock = 1;
    llpl_async_clock_ms = now_ms;
}

uint64_t llpl_async_advance_ms(uint64_t delta_ms) {
    llpl_async_manual_clock = 1;
    llpl_async_clock_ms += delta_ms;
    return llpl_async_clock_ms;
}

void llpl_irq_enter(void) {
    llpl_irq_depth++;
}

void llpl_irq_exit(void) {
    if (llpl_irq_depth > 0) {
        llpl_irq_depth--;
    }
}

int64_t llpl_in_irq(void) {
    return llpl_irq_depth > 0 ? 1 : 0;
}

// One load/store/exchange/fetch_add/compare_exchange family per width
// (8/16/32/64-bit), backed by hand-written x86_64 asm - the same
// instructions gcc/clang/tcc all assemble identically, which matters
// because tcc (the kernel example's toolchain) does not implement
// __atomic_*/__ATOMIC_SEQ_CST at all (verified directly: `tcc -run -` on
// a snippet using __ATOMIC_SEQ_CST fails with "undeclared"). The non-x86_64
// #else branch is unreachable from tcc (tcc only ever targets x86_64 in
// this project) so it's free to use __atomic_* builtins - real gcc/clang,
// unlike the plain read-modify-write this branch used to do, which wasn't
// atomic at all on a non-x86_64 host.

int8_t llpl_atomic_i8_load(int8_t* ptr) {
    __asm__ __volatile__("" ::: "memory");
    int8_t value = *ptr;
    __asm__ __volatile__("" ::: "memory");
    return value;
}

void llpl_atomic_i8_store(int8_t* ptr, int8_t value) {
    __asm__ __volatile__("" ::: "memory");
    *ptr = value;
    __asm__ __volatile__("" ::: "memory");
}

int8_t llpl_atomic_i8_exchange(int8_t* ptr, int8_t value) {
#if defined(__x86_64__)
    __asm__ __volatile__("xchgb %0, %1" : "+r"(value), "+m"(*ptr) : : "memory");
    return value;
#else
    return (int8_t)__atomic_exchange_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

int8_t llpl_atomic_i8_fetch_add(int8_t* ptr, int8_t delta) {
#if defined(__x86_64__)
    __asm__ __volatile__("lock; xaddb %0, %1" : "+r"(delta), "+m"(*ptr) : : "memory");
    return delta;
#else
    return (int8_t)__atomic_fetch_add(ptr, delta, __ATOMIC_SEQ_CST);
#endif
}

int64_t llpl_atomic_i8_compare_exchange(int8_t* ptr, int8_t* expected, int8_t desired) {
#if defined(__x86_64__)
    int8_t old = *expected;
    unsigned char ok;
    __asm__ __volatile__(
        "lock; cmpxchgb %3, %1; sete %0"
        : "=q"(ok), "+m"(*ptr), "+a"(old)
        : "r"(desired)
        : "memory");
    if (!ok) *expected = old;
    return ok ? 1 : 0;
#else
    return __atomic_compare_exchange_n(ptr, expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) ? 1 : 0;
#endif
}

int16_t llpl_atomic_i16_load(int16_t* ptr) {
    __asm__ __volatile__("" ::: "memory");
    int16_t value = *ptr;
    __asm__ __volatile__("" ::: "memory");
    return value;
}

void llpl_atomic_i16_store(int16_t* ptr, int16_t value) {
    __asm__ __volatile__("" ::: "memory");
    *ptr = value;
    __asm__ __volatile__("" ::: "memory");
}

int16_t llpl_atomic_i16_exchange(int16_t* ptr, int16_t value) {
#if defined(__x86_64__)
    __asm__ __volatile__("xchgw %0, %1" : "+r"(value), "+m"(*ptr) : : "memory");
    return value;
#else
    return (int16_t)__atomic_exchange_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

int16_t llpl_atomic_i16_fetch_add(int16_t* ptr, int16_t delta) {
#if defined(__x86_64__)
    __asm__ __volatile__("lock; xaddw %0, %1" : "+r"(delta), "+m"(*ptr) : : "memory");
    return delta;
#else
    return (int16_t)__atomic_fetch_add(ptr, delta, __ATOMIC_SEQ_CST);
#endif
}

int64_t llpl_atomic_i16_compare_exchange(int16_t* ptr, int16_t* expected, int16_t desired) {
#if defined(__x86_64__)
    int16_t old = *expected;
    unsigned char ok;
    __asm__ __volatile__(
        "lock; cmpxchgw %3, %1; sete %0"
        : "=q"(ok), "+m"(*ptr), "+a"(old)
        : "r"(desired)
        : "memory");
    if (!ok) *expected = old;
    return ok ? 1 : 0;
#else
    return __atomic_compare_exchange_n(ptr, expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) ? 1 : 0;
#endif
}

int32_t llpl_atomic_i32_load(int32_t* ptr) {
    __asm__ __volatile__("" ::: "memory");
    int32_t value = *ptr;
    __asm__ __volatile__("" ::: "memory");
    return value;
}

void llpl_atomic_i32_store(int32_t* ptr, int32_t value) {
    __asm__ __volatile__("" ::: "memory");
    *ptr = value;
    __asm__ __volatile__("" ::: "memory");
}

int32_t llpl_atomic_i32_exchange(int32_t* ptr, int32_t value) {
#if defined(__x86_64__)
    __asm__ __volatile__("xchgl %0, %1" : "+r"(value), "+m"(*ptr) : : "memory");
    return value;
#else
    return (int32_t)__atomic_exchange_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

int32_t llpl_atomic_i32_fetch_add(int32_t* ptr, int32_t delta) {
#if defined(__x86_64__)
    __asm__ __volatile__("lock; xaddl %0, %1" : "+r"(delta), "+m"(*ptr) : : "memory");
    return delta;
#else
    return (int32_t)__atomic_fetch_add(ptr, delta, __ATOMIC_SEQ_CST);
#endif
}

int64_t llpl_atomic_i32_compare_exchange(int32_t* ptr, int32_t* expected, int32_t desired) {
#if defined(__x86_64__)
    int32_t old = *expected;
    unsigned char ok;
    __asm__ __volatile__(
        "lock; cmpxchgl %3, %1; sete %0"
        : "=q"(ok), "+m"(*ptr), "+a"(old)
        : "r"(desired)
        : "memory");
    if (!ok) *expected = old;
    return ok ? 1 : 0;
#else
    return __atomic_compare_exchange_n(ptr, expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) ? 1 : 0;
#endif
}

int64_t llpl_atomic_i64_load(int64_t* ptr) {
    __asm__ __volatile__("" ::: "memory");
    int64_t value = *ptr;
    __asm__ __volatile__("" ::: "memory");
    return value;
}

void llpl_atomic_i64_store(int64_t* ptr, int64_t value) {
    __asm__ __volatile__("" ::: "memory");
    *ptr = value;
    __asm__ __volatile__("" ::: "memory");
}

int64_t llpl_atomic_i64_exchange(int64_t* ptr, int64_t value) {
#if defined(__x86_64__)
    __asm__ __volatile__("xchgq %0, %1" : "+r"(value), "+m"(*ptr) : : "memory");
    return value;
#else
    return __atomic_exchange_n(ptr, value, __ATOMIC_SEQ_CST);
#endif
}

int64_t llpl_atomic_i64_fetch_add(int64_t* ptr, int64_t delta) {
#if defined(__x86_64__)
    __asm__ __volatile__("lock; xaddq %0, %1" : "+r"(delta), "+m"(*ptr) : : "memory");
    return delta;
#else
    return __atomic_fetch_add(ptr, delta, __ATOMIC_SEQ_CST);
#endif
}

int64_t llpl_atomic_i64_compare_exchange(int64_t* ptr, int64_t* expected, int64_t desired) {
#if defined(__x86_64__)
    int64_t old = *expected;
    unsigned char ok;
    __asm__ __volatile__(
        "lock; cmpxchgq %3, %1; sete %0"
        : "=q"(ok), "+m"(*ptr), "+a"(old)
        : "r"(desired)
        : "memory");
    if (!ok) *expected = old;
    return ok ? 1 : 0;
#else
    return __atomic_compare_exchange_n(ptr, expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) ? 1 : 0;
#endif
}

uint8_t llpl_atomic_u8_load(uint8_t* ptr) {
    return (uint8_t)llpl_atomic_i8_load((int8_t*)ptr);
}

void llpl_atomic_u8_store(uint8_t* ptr, uint8_t value) {
    llpl_atomic_i8_store((int8_t*)ptr, (int8_t)value);
}

uint8_t llpl_atomic_u8_exchange(uint8_t* ptr, uint8_t value) {
    return (uint8_t)llpl_atomic_i8_exchange((int8_t*)ptr, (int8_t)value);
}

uint8_t llpl_atomic_u8_fetch_add(uint8_t* ptr, uint8_t delta) {
    return (uint8_t)llpl_atomic_i8_fetch_add((int8_t*)ptr, (int8_t)delta);
}

int64_t llpl_atomic_u8_compare_exchange(uint8_t* ptr, uint8_t* expected, uint8_t desired) {
    return llpl_atomic_i8_compare_exchange((int8_t*)ptr, (int8_t*)expected, (int8_t)desired);
}

uint16_t llpl_atomic_u16_load(uint16_t* ptr) {
    return (uint16_t)llpl_atomic_i16_load((int16_t*)ptr);
}

void llpl_atomic_u16_store(uint16_t* ptr, uint16_t value) {
    llpl_atomic_i16_store((int16_t*)ptr, (int16_t)value);
}

uint16_t llpl_atomic_u16_exchange(uint16_t* ptr, uint16_t value) {
    return (uint16_t)llpl_atomic_i16_exchange((int16_t*)ptr, (int16_t)value);
}

uint16_t llpl_atomic_u16_fetch_add(uint16_t* ptr, uint16_t delta) {
    return (uint16_t)llpl_atomic_i16_fetch_add((int16_t*)ptr, (int16_t)delta);
}

int64_t llpl_atomic_u16_compare_exchange(uint16_t* ptr, uint16_t* expected, uint16_t desired) {
    return llpl_atomic_i16_compare_exchange((int16_t*)ptr, (int16_t*)expected, (int16_t)desired);
}

uint32_t llpl_atomic_u32_load(uint32_t* ptr) {
    return (uint32_t)llpl_atomic_i32_load((int32_t*)ptr);
}

void llpl_atomic_u32_store(uint32_t* ptr, uint32_t value) {
    llpl_atomic_i32_store((int32_t*)ptr, (int32_t)value);
}

uint32_t llpl_atomic_u32_exchange(uint32_t* ptr, uint32_t value) {
    return (uint32_t)llpl_atomic_i32_exchange((int32_t*)ptr, (int32_t)value);
}

uint32_t llpl_atomic_u32_fetch_add(uint32_t* ptr, uint32_t delta) {
    return (uint32_t)llpl_atomic_i32_fetch_add((int32_t*)ptr, (int32_t)delta);
}

int64_t llpl_atomic_u32_compare_exchange(uint32_t* ptr, uint32_t* expected, uint32_t desired) {
    return llpl_atomic_i32_compare_exchange((int32_t*)ptr, (int32_t*)expected, (int32_t)desired);
}

uint64_t llpl_atomic_u64_load(uint64_t* ptr) {
    return (uint64_t)llpl_atomic_i64_load((int64_t*)ptr);
}

void llpl_atomic_u64_store(uint64_t* ptr, uint64_t value) {
    llpl_atomic_i64_store((int64_t*)ptr, (int64_t)value);
}

uint64_t llpl_atomic_u64_exchange(uint64_t* ptr, uint64_t value) {
    return (uint64_t)llpl_atomic_i64_exchange((int64_t*)ptr, (int64_t)value);
}

uint64_t llpl_atomic_u64_fetch_add(uint64_t* ptr, uint64_t delta) {
    return (uint64_t)llpl_atomic_i64_fetch_add((int64_t*)ptr, (int64_t)delta);
}

int64_t llpl_atomic_u64_compare_exchange(uint64_t* ptr, uint64_t* expected, uint64_t desired) {
    return llpl_atomic_i64_compare_exchange((int64_t*)ptr, (int64_t*)expected, (int64_t)desired);
}

static void llpl_blocking_lock_irq_check(char* name) {
    if (llpl_irq_depth > 0) {
        llpl_panic(name);
    }
}

void llpl_mutex_lock(int64_t* state) {
    llpl_blocking_lock_irq_check("blocking lock acquire is not IRQ-safe");
    while (!llpl_mutex_try_lock(state)) {
#if defined(__x86_64__)
        __asm__ __volatile__("pause");
#endif
    }
}

int64_t llpl_mutex_try_lock(int64_t* state) {
    int64_t expected = 0;
    return llpl_atomic_i64_compare_exchange(state, &expected, 1);
}

void llpl_mutex_unlock(int64_t* state) {
    if (llpl_atomic_i64_exchange(state, 0) != 1) {
        llpl_panic("Mutex.unlock: mutex is not locked");
    }
}

void llpl_rwlock_read_lock(int64_t* state) {
    llpl_blocking_lock_irq_check("blocking rwlock read acquire is not IRQ-safe");
    while (!llpl_rwlock_try_read_lock(state)) {
#if defined(__x86_64__)
        __asm__ __volatile__("pause");
#endif
    }
}

int64_t llpl_rwlock_try_read_lock(int64_t* state) {
    int64_t current = llpl_atomic_i64_load(state);
    while (current >= 0) {
        int64_t expected = current;
        if (llpl_atomic_i64_compare_exchange(state, &expected, current + 1)) {
            return 1;
        }
        current = expected;
    }
    return 0;
}

void llpl_rwlock_read_unlock(int64_t* state) {
    int64_t previous = llpl_atomic_i64_fetch_add(state, -1);
    if (previous <= 0) {
        llpl_panic("RwLock.read_unlock: read lock is not held");
    }
}

void llpl_rwlock_write_lock(int64_t* state) {
    llpl_blocking_lock_irq_check("blocking rwlock write acquire is not IRQ-safe");
    while (!llpl_rwlock_try_write_lock(state)) {
#if defined(__x86_64__)
        __asm__ __volatile__("pause");
#endif
    }
}

int64_t llpl_rwlock_try_write_lock(int64_t* state) {
    int64_t expected = 0;
    return llpl_atomic_i64_compare_exchange(state, &expected, -1);
}

void llpl_rwlock_write_unlock(int64_t* state) {
    if (llpl_atomic_i64_exchange(state, 0) != -1) {
        llpl_panic("RwLock.write_unlock: write lock is not held");
    }
}

#define LLPL_TLS_SLOT_COUNT 64
static int64_t llpl_tls_next_key = 0;
#if __STDC_HOSTED__
static pthread_key_t llpl_tls_key;
static pthread_once_t llpl_tls_once = PTHREAD_ONCE_INIT;

static void llpl_tls_destroy(void* ptr) {
    free(ptr);
}

static void llpl_tls_make_key(void) {
    if (pthread_key_create(&llpl_tls_key, llpl_tls_destroy) != 0) {
        llpl_panic("failed to initialize thread-local storage");
    }
}

static uint64_t* llpl_tls_current_slots(void) {
    pthread_once(&llpl_tls_once, llpl_tls_make_key);
    uint64_t* slots = (uint64_t*)pthread_getspecific(llpl_tls_key);
    if (!slots) {
        slots = (uint64_t*)calloc(LLPL_TLS_SLOT_COUNT, sizeof(uint64_t));
        if (!slots) {
            llpl_panic("failed to allocate thread-local storage");
        }
        if (pthread_setspecific(llpl_tls_key, slots) != 0) {
            free(slots);
            llpl_panic("failed to bind thread-local storage");
        }
    }
    return slots;
}
#else
static uint64_t llpl_tls_slots[LLPL_TLS_SLOT_COUNT];

static uint64_t* llpl_tls_current_slots(void) {
    return llpl_tls_slots;
}
#endif

int64_t llpl_tls_alloc(void) {
    int64_t key = llpl_atomic_i64_fetch_add(&llpl_tls_next_key, 1);
    if (key < 0 || key >= LLPL_TLS_SLOT_COUNT) {
        llpl_panic("thread/task-local storage key limit exceeded");
    }
    return key;
}

static void llpl_tls_check_key(int64_t key) {
    if (key < 0 || key >= LLPL_TLS_SLOT_COUNT) {
        llpl_panic("thread/task-local storage key out of range");
    }
}

void llpl_tls_set_i64(int64_t key, int64_t value) {
    llpl_tls_check_key(key);
    uint64_t* slots = llpl_tls_current_slots();
    llpl_atomic_u64_store(&slots[key], (uint64_t)value);
}

int64_t llpl_tls_get_i64(int64_t key) {
    llpl_tls_check_key(key);
    uint64_t* slots = llpl_tls_current_slots();
    return (int64_t)llpl_atomic_u64_load(&slots[key]);
}

void llpl_tls_set_u64(int64_t key, uint64_t value) {
    llpl_tls_check_key(key);
    uint64_t* slots = llpl_tls_current_slots();
    llpl_atomic_u64_store(&slots[key], value);
}

uint64_t llpl_tls_get_u64(int64_t key) {
    llpl_tls_check_key(key);
    uint64_t* slots = llpl_tls_current_slots();
    return llpl_atomic_u64_load(&slots[key]);
}

typedef void (*LLPL_ThreadEntryFn)(void* env);

typedef struct {
#if __STDC_HOSTED__
    pthread_t thread;
#endif
    __LLPL_Closure entry;
    int joined;
    int detached;
} LLPL_Thread;

#if __STDC_HOSTED__
static void* llpl_thread_trampoline(void* arg) {
    LLPL_Thread* thread = (LLPL_Thread*)arg;
    if (thread && thread->entry.fn) {
        ((LLPL_ThreadEntryFn)thread->entry.fn)(thread->entry.env);
    }
    return NULL;
}
#endif

char* llpl_thread_spawn(__LLPL_Closure entry) {
    if (!entry.fn) return NULL;
#if __STDC_HOSTED__
    LLPL_Thread* thread = (LLPL_Thread*)rc_alloc(sizeof(LLPL_Thread));
    if (!thread) return NULL;
    thread->entry = entry;
    thread->joined = 0;
    thread->detached = 0;
    if (pthread_create(&thread->thread, NULL, llpl_thread_trampoline, thread) != 0) {
        rc_free(thread);
        return NULL;
    }
    return (char*)thread;
#else
    (void)entry;
    llpl_panic("user-mode threads require a hosted runtime");
    return NULL;
#endif
}

int64_t llpl_thread_join(char* handle) {
    if (!handle) return -1;
    LLPL_Thread* thread = (LLPL_Thread*)handle;
    if (thread->joined || thread->detached) return -1;
#if __STDC_HOSTED__
    int rc = pthread_join(thread->thread, NULL);
    if (rc != 0) return -1;
    thread->joined = 1;
    rc_free(thread);
    return 1;
#else
    (void)thread;
    llpl_panic("user-mode threads require a hosted runtime");
    return -1;
#endif
}

int64_t llpl_thread_detach(char* handle) {
    if (!handle) return -1;
    LLPL_Thread* thread = (LLPL_Thread*)handle;
    if (thread->joined || thread->detached) return -1;
#if __STDC_HOSTED__
    int rc = pthread_detach(thread->thread);
    if (rc != 0) return -1;
    thread->detached = 1;
    return 1;
#else
    (void)thread;
    llpl_panic("user-mode threads require a hosted runtime");
    return -1;
#endif
}

uint64_t llpl_thread_current_id(void) {
#if __STDC_HOSTED__
    return (uint64_t)(uintptr_t)pthread_self();
#else
    return 0;
#endif
}

void llpl_thread_yield(void) {
#if __STDC_HOSTED__
    sched_yield();
#endif
}

void llpl_thread_sleep_ms(uint64_t ms) {
#if __STDC_HOSTED__
    usleep((useconds_t)(ms * 1000ULL));
#else
    uint64_t deadline = llpl_async_now_ms() + ms;
    while (llpl_async_now_ms() < deadline) { }
#endif
}

typedef struct LLPL_AsyncExecutor {
    char** tasks;
    uint64_t count;
    uint64_t capacity;
    uint64_t next;
} LLPL_AsyncExecutor;

char* llpl_async_executor_create(void) {
    LLPL_AsyncExecutor* executor = (LLPL_AsyncExecutor*)rc_alloc(sizeof(LLPL_AsyncExecutor));
    if (!executor) return NULL;
    executor->tasks = NULL;
    executor->count = 0;
    executor->capacity = 0;
    executor->next = 0;
    return (char*)executor;
}

void llpl_async_executor_destroy(char* executor) {
    if (!executor) return;
    LLPL_AsyncExecutor* ex = (LLPL_AsyncExecutor*)executor;
    for (uint64_t i = 0; i < ex->count; i++) {
        llpl_async_destroy(ex->tasks[i]);
    }
    if (ex->tasks) rc_free(ex->tasks);
    rc_free(ex);
}

int64_t llpl_async_executor_spawn(char* executor, char* task) {
    if (!executor || !task) return -1;
    LLPL_AsyncExecutor* ex = (LLPL_AsyncExecutor*)executor;
    if (ex->count == ex->capacity) {
        uint64_t new_capacity = ex->capacity == 0 ? 4 : ex->capacity * 2;
        char** new_tasks = (char**)rc_alloc(sizeof(char*) * (size_t)new_capacity);
        if (!new_tasks) return -1;
        for (uint64_t i = 0; i < ex->count; i++) {
            new_tasks[i] = ex->tasks[i];
        }
        if (ex->tasks) rc_free(ex->tasks);
        ex->tasks = new_tasks;
        ex->capacity = new_capacity;
    }
    ex->tasks[ex->count++] = task;
    return (int64_t)ex->count;
}

static void llpl_async_executor_remove(LLPL_AsyncExecutor* ex, uint64_t index) {
    llpl_async_destroy(ex->tasks[index]);
    for (uint64_t i = index + 1; i < ex->count; i++) {
        ex->tasks[i - 1] = ex->tasks[i];
    }
    ex->count--;
    if (ex->count == 0) {
        ex->next = 0;
    } else if (ex->next >= ex->count) {
        ex->next = 0;
    }
}

int64_t llpl_async_executor_poll(char* executor) {
    if (!executor) return -1;
    LLPL_AsyncExecutor* ex = (LLPL_AsyncExecutor*)executor;
    if (ex->count == 0) return 0;

    uint64_t polls = ex->count;
    while (polls > 0 && ex->count > 0) {
        uint64_t index = ex->next;
        int64_t state = llpl_async_poll(ex->tasks[index], NULL);
        if (state != 0) {
            llpl_async_executor_remove(ex, index);
        } else {
            ex->next = (index + 1) % ex->count;
        }
        polls--;
    }
    return (int64_t)ex->count;
}

int64_t llpl_async_executor_run_all(char* executor) {
    int64_t remaining = 0;
    do {
        remaining = llpl_async_executor_poll(executor);
    } while (remaining > 0);
    return remaining;
}

int64_t llpl_async_executor_run_all_timeout(char* executor, uint64_t timeout_ms) {
    uint64_t deadline = llpl_async_now_ms() + timeout_ms;
    int64_t remaining = 0;
    do {
        remaining = llpl_async_executor_poll(executor);
        if (remaining <= 0) return remaining;
        if (llpl_async_now_ms() >= deadline) return remaining;
    } while (1);
}

int64_t llpl_async_executor_cancel_all(char* executor) {
    if (!executor) return -1;
    LLPL_AsyncExecutor* ex = (LLPL_AsyncExecutor*)executor;
    uint64_t cancelled = 0;
    while (ex->count > 0) {
        llpl_async_cancel(ex->tasks[0]);
        llpl_async_executor_remove(ex, 0);
        cancelled++;
    }
    return (int64_t)cancelled;
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

static void llpl_panic_write(char* s) {
#if __STDC_HOSTED__
    fputs(s, stderr);
#else
    for (char* p = s; *p; p++) {
        llpl_panic_putc(*p);
    }
#endif
}

static bool llpl_panic_use_color(void) {
#if __STDC_HOSTED__
    return isatty(fileno(stderr)) != 0;
#else
    // Freestanding targets route this output to their console hook, which
    // is expected to be an ANSI-capable serial/terminal output path.
    return true;
#endif
}

static void llpl_panic_backtrace_from(uint64_t frame_addr) {
    char buf[256];
    int64_t depth = 0;

    if (llpl_panic_use_color()) {
        llpl_panic_write("\x1b[1;36mBacktrace:\x1b[0m\n");
    } else {
        llpl_panic_write("Backtrace:\n");
    }
    while (frame_addr != 0 && depth < 16) {
        uint64_t* frame = (uint64_t*)(uintptr_t)frame_addr;
        uint64_t next = frame[0];
        uint64_t rip = frame[1];

        if (rip == 0) {
            break;
        }

        char* sym = llpl_resolve_symbol(rip > 0 ? rip - 1 : rip);
        if (llpl_panic_use_color() && sym) {
            ksnprintf(buf, sizeof(buf),
                "\x1b[36m  #%02d\x1b[0m rbp=\x1b[33m0x%016x\x1b[0m rip=\x1b[33m0x%016x\x1b[0m \x1b[1;32m%s\x1b[0m (\x1b[2m%s:%d\x1b[0m)\n",
                depth, frame_addr, rip,
                llpl_symbol_display_name(sym), llpl_symbol_file(sym), llpl_symbol_line(sym));
        } else if (llpl_panic_use_color()) {
            ksnprintf(buf, sizeof(buf),
                "\x1b[36m  #%02d\x1b[0m rbp=\x1b[33m0x%016x\x1b[0m rip=\x1b[33m0x%016x\x1b[0m \x1b[1;31m<unknown>\x1b[0m\n",
                depth, frame_addr, rip);
        } else if (sym) {
            ksnprintf(buf, sizeof(buf),
                "  #%02d rbp=0x%016x rip=0x%016x %s (%s:%d)\n",
                depth, frame_addr, rip,
                llpl_symbol_display_name(sym), llpl_symbol_file(sym), llpl_symbol_line(sym));
        } else {
            ksnprintf(buf, sizeof(buf),
                "  #%02d rbp=0x%016x rip=0x%016x <unknown>\n",
                depth, frame_addr, rip);
        }
        llpl_panic_write(buf);

        if (next == 0) {
            break;
        }
        if (next <= frame_addr) {
            if (llpl_panic_use_color()) {
                llpl_panic_write("\x1b[33m  <stopped: non-increasing frame pointer>\x1b[0m\n");
            } else {
                llpl_panic_write("  <stopped: non-increasing frame pointer>\n");
            }
            break;
        }
        if ((next & 7) != 0) {
            if (llpl_panic_use_color()) {
                llpl_panic_write("\x1b[33m  <stopped: unaligned frame pointer>\x1b[0m\n");
            } else {
                llpl_panic_write("  <stopped: unaligned frame pointer>\n");
            }
            break;
        }
        if (next - frame_addr > 16384) {
            if (llpl_panic_use_color()) {
                llpl_panic_write("\x1b[33m  <stopped: frame pointer jump too large>\x1b[0m\n");
            } else {
                llpl_panic_write("  <stopped: frame pointer jump too large>\n");
            }
            break;
        }

        frame_addr = next;
        depth++;
    }

    if (depth == 16) {
        if (llpl_panic_use_color()) {
            llpl_panic_write("\x1b[33m  <stopped: frame limit reached>\x1b[0m\n");
        } else {
            llpl_panic_write("  <stopped: frame limit reached>\n");
        }
    }
}

void llpl_panic_backtrace(void) {
#if defined(__x86_64__)
    uint64_t rbp = 0;
    __asm__ volatile("movq %%rbp, %0" : "=r"(rbp));
    llpl_panic_backtrace_from(rbp);
#else
    if (llpl_panic_use_color()) {
        llpl_panic_write("\x1b[1;36mBacktrace:\x1b[0m \x1b[33munavailable on this architecture\x1b[0m\n");
    } else {
        llpl_panic_write("Backtrace: unavailable on this architecture\n");
    }
#endif
}

void llpl_panic_backtrace_from_frame(uint64_t frame_addr) {
    llpl_panic_backtrace_from(frame_addr);
}

void llpl_panic_at(char* msg, char* file, int64_t line) {
    if (llpl_panic_handler) {
        llpl_panic_handler(msg);
    }

    char buf[512];
    if (file && file[0]) {
        if (llpl_panic_use_color()) {
            ksnprintf(buf, sizeof(buf), "\x1b[1;31mPANIC:\x1b[0m %s at %s:%d\n", msg, file, line);
        } else {
            ksnprintf(buf, sizeof(buf), "PANIC: %s at %s:%d\n", msg, file, line);
        }
    } else {
        if (llpl_panic_use_color()) {
            ksnprintf(buf, sizeof(buf), "\x1b[1;31mPANIC:\x1b[0m %s\n", msg);
        } else {
            ksnprintf(buf, sizeof(buf), "PANIC: %s\n", msg);
        }
    }

#if __STDC_HOSTED__
    llpl_panic_write(buf);
    llpl_panic_backtrace();
    abort();
#else
    llpl_panic_write(buf);
    llpl_panic_backtrace();
    llpl_panic_halt();
#endif
}

void llpl_panic(char* msg) {
    llpl_panic_at(msg, NULL, 0);
}

// Non-fatal diagnostic support. Unlike llpl_panic, this reports the message
// through the same hosted/freestanding output path and then returns.
void llpl_check(char* msg) {
    char buf[512];
    if (llpl_panic_use_color()) {
        ksnprintf(buf, sizeof(buf), "\x1b[1;33mCHECK FAILED:\x1b[0m %s\n", msg);
    } else {
        ksnprintf(buf, sizeof(buf), "CHECK FAILED: %s\n", msg);
    }
    llpl_panic_write(buf);
}

void* __llpl_check_index(void* arr, int64_t idx, int64_t size, uint64_t elem_size, char* file, int64_t line) {
    if (idx < 0 || idx >= size) {
        char msg[512];
        if (file && file[0]) {
            ksnprintf(msg, sizeof(msg), "index out of bounds at %s:%d", file, line);
        } else {
            ksnprintf(msg, sizeof(msg), "index out of bounds at <unknown>:%d", line);
        }
        llpl_panic(msg);
    }
    return (char*)arr + idx * elem_size;
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

// Whether this translation unit can name a `double` at all - i.e. whether
// %f support below gets compiled in. GCC/Clang predefine __SSE2__ on
// x86-64 and drop it for -mno-sse2, which is exactly the signal wanted;
// tcc never defines it yet has no -mno-sse either (it always passes
// doubles in SSE registers), so a bare __SSE2__ test silently compiles
// %f out there and interpolating a float prints a literal "%f".
#if defined(__SSE2__) || defined(__TINYC__)
#define LLPL_FMT_FLOAT 1
#endif

// `%f` - fixed-point, `precision` digits after the point (6 if negative
// ("no .N given" - see kvsnprintf below), C's
// own default). No libm dependency (this runs on freestanding targets
// too) - rounds by scaling into an integer rather than calling round()/
// pow(), the same "just enough hand-rolled arithmetic" spirit
// kfmt_putuint/kfmt_putint already use for everything else here. Doesn't
// handle NaN/Infinity (not reachable from ordinary LLPL float literals/
// arithmetic today) or values large enough to overflow a uint64_t once
// scaled by 10^precision - fine for interpolation's actual use, not a
// general-purpose float formatter.
//
// Guarded by LLPL_FMT_FLOAT (defined just above) - a `double` parameter/
// return needs an SSE register by the x86-64 ABI regardless of whether
// this function is ever actually *called*; examples/baremetal_demo's own
// build.yaml passes -mno-sse -mno-sse2 -mno-80387 for its kernel target
// (no FPU support at all), so merely having this function's signature in
// the translation unit is a hard compile error there - "SSE register
// argument/return with SSE disabled" - even though that target never
// touches float/f64 anywhere and so never reaches the '%f' case below
// either. kvsnprintf's own `default:` case (print the specifier
// literally) covers '%f' there instead.
#ifdef LLPL_FMT_FLOAT
static void kfmt_putfloat(char* buf, size_t size, size_t* pos, double value, int precision) {
    if (precision < 0) precision = 6; // -1 = "no .N given"; 0 is a real, explicit precision
    if (value < 0) {
        kfmt_putc(buf, size, pos, '-');
        value = -value;
    }
    uint64_t scale = 1;
    for (int i = 0; i < precision; i++) scale *= 10;
    uint64_t scaled = (uint64_t)(value * (double)scale + 0.5);
    uint64_t int_part = scaled / scale;
    uint64_t frac_part = scaled % scale;
    kfmt_putuint(buf, size, pos, int_part, 10, 0, 0, 0);
    // Real printf's %.0f omits the point entirely ("3", not "3.") -
    // only meaningful when there's at least one fractional digit to show.
    if (precision > 0) {
        kfmt_putc(buf, size, pos, '.');
        kfmt_putuint(buf, size, pos, frac_part, 10, 0, precision, 1);
    }
}
#endif

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
        // Optional `.N` precision, %f's own - the only specifier here
        // that uses it (every int/uint one already means "N" as a field
        // *width* via the digits above, not a precision).
        int precision = -1;
        if (*fmt == '.') {
            fmt++;
            precision = 0;
            while (*fmt >= '0' && *fmt <= '9') {
                precision = precision * 10 + (*fmt - '0');
                fmt++;
            }
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
#ifdef LLPL_FMT_FLOAT
            case 'f':
                // C's own default argument promotion always widens a
                // float argument to double in a varargs call, so this is
                // correct regardless of whether the LLPL caller passed
                // f32 or f64 - same reasoning codegen.d's own %c handling
                // above already documents for a narrower int type.
                kfmt_putfloat(buf, size, &pos, va_arg(args, double), precision);
                break;
#endif
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
