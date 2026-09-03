#ifndef LLPL_LOCALE_H
#define LLPL_LOCALE_H
struct lconv { char *decimal_point; };
#define LC_ALL 0
#define LC_COLLATE 1
#define LC_CTYPE 2
#define LC_MONETARY 3
#define LC_NUMERIC 4
#define LC_TIME 5
char *setlocale(int, const char *);
struct lconv *localeconv(void);
#endif
