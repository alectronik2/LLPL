#include "lib/llpl_sys.h"
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "tinygl/include/GL/gl.h"
#include "tinygl/include/zbuffer.h"

// Renders into a named shared-memory segment (kern/mu_gl.llpl reads it
// directly from kernel code via the physical frames' HHDM mapping - see
// that file's own header comment for why this lives in userspace at all
// rather than linking TinyGL into the kernel: this kernel deliberately
// runs with FP/SSE state untracked across kernel-thread context switches,
// and TinyGL is FP-heavy throughout, so keeping it a normal user process
// (where FP context save/restore is already exercised and proven, e.g.
// by the Lua self-tests) sidesteps that question entirely) instead of the
// real framebuffer - this process no longer has, or needs, a console of
// its own.
#define WIDTH 320
#define HEIGHT 240
#define SHM_NAME "tinygl-frame"

static void cube(void) {
    glBegin(GL_QUADS);
    glColor3f(0.95f, 0.25f, 0.20f); glVertex3f(-1,-1, 1); glVertex3f( 1,-1, 1); glVertex3f( 1, 1, 1); glVertex3f(-1, 1, 1);
    glColor3f(0.20f, 0.75f, 0.95f); glVertex3f( 1,-1,-1); glVertex3f(-1,-1,-1); glVertex3f(-1, 1,-1); glVertex3f( 1, 1,-1);
    glColor3f(0.35f, 0.90f, 0.35f); glVertex3f(-1,-1,-1); glVertex3f(-1,-1, 1); glVertex3f(-1, 1, 1); glVertex3f(-1, 1,-1);
    glColor3f(0.95f, 0.75f, 0.20f); glVertex3f( 1,-1, 1); glVertex3f( 1,-1,-1); glVertex3f( 1, 1,-1); glVertex3f( 1, 1, 1);
    glColor3f(0.75f, 0.35f, 0.95f); glVertex3f(-1, 1, 1); glVertex3f( 1, 1, 1); glVertex3f( 1, 1,-1); glVertex3f(-1, 1,-1);
    glColor3f(0.20f, 0.90f, 0.75f); glVertex3f(-1,-1,-1); glVertex3f( 1,-1,-1); glVertex3f( 1,-1, 1); glVertex3f(-1,-1, 1);
    glEnd();
}

__attribute__((noreturn)) void _start(void) {
    i64 addr = (i64)call2(SYS_SHM_CREATE, (u64)SHM_NAME, WIDTH * HEIGHT * sizeof(uint32_t));
    if (addr < 0) {
        write_s("tinygl: shm_create failed\n");
        call2(SYS_EXIT, 1, 0);
    }
    uint32_t *pixels = (uint32_t *)(u64)addr;

    ZBuffer *zb = ZB_open(WIDTH, HEIGHT, ZB_MODE_RGBA, pixels);
    if (!zb) {
        write_s("tinygl: ZB_open failed\n");
        call2(SYS_EXIT, 1, 0);
    }

    glInit(zb);
    glViewport(0, 0, WIDTH, HEIGHT);
    glEnable(GL_DEPTH_TEST);
    glShadeModel(GL_SMOOTH);
    glClearColor(0.025f, 0.035f, 0.065f, 1.0f);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glFrustum(-1.333, 1.333, -1.0, 1.0, 2.0, 20.0);

    float angle = 0.0f;
    for (;;) {
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        glTranslatef(0.0f, 0.0f, -5.0f);
        glRotatef(angle, 1.0f, 0.0f, 0.0f);
        glRotatef(angle * 0.73f, 0.0f, 1.0f, 0.0f);
        cube();
        angle += 1.5f;
        u64 until = call1(SYS_MONOTONIC_MS, 0) + 33;
        while (call1(SYS_MONOTONIC_MS, 0) < until) __asm__ volatile("pause");
    }
}
