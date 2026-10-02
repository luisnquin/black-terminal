{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.tmux;
  inherit (lib) mkEnableOption mkOption types mkIf optionalString concatStringsSep concatMapStrings filter;

  autoStartSkipGuard = concatMapStrings (v: " && -z \"\${${v}:-}\"") cfg.autoStartSkipEnv;

  apps = import ./apps.nix {inherit pkgs;};
  tmuxDaemons = pkgs.callPackage ./daemons {};

  builtinTheme = cfg.theme.plugin == null;

  daemonNames =
    lib.optional cfg.status.gpg.enable "gpg"
    ++ lib.optional cfg.status.ssh.enable "ssh"
    ++ lib.optional cfg.status.lsyncd.enable "lsyncd";
  daemonArgs = concatStringsSep " " daemonNames;
  daemons = optionalString (daemonNames != []) "#(tmux-daemons segment ${daemonArgs})";
  daemonsMenu = "run -b 'tmux-daemons menu #{client_name} ${daemonArgs}'";
  daemonsBindings = optionalString (daemonNames != []) ''
    bind -n MouseUp1Status if -F '#{==:#{mouse_status_range},daemons}' "${daemonsMenu}"
    bind a ${daemonsMenu}
  '';

  statusRight = concatStringsSep "   " (filter (s: s != "") [
    daemons
    (optionalString cfg.status.git.enable ''#(tmux-git-status "#{pane_current_path}")'')
  ]);
in {
  options.shared.tmux = {
    enable = mkEnableOption "Shared tmux configuration";

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Exec tmux from interactive zsh startup. Disable when the terminal emulator launches tmux itself.";
    };

    autoStartSkipEnv = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["HERDR_ENV" "SSH_CONNECTION"];
      description = "Env vars that suppress autostart when set, e.g. when another multiplexer or an SSH-side launcher owns the shell.";
    };

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

          git.enable = mkOption {
            type = types.bool;
            default = true;
            description = "Show git branch segment, colored by worktree state.";
          };
        };
      };
      default = {};
    };

    theme = {
      plugin = mkOption {
        type = types.nullOr types.package;
        default = null;
        example = lib.literalExpression "pkgs.tmuxPlugins.rose-pine";
        description = "tmux theme plugin. Null uses the built-in theme.";
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Theme plugin options, sourced before the plugin runs.";
      };
    };
  };

  config = mkIf cfg.enable {
    programs.tmux = {
      enable = true;
      extraConfig =
        builtins.readFile ./tmux.conf
        + "\n"
        + optionalString builtinTheme (builtins.readFile ./theme.conf + "\n")
        + "set -g status-right '${statusRight}'\n"
        + daemonsBindings;

      plugins = with pkgs.tmuxPlugins;
        [
          pain-control
          sensible
          logging
          copycat
        ]
        ++ lib.optional (!builtinTheme) {
          plugin = cfg.theme.plugin;
          inherit (cfg.theme) extraConfig;
        };
    };

    programs.zsh.initContent = lib.mkMerge [
      (lib.mkIf (cfg.status.lsyncd.enable && cfg.status.lsyncd.hideOnRemoteSsh) (
        lib.mkOrder 490 ''
          if [[ -n "''${SSH_CONNECTION:-}" || -n "''${SSH_CLIENT:-}" || -n "''${SSH_TTY:-}" ]]; then
            export TMUX_HIDE_LSYNCD=1
          fi
        ''
      ))
      (lib.mkIf cfg.autoStart (lib.mkOrder 500 ''
        if [[ -z "$TMUX"${autoStartSkipGuard} && "$TERM_PROGRAM" != "vscode" && "$USER" != "root" ]]; then
          exec ${lib.getExe pkgs.tmux}
        fi
      ''))
    ];

    home.packages = [
      tmuxDaemons
      apps.paneBreathStatus
      apps.gitStatus
    ];
  };
}
