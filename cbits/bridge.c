/* SPDX-License-Identifier: BSD-3-Clause
 * River v1 protocol transport; all policy belongs to Haskell.
 * Only the oldest live seat has bindings/focus. Additional seats are retained
 * for correct protocol lifetimes, but independent multiseat is unsupported.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "bridge.h"
#include "river-window-management-v1-client-protocol.h"
#include "river-xkb-bindings-v1-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

enum phase { PHASE_IDLE, PHASE_MANAGE, PHASE_RENDER };

struct window {
    struct window *next;
    struct river_window_v1 *proxy;
    struct river_node_v1 *node;
    uint32_t id;
    bool announced, closed, configured, visible, focused;
    int32_t x, y, width, height, border, actual_width, actual_height;
};

struct output {
    struct output *next;
    struct river_output_v1 *proxy;
    uint32_t id;
    bool announced, removed, dirty, has_position, has_dimensions;
    int32_t x, y, width, height;
};

struct seat;
struct binding {
    struct binding *next;
    struct river_xkb_binding_v1 *proxy;
    struct seat *seat;
    uint32_t action;
    int32_t argument;
    bool enabled;
};

struct seat {
    struct seat *next;
    struct river_seat_v1 *proxy;
    struct binding *bindings;
    uint32_t id;
    bool removed, configured;
};

struct input {
    struct input *next;
    int32_t kind, argument;
    uint32_t id, seat_id;
};

static struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_callback *discovery;
    struct river_window_manager_v1 *manager;
    struct river_xkb_bindings_v1 *xkb;
    struct window *windows;
    struct output *outputs;
    struct seat *seats, *primary;
    struct input *input_head, *input_tail;
    enum phase phase;
    uint32_t next_id, manager_global, xkb_global;
    bool running, failed, finished, unavailable;
    bool stop_requested, stop_sent, managed, awaiting_render;
    bool locked, lock_changed, warned_multiseat;
    bool discovery_done, sigint_installed, sigterm_installed;
    struct sigaction previous_sigint, previous_sigterm;
} state;

static volatile sig_atomic_t interrupted;

/* Signal delivery may run on a different Haskell RTS thread. Do not call
 * Wayland, Haskell, allocation, logging, or any non-signal-safe function here.
 */
static void interrupt_handler(int signal_number)
{
    (void)signal_number;
    interrupted = 1;
}

static void fail(const char *message)
{
    if (!state.failed)
        fprintf(stderr, "xmonad-wayland: %s\n", message);
    state.failed = true;
    state.running = false;
}

static void *allocate(size_t size)
{
    void *p = calloc(1, size);
    if (!p)
        fail("out of memory in Wayland bridge");
    return p;
}

static uint32_t new_id(void)
{
    if (state.next_id == UINT32_MAX) {
        fail("exhausted stable window/output/seat IDs");
        return 0;
    }
    return ++state.next_id;
}

static struct window *find_window(uint32_t id)
{
    struct window *w;
    for (w = state.windows; w; w = w->next)
        if (w->id == id && !w->closed)
            return w;
    return NULL;
}

static void queue_input(int32_t kind, uint32_t id, int32_t argument,
                        const struct seat *seat)
{
    struct input *event;
    if (state.failed || state.locked || seat != state.primary || seat->removed)
        return;
    event = allocate(sizeof *event);
    if (!event)
        return;
    event->kind = kind;
    event->id = id;
    event->argument = argument;
    event->seat_id = seat->id;
    if (state.input_tail)
        state.input_tail->next = event;
    else
        state.input_head = event;
    state.input_tail = event;
}

static void binding_pressed(void *data, struct river_xkb_binding_v1 *proxy)
{
    struct binding *binding = data;
    (void)proxy;
    queue_input(6, binding->action, binding->argument, binding->seat);
}

static void binding_released(void *data, struct river_xkb_binding_v1 *proxy)
{
    (void)data;
    (void)proxy;
}

