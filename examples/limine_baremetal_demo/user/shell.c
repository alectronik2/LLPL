#include "lib/llpl_sys.h"

enum { O_READ = 1, O_WRITE = 2, O_CREATE = 4, O_TRUNC = 8 };

#define LINE_SIZE 256
#define PATH_SIZE 128
#define PS_MAX 64
#define LS_BUFFER_SIZE 2048
#define HISTORY_SIZE 8
#define MAX_STAGES 8

#define RESET   "\x1b[0m"
#define BOLD    "\x1b[1m"
#define RED     "\x1b[31m"
#define GREEN   "\x1b[32m"
#define YELLOW  "\x1b[33m"
#define BLUE    "\x1b[34m"
#define CYAN    "\x1b[36m"

struct process_info {
    u64 pid;
    u64 parent_pid;
    u64 thread_count;
    u64 exited;
    char name[64];
};

struct redirect {
    int has_input;
    char input_path[PATH_SIZE];
    int has_output;
    char output_path[PATH_SIZE];
};

static int str_eq(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}

static void write_u64_width(u64 value, u64 width) {
    u64 divisor = 1;
    u64 digits = 1;
    while (value / divisor >= 10) { divisor *= 10; ++digits; }
    while (digits++ < width) write_s(" ");
    write_u64(value);
}

static char *skip_spaces(char *s) {
    while (*s == ' ' || *s == '\t') ++s;
    return s;
}

static char *first_argument(char *line) {
    while (*line && *line != ' ' && *line != '\t') ++line;
    if (*line) *line++ = 0;
    return skip_spaces(line);
}

static int contains_pipe_or_redirect(const char *s) {
    while (*s) {
        if (*s == '|' || *s == '<' || *s == '>') return 1;
        ++s;
    }
    return 0;
}

// Splits `line` in place on '|' into up to MAX_STAGES stage strings
// (trimmed of surrounding whitespace), returning the stage count.
static int split_pipeline(char *line, char *stages[MAX_STAGES]) {
    int count = 0;
    char *cursor = line;
    for (;;) {
        stages[count] = skip_spaces(cursor);
        char *bar = stages[count];
        while (*bar && *bar != '|') ++bar;
        int more = (*bar == '|');
        if (more) *bar = 0;
        char *tail = stages[count] + str_len(stages[count]);
        while (tail > stages[count] && (tail[-1] == ' ' || tail[-1] == '\t'))
            *--tail = 0;
        ++count;
        if (!more || count == MAX_STAGES) break;
        cursor = bar + 1;
    }
    return count;
}

// Pulls "< path" / "> path" tokens out of `stage`, recording them into `r`,
// and rebuilds whatever tokens remain (the command and its own arguments)
// into `out`.
static void extract_redirects(const char *stage, char *out, u64 out_capacity,
                              struct redirect *r) {
    r->has_input = 0;
    r->has_output = 0;
    const char *p = stage;
    u64 out_len = 0;
    int first = 1;
    for (;;) {
        while (*p == ' ' || *p == '\t') ++p;
        if (!*p) break;
        if (*p == '<' || *p == '>') {
            int is_output = (*p == '>');
            ++p;
            while (*p == ' ' || *p == '\t') ++p;
            char *target = is_output ? r->output_path : r->input_path;
            u64 n = 0;
            while (*p && *p != ' ' && *p != '\t' && n + 1 < PATH_SIZE)
                target[n++] = *p++;
            target[n] = 0;
            if (is_output) r->has_output = 1; else r->has_input = 1;
            continue;
        }
        if (!first && out_len + 1 < out_capacity) out[out_len++] = ' ';
        first = 0;
        while (*p && *p != ' ' && *p != '\t') {
            if (out_len + 1 < out_capacity) out[out_len++] = *p;
            ++p;
        }
    }
    out[out_len] = 0;
}

