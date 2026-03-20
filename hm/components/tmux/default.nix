{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.tmux;
in
  with lib; {
    options.shared.tmux = {
      enable = mkEnableOption "Shared tmux";
    };

    config = mkIf cfg.enable {
      programs.tmux = {
        enable = true;
        package = pkgs.tmux;
        extraConfig = builtins.readFile ./tmux.conf;

        plugins = with pkgs; [
          tmuxPlugins.pain-control
          tmuxPlugins.sensible
          tmuxPlugins.logging
          tmuxPlugins.copycat
          {
            plugin = tmuxPlugins.tokyo-night-tmux;
            extraConfig = ''
              set -g @tokyo-night-tmux_theme night
              set -g @tokyo-night-tmux_transparent 0
            '';
          }
        ];
      };

      home.packages = [
        pkgs.gitmux
      ];

      xdg.configFile = {
        ".gitmux.conf".text = builtins.readFile ./gitmux.conf;
      };
    };
  }
