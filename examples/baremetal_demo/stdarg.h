#ifndef _STDARG_H
#define _STDARG_H

// Freestanding builds pass -nostdinc, which excludes even the compiler's
// own <stdarg.h>. va_list/va_start/va_arg/va_end aren't really library
// code though - they're thin wrappers over compiler builtins - so this is
// the same shim GCC's own header would install, minus the parts that need
// libc.

typedef __builtin_va_list va_list;
#define va_start(ap, last) __builtin_va_start(ap, last)
#define va_arg(ap, type) __builtin_va_arg(ap, type)
#define va_end(ap) __builtin_va_end(ap)
#define va_copy(dest, src) __builtin_va_copy(dest, src)

#endif
