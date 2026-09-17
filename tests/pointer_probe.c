/* SPDX-License-Identifier: BSD-3-Clause
 * Isolated real pointer probe: xdg transient, virtual pointer and keyboard.
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
#include "wlr-virtual-pointer-client-protocol.h"
#include "virtual-keyboard-client-protocol.h"
#include <xkbcommon/xkbcommon.h>

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
static struct window windows[2];
static int failed, stage;
static bool parent_set;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zwlr_virtual_pointer_v1 *virtual_pointer;
static struct zwp_virtual_keyboard_v1 *virtual_keyboard;
static int requested_edges = -1;
static uint32_t timestamp;
static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
    struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)serial; (void)surface; (void)x; (void)y;
}
static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
    struct wl_surface *surface) {
    (void)data; (void)p; (void)serial; (void)surface;
}
static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
    wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)time; (void)x; (void)y;
}
static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
    uint32_t time, uint32_t button, uint32_t pressed) {
    (void)data; (void)p; (void)time; (void)button;
    if (pressed && requested_edges >= 0) {
        if (requested_edges) xdg_toplevel_resize(windows[1].top, seat, serial, (uint32_t)requested_edges);
        else xdg_toplevel_move(windows[1].top, seat, serial);
        printf("CSD request edges=%d serial=%u\n", requested_edges, serial);
        requested_edges = -1;
    }
}
static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
    uint32_t axis, wl_fixed_t value) {
    (void)data; (void)p; (void)time; (void)axis; (void)value;
}
static const struct wl_pointer_listener pointer_listener = {
    .enter=pointer_enter, .leave=pointer_leave, .motion=pointer_motion,
    .button=pointer_button, .axis=pointer_axis
};
static void seat_capabilities(void *data, struct wl_seat *s, uint32_t capabilities) {
    (void)data;
    if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
}
static const struct wl_seat_listener seat_listener = {.capabilities=seat_capabilities};

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
    if (!strcmp(interface, "wl_seat")) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
        pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
        keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (!strcmp(interface, "wl_compositor"))
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
static int setup_input(void) {
    virtual_pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, seat);
    virtual_keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) return 1;
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!text) return 1;
    size_t length = strlen(text) + 1;
    char path[] = "/tmp/xw-pointer-keymap-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 1;
    unlink(path);
    if (write(fd, text, length) != (ssize_t)length) return 1;
    zwp_virtual_keyboard_v1_keymap(virtual_keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)length);
    close(fd); free(text); xkb_keymap_unref(keymap); xkb_context_unref(context);
    return 0;
}
static void command(char *line) {
    unsigned a, b, c, d, e;
    double dx, dy;
    if (sscanf(line, "press_at %u %u %u %u %u", &a, &b, &c, &d, &e) == 5) {
        zwlr_virtual_pointer_v1_motion_absolute(virtual_pointer, ++timestamp, a, b, c, d);
        zwlr_virtual_pointer_v1_button(virtual_pointer, ++timestamp, e, 1);
    } else if (sscanf(line, "absolute %u %u %u %u", &a, &b, &c, &d) == 4)
        zwlr_virtual_pointer_v1_motion_absolute(virtual_pointer, ++timestamp, a, b, c, d);
    else if (sscanf(line, "motion %lf %lf", &dx, &dy) == 2)
        zwlr_virtual_pointer_v1_motion(virtual_pointer, ++timestamp, wl_fixed_from_double(dx), wl_fixed_from_double(dy));
    else if (sscanf(line, "mods %u", &a) == 1)
        zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, a, 0, 0, 0);
    else if (sscanf(line, "button %u %u", &a, &b) == 2)
        zwlr_virtual_pointer_v1_button(virtual_pointer, ++timestamp, a, b);
    else if (sscanf(line, "tap %u", &a) == 1) {
        zwlr_virtual_pointer_v1_button(virtual_pointer, ++timestamp, a, 1);
        zwlr_virtual_pointer_v1_frame(virtual_pointer);
        zwlr_virtual_pointer_v1_button(virtual_pointer, ++timestamp, a, 0);
    }
    else if (sscanf(line, "csd %u", &a) == 1)
        requested_edges = (int)a;
    else if (!strncmp(line, "quit", 4)) stage = 9;
    else { fprintf(stderr, "invalid command: %s", line); failed = 1; }
    zwlr_virtual_pointer_v1_frame(virtual_pointer);
    printf("command %s", line);
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !compositor || !shm || !base ||
        !seat || !pointer_manager || !keyboard_manager || setup_input()) return 1;
    for (int i = 0; i < 2; i++) {
        struct window *window = &windows[i];
        window->index = i; window->width = 480; window->height = 320;
        window->surface = wl_compositor_create_surface(compositor);
        window->xdg = xdg_wm_base_get_xdg_surface(base, window->surface);
        xdg_surface_add_listener(window->xdg, &surface_listener, window);
        window->top = xdg_surface_get_toplevel(window->xdg);
        xdg_toplevel_add_listener(window->top, &top_listener, window);
        xdg_toplevel_set_title(window->top, i ? "Pointer dialog" : "Pointer parent");
        wl_surface_commit(window->surface);
    }
    double deadline = now() + 45;
    while (!failed && now() < deadline && stage != 9) {
        if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
        if (!parent_set && windows[0].configured && windows[1].configured) {
            if (wl_display_roundtrip(display) < 0) break;
            xdg_toplevel_set_parent(windows[1].top, windows[0].top);
            wl_surface_commit(windows[1].surface);
            parent_set = true;
            puts("READY");
        }
        struct pollfd fds[] = {{.fd=wl_display_get_fd(display), .events=POLLIN}, {.fd=STDIN_FILENO, .events=POLLIN}};
        int ready = poll(fds, 2, 50);
        if (ready < 0 && errno != EINTR) break;
        if (fds[0].revents & POLLIN) if (wl_display_dispatch(display) < 0) break;
        if (fds[1].revents & POLLIN) {
            char line[256];
            if (!fgets(line, sizeof line, stdin)) break;
            command(line);
        }
    }
    if (stage != 9 || failed || wl_display_get_error(display)) return 1;
    zwlr_virtual_pointer_v1_destroy(virtual_pointer);
    zwp_virtual_keyboard_v1_destroy(virtual_keyboard);
    for (int i = 1; i >= 0; --i) {
        xdg_toplevel_destroy(windows[i].top);
        xdg_surface_destroy(windows[i].xdg);
        wl_surface_destroy(windows[i].surface);
    }
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
