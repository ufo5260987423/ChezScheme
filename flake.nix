{ lib, stdenv, fetchurl
, coreutils, cctools
, darwin
, ncurses, libiconv, libX11, libuuid, testers
, gnumake, gcc, autoconf, automake,libtool
,zuo
 }:

stdenv.mkDerivation rec {
  name = "local-chezscheme";
  version = "1.0";
  src = ./.;
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
  ] ++ lib.optionals (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) [
    darwin.autoSignDarwinBinariesHook
  ];
  env.NIX_CFLAGS_COMPILE = lib.optionalString stdenv.cc.isGNU "-Wno-error=format-truncation";
  buildInputs = [ 
    libtool zuo
    ncurses libiconv libX11 libuuid ];
  patchPhase = ''
    substituteInPlace ./makefiles/installsh \
      --replace-warn "/usr/bin/true" "${coreutils}/bin/true"

    substituteInPlace zlib/configure \
      --replace-warn "/usr/bin/libtool" libtool
  '';
  configurePhase = ''
    ./configure --as-is --threads --installprefix=$out --installman=$out/share/man
  '';
  buildPath=''
    make -j8
  '';
}