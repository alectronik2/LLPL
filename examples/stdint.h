#ifndef _STDINT_H
#define _STDINT_H

// Fixed-width integer types for bare metal
typedef signed char        int8_t;
typedef unsigned char      uint8_t;
typedef signed short       int16_t;
typedef unsigned short     uint16_t;
typedef signed int         int32_t;
typedef unsigned int       uint32_t;
typedef signed long long   int64_t;
typedef unsigned long long uint64_t;

// Pointer-sized integers
typedef long          intptr_t;
typedef unsigned long uintptr_t;

#endif
