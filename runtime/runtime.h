#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdbool.h>

// Reference counting structure. `count` (strong references) drives
// destruction - the destructor runs and the object's *value* is gone the
// moment it hits zero, exactly as before weak references existed.
// `weak_count` only delays the underlying memory's actual rc_free: a
// Weak<T> (prelude.llpl) doesn't keep the value alive, but does need the
// RefCount header itself to remain valid memory so it can safely check
// "is this still alive?" after the strong owner is gone, instead of
// reading freed/reused memory. See rc_release/rc_weak_release.
typedef struct {
    uint32_t count;
    uint32_t weak_count;
} RefCount;

// A closure value (see codegen.d's LambdaExpr handling): `fn` and `env`
// are untyped here because C has no way to write "a pointer to a function
// taking whatever parameters this particular closure's signature has"
// generically - every closure shares this same two-word representation
// regardless of its actual signature, which is recovered by an explicit
// cast at each call site instead (the call site always knows the
// expected signature statically, from the closure-typed variable/
// parameter/field being called). `env` points at a heap-allocated (via
// rc_alloc), per-lambda-shaped struct holding that lambda's captured
// variables by value - never freed once allocated, the same trade-off
// rc_alloc's bump allocator already makes for everything else it hands
// out.
typedef struct {
    void* fn;
    void* env;
} __LLPL_Closure;

typedef intptr_t (*LLPL_AsyncPollFn)(void* frame, void* out);

typedef struct {
    void* frame;
    uint64_t frame_size;
    LLPL_AsyncPollFn poll;
    int cancelled;
} LLPL_AsyncTask;

typedef struct {
    char* name;
    char* type_name;
    uint64_t offset;
    uint64_t size;
} LLPL_FieldInfo;

typedef struct {
    char* name;
    char* kind;
    uint64_t size;
    LLPL_FieldInfo* fields;
    uint64_t field_count;
} LLPL_TypeInfo;

extern LLPL_TypeInfo __llpl_reflect_types[];
extern uint64_t __llpl_reflect_type_count;

// One entry per user-defined function/method/constructor actually
// compiled (including generic instantiations) - the compiler itself
// emits llpl_symbol_table[]/llpl_symbol_table_count (see codegen.d's
// generateBacktraceSymbolTable), the same "compiler bakes in a static
// data table, runtime.c just reads it" pattern __llpl_reflect_types
// above already uses. `file` is the declaring .llpl file's base name
// (no directory), `line` its declaration's source line.
typedef struct {
    char* name;
    void* addr;
    char* file;
    int64_t line;
} LLPL_Symbol;

extern LLPL_Symbol llpl_symbol_table[];
extern uint64_t llpl_symbol_table_count;

typedef struct {
    uint64_t rbx;
    uint64_t rbp;
    uint64_t r12;
    uint64_t r13;
    uint64_t r14;
    uint64_t r15;
    uint64_t rsp;
    uint64_t rip;
} __LLPL_EH_JumpBuf;

#define LLPL_EH_FRAME_CATCH 1
#define LLPL_EH_FRAME_CLEANUP 2

typedef struct __LLPL_EH_Frame {
    struct __LLPL_EH_Frame* prev;
    int kind;
    char* type_id;
    void* error_slot;
    uint64_t error_size;
    __LLPL_EH_JumpBuf env;
} __LLPL_EH_Frame;

int llpl_eh_setjmp(__LLPL_EH_JumpBuf* env);
void llpl_eh_longjmp(__LLPL_EH_JumpBuf* env, int value);
void llpl_eh_push(__LLPL_EH_Frame* frame);
void llpl_eh_pop(__LLPL_EH_Frame* frame);
void llpl_eh_throw(char* type_id, void* error, uint64_t error_size, char* file, int64_t line);
void llpl_eh_resume(void);

typedef char* (*LLPL_AllocFn)(uint64_t size);
typedef void (*LLPL_FreeFn)(char* ptr);

// Memory allocation for bare metal. `rc_alloc`/`rc_free` are also the
// compiler-generated class allocation path used by `new`.
void* rc_alloc(size_t size);
void rc_free(void* ptr);
void llpl_set_allocator(__LLPL_Closure alloc_fn, __LLPL_Closure free_fn);
void llpl_set_allocator_raw(LLPL_AllocFn alloc_fn, LLPL_FreeFn free_fn);
void llpl_reset_allocator(void);

// Reference counting functions
void rc_init(RefCount* rc);
void rc_release(void* ptr, void (*destructor)(void*));

