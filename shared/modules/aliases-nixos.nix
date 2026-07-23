{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux isDarwin;
  cfg = config.shared.aliases;
in
  with lib; {
    options.shared.aliases = {
      enable = mkEnableOption "Shared aliases";
    };

    config = mkIf cfg.enable {
      environment.shellAliases = import ../aliases/shell-aliases.nix {
        inherit isLinux isDarwin;
      };
    };
  }
