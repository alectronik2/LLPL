#ifndef LLPL_SYS_H
#define LLPL_SYS_H

typedef unsigned long u64;
typedef long i64;

enum {
    SYS_WRITE = 1,
    SYS_EXIT = 2,
    SYS_MMAP = 3,
    SYS_OPEN = 4,
    SYS_FD_READ = 5,
    SYS_FD_WRITE = 6,
    SYS_CLOSE = 7,
    SYS_SEEK = 8,
    SYS_GETPID = 9,
    SYS_MUNMAP = 10,
    SYS_MMAP_FILE = 11,
    SYS_MSYNC = 12,
    SYS_SPAWN = 13,
    SYS_EXEC = 14,
    SYS_WAITPID = 15,
    SYS_THREAD_CREATE = 16,
    SYS_THREAD_EXIT = 17,
    SYS_THREAD_JOIN = 18,
    SYS_THREAD_DETACH = 19,
    SYS_GET_TLS = 20,
    SYS_PIPE = 21,
    SYS_DUP = 22,
    SYS_DUP2 = 23,
    SYS_CLOEXEC = 24,
    SYS_BRK = 25,
    SYS_SBRK = 26,
    SYS_SHM_CREATE = 27,
    SYS_SHM_OPEN = 28,
    SYS_SHM_UNLINK = 29,
    SYS_TERMINATE = 30,
    SYS_QUEUE_APC = 31,
    SYS_APC_RETURN = 32,
    SYS_GETTID = 33,
    SYS_SET_EXCEPTION_HANDLER = 34,
    SYS_EXCEPTION_RETURN = 35,
    SYS_CREATE_EVENT = 36,
    SYS_SET_EVENT = 37,
    SYS_RESET_EVENT = 38,
    SYS_WAIT_HANDLE = 39,
    SYS_OPEN_PROCESS = 40,
    SYS_OPEN_THREAD = 41,
    SYS_CREATE_IOCP = 42,
    SYS_GET_QUEUED_COMPLETION = 43,
    SYS_READ_ASYNC = 44,
    SYS_WRITE_ASYNC = 45,
    SYS_CREATE_MUTEX = 46,
    SYS_RELEASE_MUTEX = 47,
    SYS_CREATE_SEMAPHORE = 48,
    SYS_RELEASE_SEMAPHORE = 49,
    SYS_GET_COMMAND_LINE = 50,
    SYS_PROCESS_SNAPSHOT = 51,
    SYS_LIST_DIRECTORY = 52,
    SYS_CHDIR = 53,
    SYS_GETCWD = 54,
    SYS_SET_FOREGROUND = 55,
    SYS_MONOTONIC_MS = 65,
    SYS_MQ_CREATE = 66,
    SYS_MQ_OPEN = 67,
    SYS_MQ_UNLINK = 68,
    SYS_MQ_SEND = 69,
    SYS_MQ_RECEIVE = 70,
    SYS_FB_INFO = 71,
    SYS_FB_PRESENT = 72
    ,SYS_UNLINK = 73,
    SYS_MKDIR = 74,
    SYS_TOUCH = 75
};

struct llpl_framebuffer_info { u64 width, height, pitch, format; };

u64 call1(u64 n, u64 a);
u64 call2(u64 n, u64 a, u64 b);
u64 call3(u64 n, u64 a, u64 b, u64 c);
u64 call4(u64 n, u64 a, u64 b, u64 c, u64 d);

u64 str_len(const char *s);
void write_n(const char *s, u64 n);
void write_c(char c);
void write_s(const char *s);
void write_i64(i64 value);
void write_u64(u64 value);

void *malloc(u64 size);
void free(void *ptr);
void *calloc(u64 nmemb, u64 size);
void *realloc(void *ptr, u64 size);

void parse_args(void);
u64 argc(void);
char *arg_at(u64 i);

#endif