static void cat_file(const char *path) {
    i64 fd = (i64)call2(SYS_OPEN, (u64)path, O_READ);
    if (fd < 0) {
        write_s(RED "cat: cannot open " RESET);
        write_s(path);
        write_s("\n");
        return;
    }
    char buffer[128];
    for (;;) {
        i64 got = (i64)call3(SYS_FD_READ, (u64)fd, (u64)buffer,
                             sizeof(buffer));
        if (got <= 0) break;
        write_n(buffer, (u64)got);
    }
    call2(SYS_CLOSE, (u64)fd, 0);
}

static void list_processes(void) {
    struct process_info entries[PS_MAX];
    i64 count = (i64)call2(SYS_PROCESS_SNAPSHOT, (u64)entries, PS_MAX);
    if (count < 0) {
        write_s(RED "ps: unable to read process table\n" RESET);
        return;
    }
    for (i64 i = 1; i < count; ++i) {
        struct process_info item = entries[i];
        i64 j = i;
        while (j > 0 && entries[j - 1].pid > item.pid) {
            entries[j] = entries[j - 1];
            --j;
        }
        entries[j] = item;
    }
    write_s(BOLD CYAN "  PID  PPID  THR  STATE    NAME\n" RESET);
    for (i64 i = 0; i < count; ++i) {
        write_s(GREEN); write_u64_width(entries[i].pid, 5); write_s(RESET " ");
        write_u64_width(entries[i].parent_pid, 5); write_s(" ");
        write_u64_width(entries[i].thread_count, 4); write_s("  ");
        write_s(entries[i].exited ? RED "exited   " RESET : GREEN "running  " RESET);
        write_s(BLUE); write_s(entries[i].name); write_s(RESET "\n");
    }
}

static void list_directory(const char *path) {
    char listing[LS_BUFFER_SIZE];
    i64 length = (i64)call3(SYS_LIST_DIRECTORY, (u64)path,
                            (u64)listing, sizeof(listing));
    if (length < 0) {
        write_s(RED "ls: cannot access " RESET);
        write_s(path);
        write_s("\n");
        return;
    }
    if (length == 0) {
        write_s(YELLOW "(empty)\n" RESET);
        return;
    }

    u64 start = 0;
    for (u64 i = 0; i <= (u64)length; ++i) {
        if (i != (u64)length && listing[i] != '\n') continue;
        if (i > start) {
            int directory = listing[i - 1] == '/';
            write_s(directory ? BOLD BLUE : CYAN);
            write_n(listing + start, i - start);
            write_s(RESET "\n");
        }
        start = i + 1;
    }
}

static void change_directory(const char *path) {
    if ((i64)call2(SYS_CHDIR, (u64)path, 0) < 0) {
        write_s(RED "cd: no such directory: " RESET);
        write_s(path);
        write_s("\n");
    }
}

static void copy_string(char *destination, const char *source, u64 capacity) {
    u64 i = 0;
    while (source[i] && i + 1 < capacity) {
        destination[i] = source[i];
        ++i;
    }
    destination[i] = 0;
}

static void write_prompt(const char *cwd) {
    write_s(BOLD GREEN "user" RESET ":" BLUE);
    write_s(cwd);
    write_s(RESET "$ ");
}

static void redraw_line(const char *cwd, const char *line, u64 length,
                        u64 cursor) {
    write_s("\r\x1b[2K");
    write_prompt(cwd);
    write_n(line, length);
    write_s("\r");
    write_prompt(cwd);
    write_n(line, cursor);
}

