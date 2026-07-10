#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

// Reference counting structure
typedef struct {
    uint32_t count;
} RefCount;

// Memory allocation for bare metal
void* rc_alloc(size_t size);
void rc_free(void* ptr);

// Reference counting functions
void rc_init(RefCount* rc);
void rc_retain(void* ptr);
void rc_release(void* ptr, void (*destructor)(void*));

// Memory functions for kernel
void* memset(void* dest, int val, size_t count);
void* memcpy(void* dest, const void* src, size_t count);
size_t strlen(const char* str);
int strcmp(const char* a, const char* b);

// LLPL-callable wrappers around the above, typed to exactly match what an
// `extern func` declaration generates for LLPL's fixed-width types (`uint`
// -> uint64_t, `int` -> int64_t, `char*` -> char*, plain - not `const char*`,
// since LLPL has no way to write "pointer to const"). Redeclaring strlen/
// strcmp/rc_alloc themselves under LLPL's types would conflict with the
// prototypes above (size_t vs uint64_t are the same width but different
// types - a hard "conflicting types" error), the same trap documented on
// ksnprintf below - hence separate wrappers instead of reusing the names.
uint64_t llpl_strlen(char* s);
int64_t llpl_strcmp(char* a, char* b);
char* llpl_alloc(uint64_t size);
void llpl_free(char* ptr);
void llpl_memcpy(char* dest, char* src, uint64_t count);

// Minimal printf-style formatter for kernel logging. Deliberately not named
// snprintf/vsnprintf: it isn't ISO C compatible (notably %d/%u/%x read a
// 64-bit value, matching LLPL's `int`/`uint`, not C's 32-bit `int`), and
// this project never links a host libc, so there's no risk of colliding
// with the real thing - the "k" prefix just makes that difference obvious.
// Supported specifiers: %d %i %u %x %X %o %b %s %c %p %%, each optionally
// preceded by a printf-style minimum-field-width (%08x, %4d, ...): a
// leading '0' zero-pads instead of space-padding. (%o/%b - octal and
// binary - aren't ISO C; both they and the width prefix exist here for
// LLPL's string-interpolation format hints, e.g. "\(n:016:hex)".)
//
// Both always NUL-terminate `buf` (if size > 0) and return the number of
// characters the *unclamped* output would have needed, like real snprintf -
// including a value >= size to signal truncation.
//
// `fmt` is plain `char*`, not `const char*`: LLPL's type system has no way
// to express "pointer to const data" (only whole-variable `const`), so an
// `extern func ksnprintf(..., fmt: char*, ...)` declared on the LLPL side
// always generates a plain `char*` parameter. A `const char*` here would be
// a different, and thus conflicting, C type in the same translation unit.
//
// `size` is `uint64_t`, not `size_t`: our freestanding stddef.h/stdint.h
// define size_t as `unsigned long` but uint64_t as `unsigned long long` -
// same width, but genuinely different C types - and LLPL's `uint` always
// maps to uint64_t, so that's what any `extern func` declaring this
// parameter will generate.
int64_t kvsnprintf(char* buf, uint64_t size, char* fmt, va_list args);
int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);

#endif // RUNTIME_H
