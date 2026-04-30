{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.zsh;
in
  with lib; {
    options.shared.zsh = {
      enable = mkEnableOption "Shared Zsh";
    };

    config = mkIf cfg.enable {
      environment.systemPackages = [
        pkgs.zsh-completions
      ];

      programs.zsh = {
        enable = true;

        enableAutosuggestions = true;
        enableBashCompletion = true;
        enableCompletion = true;

        promptInit = ''
          if [ "$TMUX" = "" ] && [ "$TERM_PROGRAM" != "vscode" ] && [ ! "$USER" = "root" ]; then
              exec ${pkgs.tmux}/bin/tmux
          fi
        '';

        interactiveShellInit = builtins.readFile (builtins.path {
          name = "system-zshrc-script";
          path = ./../../shared/zsh/.zshrc;
        });
      };
    };
  }
