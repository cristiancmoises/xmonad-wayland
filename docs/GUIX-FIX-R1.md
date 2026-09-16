# Guix packaging correction r1

The original 0.1.0 Guix recipe failed during C compilation with:

```
make: cc: No such file or directory
```

The user's build log shows GCC in the build environment, while GNU make
defaults to the unavailable `cc` command. The recipe now passes `CC=gcc`
through `#:make-flags`. Existing build, test, and install phases are retained.
The application version remains 0.1.0; application code is unchanged.

Validation also exposed an intermittent socket-close race in the protocol test
harness. A client correctly rejecting an incompatible compositor can close its
socket before the harness sends a final acknowledgement. The harness now accepts
that disconnect in its expected-rejection scenarios while checking the client's
failure status and the specific rejection diagnostic. Successful-session tests
retain their existing disconnect checks.

Validation: reproduced the original failure in a temporary build PATH without
`cc`, then compiled the bridge and both generated protocol objects successfully
using `CC=gcc`. The application build and policy, protocol, and runtime tests
also passed with the available Linux/GHC 9.4.7 toolchain. A native Guix build
with the user's GHC 9.2.8 toolchain remains to be verified on their machine.

Running the graphical session still requires River 0.4 or newer; this change
does not install or update River.
