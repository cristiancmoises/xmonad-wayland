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
#include "river-layer-shell-v1-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

enum phase { PHASE_IDLE, PHASE_MANAGE, PHASE_RENDER };
enum layer_focus { LAYER_FOCUS_NONE, LAYER_FOCUS_EXCLUSIVE, LAYER_FOCUS_NON_EXCLUSIVE };

struct window {
    struct window *next;
    struct river_window_v1 *proxy;
    struct river_node_v1 *node;
    uint32_t id;
    bool announced, closed, configured, visible, focused;
    bool parent_dirty, hints_dirty, fullscreen_dirty, fullscreen_requested, floating;
    bool exited_fullscreen, meta_dirty;
    char app_id[256], title[256];
    uint32_t parent_id, fullscreen_output;
    size_t stacking_depth;
    int32_t min_width, min_height, max_width, max_height;
    int32_t x, y, width, height, border, actual_width, actual_height;
};

struct output {
    struct output *next;
    struct river_output_v1 *proxy;
    struct river_layer_shell_output_v1 *layer;
    uint32_t id;
    bool announced, removed, dirty, has_position, has_dimensions;
    int32_t x, y, width, height;
    bool area_dirty;
    int32_t area_x, area_y, area_width, area_height;
};

struct seat;
struct pointer_binding {
    struct river_pointer_binding_v1 *proxy;
    struct seat *seat;
    uint32_t button;
    bool enabled;
};
struct binding {
    struct binding *next;
    struct river_xkb_binding_v1 *proxy;
    struct seat *seat;
    uint32_t index, mode;
    bool enabled;
};

struct seat {
    struct seat *next;
    struct river_seat_v1 *proxy;
    struct river_layer_shell_seat_v1 *layer;
    struct binding *bindings;
    struct pointer_binding pointer_bindings[2];
    uint32_t id;
    uint32_t pointer_window;
    int32_t pointer_x, pointer_y, delta_x, delta_y;
    bool pointer_known, delta_pending, release_pending;
    bool removed, configured;
    enum layer_focus layer_focus;
    bool layer_focus_override;
};

struct input {
    struct input *next;
    int32_t kind, argument, b, c, d;
    uint32_t id, seat_id;
};

static struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_callback *discovery;
    struct river_window_manager_v1 *manager;
    struct river_xkb_bindings_v1 *xkb;
    struct river_layer_shell_v1 *layer_shell;
    struct window *windows;
    struct output *outputs;
    struct seat *seats, *primary;
    struct input *input_head, *input_tail;
    enum phase phase;
    uint32_t next_id, manager_global, xkb_global, layer_global, binding_mode;
    uint32_t pointer_seat, pointer_window, pointer_edges;
    bool pointer_cancel_batch;
    bool running, failed, finished, unavailable, exit_sent;
    bool stop_requested, stop_sent, managed, awaiting_render;
    bool locked, lock_changed, warned_multiseat;
    bool discovery_done, sigint_installed, sigterm_installed;
    struct sigaction previous_sigint, previous_sigterm;
} state;

static volatile sig_atomic_t interrupted;
static atomic_bool exit_requested;

void xw_request_exit_session(void)
{
    atomic_store(&exit_requested, true);
}

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

static struct seat *find_seat(uint32_t id)
{
    struct seat *seat;
    for (seat = state.seats; seat; seat = seat->next)
        if (seat->id == id && !seat->removed) return seat;
    return NULL;
}

static void queue_pointer(struct seat *seat, uint32_t window, uint32_t edges)
{
    struct input *event;
    if (!seat || seat != state.primary || seat->removed || state.locked ||
        state.failed || state.pointer_seat || !find_window(window) ||
        seat->layer_focus == LAYER_FOCUS_EXCLUSIVE) return;
    event = allocate(sizeof *event);
    if (!event) return;
    event->kind = 21;
    event->id = window;
    event->seat_id = seat->id;
    event->argument = (int32_t)seat->id;
    event->b = (int32_t)edges;
    if (state.input_tail) state.input_tail->next = event;
    else state.input_head = event;
    state.input_tail = event;
}

static void pointer_pressed(void *data, struct river_pointer_binding_v1 *proxy)
{
    struct pointer_binding *binding = data;
    (void)proxy;
    queue_pointer(binding->seat, binding->seat->pointer_window,
                  binding->button == 272 ? 0 : 16);
}

