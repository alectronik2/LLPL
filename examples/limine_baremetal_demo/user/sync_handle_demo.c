#include "lib/llpl_sys.h"

static void spin(u64 iterations) {
    for (volatile u64 i = 0; i < iterations; i++) { }
}

static volatile u64 mutex_fd;
static volatile int main_has_released_mutex = 0;
static volatile int mutex_waiter_woke_early = 0;

void mutex_holder_thread_entry(void *arg) {
    write_s("sync_handle_demo: holder thread acquiring mutex\n");
    call1(SYS_WAIT_HANDLE, mutex_fd);
    write_s("sync_handle_demo: holder thread holding mutex\n");
    spin(3000000);
    main_has_released_mutex = 1;
    call1(SYS_RELEASE_MUTEX, mutex_fd);
    write_s("sync_handle_demo: holder thread released mutex\n");
    call2(SYS_THREAD_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}

static volatile u64 sem_fd;
static volatile int main_has_posted_sem = 0;
static volatile int sem_waiter_woke_early = 0;

void sem_waiter_thread_entry(void *arg) {
    write_s("sync_handle_demo: sem waiter thread blocking\n");
    call1(SYS_WAIT_HANDLE, sem_fd);
    if (!main_has_posted_sem) {
        sem_waiter_woke_early = 1;
    }
    write_s("sync_handle_demo: sem waiter thread woke up\n");
    call2(SYS_THREAD_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}

__attribute__((noreturn)) void _start(void) {
    write_s("sync_handle_demo: creating mutex\n");
    mutex_fd = call1(SYS_CREATE_MUTEX, 0); // not initially owned

    write_s("sync_handle_demo: spawning holder thread\n");
    u64 holder_tid = call3(SYS_THREAD_CREATE, (u64)mutex_holder_thread_entry, 0, 0);

    // Give the holder thread time to actually acquire the mutex before we
    // also try to wait on it, so our own wait is guaranteed to block.
    spin(3000000);
    write_s("sync_handle_demo: main thread waiting on mutex\n");
    call1(SYS_WAIT_HANDLE, mutex_fd);
    if (!main_has_released_mutex) {
        mutex_waiter_woke_early = 1;
    }
    write_s("sync_handle_demo: main thread acquired mutex\n");
    call1(SYS_RELEASE_MUTEX, mutex_fd);
    call2(SYS_THREAD_JOIN, holder_tid, 0);

    write_s("sync_handle_demo: creating semaphore\n");
    sem_fd = call1(SYS_CREATE_SEMAPHORE, 0); // initial count 0

    write_s("sync_handle_demo: spawning sem waiter thread\n");
    u64 sem_tid = call3(SYS_THREAD_CREATE, (u64)sem_waiter_thread_entry, 0, 0);

    // Give the waiter thread time to actually reach SYS_WAIT_HANDLE and
    // block before we post, so a premature wake would be visible.
    spin(3000000);
    write_s("sync_handle_demo: posting semaphore\n");
    main_has_posted_sem = 1;
    call2(SYS_RELEASE_SEMAPHORE, sem_fd, 1);

    call2(SYS_THREAD_JOIN, sem_tid, 0);

    if (mutex_waiter_woke_early || sem_waiter_woke_early) {
        write_s("Sync handle self-test: FAIL\n");
    } else {
        write_s("Sync handle self-test: PASS\n");
    }

    call2(SYS_EXIT, 0, 0);
    for (;;) __asm__ volatile("pause");
}
