{ pkgs, lib, theme ? null, configLua, vimOpts ? "" }:
let
  initLua = pkgs.writeText "config.lua" ''
    ${lib.optionalString (theme != null) ''
      ${lib.optionalString (theme.setup != "") theme.setup}
      vim.g.ezconf_theme = "${theme.colorscheme}"
    ''}
    -- User config
    ${builtins.readFile configLua}
    -- Injected by Nix (after user config to ensure they are not overridden)
    ${vimOpts}
  '';
  neovimPackage = pkgs.neovim.override {
    configure = {
      customRC = "luafile ${initLua}";
      packages.ezconf = {
        start = lib.optionals (theme != null) [ theme.plugin ] ++ [
          pkgs.vimPlugins.nvim-cmp
          pkgs.vimPlugins.luasnip
          pkgs.vimPlugins.cmp-nvim-lsp
          pkgs.vimPlugins.cmp-buffer
          pkgs.vimPlugins.cmp-path
          pkgs.vimPlugins.cmp_luasnip
        ];
      };
    };
  };
in pkgs.symlinkJoin {
  name = "ezconf";
  paths = [
    neovimPackage
    pkgs.nixd
    pkgs.alejandra
  ];
  postBuild = ''
    ln -s $out/bin/nvim $out/bin/ezconf
  '';
}