// Tries `command`/`args` as one of the built-ins execute() already knows
// (everything except "exit", which only makes sense as a whole-line,
// shell-terminating command, not something composable in a pipeline).
// Returns 1 if handled. Built-ins print via write_s, which now goes
// through fd 1 (hal/syscall.llpl's SYS_WRITE handler) - so a caller that
// wraps this in a dup2 redirect (run_pipeline below) redirects a
// built-in's output exactly the same way it redirects a spawned program's.
static int run_builtin(char *command, char *args) {
    if (str_eq(command, "help")) {
        write_s(BOLD CYAN "Built-ins\n" RESET
                GREEN "  help echo cat ls cd clear pid ps exit\n" RESET
                "Run initrd programs by name, for example: " YELLOW "child\n" RESET);
    } else if (str_eq(command, "echo")) {
        write_s(args);
        write_s("\n");
    } else if (str_eq(command, "cat")) {
        if (*args) cat_file(args); else write_s("usage: cat PATH\n");
    } else if (str_eq(command, "ls")) {
        list_directory(*args ? args : ".");
    } else if (str_eq(command, "cd")) {
        change_directory(*args ? args : "/");
    } else if (str_eq(command, "clear")) {
        write_s("\x1b[2J\x1b[H");
    } else if (str_eq(command, "pid")) {
        write_s(CYAN);
        write_u64(call2(SYS_GETPID, 0, 0));
        write_s(RESET "\n");
    } else if (str_eq(command, "ps")) {
        list_processes();
    } else {
        return 0;
    }
    return 1;
}

// Resolves `command` to an initrd path and spawns it with `command_line`
// as its NT-style command line. Returns the pid, or -1 ("command not
// found" already reported).
static i64 resolve_and_spawn(const char *command, const char *command_line) {
    char path[PATH_SIZE];
    u64 at = 0;
    if (command[0] != '/') {
        const char prefix[] = "/bin/";
        for (u64 i = 0; i < sizeof(prefix) - 1; ++i) path[at++] = prefix[i];
    }
    for (u64 i = 0; command[i] && at + 1 < sizeof(path); ++i)
        path[at++] = command[i];
    path[at] = 0;

    i64 pid = (i64)call2(SYS_SPAWN, (u64)path, (u64)command_line);
    if (pid < 0) {
        write_s(RED);
        write_s(command);
        write_s(": command not found\n" RESET);
    }
    return pid;
}

static void run_program(const char *command, const char *command_line) {
    i64 pid = resolve_and_spawn(command, command_line);
    if (pid < 0) return;
    u64 status = 0;
    if ((i64)call2(SYS_WAITPID, (u64)pid, (u64)&status) < 0) {
        write_s(RED "shell: wait failed\n" RESET);
        return;
    }
    if (status != 0) {
        write_s(YELLOW "[exit ");
        write_u64(status);
        write_s("]\n" RESET);
    }
}

// One pipeline stage: run as a built-in if the name matches one, else
// spawn it. Returns a pid to wait on, or -2 (a built-in already ran
// synchronously - nothing to wait for) or -1 (spawn failed, already
// reported).
#define STAGE_BUILTIN -2

static i64 run_stage(char *command, char *args) {
    if (run_builtin(command, args)) return STAGE_BUILTIN;
    char command_line[LINE_SIZE];
    copy_string(command_line, command, sizeof(command_line));
    if (*args) {
        u64 n = str_len(command_line);
        if (n + 1 < sizeof(command_line)) command_line[n++] = ' ';
        copy_string(command_line + n, args, sizeof(command_line) - n);
    }
    return resolve_and_spawn(command, command_line);
}

