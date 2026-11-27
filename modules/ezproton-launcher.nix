# ezproton-launcher/ezproton-launcher.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.ezproton-launcher;

  toValue = v: if lib.isBool v then (if v then "1" else "0") else toString v;

  exeTypes = [
    "application/x-ms-dos-executable"
    "application/x-msdownload"
    "application/vnd.microsoft.portable-executable"
  ];

  # The window with all the prefixes, in the start menu
  manager = pkgs.makeDesktopItem {
    name = "ezproton-launcher-manager";
    desktopName = "ezproton-launcher";
    comment = "Run, change and remove the Windows programs added with ezproton-launcher";
    exec = "ezproton-launcher gui";
    icon = "applications-games";
    categories = [ "Utility" ];
  };

  # Not shown in the menu: it only exists so a .exe can be opened with ezproton-launcher add
  handler = pkgs.makeDesktopItem {
    name = "ezproton-launcher";
    desktopName = "ezproton-launcher";
    comment = "Install a Windows program with Proton";
    exec = "ezproton-launcher add %f";
    mimeTypes = exeTypes;
    noDisplay = true;
  };

  # Under Open With in the file manager, for a program that is already on the disk
  addInstalled = pkgs.makeDesktopItem {
    name = "ezproton-launcher-add-installed";
    desktopName = "Add installed program to ezproton-launcher";
    comment = "Add a Windows program that is already on the disk, without an installer";
    exec = "ezproton-launcher add --installed %f";
    mimeTypes = exeTypes;
  };

  # Under Open With, to install a program in a prefix that exists
  installIn = pkgs.makeDesktopItem {
    name = "ezproton-launcher-install-in";
    desktopName = "Install in an existing ezproton-launcher prefix";
    comment = "Run a Windows installer in a prefix that is already added";
    exec = "ezproton-launcher install-in %f";
    mimeTypes = exeTypes;
  };

  # Under Open With, for a program that is on the disk, as another entry of a prefix
  addTo = pkgs.makeDesktopItem {
    name = "ezproton-launcher-add-to";
    desktopName = "Add to an existing ezproton-launcher prefix";
    comment = "Add a Windows program as another start menu entry of a prefix that is already added";
    exec = "ezproton-launcher add-to %f";
    mimeTypes = exeTypes;
  };
in
{
  options.programs.ezproton-launcher = {
    enable = lib.mkEnableOption "ezproton-launcher — install and launch Windows programs and games with Proton";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ezproton-launcher;
      defaultText = lib.literalExpression "pkgs.ezproton-launcher";
      description = "The ezproton-launcher package.";
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
        Environment variables every prefix starts with, written to /etc/ezproton-launcher/config.
        Any Proton option works. A prefix's own settings (right-click Settings) override these.
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
      description = ''
        Open .exe files with `ezproton-launcher add` when they are double-clicked.
        On KDE this also turns off the "Open or Execute?" question for executable files
        (`/etc/xdg/kiorc`), so they open with their default app.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The start menu entries run each prefix's launch script, which needs umu-run on the PATH
    environment.systemPackages = [
      cfg.package
      manager
      pkgs.umu-launcher
    ]
    ++ lib.optionals cfg.exeHandler [
      handler
      addInstalled
      installIn
      addTo
    ];

    environment.etc."ezproton-launcher/config".text = lib.concatStrings (
      lib.mapAttrsToList (k: v: "${k}=${toValue v}\n") cfg.defaults
    );

    # KDE asks "Open or Execute?" before opening an executable file; open it with its app instead.
    # ezlaunch writes the same file, so the text is only set when it is not.
    environment.etc."xdg/kiorc" =
      lib.mkIf
        (cfg.exeHandler && !(config.programs.ezlaunch.enable && config.programs.ezlaunch.exeHandler))
        {
          text = ''
            [Executable scripts]
            behaviourOnLaunch=open
          '';
        };

    # Wins over ezlaunch when both are enabled
    xdg.mime.defaultApplications = lib.mkIf cfg.exeHandler (
      lib.genAttrs exeTypes (_: lib.mkOverride 90 "ezproton-launcher.desktop")
    );
  };
}
