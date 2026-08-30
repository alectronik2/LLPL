// A handful of runtime.c's public (runtime.h) helpers, reimplemented
// standalone for libsys.so specifically - not the whole of runtime.c.
//
// libsys.llpl's own generated code (via prelude.llpl's always-compiled-in
// String/class boilerplate - see every LLPL program's generated C, not
// just this one) already references most of runtime.c's surface
// (regex, reflection, backtraces, ...) internally, which makes
// --gc-sections unable to strip any of it once the real runtime.c is
// linked in at all: pulling in the whole file to fix one missing symbol
// (llpl_strcmp - see build.yaml's libsys link step for the actual story)
// made libsys.so balloon past the VFS's 32KB max file size (see
// vfs.llpl's MAX_DIRECT_BLOCKS). Each function reimplemented here is
// self-contained (no dependency on regex/reflection/backtraces/etc.), so
// duplicating just them avoids linking any of the rest of runtime.c into
// libsys.so at all.
//
// Deliberately NOT __builtin_strlen/strcmp/memcpy: under -nostdlib
// (no libc to link against), GCC is still free to lower a builtin call
// to a *real* libc call by name if it doesn't recognize a profitable
// inline expansion at this optimization level - which silently adds an
// unresolved `strcmp`/`strlen`/`memcpy` (not `llpl_*`) to libsys.so's own
// dynsym table, breaking every single program that loads it, not just
// whichever one needed llpl_strcmp. Plain hand-written loops have
// nothing for the compiler to "fall back" to.
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

extern uint64_t syscall1(uint64_t number, uint64_t a);
extern uint64_t syscall3(uint64_t number, uint64_t a, uint64_t b, uint64_t c);

#define SYS_EXIT 0
#define SYS_CRASH_REPORT 44

uint64_t llpl_strlen(char* s) {
    uint64_t n = 0;
    while (s[n] != 0) {
        n = n + 1;
    }
    return n;
}

int64_t llpl_strcmp(char* a, char* b) {
    uint64_t i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) {
            return (int64_t)(unsigned char)a[i] - (int64_t)(unsigned char)b[i];
        }
        i = i + 1;
    }
    return (int64_t)(unsigned char)a[i] - (int64_t)(unsigned char)b[i];
}

void llpl_memcpy(char* dest, char* src, uint64_t count) {
    uint64_t i = 0;
    while (i < count) {
        dest[i] = src[i];
        i = i + 1;
    }
}

// Free-list heap allocator + refcounting, copied verbatim from
// runtime.c's own (also self-contained) implementation - the first
// dynamically-linked userapp needing `new`/class instances (ui_demo.elf,
// see build.yaml) has no other way to reach a heap allocator, since a
// `-shared` userapp only links against libsys.so, never runtime.o
// directly. `heap`/`free_list` are per-process here exactly as they are
// in every other shared library's writable globals - ldso.llpl gives
// each loaded process its own private mapping of libsys.so's data/bss,
// the same guarantee any real dynamic linker has to provide (otherwise
// two processes loading libsys.so would corrupt each other's heap, not
// just this allocator - already relied on implicitly by every existing
// consumer of libsys.so's other mutable state). Adds real code (not
// just a bigger .bss - `heap` itself is zero-initialized and costs
// nothing in the file), so if libsys.so ever creeps back up against the
// 32KB VFS file-size limit (see this file's own header comment), this
// is the block to look at first.
typedef struct {
    uint32_t count;
    uint32_t weak_count;
} RefCount;

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

bool rc_is_alive(char* ptr) {
    if (!ptr) return false;
    RefCount* rc = (RefCount*)ptr;
    return rc->count > 0;
}

char* llpl_alloc(uint64_t size) {
    return (char*)rc_alloc((size_t)size);
}

void llpl_free(char* ptr) {
    rc_free((void*)ptr);
}

void llpl_panic(char* msg) {
    uint64_t rbp = 0;
    __asm__ volatile("movq %%rbp, %0" : "=r"(rbp));
    syscall3(SYS_CRASH_REPORT, (uint64_t)(uintptr_t)msg,
        (uint64_t)(uintptr_t)__builtin_return_address(0), rbp);
    syscall1(SYS_EXIT, 0x90);
    while (1) {
    }
}

void* __llpl_check_index(void* arr, int64_t idx, int64_t size, uint64_t elem_size, char* file, int64_t line) {
    if (idx < 0 || idx >= size) {
        if (file && file[0]) {
            llpl_panic("index out of bounds");
        } else {
            llpl_panic("index out of bounds");
        }
    }
    (void)line;
    return (char*)arr + idx * elem_size;
}
