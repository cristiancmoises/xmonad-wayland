# Local Guix build

From the project directory, run:

```sh
bash scripts/guix-build
```

The script uses the authenticated official Guix channel at commit
`fe590afef7319a8ea921d35b67fb39fb79f5a3b3`. It builds River 0.4.8 and the
current local manager source, runs their test phases, and creates:

- `build/guix-river`: River's store output, registered as a GC root.
- `build/guix-manager`: the manager's store output, registered as a GC root.
- `build/guix-runtime`: a project-local profile with both programs, foot,
  fuzzel, and DejaVu fonts.

`--build-only` omits the combined profile. `GUIX_BUILD_CORES` defaults to 2;
the script allows one derivation at a time. Logs are written to `evidence/`.
Substitutes use the official `ci.guix.gnu.org` and `bordeaux.guix.gnu.org`
servers, in that order. Set `GUIX_SUBSTITUTE_URLS` to a space-separated list
to select other already-authorized substitutes. Normal signature verification
remains enabled.
No system reconfiguration or changes to the user's Guix channels are needed.

This official revision dates to 2026-07-24 and matches the dependency graph
available on the development machine. The original 2026-09-16 revision
`6f48315b04782cbc06c614e641bcdd07aab8f5a3` authenticated and evaluated, but its
larger dependency update failed during substitute downloads with DNS errors.
Those attempts remain in the evidence logs. The selected baseline retains
Guix's normal grafting and all package tests.

For a shell using the runtime profile, source its environment in Bash:

```sh
export GUIX_PROFILE="$PWD/build/guix-runtime"
. "$GUIX_PROFILE/etc/profile"
export PATH="$GUIX_PROFILE/bin:$PATH"
```

Use the project's launcher to run the nested session. Installing the package
does not configure a display manager or prove GPU/session compatibility.

The manager recipe intentionally uses `local-file`: it builds the source
currently under review. It is not an upstream Guix submission with a public
release origin. Generated build products, logs, release archives and Git data
are excluded from that source snapshot. The River recipe uses fixed public
source archives with SHA-256 hashes and verifies Zig's dependency hashes
before its offline build.

## Original loading and build failures

The supplied channel file began with `(use-modules (guix channels))`. Current
Guix evaluates channel files in an isolated environment that supplies channel
constructors but excludes `use-modules`; this produced the reported unbound
variable before the River recipe was loaded. `channels.scm` is now a plain
channel expression and retains the channel introduction and fixed commit.

The River recipe also mixed labelled and unlabelled native inputs, which Guix
rejected during package evaluation. All its native inputs now use one format.

The first actual River build showed that Aro's C translator could not find
`libinput.h`. Guix's pkg-config normally omits include paths already present
in `C_INCLUDE_PATH`, but Aro does not consume that environment variable.
The recipe sets `PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1` to preserve those flags.

## Checks

```sh
guix time-machine -C packaging/guix/channels.scm -- describe
guix lint -e '(load "packaging/guix/river.scm")'
guix lint -e '(load "packaging/guix/guix.scm")'
guix style -n -f packaging/guix/river.scm packaging/guix/guix.scm
```

The channel check pulls and authenticates the pinned revision through
`time-machine`, without updating the user's current `guix` profile. Actual
results and any remaining limitations are recorded in `evidence/guix-*.log`.

## Optional input configuration

`channel.scm` supplies the separate Channel daemon for River's input-management,
XKB and libinput protocols. It is pinned with its dependencies and is not added
to the generic runtime profile. A custom desktop may load the package expression
and start `channel` after placing its `config.rh` under the River config
directory. The package and all available dependency tests are described in
[SOURCES.md](SOURCES.md). Device-specific rules belong in the machine's desktop
configuration. A successful package build does not test physical input devices.

On proprietary NVIDIA Guix systems, the River package must participate in the
same Mesa-to-NVIDIA package transformation as the rest of the desktop. Merely
selecting an NVIDIA EGL ICD does not replace a River dependency linked directly
to Mesa's EGL. The user's existing nonguix transformation passed a nested GLES2
trial; it is deliberately not imposed on the generic, free-software recipe.