static void pointer_released(void *data, struct river_pointer_binding_v1 *proxy)
{
    /* Only op_release ends the operation, after every pointer button is up. */
    (void)data; (void)proxy;
}

static const struct river_pointer_binding_v1_listener pointer_listener = {
    .pressed = pointer_pressed,
    .released = pointer_released,
};

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
    queue_input(20, binding->index, 0, binding->seat);
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

void xw_add_binding(uint32_t keysym, uint32_t modifiers, uint32_t index,
                    uint32_t mode)
{
    struct seat *seat = state.primary;
    if (state.phase != PHASE_MANAGE || !seat || !state.xkb) {
        fail("keyboard bindings must be configured during manage");
        return;
    }
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
    binding->index = index;
    binding->mode = mode;
    binding->next = seat->bindings;
    seat->bindings = binding;
    if (river_xkb_binding_v1_add_listener(binding->proxy, &binding_listener,
                                         binding) < 0)
        fail("could not install River keyboard binding listener");
}

static void configure_seat(struct seat *seat)
{
    for (unsigned i = 0; i < 2; ++i) {
        struct pointer_binding *binding = &seat->pointer_bindings[i];
        if (binding->proxy) continue;
        binding->seat = seat;
        binding->button = 272 + i;
        binding->proxy = river_seat_v1_get_pointer_binding(seat->proxy,
            binding->button, RIVER_SEAT_V1_MODIFIERS_MOD4);
        if (!binding->proxy || river_pointer_binding_v1_add_listener(
                binding->proxy, &pointer_listener, binding) < 0) {
            fail("could not create River pointer binding");
            return;
        }
    }
    xw_configure_bindings();
    seat->configured = true;
}

void xw_set_cursor_theme(const char *name, uint32_t size)
{
    if (state.phase != PHASE_MANAGE || !state.primary) return;
    if (river_seat_v1_get_version(state.primary->proxy) >= 2)
        river_seat_v1_set_xcursor_theme(state.primary->proxy, name, size);
    else
        fprintf(stderr, "xmonad-wayland: cursor theme requires River seat protocol version 2\n");
}

void xw_set_binding_mode(uint32_t mode)
{
    struct binding *binding;
    if (state.phase != PHASE_MANAGE) {
        fail("keyboard modes must be changed during manage");
        return;
    }
    state.binding_mode = mode;
    if (!state.primary) return;
    for (binding = state.primary->bindings; binding; binding = binding->next) {
        bool enabled = !state.locked && binding->mode == state.binding_mode;
        if (binding->enabled == enabled) continue;
        if (enabled) river_xkb_binding_v1_enable(binding->proxy);
        else river_xkb_binding_v1_disable(binding->proxy);
        binding->enabled = enabled;
    }
    for (unsigned i = 0; i < 2; ++i) {
        struct pointer_binding *pointer = &state.primary->pointer_bindings[i];
        bool enabled = !state.locked &&
            state.primary->layer_focus != LAYER_FOCUS_EXCLUSIVE;
        if (!pointer->proxy || pointer->enabled == enabled) continue;
        if (enabled) river_pointer_binding_v1_enable(pointer->proxy);
        else river_pointer_binding_v1_disable(pointer->proxy);
        pointer->enabled = enabled;
    }
}

void xw_set_pointer_operation(uint32_t seat_id, uint32_t window_id, uint32_t edges)
{
    struct seat *seat;
    struct window *window;
    if (state.phase != PHASE_MANAGE) {
        fail("pointer operations must change during manage");
        return;
    }
    if (seat_id == state.pointer_seat && window_id == state.pointer_window &&
        edges == state.pointer_edges) return;
    if (state.pointer_seat) {
        seat = find_seat(state.pointer_seat);
        window = find_window(state.pointer_window);
        if (seat) {
            river_seat_v1_op_end(seat->proxy);
            seat->delta_pending = seat->release_pending = false;
        }
        if (window && state.pointer_edges)
            river_window_v1_inform_resize_end(window->proxy);
        state.pointer_seat = state.pointer_window = state.pointer_edges = 0;
        /* River ignores start while the previous operation is still active. */
        if (seat_id) fail("cannot replace pointer operation in one manage sequence");
        return;
    }
    if (!seat_id) return;
    seat = find_seat(seat_id);
    window = find_window(window_id);
    if (!seat || seat != state.primary || !window || state.locked ||
        seat->layer_focus == LAYER_FOCUS_EXCLUSIVE) return;
    state.pointer_seat = seat_id;
    state.pointer_window = window_id;
    state.pointer_edges = edges;
    seat->delta_pending = seat->release_pending = false;
    river_seat_v1_op_start_pointer(seat->proxy);
    if (edges) river_window_v1_inform_resize_start(window->proxy);
}

