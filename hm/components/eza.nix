{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isDarwin isLinux;
  cfg = config.shared.eza;
in
  with lib; {
    options.shared.eza = {
      enable = mkEnableOption "Shared eza";
    };

    config = mkIf cfg.enable {
      programs.eza = {
        enable = true;
        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        enableFishIntegration = isDarwin;
      };

      home.shellAliases = import ../../shared/eza/shell-aliases.nix;
    };
  }
