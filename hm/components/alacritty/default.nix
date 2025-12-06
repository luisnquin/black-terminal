{
  config,
  lib,
  ...
}: let
  cfg = config.shared.alacritty;
in
  with lib; {
    options.shared.alacritty = {
      enable = mkEnableOption "Shared Alacritty";
    };

    config = mkIf cfg.enable {
      programs.alacritty.enable = true;

      xdg.configFile = {
        "alacritty.toml".text = builtins.readFile ./alacritty.toml;
      };
    };
  }
