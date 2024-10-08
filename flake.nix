{ lib, stdenv, fetchurl
, coreutils, cctools
, darwin
, ncurses, libiconv, libX11, libuuid, testers }:

stdenv.mkDerivation rec {
  name = "local-chezscheme";
  version = "1.0";
  src = ./.;
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
  ] ++ lib.optionals (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) [
    darwin.autoSignDarwinBinariesHook
  ];
  buildInputs = [ ncurses libiconv libX11 libuuid ];
  configurePhase = ''
    ./configure --as-is --threads --installprefix=$out --installman=$out/share/man
  '';
}