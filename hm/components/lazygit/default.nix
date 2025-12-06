{
  config,
  lib,
  ...
}: let
  cfg = config.shared.lazygit;
in
  with lib; {
    options.shared.lazygit = {
      enable = mkEnableOption "Shared lazygit";
    };

    config = mkIf cfg.enable {
      programs.lazygit.enable = true;

      xdg.configFile."lazygit/config.yml".source = builtins.path {
        name = "lazygit-config.yml";
        path = ./config.yml;
      };
    };
  }
