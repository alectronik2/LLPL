#include "llpl_sys.h"

// Classic K&R (2nd ed., 8.7) free-list allocator: an ascending, circular,
// address-ordered list of free blocks, extended on demand via SYS_SBRK.
// Not thread-safe - callers spawning threads that also allocate need to
// serialize their own malloc/free calls.

typedef union header {
    struct {
        union header *next;
        u64 size; // in Header-sized units, header included
    } s;
    i64 align;
} Header;

#define NALLOC 4096 // minimum units requested from SYS_SBRK at a time

static Header base;
static Header *freep = 0;

static Header *morecore(u64 nunits) {
    if (nunits < NALLOC) nunits = NALLOC;
    i64 got = (i64)call2(SYS_SBRK, nunits * sizeof(Header), 0);
    if (got < 0) return 0;
    Header *up = (Header *)got;
    up->s.size = nunits;
    free((void *)(up + 1));
    return freep;
}

void *malloc(u64 nbytes) {
    if (nbytes == 0) return 0;
    u64 nunits = (nbytes + sizeof(Header) - 1) / sizeof(Header) + 1;

    Header *prevp = freep;
    if (prevp == 0) {
        base.s.next = freep = prevp = &base;
        base.s.size = 0;
    }

    for (Header *p = prevp->s.next; ; prevp = p, p = p->s.next) {
        if (p->s.size >= nunits) {
            if (p->s.size == nunits) {
                prevp->s.next = p->s.next;
            } else {
                p->s.size -= nunits;
                p += p->s.size;
                p->s.size = nunits;
            }
            freep = prevp;
            return (void *)(p + 1);
        }
        if (p == freep) {
            p = morecore(nunits);
            if (p == 0) return 0;
        }
    }
}

void free(void *ap) {
    if (ap == 0) return;
    Header *bp = (Header *)ap - 1;
    Header *p;
    for (p = freep; !(bp > p && bp < p->s.next); p = p->s.next) {
        if (p >= p->s.next && (bp > p || bp < p->s.next)) break;
    }

    if (bp + bp->s.size == p->s.next) {
        bp->s.size += p->s.next->s.size;
        bp->s.next = p->s.next->s.next;
    } else {
        bp->s.next = p->s.next;
    }
    if (p + p->s.size == bp) {
        p->s.size += bp->s.size;
        p->s.next = bp->s.next;
    } else {
        p->s.next = bp;
    }
    freep = p;
}

void *calloc(u64 nmemb, u64 size) {
    u64 total = nmemb * size;
    void *p = malloc(total);
    if (p != 0) {
        char *b = (char *)p;
        for (u64 i = 0; i < total; i++) b[i] = 0;
    }
    return p;
}

void *realloc(void *ptr, u64 size) {
    if (ptr == 0) return malloc(size);
    if (size == 0) {
        free(ptr);
        return 0;
    }
    Header *bp = (Header *)ptr - 1;
    u64 old_bytes = (bp->s.size - 1) * sizeof(Header);
    void *newp = malloc(size);
    if (newp == 0) return 0;
    u64 copy_bytes = old_bytes < size ? old_bytes : size;
    char *src = (char *)ptr;
    char *dst = (char *)newp;
    for (u64 i = 0; i < copy_bytes; i++) dst[i] = src[i];
    free(ptr);
    return newp;
}
