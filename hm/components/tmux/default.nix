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
      };

      home.packages = [
        pkgs.gitmux
      ];

      xdg.configFile = {
        ".gitmux.conf".text = builtins.readFile ./gitmux.conf;
      };
    };
  }