// `char*`, not `void*` - unlike rc_init/rc_release (compiler-generated
// code only), these four are also called directly from LLPL source (see
// prelude.llpl's `extern func` declarations for them, and Weak<T>) -
// their C parameter type has to match that extern declaration exactly,
// or two conflicting prototypes for the same symbol is a compile error.
//
// Weak references (see prelude.llpl's Weak<T>) never keep `ptr`'s value
// alive (rc_weak_retain never runs its destructor), only its memory, for
// exactly as long as it takes every weak reference to also let go (see
// rc_release/rc_weak_release's comments in runtime.c).
void rc_retain(char* ptr);
void rc_weak_retain(char* ptr);
void rc_weak_release(char* ptr);
bool rc_is_alive(char* ptr);
int64_t rc_use_count(char* ptr);

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
bool llpl_utf8_valid(char* s);
uint64_t llpl_utf8_len(char* s);
uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index);
uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset);
uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index);
bool llpl_regex_match(char* pattern, char* text);
uint64_t llpl_regex_group_count(char* pattern);
bool llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end);
char* llpl_regex_capture(char* pattern, char* text, uint64_t group);
char* llpl_reflect_type(char* name);
char* llpl_reflect_type_name(char* type);
char* llpl_reflect_type_kind(char* type);
uint64_t llpl_reflect_type_size(char* type);
uint64_t llpl_reflect_field_count(char* type);
char* llpl_reflect_field(char* type, uint64_t index);
char* llpl_reflect_field_name(char* field);
char* llpl_reflect_field_type_name(char* field);
uint64_t llpl_reflect_field_offset(char* field);
uint64_t llpl_reflect_field_size(char* field);
char* llpl_alloc(uint64_t size);
void llpl_free(char* ptr);
void llpl_memcpy(char* dest, char* src, uint64_t count);
char* llpl_async_create(uint64_t frame_size, void* poll_fn);
char* llpl_async_frame(char* task);
int64_t llpl_async_poll(char* task, char* out);
int64_t llpl_async_block_on(char* task, char* out);
int64_t llpl_async_block_on_timeout(char* task, char* out, uint64_t timeout_ms);
int64_t llpl_async_cancel(char* task);
int64_t llpl_async_is_cancelled(char* task);
void llpl_async_destroy(char* task);
uint64_t llpl_async_now_ms(void);
void llpl_async_set_now_ms(uint64_t now_ms);
uint64_t llpl_async_advance_ms(uint64_t delta_ms);
char* llpl_async_executor_create(void);
void llpl_async_executor_destroy(char* executor);
int64_t llpl_async_executor_spawn(char* executor, char* task);
int64_t llpl_async_executor_poll(char* executor);
int64_t llpl_async_executor_run_all(char* executor);
int64_t llpl_async_executor_run_all_timeout(char* executor, uint64_t timeout_ms);
int64_t llpl_async_executor_cancel_all(char* executor);
void llpl_irq_enter(void);
void llpl_irq_exit(void);
int64_t llpl_in_irq(void);
int64_t llpl_atomic_i64_load(int64_t* ptr);
void llpl_atomic_i64_store(int64_t* ptr, int64_t value);
int64_t llpl_atomic_i64_exchange(int64_t* ptr, int64_t value);
int64_t llpl_atomic_i64_fetch_add(int64_t* ptr, int64_t delta);
int64_t llpl_atomic_i64_compare_exchange(int64_t* ptr, int64_t* expected, int64_t desired);
uint64_t llpl_atomic_u64_load(uint64_t* ptr);
void llpl_atomic_u64_store(uint64_t* ptr, uint64_t value);
uint64_t llpl_atomic_u64_exchange(uint64_t* ptr, uint64_t value);
uint64_t llpl_atomic_u64_fetch_add(uint64_t* ptr, uint64_t delta);
int64_t llpl_atomic_u64_compare_exchange(uint64_t* ptr, uint64_t* expected, uint64_t desired);
void llpl_mutex_lock(int64_t* state);
int64_t llpl_mutex_try_lock(int64_t* state);
void llpl_mutex_unlock(int64_t* state);
void llpl_rwlock_read_lock(int64_t* state);
int64_t llpl_rwlock_try_read_lock(int64_t* state);
void llpl_rwlock_read_unlock(int64_t* state);
void llpl_rwlock_write_lock(int64_t* state);
int64_t llpl_rwlock_try_write_lock(int64_t* state);
void llpl_rwlock_write_unlock(int64_t* state);
int64_t llpl_tls_alloc(void);
void llpl_tls_set_i64(int64_t key, int64_t value);
int64_t llpl_tls_get_i64(int64_t key);
void llpl_tls_set_u64(int64_t key, uint64_t value);
uint64_t llpl_tls_get_u64(int64_t key);
char* llpl_thread_spawn(__LLPL_Closure entry);
int64_t llpl_thread_join(char* thread);
int64_t llpl_thread_detach(char* thread);
uint64_t llpl_thread_current_id(void);
void llpl_thread_yield(void);
void llpl_thread_sleep_ms(uint64_t ms);

// Finds the llpl_symbol_table entry whose address is the closest one at
// or before `addr` (i.e. "which function contains this return address") -
// an opaque handle (NULL if addr is before every known symbol, or the
// table is empty), read via llpl_symbol_name/_file/_line - the same
// "opaque handle, then extract fields" pattern llpl_reflect_type already
// uses. `addr` is uint64_t, not void*, to exactly match what an LLPL
// `extern func` declaring a `uint` parameter generates (the same
// conflicting-types trap ksnprintf's own comment documents). A simple
// linear scan - only ever called from a panic/backtrace path.
char* llpl_resolve_symbol(uint64_t addr);
char* llpl_symbol_name(char* symbol);
char* llpl_symbol_file(char* symbol);
int64_t llpl_symbol_line(char* symbol);

// Panic: print a message (hosted) or hand it to weak hooks (freestanding),
// then halt. An optional handler is called first so user code can log/cleanup.
void llpl_set_panic_handler(void (*handler)(char*));
void llpl_panic_backtrace(void);
void llpl_panic_backtrace_from_frame(uint64_t frame_addr);
void llpl_panic(char* msg);
void llpl_panic_at(char* msg, char* file, int64_t line);
void llpl_check(char* msg);
void* __llpl_check_index(void* arr, int64_t idx, int64_t size, uint64_t elem_size, char* file, int64_t line);

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
