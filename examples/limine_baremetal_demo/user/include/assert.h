#ifndef LLPL_ASSERT_H
#define LLPL_ASSERT_H
#include <stdlib.h>
#define assert(x) ((x) ? (void)0 : abort())
#endif
