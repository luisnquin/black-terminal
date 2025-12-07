{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux isDarwin;
  cfg = config.shared.zoxide;
in
  with lib; {
    options.shared.zoxide = {
      enable = mkEnableOption "Shared Zoxide";
    };

    config = mkIf cfg.enable {
      programs.zoxide = {
        enable = true;
        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        enableFishIntegration = isDarwin;
        options = ["--cmd cd"];
      };
    };
  }