void xw_reset_bindings(void)
{
    struct binding *binding;
    if (state.phase != PHASE_MANAGE) {
        fail("keyboard bindings must be reloaded during manage");
        return;
    }
    if (!state.primary) return;
    while ((binding = state.primary->bindings)) {
        state.primary->bindings = binding->next;
        river_xkb_binding_v1_destroy(binding->proxy);
        free(binding);
    }
    configure_seat(state.primary);
    xw_set_binding_mode(state.binding_mode);
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
    if (width <= 0 || height <= 0) {
        fail("compositor sent invalid window dimensions");
        return;
    }
    w->actual_width = width;
    w->actual_height = height;
}

static void window_dimensions_hint(void *data, struct river_window_v1 *proxy,
                                    int32_t min_width, int32_t min_height,
                                    int32_t max_width, int32_t max_height)
{
    struct window *w = data;
    (void)proxy;
    w->min_width = min_width;
    w->min_height = min_height;
    w->max_width = max_width;
    w->max_height = max_height;
    w->hints_dirty = true;
}

static void window_meta(char *destination, size_t capacity, const char *text)
{
    /* Protocol strings are untrusted: bound the copy and keep NUL termination. */
    size_t length = text ? strlen(text) : 0;
    if (length >= capacity) length = capacity - 1;
    if (length) memcpy(destination, text, length);
    destination[length] = '\0';
}

static void window_app_id(void *data, struct river_window_v1 *proxy,
                          const char *app_id)
{
    struct window *w = data;
    (void)proxy;
    window_meta(w->app_id, sizeof w->app_id, app_id);
    w->meta_dirty = true;
}

static void window_title(void *data, struct river_window_v1 *proxy,
                         const char *title)
{
    struct window *w = data;
    (void)proxy;
    window_meta(w->title, sizeof w->title, title);
    w->meta_dirty = true;
}

static void window_text(void *data, struct river_window_v1 *proxy,
                        const char *text)
{
    (void)data; (void)proxy; (void)text;
}

static void window_parent(void *data, struct river_window_v1 *proxy,
                           struct river_window_v1 *parent)
{
    struct window *w = data, *candidate;
    (void)proxy;
    w->parent_id = 0;
    for (candidate = state.windows; candidate; candidate = candidate->next)
        if (candidate->proxy == parent && !candidate->closed) {
            w->parent_id = candidate->id;
            break;
        }
    w->parent_dirty = true;
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
    struct seat *candidate;
    (void)proxy;
    for (candidate = state.seats; candidate; candidate = candidate->next)
        if (candidate->proxy == seat) queue_pointer(candidate, ((struct window *)data)->id, 0);
}

static void window_pointer_resize(void *data, struct river_window_v1 *proxy,
                                   struct river_seat_v1 *seat, uint32_t edges)
{
    struct seat *candidate;
    (void)proxy;
    if (!edges || edges > 15 || (edges & 3) == 3 || (edges & 12) == 12) return;
    for (candidate = state.seats; candidate; candidate = candidate->next)
        if (candidate->proxy == seat) queue_pointer(candidate, ((struct window *)data)->id, edges);
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
    struct window *w = data;
    (void)proxy; (void)output;
    /* The protocol's requested output is a hint. Keep the window on its
     * workspace's output instead of moving a hidden client's workspace. */
    w->fullscreen_requested = w->fullscreen_dirty = true;
}

static void window_exit_fullscreen(void *data, struct river_window_v1 *proxy)
{
    struct window *w = data;
    (void)proxy;
    w->fullscreen_requested = false;
    w->fullscreen_dirty = true;
}

/* Every event, including ignored client requests and later-version events,
 * has a correctly typed listener. Only implemented capabilities are advertised.
 */
