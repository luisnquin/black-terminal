{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.tmux;
  inherit (lib) mkEnableOption mkOption types mkIf optionalString concatStringsSep filter;

  lsyncdHideBlock = optionalString (cfg.status.lsyncd.enable && cfg.status.lsyncd.hideOnRemoteSsh) ''
    if [ "''${TMUX_HIDE_LSYNCD:-0}" = 1 ]; then
      exit 0
    fi

  '';

  apps = import ./apps.nix {
    inherit pkgs;
    inherit lsyncdHideBlock;
  };

  statusRight = concatStringsSep " " (filter (s: s != "") [
    (optionalString cfg.status.gpg.enable "#(tmux-gpg-agent-status)")
    (optionalString cfg.status.ssh.enable "#(tmux-ssh-agent-status)")
    (optionalString cfg.status.lsyncd.enable "#(tmux-lsyncd-status)")
    (optionalString cfg.status.gitmux.enable ''#(gitmux -cfg $HOME/.config/gitmux.conf "#{pane_current_path}")'')
  ]);
in {
  options.shared.tmux = {
    enable = mkEnableOption "Shared tmux configuration";

    status = mkOption {
      description = "Which segments appear in tmux status-right.";
      type = types.submodule {
        options = {
          gpg.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Show GPG agent segment.";
          };

          ssh.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Show SSH agent segment.";
          };

          lsyncd = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Show lsyncd segment.";
            };

            hideOnRemoteSsh = mkOption {
              type = types.bool;
              default = true;
              description = "Hide lsyncd segment when tmux starts from a remote SSH session.";
            };
          };

          gitmux.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Show gitmux segment.";
          };
        };
      };
      default = {};
    };

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
        + "set -g status-right '${statusRight}'\n"
        + cfg.theme.extraConfig;

      plugins = with pkgs.tmuxPlugins; [
        pain-control
        sensible
        logging
        copycat
        cfg.theme.plugin
      ];
    };

    programs.zsh.initContent = lib.mkMerge [
      (lib.mkIf (cfg.status.lsyncd.enable && cfg.status.lsyncd.hideOnRemoteSsh) (
        lib.mkOrder 490 ''
          if [[ -n "''${SSH_CONNECTION:-}" || -n "''${SSH_CLIENT:-}" || -n "''${SSH_TTY:-}" ]]; then
            export TMUX_HIDE_LSYNCD=1
          fi
        ''
      ))
      (lib.mkOrder 500 ''
        if [[ -z "$TMUX" && "$TERM_PROGRAM" != "vscode" && "$USER" != "root" ]]; then
          exec ${lib.getExe pkgs.tmux}
        fi
      '')
    ];

    home.packages = [
      pkgs.gitmux
      apps.lsyncdStatus
      apps.paneBreathStatus
      apps.gpgAgentStatus
      apps.sshAgentStatus
    ];

    xdg.configFile."gitmux.conf".source = ./gitmux.conf;
  };
}
