{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenv) isDarwin isLinux;
  cfg = config.shared.ghostty;
in
  with lib; {
    options.shared.ghostty = {
      enable = mkEnableOption "Shared Ghostty";
      package = mkOption {
        type = types.nullOr types.package;
        default = pkgs.ghostty;
      };
      settings = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Extra settings to pass to Ghostty.";
      };
    };

    config = mkIf cfg.enable {
      programs.ghostty = {
        enable = true;
        package =
          if isDarwin
          then null
          else cfg.package;

        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        enableFishIntegration = isDarwin;

        settings =
          {
            theme = "Iceberg Dark";
            cursor-style = "bar";
            cursor-style-blink = "true";
            font-synthetic-style = "bold";

            background-opacity = "0.8";
            link-url = "true";
            working-directory = "home";

            window-padding-x = "15,4";
            window-padding-y = "8,6";
            window-vsync = "false";
            window-save-state = "never";
            window-decoration =
              if isDarwin
              then "auto"
              else "none";

            clipboard-read = "allow";
            clipboard-write = "allow";

            clipboard-trim-trailing-spaces = "true";
            clipboard-paste-protection = "true";
            shell-integration =
              if isLinux
              then "zsh"
              else "fish";
            desktop-notifications = "true";
            auto-update = "off";
            auto-update-channel = "tip";
          }
          // cfg.settings;
      };
    };
  }
