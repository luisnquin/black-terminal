{
  config,
  lib,
  ...
}: let
  cfg = config.shared.bat;
in
  with lib; {
    options.shared.bat = {
      enable = mkEnableOption "Shared bat";
    };

    config = mkIf cfg.enable {
      programs.bat = {
        enable = true;
        config = {
          theme = "Nord";
          italic-text = "always";
        };
      };
    };
  }