static const struct river_window_v1_listener window_listener = {
    .closed = window_closed,
    .dimensions_hint = window_dimensions_hint,
    .dimensions = window_dimensions,
    .app_id = window_app_id,
    .title = window_title,
    .parent = window_parent,
    .decoration_hint = window_uint,
    .pointer_move_requested = window_pointer_move,
    .pointer_resize_requested = window_pointer_resize,
    .show_window_menu_requested = window_menu,
    .maximize_requested = window_request,
    .unmaximize_requested = window_request,
    .fullscreen_requested = window_fullscreen,
    .exit_fullscreen_requested = window_exit_fullscreen,
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
    state.pointer_cancel_batch = true;
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
    if (output->x != x || output->y != y) state.pointer_cancel_batch = true;
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
    if (output->width != width || output->height != height) state.pointer_cancel_batch = true;
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
    struct seat *seat = data;
    struct window *w;
    (void)proxy;
    seat->pointer_window = 0;
    for (w = state.windows; w; w = w->next)
        if (w->proxy == window && !w->closed) seat->pointer_window = w->id;
}

static void seat_pointer_leave(void *data, struct river_seat_v1 *proxy)
{
    (void)proxy;
    ((struct seat *)data)->pointer_window = 0;
}

static void seat_op_release(void *data, struct river_seat_v1 *proxy)
{
    struct seat *seat = data;
    (void)proxy;
    if (seat->id == state.pointer_seat) seat->release_pending = true;
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

static void seat_delta(void *data, struct river_seat_v1 *proxy,
                              int32_t x, int32_t y)
{
    struct seat *seat = data;
    (void)proxy;
    if (seat->id != state.pointer_seat) return;
    seat->delta_x = x;
    seat->delta_y = y;
    seat->delta_pending = true;
}

static void seat_position(void *data, struct river_seat_v1 *proxy,
                          int32_t x, int32_t y)
{
    struct seat *seat = data;
    (void)proxy;
    seat->pointer_x = x;
    seat->pointer_y = y;
    seat->pointer_known = true;
}

static const struct river_seat_v1_listener seat_listener = {
    .removed = seat_removed,
    .wl_seat = seat_wl_seat,
    .pointer_enter = seat_pointer_enter,
    .pointer_leave = seat_pointer_leave,
    .window_interaction = seat_window_interaction,
    .shell_surface_interaction = seat_shell_interaction,
    .op_delta = seat_delta,
    .op_release = seat_op_release,
    .pointer_position = seat_position,
};

static void layer_area(void *data, struct river_layer_shell_output_v1 *proxy,
                       int32_t x, int32_t y, int32_t width, int32_t height)
{
    struct output *output = data;
    (void)proxy;
    if (output->area_x != x || output->area_y != y ||
        output->area_width != width || output->area_height != height)
        state.pointer_cancel_batch = true;
    output->area_x = x;
    output->area_y = y;
    output->area_width = width;
    output->area_height = height;
    output->area_dirty = true;
}

static const struct river_layer_shell_output_v1_listener layer_output_listener = {
    .non_exclusive_area = layer_area,
};

static void layer_focus_exclusive(void *data, struct river_layer_shell_seat_v1 *proxy)
{
    (void)proxy;
    ((struct seat *)data)->layer_focus = LAYER_FOCUS_EXCLUSIVE;
    if (data == state.primary) state.pointer_cancel_batch = true;
}

static void layer_focus_non_exclusive(void *data, struct river_layer_shell_seat_v1 *proxy)
{
    (void)proxy;
    ((struct seat *)data)->layer_focus = LAYER_FOCUS_NON_EXCLUSIVE;
}

static void layer_focus_none(void *data, struct river_layer_shell_seat_v1 *proxy)
{
    (void)proxy;
    ((struct seat *)data)->layer_focus = LAYER_FOCUS_NONE;
}

static const struct river_layer_shell_seat_v1_listener layer_seat_listener = {
    .focus_exclusive = layer_focus_exclusive,
    .focus_non_exclusive = layer_focus_non_exclusive,
    .focus_none = layer_focus_none,
};

static void attach_layer_output(struct output *output)
{
    if (!state.layer_shell || output->layer || output->removed)
        return;
    output->layer = river_layer_shell_v1_get_output(state.layer_shell, output->proxy);
    if (!output->layer || river_layer_shell_output_v1_add_listener(
            output->layer, &layer_output_listener, output) < 0)
        fail("could not create River layer-shell output state");
}

static void attach_layer_seat(struct seat *seat)
{
    if (!state.layer_shell || seat->layer || seat->removed)
        return;
    seat->layer = river_layer_shell_v1_get_seat(state.layer_shell, seat->proxy);
    if (!seat->layer || river_layer_shell_seat_v1_add_listener(
            seat->layer, &layer_seat_listener, seat) < 0)
        fail("could not create River layer-shell seat state");
}

static bool layer_has_focus(void)
{
    return state.primary && state.primary->layer_focus != LAYER_FOCUS_NONE &&
        !state.primary->layer_focus_override;
}

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
    if (output->layer) {
        if (protocol) river_layer_shell_output_v1_destroy(output->layer);
        else wl_proxy_destroy((struct wl_proxy *)output->layer);
    }
    if (protocol) river_output_v1_destroy(output->proxy);
    else wl_proxy_destroy((struct wl_proxy *)output->proxy);
    free(output);
}

