# Local port only, not submitted or built on FreeBSD.
# Put xmonad-wayland-0.1.0.tar.gz in a private DISTDIR, then run `make makesum`.
# No network download is configured and no distinfo checksum is fabricated.
PORTNAME=       xmonad-wayland
DISTVERSION=    0.1.0
CATEGORIES=     x11-wm
MASTER_SITES=
DISTFILES=      ${DISTNAME}.tar.gz

MAINTAINER=     root@localhost
COMMENT=        Experimental XMonad StackSet window manager for River Wayland

LICENSE=        BSD3CLAUSE MIT
LICENSE_COMB=   multi
LICENSE_FILE_BSD3CLAUSE= ${WRKSRC}/LICENSE

BUILD_DEPENDS=  ghc>=9.0:lang/ghc \
                wayland>=1.20:graphics/wayland
LIB_DEPENDS=    libwayland-client.so:graphics/wayland \
                libgmp.so:math/gmp \
                libffi.so:devel/libffi
RUN_DEPENDS=    river>=0.4:x11-wm/river

USES=           compiler:c11 gmake pkgconfig python:build
BINARY_ALIAS=   python3=${PYTHON_CMD}
MAKE_ARGS=      PREFIX=${PREFIX} CC=${CC}
ALL_TARGET=     all
TEST_TARGET=    test

PLIST_FILES=    bin/xmonad-wayland \
                bin/xmonad-wayland-session \
                share/wayland-sessions/xmonad-wayland.desktop
PORTDATA=       *
PORTDOCS=       *

do-install:
	${SETENV} ${MAKE_ENV} ${MAKE_CMD} -C ${WRKSRC} ${MAKE_ARGS} \
		DESTDIR=${STAGEDIR} install

.include <bsd.port.mk>
