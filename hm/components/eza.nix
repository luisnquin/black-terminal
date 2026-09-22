{
  config,
  lib,
  ...
}: let
  cfg = config.shared.eza;
in
  with lib; {
    options.shared.eza = {
      enable = mkEnableOption "Shared eza";
    };

    config = mkIf cfg.enable {
      # The per-shell integrations only emit their own aliases, which these replace.
      programs.eza = {
        enable = true;
        enableZshIntegration = false;
        enableBashIntegration = false;
        enableFishIntegration = false;
      };

      home.shellAliases = import ../../shared/eza/shell-aliases.nix;
    };
  }