static const struct river_xkb_binding_v1_listener binding_listener = {
    .pressed = binding_pressed,
    .released = binding_released,
    .stop_repeat = binding_released,
};

static void add_binding(struct seat *seat, uint32_t keysym, uint32_t modifiers,
                        uint32_t action, int32_t argument)
{
    struct binding *binding = allocate(sizeof *binding);
    if (!binding)
        return;
    binding->proxy = river_xkb_bindings_v1_get_xkb_binding(
        state.xkb, seat->proxy, keysym, modifiers);
    if (!binding->proxy) {
        free(binding);
        fail("could not create River keyboard binding");
        return;
    }
    binding->seat = seat;
    binding->action = action;
    binding->argument = argument;
    binding->next = seat->bindings;
    seat->bindings = binding;
    if (river_xkb_binding_v1_add_listener(binding->proxy, &binding_listener,
                                         binding) < 0)
        fail("could not install River keyboard binding listener");
}

static void configure_seat(struct seat *seat)
{
    const uint32_t super = RIVER_SEAT_V1_MODIFIERS_MOD4;
    const uint32_t shifted = super | RIVER_SEAT_V1_MODIFIERS_SHIFT;
    uint32_t digit;
    /* XKB Latin keysyms equal their ASCII code; Return is XKB_KEY_Return.
     * No libxkbcommon runtime dependency is needed to name these keysyms.
     */
    add_binding(seat, 'j', super, 1, 0);
    add_binding(seat, 'k', super, 2, 0);
    add_binding(seat, 'j', shifted, 13, 0);
    add_binding(seat, 'k', shifted, 14, 0);
    add_binding(seat, 0xff0d, super, 10, 0);
    add_binding(seat, 0xff0d, shifted, 3, 0);
    add_binding(seat, ' ', super, 4, 0);
    add_binding(seat, 'h', super, 5, 0);
    add_binding(seat, 'l', super, 6, 0);
    add_binding(seat, 'c', shifted, 9, 0);
    add_binding(seat, 'p', super, 11, 0);
    add_binding(seat, 'q', shifted, 12, 0);
    for (digit = 1; digit <= 9; ++digit) {
        add_binding(seat, '0' + digit, super, 7, (int32_t)digit);
        add_binding(seat, '0' + digit, shifted, 8, (int32_t)digit);
    }
    seat->configured = true;
}

static void window_closed(void *data, struct river_window_v1 *proxy)
{
    (void)proxy;
    ((struct window *)data)->closed = true;
}

static void window_dimensions(void *data, struct river_window_v1 *proxy,
                               int32_t width, int32_t height)
{
    struct window *w = data;
    (void)proxy;
    w->actual_width = width;
    w->actual_height = height;
}

static void window_dimensions_hint(void *data, struct river_window_v1 *proxy,
                                    int32_t min_width, int32_t min_height,
                                    int32_t max_width, int32_t max_height)
{
    (void)data; (void)proxy;
    (void)min_width; (void)min_height; (void)max_width; (void)max_height;
}

static void window_text(void *data, struct river_window_v1 *proxy,
                         const char *text)
{
    (void)data; (void)proxy; (void)text;
}

static void window_parent(void *data, struct river_window_v1 *proxy,
                           struct river_window_v1 *parent)
{
    (void)data; (void)proxy; (void)parent;
}

static void window_uint(void *data, struct river_window_v1 *proxy, uint32_t value)
{
    (void)data; (void)proxy; (void)value;
}

static void window_pid(void *data, struct river_window_v1 *proxy, int32_t pid)
{
    (void)data; (void)proxy; (void)pid;
}

static void window_pointer_move(void *data, struct river_window_v1 *proxy,
                                 struct river_seat_v1 *seat)
{
    (void)data; (void)proxy; (void)seat;
}

static void window_pointer_resize(void *data, struct river_window_v1 *proxy,
                                   struct river_seat_v1 *seat, uint32_t edges)
{
    (void)data; (void)proxy; (void)seat; (void)edges;
}

