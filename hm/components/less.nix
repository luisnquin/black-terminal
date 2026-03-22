{
  config,
  lib,
  ...
}: let
  cfg = config.shared.less;
in
  with lib; {
    options.shared.less = {
      enable = mkEnableOption "Shared less";
    };

    config = mkIf cfg.enable {
      programs.less = {
        enable = true;

        options = {
          R = true; # raw control chars
          F = true; # quit if content fits screen
          X = true; # no clear screen on exit
          M = true; # long prompt
          S = true; # chop long lines
          i = true; # case-insensitive search
          mouse = true;
        };
      };
    };
  }
