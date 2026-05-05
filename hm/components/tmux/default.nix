{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.tmux;
  inherit (lib) mkEnableOption mkOption types mkIf;

  lsyncdStatus = pkgs.writeShellApplication {
    name = "tmux-lsyncd-status";
    runtimeInputs = with pkgs; [
      tmux
      gnugrep
      gnused
    ];
    text = ''
      set -euo pipefail

      if [ "''${TMUX_HIDE_LSYNCD:-0}" = 1 ]; then
        exit 0
      fi

      status_file="$(tmux show-option -gqv @lsyncd_status_file)"
      status_file="''${status_file:-/tmp/lsyncd.status}"

      if ! pgrep -x lsyncd >/dev/null 2>&1; then
        printf "lsyncd: down"
        exit 0
      fi

      if [ ! -f "$status_file" ]; then
        printf "lsyncd: ?"
        exit 0
      fi

      content="$(cat "$status_file" 2>/dev/null || true)"

      active="$(printf '%s\n' "$content" | sed -nE 's/.*active[:=][[:space:]]*([0-9]+).*/\1/p' | head -n1)"
      queued="$(printf '%s\n' "$content" | sed -nE 's/.*queued[:=][[:space:]]*([0-9]+).*/\1/p' | head -n1)"

      if printf '%s\n' "$content" | grep -qi 'error'; then
        printf "lsyncd: error"
      elif [ -n "''${active:-}" ] && [ "$active" -gt 0 ]; then
        printf "lsyncd: sync %s" "$active"
      elif [ -n "''${queued:-}" ] && [ "$queued" -gt 0 ]; then
        printf "lsyncd: queued %s" "$queued"
      else
        printf "lsyncd: ok"
      fi
    '';
  };
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
      extraConfig =
        builtins.readFile ./tmux.conf
        + "\n"
        + cfg.theme.extraConfig;

      plugins = with pkgs.tmuxPlugins; [
        pain-control
        sensible
        logging
        copycat
        cfg.theme.plugin
      ];
    };

    programs.zsh.initContent = ''
      if [ -n "''${SSH_CONNECTION:-}" ] || [ -n "''${SSH_CLIENT:-}" ] || [ -n "''${SSH_TTY:-}" ]; then
        export TMUX_HIDE_LSYNCD=1
      fi

      if [ "$TMUX" = "" ] && [ "$TERM_PROGRAM" != "vscode" ] && [ ! "$USER" = "root" ]; then
          exec ${pkgs.tmux}/bin/tmux
      fi
    '';

    home.packages = [
      pkgs.gitmux
      lsyncdStatus
    ];

    xdg.configFile."gitmux.conf".source = ./gitmux.conf;
  };
}