static void window_menu(void *data, struct river_window_v1 *proxy,
                         int32_t x, int32_t y)
{
    (void)data; (void)proxy; (void)x; (void)y;
}

static void window_request(void *data, struct river_window_v1 *proxy)
{
    (void)data; (void)proxy;
}

static void window_fullscreen(void *data, struct river_window_v1 *proxy,
                               struct river_output_v1 *output)
{
    (void)data; (void)proxy; (void)output;
}

/* Every event, including ignored client requests and later-version events,
 * has a correctly typed listener. We advertise unsupported capabilities as 0.
 */
static const struct river_window_v1_listener window_listener = {
    .closed = window_closed,
    .dimensions_hint = window_dimensions_hint,
    .dimensions = window_dimensions,
    .app_id = window_text,
    .title = window_text,
    .parent = window_parent,
    .decoration_hint = window_uint,
    .pointer_move_requested = window_pointer_move,
    .pointer_resize_requested = window_pointer_resize,
    .show_window_menu_requested = window_menu,
    .maximize_requested = window_request,
    .unmaximize_requested = window_request,
    .fullscreen_requested = window_fullscreen,
    .exit_fullscreen_requested = window_request,
    .minimize_requested = window_request,
    .unreliable_pid = window_pid,
    .presentation_hint = window_uint,
    .identifier = window_text,
    .capture_sessions = window_uint,
};

static void output_removed(void *data, struct river_output_v1 *proxy)
{
    (void)proxy;
    ((struct output *)data)->removed = true;
}

static void output_uint(void *data, struct river_output_v1 *proxy, uint32_t value)
{
    (void)data; (void)proxy; (void)value;
}

static void output_position(void *data, struct river_output_v1 *proxy,
                            int32_t x, int32_t y)
{
    struct output *output = data;
    (void)proxy;
    output->x = x;
    output->y = y;
    output->has_position = output->dirty = true;
}

static void output_dimensions(void *data, struct river_output_v1 *proxy,
                              int32_t width, int32_t height)
{
    struct output *output = data;
    (void)proxy;
    if (width <= 0 || height <= 0) {
        fail("compositor sent invalid logical output dimensions");
        return;
    }
    output->width = width;
    output->height = height;
    output->has_dimensions = output->dirty = true;
}

static const struct river_output_v1_listener output_listener = {
    .removed = output_removed,
    .wl_output = output_uint,
    .position = output_position,
    .dimensions = output_dimensions,
    .capture_sessions = output_uint,
};

static void seat_removed(void *data, struct river_seat_v1 *proxy)
{
    (void)proxy;
    ((struct seat *)data)->removed = true;
}

static void seat_wl_seat(void *data, struct river_seat_v1 *proxy, uint32_t name)
{
    (void)data; (void)proxy; (void)name;
}

static void seat_pointer_enter(void *data, struct river_seat_v1 *proxy,
                                struct river_window_v1 *window)
{
    (void)data; (void)proxy; (void)window;
}

static void seat_simple(void *data, struct river_seat_v1 *proxy)
{
    (void)data; (void)proxy;
}

static void seat_window_interaction(void *data, struct river_seat_v1 *proxy,
                                     struct river_window_v1 *window)
{
    struct window *w;
    (void)proxy;
    /* Resolve only against live local records, never trust a recycled ID. */
    for (w = state.windows; w; w = w->next)
        if (w->proxy == window && !w->closed) {
            queue_input(5, w->id, 0, data);
            return;
        }
}

static void seat_shell_interaction(void *data, struct river_seat_v1 *proxy,
                                    struct river_shell_surface_v1 *surface)
{
    (void)data; (void)proxy; (void)surface;
}

static void seat_coordinates(void *data, struct river_seat_v1 *proxy,
                              int32_t x, int32_t y)
{
    (void)data; (void)proxy; (void)x; (void)y;
}

