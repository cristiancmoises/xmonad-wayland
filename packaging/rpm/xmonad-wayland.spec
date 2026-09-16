# Local source recipe for Fedora and openSUSE; not built on either distribution.
# There is no published project download URL: supply Source0 locally.
Name:           xmonad-wayland
Version:        0.1.0
Release:        1%{?dist}
Summary:        Experimental XMonad StackSet window manager for River Wayland
License:        BSD-3-Clause AND MIT
Source0:        %{name}-%{version}.tar.gz
BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  /usr/bin/pkg-config
BuildRequires:  ghc >= 9.0
BuildRequires:  ghc-base-devel
BuildRequires:  ghc-containers-devel
BuildRequires:  ghc-transformers-devel
BuildRequires:  ghc-process-devel
BuildRequires:  ghc-directory-devel
BuildRequires:  pkgconfig(wayland-client) >= 1.20
BuildRequires:  pkgconfig(wayland-scanner) >= 1.20
BuildRequires:  python3
Requires:       river >= 0.4
Recommends:     foot
Recommends:     fuzzel

# This local recipe does not claim to produce useful GHC debuginfo.
%global debug_package %{nil}

%description
An independent experimental port of XMonad's pure StackSet core to native
Wayland through River 0.4 or newer. River supplies the compositor; this package
supplies its window-management policy. River classic/0.3 is incompatible.
Existing arbitrary X11 xmonad.hs and XMonad.Contrib modules are not supported.

%prep
%setup -q

%build
make %{?_smp_mflags} all PREFIX=%{_prefix} CFLAGS="%{optflags}"

%check
make test

%install
make install PREFIX=%{_prefix} DESTDIR=%{buildroot}

%files
%license LICENSE licenses
%doc %{_datadir}/doc/xmonad-wayland
%{_bindir}/xmonad-wayland
%{_bindir}/xmonad-wayland-session
%{_datadir}/wayland-sessions/xmonad-wayland.desktop
%{_datadir}/xmonad-wayland

%changelog
* Wed Sep 16 2026 Local Builder <root@localhost> - 0.1.0-1
- Initial local experimental recipe; not a distribution-maintained package.
