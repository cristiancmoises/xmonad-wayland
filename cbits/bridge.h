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
void xw_set_window(uint32_t id, int visible, int x, int y,
                   int width, int height, int focused);
void xw_focus(uint32_t id);
void xw_close(uint32_t id);
void xw_stop(void);

/* Haskell export. Events and actions are documented in the design spec. */
void xw_event(int32_t kind, uint32_t id, int32_t a, int32_t b,
              int32_t c, int32_t d);

#endif
