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
#define FRAME_BYTES (WIDTH * HEIGHT * sizeof(uint32_t))
// One full page for the ready-flag rather than packing it right after
// frame1: keeps both frames' own byte ranges page-aligned (FRAME_BYTES
// here is already an exact multiple of it), which is what lets
// kern/mu_gl.llpl's pump_frame walk the segment page-by-page via the HHDM
// without needing to handle a sub-page byte offset anywhere.
#define SHM_PAGE_SIZE 4096

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
    // Two full frame buffers plus a one-page ready-flag, instead of a
    // single buffer TinyGL draws into in place: kern/mu_gl.llpl used to
    // read whatever was in that single buffer at whatever moment its own
    // tick happened to run, with nothing stopping it from landing mid-
    // frame (a fresh glClear with only some of the cube's faces drawn so
    // far) - an occasional torn/glitched cube, once acceptable as a rare
    // cosmetic one-tick artifact but not worth the tradeoff once it was
    // actually noticeable. Now this always renders into whichever of the
    // two buffers *isn't* the one last published as complete, and only
    // publishes (flips ready_index) after a frame is fully drawn - the
    // reader always has a completed frame to read no matter when it
    // happens to look.
    i64 addr = (i64)call2(SYS_SHM_CREATE, (u64)SHM_NAME, 2 * FRAME_BYTES + SHM_PAGE_SIZE);
    if (addr < 0) {
        write_s("tinygl: shm_create failed\n");
        call2(SYS_EXIT, 1, 0);
    }
    uint32_t *frame[2];
    frame[0] = (uint32_t *)(u64)addr;
    frame[1] = (uint32_t *)((u64)addr + FRAME_BYTES);
    // volatile: this is the only cross-process signal here, and the
    // compiler must never cache or reorder around it - see the publish
    // site below for why plain store/load (no fence) is enough on x86.
    volatile uint32_t *ready_index = (volatile uint32_t *)((u64)addr + 2 * FRAME_BYTES);
    *ready_index = 0;

    ZBuffer *zb = ZB_open(WIDTH, HEIGHT, ZB_MODE_RGBA, frame[0]);
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
    int draw_index = 1;
    for (;;) {
        // Render into the buffer that ISN'T the one currently published
        // as ready - the reader (kern/mu_gl.llpl) only ever looks at
        // *ready_index, never draw_index, so it can never observe this
        // buffer mid-draw.
        zb->pbuf = frame[draw_index];
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
        glTranslatef(0.0f, 0.0f, -5.0f);
        glRotatef(angle, 1.0f, 0.0f, 0.0f);
        glRotatef(angle * 0.73f, 0.0f, 1.0f, 0.0f);
        cube();
        angle += 1.5f;
        // Publish only now that the frame is completely drawn - x86's own
        // memory ordering (stores from one CPU become visible to others
        // in the order they were issued) is all the guarantee this needs:
        // no reader can see this store before every pixel store above it
        // that landed in the same coherent memory.
        *ready_index = (uint32_t)draw_index;
        draw_index = 1 - draw_index;
        u64 until = call1(SYS_MONOTONIC_MS, 0) + 33;
        while (call1(SYS_MONOTONIC_MS, 0) < until) __asm__ volatile("pause");
    }
}
