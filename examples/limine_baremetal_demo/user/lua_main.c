#include "lib/llpl_sys.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>

static int report(lua_State *L, int status) {
    if (status != LUA_OK) {
        const char *message = lua_tostring(L, -1);
        fprintf(stderr, "lua: %s\n", message ? message : "unknown error");
        lua_pop(L, 1);
        return 1;
    }
    return 0;
}

static int run_file(lua_State *L, const char *path) {
    int status = luaL_loadfile(L, path);
    if (status == LUA_OK)
        status = lua_pcall(L, 0, LUA_MULTRET, 0);
    return report(L, status);
}

/* /dev/kbd is intentionally a raw character device, so unlike a hosted TTY
   it does not echo or edit input for us. Keep that policy out of libc and do
   the small amount of terminal handling the Lua REPL needs here. */
static char *repl_readline(char *line, u64 capacity) {
    u64 length = 0;
    for (;;) {
        int c = fgetc(stdin);
        if (c == EOF) return length ? line : 0;
        if (c == '\r' || c == '\n') {
            write_s("\n");
            line[length] = 0;
            return line;
        }
        if (c == '\b' || c == 127) {
            if (length != 0) {
                length--;
                write_s("\b \b");
            }
            continue;
        }
        if (c == 27) {  /* discard a basic three-byte arrow-key sequence */
            int bracket = fgetc(stdin);
            if (bracket == '[') (void)fgetc(stdin);
            continue;
        }
        if (c >= 32 && c < 127 && length + 1 < capacity) {
            line[length++] = (char)c;
            write_c((char)c);
        }
    }
}

static int repl(lua_State *L) {
    char line[512];
    write_s("Lua 5.4.9 for DimensionOS\n> ");
    while (repl_readline(line, sizeof(line))) {
        int status = luaL_loadbuffer(L, line, strlen(line), "=stdin");
        if (status == LUA_OK)
            status = lua_pcall(L, 0, LUA_MULTRET, 0);
        report(L, status);
        write_s("> ");
    }
    return 0;
}

__attribute__((noreturn)) void _start(void) {
    parse_args();
    lua_State *L = luaL_newstate();
    if (!L) {
        write_s("lua: cannot create state\n");
        call2(SYS_EXIT, 1, 0);
        __builtin_unreachable();
    }
    luaL_openlibs(L);

    /* SYS_SPAWN callers traditionally pass only arguments, whereas the shell
       includes argv[0] in its reconstructed command line. Accept both ABIs. */
    u64 first = 0;
    if (argc() > 0 && (strcmp(arg_at(0), "lua") == 0 ||
                       strcmp(arg_at(0), "/bin/lua") == 0))
        first = 1;

    int rc;
    if (first >= argc()) {
        rc = repl(L);
    } else if (strcmp(arg_at(first), "-e") == 0 && first + 1 < argc()) {
        int status = luaL_loadstring(L, arg_at(first + 1));
        if (status == LUA_OK) status = lua_pcall(L, 0, LUA_MULTRET, 0);
        rc = report(L, status);
    } else {
        rc = run_file(L, arg_at(first));
    }
    lua_close(L);
    call2(SYS_EXIT, (u64)rc, 0);
    __builtin_unreachable();
}