static void destroy_seat(struct seat *seat, bool protocol)
{
    struct binding *binding;
    for (unsigned i = 0; i < 2; ++i) {
        struct river_pointer_binding_v1 *pointer = seat->pointer_bindings[i].proxy;
        if (!pointer) continue;
        if (protocol) river_pointer_binding_v1_destroy(pointer);
        else wl_proxy_destroy((struct wl_proxy *)pointer);
    }
    if (seat->layer) {
        if (protocol) river_layer_shell_seat_v1_destroy(seat->layer);
        else wl_proxy_destroy((struct wl_proxy *)seat->layer);
    }
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
        if (output->area_dirty) {
            xw_event(14, output->id, output->area_x, output->area_y,
                      output->area_width, output->area_height);
            output->area_dirty = false;
        }
    }
    for (w = state.windows; w; w = w->next) {
        if (!w->configured) {
            w->node = river_window_v1_get_node(w->proxy);
            if (!w->node) {
                fail("could not create River window render node");
                return;
            }
            river_window_v1_set_capabilities(w->proxy, RIVER_WINDOW_V1_CAPABILITIES_FULLSCREEN);
            river_window_v1_use_ssd(w->proxy);
            river_window_v1_set_tiled(w->proxy, 15);
            w->configured = true;
        }
        if (!w->announced) {
            xw_event(3, w->id, 0, 0, 0, 0);
            w->announced = true;
        }
    }
    /* Parent references may point at another window announced in this same
     * transaction. Insert every window before publishing its metadata. */
    for (w = state.windows; w; w = w->next) {
        if (w->parent_dirty) {
            xw_event(11, w->id, (int32_t)w->parent_id, 0, 0, 0);
            w->parent_dirty = false;
        }
        if (w->hints_dirty) {
            xw_event(12, w->id, w->min_width, w->min_height, w->max_width, w->max_height);
            w->hints_dirty = false;
        }
        if (w->meta_dirty) {
            xw_window_string(26, w->id, w->app_id);
            xw_window_string(27, w->id, w->title);
            w->meta_dirty = false;
        }
        if (w->fullscreen_dirty) {
            xw_event(13, w->id, w->fullscreen_requested, 0, 0, 0);
            w->fullscreen_dirty = false;
        }
    }
    while ((seat = *seat_link)) {
        if (seat->removed) {
            xw_event(24, seat->id, 0, 0, 0, 0);
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
    xw_set_binding_mode(state.binding_mode);
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
    /* Metadata can change policy focus. Publish the transaction's lock state
     * first, including when a fullscreen request arrives in the same batch. */
    if (state.lock_changed) {
        xw_event(state.locked ? 9 : 10, 0, 0, 0, 0, 0);
        state.lock_changed = false;
    }
    update_lifecycle();
    if (state.pointer_seat && (state.pointer_cancel_batch || state.locked ||
        !state.primary || state.primary->id != state.pointer_seat ||
        state.primary->layer_focus == LAYER_FOCUS_EXCLUSIVE))
        xw_event(24, state.pointer_seat, 0, 0, 0, 0);
    if (state.primary)
        state.primary->layer_focus_override = false;
    while ((event = state.input_head)) {
        state.input_head = event->next;
        if (!state.failed && !state.locked && state.primary &&
            event->seat_id == state.primary->id &&
            ((event->kind != 5 && event->kind != 21) || find_window(event->id)) &&
            (event->kind != 21 || (!state.pointer_cancel_batch &&
             state.primary->layer_focus != LAYER_FOCUS_EXCLUSIVE))) {
            /* A click or an explicit WM binding may leave an on-demand layer.
             * Exclusive layer focus remains compositor-controlled. */
            if (state.primary->layer_focus == LAYER_FOCUS_NON_EXCLUSIVE)
                state.primary->layer_focus_override = true;
            if (event->kind == 21 && event->b == 16) {
                /* pointer_position is transaction state and may follow pressed. */
                if (state.primary->pointer_known) {
                    event->c = state.primary->pointer_x;
                    event->d = state.primary->pointer_y;
                } else event->b = 10;
            }
            xw_event(event->kind, event->id, event->argument, event->b, event->c, event->d);
        }
        free(event);
    }
    state.input_tail = NULL;
    if (state.primary && state.pointer_seat == state.primary->id) {
        struct seat *seat = state.primary;
        /* River deltas are cumulative logical integers. Apply the newest total
         * before release even when the release callback preceded that delta. */
        if (seat->delta_pending)
            xw_event(22, seat->id, seat->delta_x, seat->delta_y, 0, 0);
        if (seat->release_pending) xw_event(23, seat->id, 0, 0, 0, 0);
        seat->delta_pending = seat->release_pending = false;
    }
    state.pointer_cancel_batch = false;
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
    size_t count = 0, maximum_depth = 0, depth;
    (void)data;
    if (state.failed)
        return;
    if (state.phase != PHASE_IDLE || !state.managed) {
        fail("compositor violated River render sequence ordering");
        return;
    }
    state.phase = PHASE_RENDER;
    /* Borders may change without another content dimensions event. Publish
     * actual OUTER sizes using the current border before correcting anchors. */
    for (w = state.windows; w; w = w->next) {
        if (w->closed || !w->announced || w->actual_width <= 0 || w->actual_height <= 0)
            continue;
        int64_t width = (int64_t)w->actual_width + 2 * w->border;
        int64_t height = (int64_t)w->actual_height + 2 * w->border;
        xw_event(25, w->id, (int32_t)(width > INT32_MAX ? INT32_MAX : width),
            (int32_t)(height > INT32_MAX ? INT32_MAX : height), 0, 0);
    }
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
            if (!w->floating)
                river_node_v1_place_top(w->node);
        }
        if (focused && !focused->floating)
            river_node_v1_place_top(focused->node);
        /* Floating dialogs must remain above tiles and their own parents,
         * including a focused floating parent. Bound ancestry traversal even
         * if a faulty compositor violates the protocol's acyclic tree rule. */
        for (w = state.windows; w; w = w->next)
            ++count;
        for (w = state.windows; w; w = w->next) {
            struct window *parent = w;
            w->stacking_depth = 1;
            while ((parent = find_window(parent->parent_id)) && parent->floating &&
                   w->stacking_depth < count)
                ++w->stacking_depth;
            if (w->floating && w->stacking_depth > maximum_depth)
                maximum_depth = w->stacking_depth;
        }
        for (depth = 1; depth <= maximum_depth; ++depth) {
            for (w = state.windows; w; w = w->next)
                if (!w->closed && w->node && w->visible && w->floating && w->stacking_depth == depth)
                    river_node_v1_place_top(w->node);
            if (focused && focused->floating && focused->stacking_depth == depth)
                river_node_v1_place_top(focused->node);
        }
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
    state.pointer_cancel_batch = true;
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
    attach_layer_output(output);
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
    attach_layer_seat(seat);
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
                                          &river_window_manager_v1_interface, version < 4 ? version : 4);
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
    } else if (!strcmp(interface, river_layer_shell_v1_interface.name) && !state.layer_shell) {
        struct output *output;
        struct seat *seat;
        state.layer_shell = wl_registry_bind(registry, name, &river_layer_shell_v1_interface, 1);
        state.layer_global = name;
        if (!state.layer_shell) {
            fail("could not bind river_layer_shell_v1");
            return;
        }
        for (output = state.outputs; output; output = output->next)
            attach_layer_output(output);
        for (seat = state.seats; seat; seat = seat->next)
            attach_layer_seat(seat);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data; (void)registry;
    if (name == state.manager_global || name == state.xkb_global || name == state.layer_global)
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
    w->focused = focused != 0 && !layer_has_focus();
    /* Windows are drawn without a frame: the maintainer's session shows no
     * border line around tiles.  Keep the inset arithmetic so geometry stays
     * correct if a configurable border returns later. */
    w->border = 0;
    /* Do arithmetic in 64 bits so even an extreme logical output position
     * cannot cause signed C overflow. Clamp unrepresentable content positions.
     */
    w->x = (int64_t)x + w->border > INT32_MAX ? INT32_MAX : x + w->border;
    w->y = (int64_t)y + w->border > INT32_MAX ? INT32_MAX : y + w->border;
    w->width = width > 0 ? width - 2 * w->border : 1;
    w->height = height > 0 ? height - 2 * w->border : 1;
    if (w->visible && !w->fullscreen_output) {
        river_window_v1_propose_dimensions(w->proxy, w->width, w->height);
        /* River undefines position/dimensions after exit_fullscreen. Restore
         * both in a manage transaction, retaining the obligation while hidden. */
        if (w->exited_fullscreen && w->node) {
            river_node_v1_set_position(w->node, w->x, w->y);
            w->exited_fullscreen = false;
        }
    }
    /* show/hide, position, stacking and borders are deferred to render. */
}

