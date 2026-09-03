#ifndef LLPL_STDIO_H
#define LLPL_STDIO_H
#include <stddef.h>
#include <stdarg.h>
typedef struct LLPL_FILE { long fd; unsigned flags; int error; int eof; int ungot; } FILE;
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;
#define EOF (-1)
#define BUFSIZ 1024
#define L_tmpnam 32
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
FILE *fopen(const char *, const char *);
int fclose(FILE *);
size_t fread(void *, size_t, size_t, FILE *);
size_t fwrite(const void *, size_t, size_t, FILE *);
int fseek(FILE *, long, int);
long ftell(FILE *);
int fflush(FILE *);
int feof(FILE *);
int ferror(FILE *);
void clearerr(FILE *);
int fgetc(FILE *);
int getc(FILE *);
char *fgets(char *, int, FILE *);
int fputc(int, FILE *);
int ungetc(int, FILE *);
int fputs(const char *, FILE *);
int remove(const char *);
int rename(const char *, const char *);
int snprintf(char *, size_t, const char *, ...);
int sprintf(char *, const char *, ...);
int vsnprintf(char *, size_t, const char *, va_list);
int printf(const char *, ...);
int fprintf(FILE *, const char *, ...);
FILE *freopen(const char *, const char *, FILE *);
FILE *tmpfile(void);
char *tmpnam(char *);
int setvbuf(FILE *, char *, int, size_t);
#define _IONBF 0
#define _IOLBF 1
#define _IOFBF 2
#endif