// Runs a '|'-separated pipeline (each stage optionally carrying its own
// '<'/'>' redirect). There's no fork() here - SYS_SPAWN loads and clones
// the parent's fd table in one step - so redirection works by briefly
// retargeting the shell's own fd 0/1 immediately before each stage (spawn
// or built-in) and restoring them right after. Closing the shell's own
// copy of each pipe end as soon as the stage that needed it has been
// started is what lets Kern.Pipe's writer/reader-count EOF logic
// (kern/handle.llpl) work at all.
static void run_pipeline(char *line) {
    char *stage_text[MAX_STAGES];
    int stage_count = split_pipeline(line, stage_text);

    char stage_line[MAX_STAGES][LINE_SIZE];
    struct redirect stage_redirect[MAX_STAGES];
    for (int i = 0; i < stage_count; ++i)
        extract_redirects(stage_text[i], stage_line[i], LINE_SIZE, &stage_redirect[i]);

    i64 pids[MAX_STAGES];
    i64 prev_read_fd = -1;

    for (int i = 0; i < stage_count; ++i) {
        int is_last = (i == stage_count - 1);
        i64 pipe_fds[2];
        pipe_fds[0] = -1;
        pipe_fds[1] = -1;
        if (!is_last && (i64)call2(SYS_PIPE, (u64)pipe_fds, 0) < 0) {
            write_s(RED "shell: pipe failed\n" RESET);
            pids[i] = -1;
            if (prev_read_fd >= 0) { call2(SYS_CLOSE, (u64)prev_read_fd, 0); prev_read_fd = -1; }
            continue;
        }

        i64 saved_stdin = -1, saved_stdout = -1;
        i64 input_fd = -1, output_fd = -1;

        if (prev_read_fd >= 0) {
            saved_stdin = (i64)call2(SYS_DUP, 0, 0);
            call2(SYS_DUP2, (u64)prev_read_fd, 0);
        } else if (stage_redirect[i].has_input) {
            input_fd = (i64)call2(SYS_OPEN, (u64)stage_redirect[i].input_path, O_READ);
            if (input_fd < 0) {
                write_s(RED "shell: cannot open " RESET);
                write_s(stage_redirect[i].input_path);
                write_s("\n");
            } else {
                saved_stdin = (i64)call2(SYS_DUP, 0, 0);
                call2(SYS_DUP2, (u64)input_fd, 0);
            }
        }

        if (!is_last) {
            saved_stdout = (i64)call2(SYS_DUP, 1, 0);
            call2(SYS_DUP2, (u64)pipe_fds[1], 1);
        } else if (stage_redirect[i].has_output) {
            output_fd = (i64)call2(SYS_OPEN, (u64)stage_redirect[i].output_path,
                                   O_WRITE | O_CREATE | O_TRUNC);
            if (output_fd < 0) {
                write_s(RED "shell: cannot open " RESET);
                write_s(stage_redirect[i].output_path);
                write_s("\n");
            } else {
                saved_stdout = (i64)call2(SYS_DUP, 1, 0);
                call2(SYS_DUP2, (u64)output_fd, 1);
            }
        }

        char *args = first_argument(stage_line[i]);
        pids[i] = run_stage(stage_line[i], args);

        if (saved_stdin >= 0) { call2(SYS_DUP2, (u64)saved_stdin, 0); call2(SYS_CLOSE, (u64)saved_stdin, 0); }
        if (saved_stdout >= 0) { call2(SYS_DUP2, (u64)saved_stdout, 1); call2(SYS_CLOSE, (u64)saved_stdout, 0); }
        if (input_fd >= 0) call2(SYS_CLOSE, (u64)input_fd, 0);
        if (output_fd >= 0) call2(SYS_CLOSE, (u64)output_fd, 0);
        if (prev_read_fd >= 0) call2(SYS_CLOSE, (u64)prev_read_fd, 0);
        if (!is_last) {
            call2(SYS_CLOSE, (u64)pipe_fds[1], 0);
            prev_read_fd = pipe_fds[0];
        } else {
            prev_read_fd = -1;
        }
    }

    for (int i = 0; i < stage_count; ++i) {
        if (pids[i] < 0) continue;
        u64 status = 0;
        i64 waited = (i64)call2(SYS_WAITPID, (u64)pids[i], (u64)&status);
        if (i == stage_count - 1 && waited >= 0 && status != 0) {
            write_s(YELLOW "[exit ");
            write_u64(status);
            write_s("]\n" RESET);
        }
    }
}

static int execute(char *line) {
    char original[LINE_SIZE];
    u64 i = 0;
    for (; line[i] && i + 1 < sizeof(original); ++i) original[i] = line[i];
    original[i] = 0;

    if (!line[0]) return 1;
    if (contains_pipe_or_redirect(original)) {
        run_pipeline(original);
        return 1;
    }

    char *args = first_argument(line);
    if (str_eq(line, "exit")) {
        return 0;
    } else if (!run_builtin(line, args)) {
        run_program(line, original);
    }
    return 1;
}

