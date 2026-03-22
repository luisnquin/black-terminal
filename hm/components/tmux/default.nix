{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.tmux;
  inherit (lib) mkEnableOption mkOption types mkIf;
in {
  options.shared.tmux = {
    enable = mkEnableOption "Shared tmux configuration";

    theme = {
      plugin = mkOption {
        type = types.package;
        default = pkgs.tmuxPlugins.tokyo-night-tmux;
        description = "Package for the tmux theme.";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = ''
          set -g @tokyo-night-tmux_theme night
          set -g @tokyo-night-tmux_transparent 0
          set -g @theme_variation 'storm'
          set -g @theme_left_separator ''
          set -g @theme_right_separator ''
        '';
        description = "Additional theme-specific tmux configuration.";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      extraConfig = builtins.readFile ./tmux.conf;

      plugins = with pkgs.tmuxPlugins; [
        pain-control
        sensible
        logging
        copycat
        cfg.theme
      ];
    };

    home.packages = [pkgs.gitmux];

    xdg.configFile."gitmux.conf".source = ./gitmux.conf;
  };
}
