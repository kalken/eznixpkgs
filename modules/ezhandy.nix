{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ezhandy;

  # Modifier names as handy-keys parses them (handy-keys src/types/modifiers.rs, parse_single).
  # Handy's default (Tauri) shortcut backend needs a main key and rejects the side-specific
  # names, so a talk key made only of modifiers, or naming a side, needs HandyKeys.
  compoundModifiers = [ "cmd" "command" "meta" "super" "win" "windows" "shift" "ctrl" "control"
                        "opt" "option" "alt" "fn" "function" ];
  sideModifiers = lib.concatMap (m: [ "${m}left" "${m}_left" "${m}right" "${m}_right" ])
                    [ "cmd" "command" "super" "win" "windows" "meta" "shift" "ctrl" "control"
                      "opt" "option" "alt" ]
                  ++ [ "lcmd" "rcmd" "lcommand" "rcommand" "lshift" "rshift" "lctrl" "rctrl"
                       "lcontrol" "rcontrol" "lopt" "ropt" "loption" "roption" "lalt" "ralt"
                       "altgr" ];
  keyParts = key: map (p: lib.toLower (lib.trim p)) (lib.splitString "+" key);
  needsHandyKeys = key:
    lib.all (p: lib.elem p (compoundModifiers ++ sideModifiers)) (keyParts key)
    || lib.any (p: lib.elem p sideModifiers) (keyParts key);

  keyboardImplementation =
    if cfg.keyboardImplementation != "auto" then cfg.keyboardImplementation
    else if cfg.talkKey != null && needsHandyKeys cfg.talkKey then "handy_keys"
    else "tauri";
  useHandyKeys = keyboardImplementation == "handy_keys";

  # Handy rejects the whole stored binding map if one entry is incomplete, so the talk key is
  # written as a full binding (the default one from Handy's src-tauri/src/settings.rs).
  managed = lib.recursiveUpdate cfg.settings (lib.filterAttrs (_: v: v != null) {
    keyboard_implementation = keyboardImplementation;
    paste_method            = cfg.pasteMethod;
    # Handy's own login entry runs the unwrapped binary from a fixed store path, and would
    # shadow ours (same file name); the module's entry replaces it.
    autostart_enabled       = if cfg.autostart then false else null;
    bindings = if cfg.talkKey == null then null else {
      transcribe = {
        id              = "transcribe";
        name            = "Transcribe";
        description     = "Converts your speech into text.";
        default_binding = "ctrl+space";
        current_binding = cfg.talkKey;
      };
    };
  });
  managedJson = pkgs.writeText "ezhandy-settings.json" (builtins.toJSON managed);

  # Merges the managed settings into Handy's store, then starts Handy. Skipped while Handy is
  # running: it keeps the store in memory and would write over the merge (and a second launch
  # only hands its arguments to the running instance anyway).
  launcher = pkgs.writeShellApplication {
    name = "handy";
    runtimeInputs = [ pkgs.jq pkgs.procps pkgs.coreutils ];
    text = ''
      ${lib.optionalString (cfg.microphone != null) ''
        # Handy records through ALSA's pipewire plugin, which takes its target from here.
        export PIPEWIRE_NODE=${lib.escapeShellArg cfg.microphone}
      ''}
      store="''${XDG_DATA_HOME:-$HOME/.local/share}/com.pais.handy/settings_store.json"
      if ! pgrep -u "$(id -u)" -x .handy-wrapped >/dev/null; then
        mkdir -p "$(dirname "$store")"
        [ -s "$store" ] || echo '{}' > "$store"
        tmp=$(mktemp "$store.XXXXXX")
        if jq --slurpfile m ${managedJson} '.settings = ((.settings // {}) * $m[0])' "$store" > "$tmp"; then
          mv "$tmp" "$store"
        else
          echo "ezhandy: could not merge settings into $store, starting Handy without them" >&2
          rm -f "$tmp"
        fi
      fi
      exec ${cfg.package}/bin/handy "$@"
    '';
  };

  # The package with bin/handy replaced by the launcher; its desktop file runs `handy`, so the
  # app menu goes through the launcher too.
  package = pkgs.symlinkJoin {
    name = "ezhandy-${cfg.package.version}";
    paths = [ cfg.package ];
    postBuild = ''
      rm $out/bin/handy
      ln -s ${launcher}/bin/handy $out/bin/handy
    '';
  };
  # The login entry is system-wide; it starts Handy only for the configured users, the ones
  # with the package and the groups.
  autostartScript = pkgs.writeShellScript "ezhandy-autostart" ''
    case " ${lib.concatStringsSep " " cfg.users} " in
      *" $(${pkgs.coreutils}/bin/id -un) "*) exec ${package}/bin/handy --start-hidden ;;
    esac
  '';
