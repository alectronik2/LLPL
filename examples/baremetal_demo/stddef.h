#ifndef _STDDEF_H
#define _STDDEF_H

// Basic types for bare metal
typedef unsigned long size_t;
typedef long ptrdiff_t;

#define NULL ((void*)0)

#define offsetof(type, member) ((size_t)&((type*)0)->member)

#endif