void xw_set_output(uint32_t id)
{
    struct output *output;
    if (!require_manage())
        return;
    for (output = state.outputs; output; output = output->next)
        if (output->id == id && output->layer && !output->removed) {
            river_layer_shell_output_v1_set_default(output->layer);
            return;
        }
}

void xw_set_mode(uint32_t id, uint32_t output_id, int floating, int fullscreen)
{
    struct window *w;
    struct output *output;
    if (!require_manage() || !(w = find_window(id)))
        return;
    w->floating = floating != 0;
    river_window_v1_set_tiled(w->proxy, w->floating ? 0 : 15);
    for (output = state.outputs; output; output = output->next)
        if (output->id == output_id && !output->removed)
            break;
    if (!fullscreen || !output) {
        if (w->fullscreen_output) {
            river_window_v1_exit_fullscreen(w->proxy);
            river_window_v1_inform_not_fullscreen(w->proxy);
            w->fullscreen_output = 0;
            w->exited_fullscreen = true;
        }
    } else if (w->fullscreen_output != output_id) {
        river_window_v1_fullscreen(w->proxy, output->proxy);
        river_window_v1_inform_fullscreen(w->proxy);
        w->fullscreen_output = output_id;
    }
}

void xw_set_render_position(uint32_t id, int x, int y)
{
    struct window *w = find_window(id);
    if (state.phase != PHASE_RENDER) {
        fail("actual-size position corrections must occur during render");
        return;
    }
    if (!w || !w->visible) return;
    w->x = (int32_t)((int64_t)x + w->border > INT32_MAX ? INT32_MAX : x + w->border);
    w->y = (int32_t)((int64_t)y + w->border > INT32_MAX ? INT32_MAX : y + w->border);
}