in
{
  imports = [
    (lib.mkChangedOptionModule [ "programs" "ezhandy" "user" ] [ "programs" "ezhandy" "users" ]
      (config: [ config.programs.ezhandy.user ]))
  ];

  options.programs.ezhandy = {
    enable = lib.mkEnableOption "ezhandy - Handy offline speech-to-text, set up for Plasma Wayland";

    users = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      description = ''
        User accounts Handy is for: each gets the package and the groups it needs, and Handy
        starts at their login. Other users get neither.
      '';
      example     = [ "alice" "bob" ];
    };

    package = lib.mkPackageOption pkgs "handy" { };

    talkKey = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Shortcut for Transcribe (hold to talk, tap to toggle), in Handy's own key names:
        "ctrl+space", "f12", "end", "numpad0", "ctrl_right", "shift_right". A modifier on its
        own, or one naming a side, switches Handy to its HandyKeys backend (see
        keyboardImplementation). null leaves the shortcut to Handy's settings.
      '';
      example = "ctrl_right";
    };

    keyboardImplementation = lib.mkOption {
      type    = lib.types.enum [ "auto" "tauri" "handy_keys" ];
      default = "auto";
      description = ''
        Handy's shortcut backend. "tauri" listens through the desktop: apps still get the key.
        "handy_keys" reads the keyboards directly (adds the user to the input group) and
        swallows the talk key, so no app sees it; Handy calls it experimental. "auto" picks
        handy_keys when talkKey needs it, tauri otherwise.
      '';
    };

    pasteMethod = lib.mkOption {
      type    = lib.types.nullOr (lib.types.enum
                  [ "ctrl_v" "ctrl_shift_v" "shift_insert" "direct" "none" "external_script" ]);
      default = null;
      description = ''
        How Handy puts the text into the focused app. "ctrl_shift_v" works in terminals,
        browsers and (with kdePasteShortcut) KDE apps. "direct" types key by key: slow, and
        ydotool assumes a US layout. null leaves it to Handy's settings.
      '';
      example = "ctrl_shift_v";
    };

    kdePasteShortcut = lib.mkOption {
      type    = lib.types.bool;
      default = cfg.pasteMethod == "ctrl_shift_v";
      defaultText = lib.literalExpression ''pasteMethod == "ctrl_shift_v"'';
      description = ''
        Add Ctrl+Shift+V to KDE's standard Paste shortcut (/etc/xdg/kdeglobals), so KDE apps
        like Kate paste on it. KDE apps read that file on any desktop; nothing else does.
      '';
    };

    autoGain = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Give Handy its own microphone, run through PipeWire's WebRTC voice processing:
        automatic gain control, noise suppression and a high-pass filter, as in Discord and
        browser calls. Helps when the mic is quiet or uneven (some onboard audio, like ASUS's
        USB Realtek ALC4080, has no mic boost on Linux). Other programs keep the plain mic.
      '';
    };

    autoGainVolume = lib.mkOption {
      type    = lib.types.number;
      default = 1.0;
      description = ''
        Volume of the auto-gain microphone, after the processing (wpctl scale: 1.0 = 100%,
        3.0 ≈ +28 dB). WebRTC's gain control only adds so much, and starts over at each
        recording; raise this when Handy's recordings are still quiet. Set at every start of
        WirePlumber, which doesn't keep a volume for this source.
      '';
      example = 3.0;
    };

    microphone = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = if cfg.autoGain then "ezhandy-autogain" else null;
      defaultText = lib.literalExpression ''if autoGain then "ezhandy-autogain" else null'';
      description = ''
        PipeWire source (node.name, see `wpctl status` / `pw-cli ls Node`) Handy records from,
        whatever the default microphone is. null uses the default microphone. Applies to
        Handy's audio-feedback sounds too, which then don't play.
      '';
      example = "alsa_input.usb-Generic_USB_Audio-00.HiFi__Mic__source";
    };

    autostart = lib.mkOption {
      type    = lib.types.bool;
      default = true;
      description = "Start Handy hidden in the tray at login (/etc/xdg/autostart).";
    };

    settings = lib.mkOption {
      type    = (pkgs.formats.json { }).type;
      default = { };
      description = ''
        Any of Handy's settings, by the names in its settings_store.json, merged into it every
        time Handy starts. Settings not listed stay editable in the app; listed ones go back to
        these values at the next start. The options above win over the same keys here.
      '';
      example = lib.literalExpression ''
        {
          custom_words = [ "eznix" ];
          append_trailing_space = true;
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != [ ];
        message = "programs.ezhandy.users is empty: list the user accounts Handy is for.";
      }
      {
        assertion = cfg.talkKey == null || builtins.match ".*[[:space:]].*" cfg.talkKey == null;
        message = ''
          programs.ezhandy.talkKey "${toString cfg.talkKey}" contains a space. Handy's key names
          have none: "numpad0", not "numpad 0" (Handy's own shortcut recorder saves that form,
          and Handy can't parse it).
        '';
      }
      {
        assertion = cfg.talkKey == null || keyboardImplementation == "handy_keys"
                    || !needsHandyKeys cfg.talkKey;
        message = ''
          programs.ezhandy.talkKey "${toString cfg.talkKey}" needs the handy_keys backend
          (a modifier on its own, or a side-specific one), but keyboardImplementation is "tauri".
        '';
      }
      {
        assertion = cfg.microphone == null
                    || (config.services.pipewire.enable && config.services.pipewire.alsa.enable);
        message = ''
          programs.ezhandy.autoGain and programs.ezhandy.microphone need PipeWire with its ALSA
          support (services.pipewire.enable and services.pipewire.alsa.enable): Handy records
          through ALSA, and only PipeWire's ALSA plugin can send it to a chosen source.
        '';
      }
    ];

    users.users = lib.genAttrs cfg.users (_: {
      packages    = [ package ];
      # ydotool: Handy types and pastes through it on Wayland (wtype needs a protocol KWin
      # doesn't offer). input: HandyKeys reads /dev/input. Both take effect at the next login.
      extraGroups = [ "ydotool" ] ++ lib.optional useHandyKeys "input";
    });

    programs.ydotool.enable = true;

    # The echo-cancel module with the WebRTC library, in monitor mode (the default sink's
    # monitor is the echo reference, so no extra sink appears). Its capture side follows the
    # default microphone; passive nodes keep the mic closed until Handy records.
    services.pipewire.extraConfig.pipewire."60-ezhandy-autogain" = lib.mkIf cfg.autoGain {
      "context.modules" = [{
        name = "libpipewire-module-echo-cancel";
        args = {
          "library.name" = "aec/libspa-aec-webrtc";
          "monitor.mode" = true;
          "aec.args" = {
            "webrtc.gain_control"      = true;
            "webrtc.noise_suppression" = true;
            "webrtc.high_pass_filter"  = true;
          };
          "capture.props"  = { "node.name" = "ezhandy-autogain.capture"; "node.passive" = true; };
          "playback.props" = { "node.name" = "ezhandy-autogain.reference"; "node.passive" = true; };
          "source.props" = {
            "node.name"        = "ezhandy-autogain";
            "node.description" = "Microphone for Handy (auto gain)";
            # Never picked as the default microphone.
            "priority.session" = 0;
          };
        };
      }];
    };

    systemd.user.services.ezhandy-autogain-volume = lib.mkIf (cfg.autoGain && cfg.autoGainVolume != 1.0) {
      description = "Set the volume of Handy's auto-gain microphone";
      after       = [ "wireplumber.service" ];
      partOf      = [ "wireplumber.service" ];
      wantedBy    = [ "wireplumber.service" ];
      path        = [ pkgs.wireplumber pkgs.gnugrep pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        # The source appears once WirePlumber has linked the module up; wait for it.
        for _ in $(seq 50); do
          id=$(wpctl status | grep -E '[0-9]+\. ezhandy-autogain +\[Audio/Source\]' | grep -oE '[0-9]+' | head -n1 || true)
          if [ -n "$id" ]; then
            exec wpctl set-volume "$id" ${toString cfg.autoGainVolume}
          fi
          sleep 0.2
        done
        echo "ezhandy-autogain source not found" >&2
        exit 1
      '';
    };

    environment.etc."xdg/kdeglobals" = lib.mkIf cfg.kdePasteShortcut {
      text = ''
        [Shortcuts]
        Paste=Ctrl+V; Shift+Ins; Ctrl+Shift+V
      '';
    };

    environment.etc."xdg/autostart/Handy.desktop" = lib.mkIf cfg.autostart {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Handy
        Icon=handy
        Exec=${autostartScript}
        StartupNotify=false
        Terminal=false
      '';
    };
  };
}
