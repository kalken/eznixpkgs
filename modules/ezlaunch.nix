# ezlaunch/ezlaunch.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.ezlaunch;

  toValue = v: if lib.isBool v then (if v then "1" else "0") else toString v;

  exeTypes = [
    "application/x-ms-dos-executable"
    "application/x-msdownload"
    "application/vnd.microsoft.portable-executable"
  ];

  # The window with all the games, in the start menu
  manager = pkgs.makeDesktopItem {
    name = "ezlaunch-manager";
    desktopName = "ezlaunch";
    comment = "Run, change and remove the Windows games added with ezlaunch";
    exec = "ezlaunch gui";
    icon = "applications-games";
    categories = [
      "Game"
      "Utility"
    ];
  };

  # Not shown in the menu: it only exists so a .exe can be opened with ezlaunch add
  handler = pkgs.makeDesktopItem {
    name = "ezlaunch";
    desktopName = "ezlaunch";
    comment = "Install a Windows game with Proton";
    exec = "ezlaunch add %f";
    mimeTypes = exeTypes;
    noDisplay = true;
  };

  # Under Open With in the file manager, for a game that is already on the disk
  addInstalled = pkgs.makeDesktopItem {
    name = "ezlaunch-add-installed";
    desktopName = "Add installed game to ezlaunch";
    comment = "Add a Windows game that is already on the disk, without an installer";
    exec = "ezlaunch add --installed %f";
    mimeTypes = exeTypes;
  };
in
{
  options.programs.ezlaunch = {
    enable = lib.mkEnableOption "ezlaunch — install and launch Windows games with Proton";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ezlaunch;
      defaultText = lib.literalExpression "pkgs.ezlaunch";
      description = "The ezlaunch package.";
    };

    defaults = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = {
        PROTONPATH = "GE-Proton-Latest";
      };
      description = ''
        Environment variables every game starts with, written to /etc/ezlaunch/config.
        Any Proton option works. A game's own settings (right-click Settings) override these.
        `PROTONPATH` can be a name from `~/.local/share/Steam/compatibilitytools.d`
        (see services.ezproton), a full path, or a version umu downloads itself.
        Booleans become 1 and 0.
      '';
      example = {
        PROTONPATH = "GE-Proton-Latest";
        PROTON_ENABLE_WAYLAND = true;
        PROTON_ENABLE_HDR = true;
        MANGOHUD = true;
      };
    };

    exeHandler = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open .exe files with `ezlaunch add` when they are double-clicked.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      manager
    ]
    ++ lib.optionals cfg.exeHandler [
      handler
      addInstalled
    ];

    environment.etc."ezlaunch/config".text = lib.concatStrings (
      lib.mapAttrsToList (k: v: "${k}=${toValue v}\n") cfg.defaults
    );

    xdg.mime.defaultApplications = lib.mkIf cfg.exeHandler (
      lib.genAttrs exeTypes (_: "ezlaunch.desktop")
    );
  };
}
