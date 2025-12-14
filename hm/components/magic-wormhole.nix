{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.magic-wormhole;
in
  with lib; {
    options.shared.magic-wormhole = {
      enable = mkEnableOption "Shared magic wormhole";
    };

    config = mkIf cfg.enable {
      home = {
        packages = [pkgs.magic-wormhole];

        shellAliases = {
          "mw" = "magic-wormhole";
          "mw-s" = "magic-wormhole send";
          "mw-r" = "magic-wormhole receive";
        };
      };
    };
  }
