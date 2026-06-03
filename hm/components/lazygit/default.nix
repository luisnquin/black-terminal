{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.lazygit;

  lazygitConfigDir =
    if pkgs.stdenv.hostPlatform.isDarwin && !config.xdg.enable
    then "Library/Application Support/lazygit"
    else "${config.xdg.configHome}/lazygit";
in
  with lib; {
    options.shared.lazygit = {
      enable = mkEnableOption "Shared lazygit";
    };

    config = mkIf cfg.enable {
      programs.lazygit.enable = false;

      home.packages = [
        pkgs.lazygit
      ];

      home.file."${lazygitConfigDir}/config.yml" = {
        source = builtins.path {
          name = "lazygit-config.yml";
          path = ./config.yml;
        };
        force = true;
      };
    };
  }
