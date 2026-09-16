# Security model and boundaries

This is experimental desktop software. Run it as a normal desktop user inside
a nested River session first. There is no setuid helper, root daemon, listener
on a network socket, telemetry, updater, or remote configuration download.

The manager has the authority granted by River's window-management globals:
it can arrange/focus/close applications and register shortcuts. Protect its
executable and Haskell configuration like other code executed at login. A
Haskell configuration is executable code, not a restricted configuration format.

Application titles/app IDs do not become commands. Terminal and launcher commands
are configured as an executable plus an argument list and launched without a
shell. River's session launcher receives a fixed literal init command; it never
constructs one from application metadata. Child processes are reaped.

The real Wayland connection uses libwayland-client, including validation by the
generated protocol bindings. The bridge checks required globals, enforces its
manage/render phases and handles proxy destruction. A compatible compositor is
trusted; this is not a sandbox against a malicious compositor.

Session lock implementation belongs to River and a separately installed locker.
This manager suppresses its policy actions while informed that the session is
locked. It does not itself lock the screen, provide automatic idle locking, or
prove the security of a compositor/locker combination. The stop shortcut quits
only the manager and must not be used as a lock shortcut.

XWayland applications inherit XWayland's security boundaries; this package does
not promise isolation between X11 clients. A native Wayland port alone does not
constitute an audited secure desktop. No security audit or production-readiness
claim is made for version 0.1.0.

No package script changes existing XMonad files, display-manager selection,
user river/init, device permissions, kernel settings or firewall configuration.