static const struct river_seat_v1_listener seat_listener = {
    .removed = seat_removed,
    .wl_seat = seat_wl_seat,
    .pointer_enter = seat_pointer_enter,
    .pointer_leave = seat_simple,
    .window_interaction = seat_window_interaction,
    .shell_surface_interaction = seat_shell_interaction,
    .op_delta = seat_coordinates,
    .op_release = seat_simple,
    .pointer_position = seat_coordinates,
};

/* The protocol destructor is valid after removed/closed or manager.finished.
 * During disconnect/error cleanup only destroy client-side proxies: no request
 * may be sent for a still-live object whose destructor has a lifetime rule.
 */
static void destroy_window(struct window *w, bool protocol)
{
    if (w->node) {
        if (protocol) river_node_v1_destroy(w->node);
        else wl_proxy_destroy((struct wl_proxy *)w->node);
    }
    if (protocol) river_window_v1_destroy(w->proxy);
    else wl_proxy_destroy((struct wl_proxy *)w->proxy);
    free(w);
}

static void destroy_output(struct output *output, bool protocol)
{
    if (protocol) river_output_v1_destroy(output->proxy);
    else wl_proxy_destroy((struct wl_proxy *)output->proxy);
    free(output);
}

static void destroy_seat(struct seat *seat, bool protocol)
{
    struct binding *binding;
    while ((binding = seat->bindings)) {
        seat->bindings = binding->next;
        if (protocol) river_xkb_binding_v1_destroy(binding->proxy);
        else wl_proxy_destroy((struct wl_proxy *)binding->proxy);
        free(binding);
    }
    if (protocol) river_seat_v1_destroy(seat->proxy);
    else wl_proxy_destroy((struct wl_proxy *)seat->proxy);
    free(seat);
}

static void update_lifecycle(void)
{
    struct output **output_link = &state.outputs;
    struct window **window_link = &state.windows;
    struct seat **seat_link = &state.seats;
    struct output *output;
    struct window *w;
    struct seat *seat;

    while ((output = *output_link)) {
        if (output->removed) {
            if (output->announced)
                xw_event(2, output->id, 0, 0, 0, 0);
            *output_link = output->next;
            destroy_output(output, true);
        } else {
            output_link = &output->next;
        }
    }
    while ((w = *window_link)) {
        if (w->closed) {
            if (w->announced)
                xw_event(4, w->id, 0, 0, 0, 0);
            *window_link = w->next;
            destroy_window(w, true);
        } else {
            window_link = &w->next;
        }
    }
    /* Complete output geometry is published before window insertion and before
     * the policy's manage callback. Never publish position with stale 0x0 size.
     */
    for (output = state.outputs; output; output = output->next) {
        if (!output->has_position || !output->has_dimensions) {
            fail("compositor started manage before sending output geometry");
            return;
        }
        if (output->dirty) {
            xw_event(1, output->id, output->x, output->y,
                      output->width, output->height);
            output->dirty = false;
            output->announced = true;
        }
    }
    for (w = state.windows; w; w = w->next) {
        if (!w->configured) {
            w->node = river_window_v1_get_node(w->proxy);
            if (!w->node) {
                fail("could not create River window render node");
                return;
            }
            river_window_v1_set_capabilities(w->proxy, 0);
            river_window_v1_use_ssd(w->proxy);
            river_window_v1_set_tiled(w->proxy, 15);
            w->configured = true;
        }
        if (!w->announced) {
            xw_event(3, w->id, 0, 0, 0, 0);
            w->announced = true;
        }
    }
    while ((seat = *seat_link)) {
        if (seat->removed) {
            if (state.primary == seat)
                state.primary = NULL;
            *seat_link = seat->next;
            destroy_seat(seat, true);
        } else {
            seat_link = &seat->next;
        }
    }
    if (!state.primary)
        state.primary = state.seats;
    if (state.primary && !state.primary->configured)
        configure_seat(state.primary);
    if (state.primary) {
        struct binding *binding;
        for (binding = state.primary->bindings; binding; binding = binding->next) {
            if (binding->enabled == state.locked) {
                if (state.locked)
                    river_xkb_binding_v1_disable(binding->proxy);
                else
                    river_xkb_binding_v1_enable(binding->proxy);
                binding->enabled = !state.locked;
            }
        }
    }
}