__attribute__((noreturn)) void _start(void) {
    i64 keyboard = (i64)call2(SYS_OPEN, (u64)"/dev/kbd", O_READ);
    if (keyboard < 0) {
        write_s("shell: cannot open /dev/kbd\n");
        call2(SYS_EXIT, 1, 0);
    }

    write_s("\n" BOLD CYAN "DimensionOS" RESET " user shell\n"
            "Type " YELLOW "help" RESET " for commands.\n");
    char line[LINE_SIZE];
    char history[HISTORY_SIZE][LINE_SIZE];
    u64 history_count = 0;
    u64 history_position = 0;
    char saved_line[LINE_SIZE];
    u64 length = 0;
    for (;;) {
        char cwd[PATH_SIZE];
        if ((i64)call2(SYS_GETCWD, (u64)cwd, sizeof(cwd)) < 0) {
            cwd[0] = '/'; cwd[1] = 0;
        }
        write_prompt(cwd);
        length = 0;
        u64 cursor = 0;
        history_position = history_count;
        saved_line[0] = 0;
        for (;;) {
            char c = 0;
            if ((i64)call3(SYS_FD_READ, (u64)keyboard, (u64)&c, 1) != 1)
                continue;
            if (c == '\r' || c == '\n') {
                write_s("\n");
                line[length] = 0;
                break;
            }
            if ((unsigned char)c == 27) {
                char bracket = 0, key = 0;
                if ((i64)call3(SYS_FD_READ, (u64)keyboard, (u64)&bracket, 1) != 1 ||
                    bracket != '[' ||
                    (i64)call3(SYS_FD_READ, (u64)keyboard, (u64)&key, 1) != 1)
                    continue;
                if (key == '3') {
                    char tilde = 0;
                    call3(SYS_FD_READ, (u64)keyboard, (u64)&tilde, 1);
                    if (cursor < length) {
                        for (u64 i = cursor; i < length; ++i) line[i] = line[i + 1];
                        --length;
                        redraw_line(cwd, line, length, cursor);
                    }
                } else if (key == 'D' && cursor > 0) {
                    --cursor; redraw_line(cwd, line, length, cursor);
                } else if (key == 'C' && cursor < length) {
                    ++cursor; redraw_line(cwd, line, length, cursor);
                } else if (key == 'H') {
                    cursor = 0; redraw_line(cwd, line, length, cursor);
                } else if (key == 'F') {
                    cursor = length; redraw_line(cwd, line, length, cursor);
                } else if (key == 'A' && history_position > 0) {
                    if (history_position == history_count) {
                        line[length] = 0;
                        copy_string(saved_line, line, sizeof(saved_line));
                    }
                    --history_position;
                    copy_string(line, history[history_position], sizeof(line));
                    length = cursor = str_len(line);
                    redraw_line(cwd, line, length, cursor);
                } else if (key == 'B' && history_position < history_count) {
                    ++history_position;
                    if (history_position == history_count)
                        copy_string(line, saved_line, sizeof(line));
                    else
                        copy_string(line, history[history_position], sizeof(line));
                    length = cursor = str_len(line);
                    redraw_line(cwd, line, length, cursor);
                }
                continue;
            }
            if (c == '\b') {
                if (cursor) {
                    for (u64 i = cursor - 1; i < length; ++i) line[i] = line[i + 1];
                    --length;
                    --cursor;
                    redraw_line(cwd, line, length, cursor);
                }
                continue;
            }
            if (c >= ' ' && c <= '~' && length + 1 < sizeof(line)) {
                for (u64 i = length; i > cursor; --i) line[i] = line[i - 1];
                line[cursor++] = c;
                ++length;
                line[length] = 0;
                redraw_line(cwd, line, length, cursor);
            }
        }
        if (length && (history_count == 0 ||
            !str_eq(line, history[history_count - 1]))) {
            if (history_count == HISTORY_SIZE) {
                for (u64 i = 1; i < HISTORY_SIZE; ++i)
                    copy_string(history[i - 1], history[i], LINE_SIZE);
                --history_count;
            }
            copy_string(history[history_count++], line, LINE_SIZE);
        }
        if (!execute(skip_spaces(line))) break;
    }
    call2(SYS_CLOSE, (u64)keyboard, 0);
    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
