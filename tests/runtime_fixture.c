#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>

extern void xw_event(int32_t, uint32_t, int32_t, int32_t, int32_t, int32_t);

static int phase, setters, focus_calls, closed, stopped;

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
    xw_event(6, 10, 0, 0, 0, 0);
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
    assert(stopped == 0);
    return 0;
}