static void send_stop(void)
{
    if (state.stop_requested && !state.stop_sent && state.manager &&
        !state.finished && !state.unavailable && !state.failed) {
        river_window_manager_v1_stop(state.manager);
        state.stop_sent = true;
    }
}

static void manager_manage_start(void *data, struct river_window_manager_v1 *proxy)
{
    struct input *event;
    (void)data;
    if (state.failed)
        return;
    if (state.phase != PHASE_IDLE || state.awaiting_render) {
        fail("compositor violated River manage/render sequence ordering");
        return;
    }
    if (!state.xkb) {
        fail("compositor lacks river_xkb_bindings_v1; River >= 0.4 is required");
        return;
    }
    state.phase = PHASE_MANAGE;
    update_lifecycle();
    if (state.lock_changed) {
        xw_event(state.locked ? 9 : 10, 0, 0, 0, 0, 0);
        state.lock_changed = false;
    }
    while ((event = state.input_head)) {
        state.input_head = event->next;
        if (!state.failed && !state.locked && state.primary &&
            event->seat_id == state.primary->id &&
            (event->kind != 5 || find_window(event->id)))
            xw_event(event->kind, event->id, event->argument, 0, 0, 0);
        free(event);
    }
    state.input_tail = NULL;
    if (!state.failed)
        xw_event(7, 0, 0, 0, 0, 0);
    if (!state.failed) {
        river_window_manager_v1_manage_finish(proxy);
        state.managed = true;
        state.awaiting_render = true;
    }
    state.phase = PHASE_IDLE;
    send_stop();
}

static void manager_render_start(void *data, struct river_window_manager_v1 *proxy)
{
    struct window *w, *focused = NULL;
    (void)data;
    if (state.failed)
        return;
    if (state.phase != PHASE_IDLE || !state.managed) {
        fail("compositor violated River render sequence ordering");
        return;
    }
    state.phase = PHASE_RENDER;
    xw_event(8, 0, 0, 0, 0, 0);
    if (!state.failed) {
        for (w = state.windows; w; w = w->next) {
            if (w->closed || !w->node)
                continue;
            if (!w->visible) {
                river_window_v1_hide(w->proxy);
                continue;
            }
            river_window_v1_show(w->proxy);
            river_node_v1_set_position(w->node, w->x, w->y);
            if (w->focused && !state.locked) {
                river_window_v1_set_borders(w->proxy, 15, w->border,
                    0, UINT32_MAX, UINT32_MAX, UINT32_MAX);
                focused = w;
            } else {
                river_window_v1_set_borders(w->proxy, 15, w->border,
                    0x44444444u, 0x44444444u, 0x44444444u, UINT32_MAX);
            }
            river_node_v1_place_top(w->node);
        }
        if (focused)
            river_node_v1_place_top(focused->node);
        river_window_manager_v1_render_finish(proxy);
        state.awaiting_render = false;
    }
    state.phase = PHASE_IDLE;
    send_stop();
}

static void manager_unavailable(void *data, struct river_window_manager_v1 *proxy)
{
    (void)data; (void)proxy;
    state.unavailable = true;
    fail("River window management is unavailable (another window manager may be running)");
}

static void manager_finished(void *data, struct river_window_manager_v1 *proxy)
{
    (void)data; (void)proxy;
    state.finished = true;
    state.running = false;
}

static void manager_locked(void *data, struct river_window_manager_v1 *proxy)
{
    (void)data; (void)proxy;
    state.locked = state.lock_changed = true;
}