void xw_focus(uint32_t id)
{
    struct window *w;
    if (!require_manage() || !state.primary || state.primary->removed)
        return;
    if (!state.locked && layer_has_focus())
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
    if (state.layer_shell) {
        if (protocol) river_layer_shell_v1_destroy(state.layer_shell);
        else wl_proxy_destroy((struct wl_proxy *)state.layer_shell);
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
    if (atomic_exchange(&exit_requested, false) && state.manager) {
        if (river_window_manager_v1_get_version(state.manager) >= 4) {
            river_window_manager_v1_exit_session(state.manager);
            state.exit_sent = true;
        } else {
            fprintf(stderr, "xmonad-wayland: session exit requires River window management protocol version 4\n");
        }
    }
    while (wl_display_prepare_read(state.display) != 0) {
        if (interrupted || !state.running || state.failed)
            return;
        if (wl_display_dispatch_pending(state.display) < 0) {
            if (!interrupted && !state.exit_sent)
                fail("Wayland connection lost while dispatching pending events");
            state.running = false;
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
            if (!interrupted && !state.exit_sent && error != EINTR)
                fail("Wayland connection lost while flushing requests");
            if (state.exit_sent) state.running = false;
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
            if (!interrupted && !state.exit_sent && errno != EINTR)
                fail("Wayland connection lost or compositor rejected a protocol request (see Wayland diagnostic above)");
            if (state.exit_sent) state.running = false;
            return;
        }
        if (!interrupted && wl_display_dispatch_pending(state.display) < 0 && !interrupted) {
            if (!state.exit_sent) fail("Wayland connection lost while dispatching events");
            else state.running = false;
        }
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
    atomic_store(&exit_requested, false);
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
