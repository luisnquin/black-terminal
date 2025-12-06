{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux;
  cfg = config.shared.direnv;
in
  with lib; {
    options.shared.direnv = {
      enable = mkEnableOption "Shared direnv";
    };

    config = mkIf cfg.enable {
      programs.direnv = {
        enable = true;
        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        # enableFishIntegration = isDarwin; - readonly
        config = {
          global = {
            load_dotenv = true;
            warn_timeout = "5s";
          };

          whitelist = {
            prefix = [
              "$HOME/Projects/github.com/luisnquin"
              "$HOME/Projects/github.com/chanchitaapp"
              "$HOME/Projects/github.com/0xc000022070"
              "$HOME/.dotfiles"
            ];
          };
        };

        nix-direnv.enable = true;
      };

      home.sessionVariables = {
        DIRENV_LOG_FORMAT = "direnv: %s";
      };
    };
  }
