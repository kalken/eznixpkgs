# ezconf.nix
{ stdenv, lib, makeWrapper, neovim, nixd, alejandra, fetchFromGitHub }:

stdenv.mkDerivation {
  pname = "ezconf";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "kalken";
    repo = "ezconf";
    rev = "d7e2ffeaa85533b6a824a7c8746cd976453e8ea0";
    sha256 = "sha256-E3NXBrj4RY95t46Z7EO/q71f6YsDBeNkywziBojbId8=";
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ nixd alejandra ];

  installPhase = ''
    mkdir -p $out/share/nvim
    cp -r * $out/share/nvim/
    
    mkdir -p $out/bin
    makeWrapper ${neovim}/bin/nvim $out/bin/ezconf \
      --add-flags "-u $out/share/nvim/init.lua" \
      --prefix PATH : ${lib.makeBinPath [ nixd alejandra ]} \
      --set NVIM_APPNAME ezconf \
      --add-flags "--cmd 'set runtimepath^=$out/share/nvim'"
  '';

  meta = with lib; {
    description = "My Neovim configuration";
    homepage = "https://github.com/kalken/ezconf";
    license = licenses.mit;
    maintainers = [ ];
  };
}
