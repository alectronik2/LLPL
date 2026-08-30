#include "llpl_sys.h"

#define MAX_ARGS 32
#define ARGS_BUF_SIZE 256

static char args_storage[ARGS_BUF_SIZE];
static char *args_argv[MAX_ARGS];
static u64 args_argc = 0;

// Splits the raw, space-separated command line (SYS_GET_COMMAND_LINE) into
// argc/argv - the kernel hands back one joined string, not a pre-split
// array, so every program that wants argv has to do this itself.
void parse_args(void) {
    u64 got = call2(SYS_GET_COMMAND_LINE, (u64)args_storage, ARGS_BUF_SIZE);
    args_argc = 0;
    u64 i = 0;
    while (i < got && args_argc < MAX_ARGS) {
        while (i < got && args_storage[i] == ' ') i++;
        if (i >= got) break;
        args_argv[args_argc++] = &args_storage[i];
        while (i < got && args_storage[i] != ' ') i++;
        if (i < got) args_storage[i++] = 0;
    }
}

u64 argc(void) {
    return args_argc;
}

char *arg_at(u64 i) {
    return i < args_argc ? args_argv[i] : "";
}