static void manager_unlocked(void *data, struct river_window_manager_v1 *proxy)
{
    (void)data; (void)proxy;
    state.locked = false;
    state.lock_changed = true;
}

static void manager_window(void *data, struct river_window_manager_v1 *proxy,
                            struct river_window_v1 *window)
{
    struct window *w = allocate(sizeof *w), **tail = &state.windows;
    (void)data; (void)proxy;
    if (!w) {
        wl_proxy_destroy((struct wl_proxy *)window);
        return;
    }
    w->proxy = window;
    w->id = new_id();
    while (*tail) tail = &(*tail)->next;
    *tail = w;
    if (river_window_v1_add_listener(window, &window_listener, w) < 0)
        fail("could not install River window listener");
}

static void manager_output(void *data, struct river_window_manager_v1 *proxy,
                            struct river_output_v1 *river_output)
{
    struct output *output = allocate(sizeof *output), **tail = &state.outputs;
    (void)data; (void)proxy;
    if (!output) {
        wl_proxy_destroy((struct wl_proxy *)river_output);
        return;
    }
    output->proxy = river_output;
    output->id = new_id();
    while (*tail) tail = &(*tail)->next;
    *tail = output;
    if (river_output_v1_add_listener(river_output, &output_listener, output) < 0)
        fail("could not install River output listener");
}

static void manager_seat(void *data, struct river_window_manager_v1 *proxy,
                          struct river_seat_v1 *river_seat)
{
    struct seat *seat = allocate(sizeof *seat), **tail = &state.seats;
    (void)data; (void)proxy;
    if (!seat) {
        wl_proxy_destroy((struct wl_proxy *)river_seat);
        return;
    }
    seat->proxy = river_seat;
    seat->id = new_id();
    if (state.seats && !state.warned_multiseat) {
        fprintf(stderr, "xmonad-wayland: one logical seat is supported; additional seats have no WM bindings or focus policy\n");
        state.warned_multiseat = true;
    }
    while (*tail) tail = &(*tail)->next;
    *tail = seat;
    if (!state.primary)
        state.primary = seat;
    if (river_seat_v1_add_listener(river_seat, &seat_listener, seat) < 0)
        fail("could not install River seat listener");
}

static const struct river_window_manager_v1_listener manager_listener = {
    .unavailable = manager_unavailable,
    .finished = manager_finished,
    .manage_start = manager_manage_start,
    .render_start = manager_render_start,
    .session_locked = manager_locked,
    .session_unlocked = manager_unlocked,
    .window = manager_window,
    .output = manager_output,
    .seat = manager_seat,
};

