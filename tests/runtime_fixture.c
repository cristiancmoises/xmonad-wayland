#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern void xw_event(int32_t, uint32_t, int32_t, int32_t, int32_t, int32_t);
extern void xw_configure_bindings(void);

static int phase, setters, focus_calls, closed, stopped;
static int bindings, resets;
static uint32_t command_binding, reload_binding, confirm_binding;
static atomic_uint exit_requests;

void xw_set_cursor_theme(const char *name, uint32_t size)
{
    assert(phase == 1 && name && size);
}

void xw_request_exit_session(void)
{
    atomic_fetch_add(&exit_requests, 1);
}

void xw_add_binding(uint32_t keysym, uint32_t modifiers, uint32_t index, uint32_t mode)
{
    assert(phase == 1 && mode <= 1);
    assert(keysym != 0 && modifiers < 256);
    if (keysym == 0xff0d && modifiers == 64) command_binding = index;
    if (keysym == 'r' && modifiers == 64) reload_binding = index;
    if (keysym == 'e' && modifiers == 64) confirm_binding = index;
    bindings++;
}

void xw_set_binding_mode(uint32_t mode)
{
    assert(phase == 1 && mode <= 1);
}

void xw_set_pointer_operation(uint32_t seat, uint32_t window, uint32_t edges)
{
    assert(phase == 1 && seat == 0 && window == 0 && edges == 0);
}

void xw_set_render_position(uint32_t id, int x, int y)
{
    (void)id; (void)x; (void)y;
    assert(phase == 2);
}

void xw_reset_bindings(void)
{
    assert(phase == 1);
    resets++;
    xw_configure_bindings();
}

void xw_set_output(uint32_t output)
{
    assert(phase == 1 && output == 7);
}

void xw_set_mode(uint32_t id, uint32_t output, int floating, int fullscreen)
{
    assert(phase == 1);
    assert(id == 10 || id == 20);
    assert(output == 7 && !floating && !fullscreen);
}

void xw_set_window(uint32_t id, int visible, int x, int y, int width,
                   int height, int focused)
{
    assert(phase == 1);
    assert(id == 10 || id == 20);
    assert(visible == 1 && y == 0 && width == 400 && height == 600);
    assert(x == 0 || x == 400);
    assert(focused == (id == 10));
    setters++;
}

void xw_focus(uint32_t id)
{
    assert(phase == 1 && id == 10);
    focus_calls++;
}

void xw_close(uint32_t id)
{
    assert(phase == 1 && id == 10);
    closed++;
}

void xw_stop(void)
{
    stopped++;
}

/* WNOWAIT observes child exit without reaping it ourselves. ECHILD proves
 * that Runtime's waiter collected the child. Give slow CI five seconds. */
static void assert_child_reaped(void)
{
    const struct timespec delay = {0, 10000000};
    for (int attempt = 0; attempt < 500; attempt++) {
        siginfo_t info = {0};
        int result = waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT);
        if (result == -1 && errno == ECHILD)
            return;
        assert(result == 0 || errno == EINTR);
        nanosleep(&delay, NULL);
    }
    assert(!"Runtime did not reap its child before the timeout");
}

int xw_run(void)
{
    phase = 1;
    xw_configure_bindings();
    assert(bindings > 0);
    phase = 0;
    xw_event(1, 7, 0, 0, 800, 600);
    xw_event(3, 10, 0, 0, 0, 0);
    xw_event(3, 20, 0, 0, 0, 0);
    xw_event(6, 1, 0, 0, 0, 0);
    assert(setters == 0 && focus_calls == 0);
    phase = 1;
    xw_event(7, 0, 0, 0, 0, 0);
    phase = 0;
    assert(setters == 2 && focus_calls == 1);
    xw_event(8, 0, 0, 0, 0, 0);
    assert(setters == 2 && focus_calls == 1);
    xw_event(6, 9, 0, 0, 0, 0);
    xw_event(20, command_binding, 0, 0, 0, 0);
    assert(closed == 0);
    phase = 1;
    xw_event(7, 0, 0, 0, 0, 0);
    phase = 0;
    assert(closed == 1);
    if (getenv("XW_RUNTIME_FAIL")) {
        assert(stopped == 1);
        return 0;
    }
    assert_child_reaped();
    if (getenv("XW_RUNTIME_RELOAD")) {
        xw_event(20, reload_binding, 0, 0, 0, 0);
        phase = 1;
        xw_event(7, 0, 0, 0, 0, 0);
        phase = 0;
        assert(setters == 6 && focus_calls == 3);
        assert(resets == (getenv("XW_RUNTIME_RELOAD_INVALID") ? 0 : 1));
    }
    if (getenv("XW_RUNTIME_CONFIRM")) {
        const char *mode = getenv("XW_RUNTIME_CONFIRM");
        const struct timespec delay = {0, 10000000};
        xw_event(20, confirm_binding, 0, 0, 0, 0);
        xw_event(20, confirm_binding, 0, 0, 0, 0);
        phase = 1;
        xw_event(7, 0, 0, 0, 0, 0);
        phase = 0;
        int started = 0;
        for (int attempt = 0; attempt < 500; attempt++) {
            if (access(getenv("XW_CONFIRM_MARKER"), F_OK) == 0) {
                started = 1;
                break;
            }
            nanosleep(&delay, NULL);
        }
        assert(started && "confirmation process never started");
        if (strcmp(mode, "confirm-block") != 0 && strcmp(mode, "confirm-ignore-term") != 0) {
            assert_child_reaped();
            for (int attempt = 0; attempt < 100 && !atomic_load(&exit_requests); attempt++)
                nanosleep(&delay, NULL);
        }
        assert(atomic_load(&exit_requests) == (strcmp(mode, "confirm-exit") == 0 ? 1U : 0U));
    }
    assert(stopped == 0);
    return 0;
}
