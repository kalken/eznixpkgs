{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage {
  pname = "ezsocks-rs";
  version = "unstable-2026-10-31";

  src = fetchFromGitHub {
    owner = "kalken";
    repo = "ezsocks-rs";
    rev = "124d69af90072277c03eb84e9c9c5345535e6fa7"; # develop branch
    hash = "sha256-hOObc5hu0SWan+RQTjB3pMVOUAE2VJS1w3NPIE1svX8=";
  };

  cargoHash = "sha256-bhvn7oSLi3A9JX4j5f3ZvTt6hRCaSDpYM7NHRWzSYQ0=";

  meta = with lib; {
    description = "Small SOCKS5 proxy for network namespaces, with Happy Eyeballs";
    homepage = "https://github.com/kalken/ezsocks-rs";
    license = licenses.mit;
    mainProgram = "ezsocks";
    platforms = platforms.unix;
  };
}
