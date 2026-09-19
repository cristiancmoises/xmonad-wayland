/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef XMONAD_WAYLAND_BRIDGE_H
#define XMONAD_WAYLAND_BRIDGE_H

#include <stdint.h>

/* All calls and callbacks run on the Wayland event thread. Import xw_run
 * with Haskell's `safe` FFI: it dispatches callbacks into the Haskell RTS.
 * Window setters, focus and close are valid only during event 7 (manage).
 * The rectangle describes the OUTER tile allocation. The bridge reserves 2px
 * per edge for borders, or uses no border when either dimension is <= 4px.
 * xw_stop stops this window manager, never the compositor/session.
 */
int xw_run(void);
void xw_set_output(uint32_t output);
void xw_set_mode(uint32_t id, uint32_t output, int floating, int fullscreen);
void xw_set_window(uint32_t id, int visible, int x, int y,
                   int width, int height, int focused);
void xw_focus(uint32_t id);
void xw_close(uint32_t id);
void xw_stop(void);
void xw_add_binding(uint32_t keysym, uint32_t modifiers, uint32_t index, uint32_t mode);
void xw_set_binding_mode(uint32_t mode);
void xw_set_pointer_operation(uint32_t seat, uint32_t window, uint32_t edges);
/* Render-only correction using actual client dimensions; outer coordinates. */
void xw_set_render_position(uint32_t id, int x, int y);
void xw_reset_bindings(void);
void xw_set_cursor_theme(const char *name, uint32_t size);
/* Thread-safe: only sets an atomic flag for the Wayland event thread. */
void xw_request_exit_session(void);

/* Haskell export. Events and actions are documented in the design spec. */
void xw_event(int32_t kind, uint32_t id, int32_t a, int32_t b,
              int32_t c, int32_t d);
/* Metadata strings: 26 = app id, 27 = title; NUL-terminated, bounded. */
void xw_window_string(int32_t kind, uint32_t id, const char *text);
void xw_configure_bindings(void);

#endif
