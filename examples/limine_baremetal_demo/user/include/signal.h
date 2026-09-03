#ifndef LLPL_SIGNAL_H
#define LLPL_SIGNAL_H
typedef int sig_atomic_t;
typedef void (*sighandler_t)(int);
#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIGINT 2
sighandler_t signal(int, sighandler_t);
#endif
