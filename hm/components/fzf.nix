{
  config,
  lib,
  ...
}: let
  cfg = config.shared.fzf;
in
  with lib; {
    options.shared.fzf = {
      enable = mkEnableOption "Shared fzf";
    };

    config = mkIf cfg.enable {
      programs.fzf = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;

        colors = {
          "fg" = "#e8d4f3";
          "fg+" = "#d0d0d0";
          "bg" = "-1";
          "bg+" = "#221326";
          "hl" = "#4eb0d0";
          "hl+" = "#4eb8dc";

          "spinner" = "#af5fff";
          "marker" = "#782cce";
          "prompt" = "#3d848b";
          "pointer" = "#af5fff";
          "header" = "#87afaf";
          "info" = "#d2d286";

          "border" = "#262626";
          "query" = "#d9d9d9";
          "label" = "#aeaeae";
        };

        defaultOptions = [
          "--border=rounded"
          "--preview-window=border-rounded"
          "--prompt='> '"
          "--marker='>'"
          "--pointer='◆'"
          "--separator='─'"
          "--scrollbar='│'"
        ];
      };
    };
  }
