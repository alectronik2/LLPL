#ifndef _STDBOOL_H
#define _STDBOOL_H

// Bare metal (-nostdinc build) has no libc to provide this.
#define bool  _Bool
#define true  1
#define false 0

#define __bool_true_false_are_defined 1

#endif
