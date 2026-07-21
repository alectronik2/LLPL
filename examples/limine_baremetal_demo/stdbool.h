#ifndef _STDBOOL_H
#define _STDBOOL_H

// Bare metal (-nostdinc build - see build.yaml) has no libc to supply this,
// same reason stdint.h/stddef.h/stdarg.h live here too. Matches the real
// C99 stdbool.h's own shape exactly.
#define bool  _Bool
#define true  1
#define false 0

#define __bool_true_false_are_defined 1

#endif
