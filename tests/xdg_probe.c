/* SPDX-License-Identifier: BSD-3-Clause
 * Real xdg-shell/shm client: three windows, a transient and fullscreen roundtrip.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

struct window {
    struct wl_surface *surface;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    int width, height, index, configured;
    bool fullscreen;
};
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *base;
static struct window windows[3];
static int failed, stage;
static double action_time;
static bool parent_set;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}
static void released(void *data, struct wl_buffer *buffer) {
    (void)data;
    wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = { .release = released };

static void draw(struct window *window) {
    int width = window->width, height = window->height;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
        fprintf(stderr, "invalid configure size %dx%d\n", width, height);
        failed = 1;
        return;
    }
    char path[] = "/tmp/xmonad-way-shm-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) { perror("mkstemp"); failed = 1; return; }
    unlink(path);
    size_t size = (size_t)width * height * 4;
    if (ftruncate(fd, (off_t)size) < 0) {
        perror("ftruncate"); close(fd); failed = 1; return;
    }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { perror("mmap"); close(fd); failed = 1; return; }
    for (size_t i = 0; i < size / 4; i++)
        pixels[i] = 0xff304050u + 0x00202020u * (unsigned)window->index;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
                                                        width * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_shm_pool_destroy(pool);
    close(fd);
    munmap(pixels, size);
    wl_surface_attach(window->surface, buffer, 0, 0);
    wl_surface_damage(window->surface, 0, 0, width, height);
    wl_surface_commit(window->surface);
}
static void surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct window *window = data;
    xdg_surface_ack_configure(surface, serial);
    draw(window);
    window->configured++;
    printf("configure window=%d size=%dx%d fullscreen=%d count=%d\n",
           window->index, window->width, window->height, window->fullscreen,
           window->configured);
    fflush(stdout);
    if (window->index == 2 && stage == 1 && window->fullscreen) {
        stage = 2;
        action_time = now();
    } else if (window->index == 2 && stage == 3 && !window->fullscreen) {
        stage = 4;
    }
}
static const struct xdg_surface_listener surface_listener = { .configure = surface_configure };
static void top_configure(void *data, struct xdg_toplevel *top,
                          int32_t width, int32_t height, struct wl_array *states) {
    (void)top;
    struct window *window = data;
    if (width > 0) window->width = width;
    if (height > 0) window->height = height;
    window->fullscreen = false;
    uint32_t *state;
    wl_array_for_each(state, states)
        if (*state == XDG_TOPLEVEL_STATE_FULLSCREEN) window->fullscreen = true;
}
static void top_close(void *data, struct xdg_toplevel *top) {
    (void)data; (void)top;
    fprintf(stderr, "unexpected close\n"); failed = 1;
}
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close
};
static void ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data; xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener base_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "xdg_wm_base")) {
        base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(base, &base_listener, NULL);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_remove
};
int main(void) {
    display = wl_display_connect(NULL);
    if (!display) { perror("wl_display_connect"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !base) {
        fprintf(stderr, "missing xdg-shell/shm globals\n"); return 1;
    }
    for (int i = 0; i < 3; i++) {
        struct window *window = &windows[i];
        window->index = i;
        window->width = i == 2 ? 320 : 480;
        window->height = i == 2 ? 200 : 320;
        window->surface = wl_compositor_create_surface(compositor);
        window->xdg = xdg_wm_base_get_xdg_surface(base, window->surface);
        xdg_surface_add_listener(window->xdg, &surface_listener, window);
        window->top = xdg_surface_get_toplevel(window->xdg);
        xdg_toplevel_add_listener(window->top, &top_listener, window);
        xdg_toplevel_set_title(window->top, "XMonad Wayland real compositor probe");
        xdg_toplevel_set_app_id(window->top, "org.xmonad.wayland.Probe");
        if (i == 2) {
            xdg_toplevel_set_min_size(window->top, 320, 200);
            xdg_toplevel_set_max_size(window->top, 320, 200);
        }
        wl_surface_commit(window->surface);
    }
    double deadline = now() + 15.0;
    while (!failed && now() < deadline && stage != 4) {
        if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
        if (!parent_set && windows[0].configured && windows[1].configured
            && windows[2].configured) {
            /* xdg-shell discards a parent that is not mapped. Ensure the
             * acknowledged configure/buffer commits reached the compositor. */
            if (wl_display_roundtrip(display) < 0) break;
            xdg_toplevel_set_parent(windows[2].top, windows[0].top);
            wl_surface_commit(windows[2].surface);
            parent_set = true;
            action_time = now();
        } else if (stage == 0 && parent_set && now() - action_time > 0.2) {
            if (windows[2].width != 320 || windows[2].height != 200) {
                fprintf(stderr, "fixed-size dialog was not respected\n"); failed = 1; break;
            }
            puts("request fullscreen");
            stage = 1;
            xdg_toplevel_set_fullscreen(windows[2].top, NULL);
        } else if (stage == 2 && now() - action_time > 0.2) {
            puts("request unfullscreen");
            stage = 3;
            xdg_toplevel_unset_fullscreen(windows[2].top);
        }
        wl_display_flush(display);
        struct pollfd fd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        int ready = poll(&fd, 1, 50);
        if (ready < 0 && errno != EINTR) break;
        if (ready > 0 && wl_display_dispatch(display) < 0) break;
    }
    if (stage != 4 || failed || wl_display_get_error(display)) {
        fprintf(stderr, "FAIL: real compositor scenario stage=%d error=%d\n", stage,
                wl_display_get_error(display));
        return 1;
    }
    for (int i = 2; i >= 0; i--) {
        xdg_toplevel_destroy(windows[i].top);
        xdg_surface_destroy(windows[i].xdg);
        wl_surface_destroy(windows[i].surface);
    }
    if (wl_display_roundtrip(display) < 0) return 1;
    wl_display_disconnect(display);
    puts("PASS: three mapped xdg windows, fixed transient, fullscreen enter/exit and destroy");
    return 0;
}