static void registry_global(void *data, struct wl_registry *registry,
                             uint32_t name, const char *interface, uint32_t version)
{
    (void)data;
    if (version < 1)
        return;
    if (!strcmp(interface, river_window_manager_v1_interface.name) && !state.manager) {
        state.manager = wl_registry_bind(registry, name,
                                          &river_window_manager_v1_interface, 1);
        state.manager_global = name;
        if (!state.manager) {
            fail("could not bind river_window_manager_v1");
            return;
        }
        if (river_window_manager_v1_add_listener(state.manager, &manager_listener, NULL) < 0)
            fail("could not install River window manager listener");
    } else if (!strcmp(interface, river_xkb_bindings_v1_interface.name) && !state.xkb) {
        state.xkb = wl_registry_bind(registry, name,
                                     &river_xkb_bindings_v1_interface, 1);
        state.xkb_global = name;
        if (!state.xkb)
            fail("could not bind river_xkb_bindings_v1");
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data; (void)registry;
    if (name == state.manager_global || name == state.xkb_global)
        fail("compositor removed a required River window-management global");
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static bool require_manage(void)
{
    if (state.failed)
        return false;
    if (state.phase != PHASE_MANAGE) {
        fail("Haskell policy attempted a window-management request outside manage");
        return false;
    }
    return true;
}

void xw_set_window(uint32_t id, int visible, int x, int y,
                   int width, int height, int focused)
{
    struct window *w;
    if (!require_manage() || !(w = find_window(id)))
        return;
    w->visible = visible != 0;
    w->focused = focused != 0;
    w->border = width > 4 && height > 4 ? 2 : 0;
    /* Do arithmetic in 64 bits so even an extreme logical output position
     * cannot cause signed C overflow. Clamp unrepresentable content positions.
     */
    w->x = (int64_t)x + w->border > INT32_MAX ? INT32_MAX : x + w->border;
    w->y = (int64_t)y + w->border > INT32_MAX ? INT32_MAX : y + w->border;
    w->width = width > 0 ? width - 2 * w->border : 1;
    w->height = height > 0 ? height - 2 * w->border : 1;
    if (w->visible)
        river_window_v1_propose_dimensions(w->proxy, w->width, w->height);
    /* show/hide, position, stacking and borders are deferred to render. */
}

void xw_focus(uint32_t id)
{
    struct window *w;
    if (!require_manage() || !state.primary || state.primary->removed)
        return;
    w = find_window(id);
    if (w && w->visible && !state.locked)
        river_seat_v1_focus_window(state.primary->proxy, w->proxy);
    else
        river_seat_v1_clear_focus(state.primary->proxy);
}

void xw_close(uint32_t id)
{
    struct window *w;
    if (!require_manage() || state.locked || !(w = find_window(id)))
        return;
    river_window_v1_close(w->proxy);
}

void xw_stop(void)
{
    state.stop_requested = true;
    if (state.phase == PHASE_IDLE)
        send_stop();
}

static void cleanup(void)
{
    struct window *w;
    struct output *output;
    struct seat *seat;
    struct input *event;
    bool protocol = state.finished && !state.failed;
    if (state.discovery)
        wl_callback_destroy(state.discovery);
    while ((w = state.windows)) {
        state.windows = w->next;
        destroy_window(w, protocol);
    }
    while ((output = state.outputs)) {
        state.outputs = output->next;
        destroy_output(output, protocol);
    }
    while ((seat = state.seats)) {
        state.seats = seat->next;
        destroy_seat(seat, protocol);
    }
    while ((event = state.input_head)) {
        state.input_head = event->next;
        free(event);
    }
    if (state.xkb) {
        if (protocol) river_xkb_bindings_v1_destroy(state.xkb);
        else wl_proxy_destroy((struct wl_proxy *)state.xkb);
    }
    if (state.manager) {
        if (protocol) river_window_manager_v1_destroy(state.manager);
        else wl_proxy_destroy((struct wl_proxy *)state.manager);
    }
    if (state.registry)
        wl_registry_destroy(state.registry);
    if (state.display) {
        if (protocol)
            (void)wl_display_flush(state.display);
        wl_display_disconnect(state.display);
    }
}

static void discovery_done(void *data, struct wl_callback *callback, uint32_t serial)
{
    (void)data; (void)serial;
    state.discovery_done = true;
    state.discovery = NULL;
    wl_callback_destroy(callback);
}

static const struct wl_callback_listener discovery_listener = {
    .done = discovery_done,
};

static void install_signal_handlers(void)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = interrupt_handler;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGINT);
    sigaddset(&action.sa_mask, SIGTERM);
    if (sigaction(SIGINT, &action, &state.previous_sigint) < 0) {
        fail("could not install SIGINT shutdown handler");
        return;
    }
    state.sigint_installed = true;
    if (sigaction(SIGTERM, &action, &state.previous_sigterm) < 0) {
        fail("could not install SIGTERM shutdown handler");
        return;
    }
    state.sigterm_installed = true;
}

static void restore_signal_handlers(void)
{
    if (state.sigterm_installed &&
        sigaction(SIGTERM, &state.previous_sigterm, NULL) < 0)
        fail("could not restore original SIGTERM handler");
    if (state.sigint_installed &&
        sigaction(SIGINT, &state.previous_sigint, NULL) < 0)
        fail("could not restore original SIGINT handler");
}

