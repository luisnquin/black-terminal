{
  config,
  pkgs,
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
      environment = {
        systemPackages = [pkgs.eza];
        shellAliases = import ../eza/shell-aliases.nix;
      };
    };
  }
