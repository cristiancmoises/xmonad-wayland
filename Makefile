PREFIX ?= /usr/local
DESTDIR ?=
GHC ?= ghc
CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
PYTHON ?= python3
GHCFLAGS ?= -O2 -Wall -threaded
MAIN ?= app/Main.hs
CFLAGS ?= -O2 -g
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags wayland-client) -Ibuild -Icbits
LDLIBS += $(shell $(PKG_CONFIG) --libs wayland-client)
PROTOCOLS = river-window-management-v1 river-xkb-bindings-v1
HEADERS = $(addprefix build/,$(addsuffix -client-protocol.h,$(PROTOCOLS)))
OBJECTS = build/bridge.o $(addprefix build/,$(addsuffix -protocol.o,$(PROTOCOLS)))
HASKELL = $(shell find src app vendor -name '*.hs')

.PHONY: all test test-policy test-protocol test-runtime install uninstall clean check-deps FORCE
all: build/xmonad-wayland

build:
	mkdir -p build

check-deps:
	$(PKG_CONFIG) --atleast-version=1.20 wayland-client
	$(WAYLAND_SCANNER) --version
	$(GHC) --numeric-version

build/%-client-protocol.h: protocols/%.xml | build
	$(WAYLAND_SCANNER) client-header $< $@

build/%-protocol.c: protocols/%.xml | build
	$(WAYLAND_SCANNER) private-code $< $@

build/%-protocol.o: build/%-protocol.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -c $< -o $@

build/bridge.o: cbits/bridge.c cbits/bridge.h $(HEADERS) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -Wall -Wextra -Werror -c $< -o $@

build/xmonad-wayland: $(HASKELL) $(MAIN) $(OBJECTS) FORCE | build
	$(GHC) $(GHCFLAGS) -isrc -ivendor -i$(dir $(MAIN)) -outputdir build/ghc $(MAIN) $(OBJECTS) $(LDLIBS) -o $@

build/policy-test: tests/PolicyTest.hs $(HASKELL) | build
	$(GHC) -O1 -Wall -isrc -ivendor -outputdir build/test-ghc tests/PolicyTest.hs -o $@

test-policy: build/policy-test
	./build/policy-test

test-protocol: build/xmonad-wayland
	$(PYTHON) tests/protocol_smoke.py ./build/xmonad-wayland

build/runtime-test/runtime-test: tests/RuntimeTest.hs tests/runtime_fixture.c $(HASKELL) | build
	mkdir -p build/runtime-test
	$(GHC) -Wall -Wno-unused-imports -Werror -threaded -isrc -ivendor -outputdir build/runtime-test tests/RuntimeTest.hs tests/runtime_fixture.c -o $@

test-runtime: build/runtime-test/runtime-test
	PYTHON="$(PYTHON)" sh tests/runtime_test.sh build/runtime-test/runtime-test

test: test-policy test-protocol test-runtime

install: all
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/share/wayland-sessions
	install -m755 build/xmonad-wayland $(DESTDIR)$(PREFIX)/bin/
	install -m755 scripts/xmonad-wayland-session $(DESTDIR)$(PREFIX)/bin/
	install -m644 packaging/xmonad-wayland.desktop $(DESTDIR)$(PREFIX)/share/wayland-sessions/
	install -d $(DESTDIR)$(PREFIX)/share/xmonad-wayland $(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland
	cp -R src vendor app examples cbits protocols tests scripts packaging Makefile LICENSE licenses README.md docs $(DESTDIR)$(PREFIX)/share/xmonad-wayland/
	cp -R LICENSE licenses README.md docs $(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland/

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/xmonad-wayland $(DESTDIR)$(PREFIX)/bin/xmonad-wayland-session
	rm -f $(DESTDIR)$(PREFIX)/share/wayland-sessions/xmonad-wayland.desktop
	rm -rf $(DESTDIR)$(PREFIX)/share/xmonad-wayland $(DESTDIR)$(PREFIX)/share/doc/xmonad-wayland

clean:
	rm -rf build