/* A bounded poll also covers signals delivered on another RTS thread, where
 * poll need not return EINTR, and the race between testing interrupted and
 * entering poll. There is no unbounded blocking operation after prepare_read.
 * A signal disconnects this WM promptly, even if the compositor is stalled.
 */
static void dispatch_once(void)
{
    struct pollfd descriptor;
    int ready;
    while (wl_display_prepare_read(state.display) != 0) {
        if (interrupted || !state.running || state.failed)
            return;
        if (wl_display_dispatch_pending(state.display) < 0) {
            if (!interrupted)
                fail("Wayland connection lost while dispatching pending events");
            return;
        }
    }
    if (interrupted || !state.running || state.failed) {
        wl_display_cancel_read(state.display);
        return;
    }
    descriptor.fd = wl_display_get_fd(state.display);
    descriptor.events = POLLIN;
    descriptor.revents = 0;
    if (wl_display_flush(state.display) < 0) {
        if (errno == EAGAIN) {
            descriptor.events |= POLLOUT;
        } else {
            int error = errno;
            wl_display_cancel_read(state.display);
            if (!interrupted && error != EINTR)
                fail("Wayland connection lost while flushing requests");
            return;
        }
    }
    ready = poll(&descriptor, 1, 100);
    if (interrupted || ready <= 0) {
        wl_display_cancel_read(state.display);
        if (!interrupted && ready < 0 && errno != EINTR)
            fail("could not poll Wayland connection");
        return;
    }
    if (descriptor.revents & (POLLIN | POLLHUP | POLLERR)) {
        if (wl_display_read_events(state.display) < 0) {
            if (!interrupted && errno != EINTR)
                fail("Wayland connection lost or compositor rejected a protocol request (see Wayland diagnostic above)");
            return;
        }
        if (!interrupted && wl_display_dispatch_pending(state.display) < 0 && !interrupted)
            fail("Wayland connection lost while dispatching events");
    } else {
        wl_display_cancel_read(state.display);
        if (descriptor.revents & POLLNVAL)
            fail("Wayland connection descriptor became invalid");
    }
}

int xw_run(void)
{
    int result;
    if (state.running) {
        fprintf(stderr, "xmonad-wayland: xw_run may not be entered recursively\n");
        return 1;
    }
    memset(&state, 0, sizeof state);
    interrupted = 0;
    state.running = true;
    state.display = wl_display_connect(NULL);
    if (!state.display) {
        fprintf(stderr, "xmonad-wayland: cannot connect to Wayland display: %s; start this program as River's window manager\n", strerror(errno));
        state.running = false;
        return 1;
    }
    state.registry = wl_display_get_registry(state.display);
    if (!state.registry)
        fail("could not obtain Wayland registry");
    else if (wl_registry_add_listener(state.registry, &registry_listener, NULL) < 0)
        fail("could not install Wayland registry listener");
    if (!state.failed)
        install_signal_handlers();
    if (!state.failed) {
        state.discovery = wl_display_sync(state.display);
        if (!state.discovery ||
            wl_callback_add_listener(state.discovery, &discovery_listener, NULL) < 0)
            fail("could not start Wayland registry discovery");
    }
    while (!state.discovery_done && state.running && !state.failed && !interrupted)
        dispatch_once();
    if (!interrupted && !state.failed && !state.manager)
        fail("compositor lacks river_window_manager_v1; River >= 0.4 is required (River classic/0.3 is incompatible)");
    if (!interrupted && !state.failed && !state.xkb)
        fail("compositor lacks river_xkb_bindings_v1; River >= 0.4 is required");
    while (state.running && !state.failed && !interrupted)
        dispatch_once();
    cleanup();
    restore_signal_handlers();
    result = state.failed ? 1 : 0;
    memset(&state, 0, sizeof state);
    return result;
}
