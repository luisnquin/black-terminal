{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  cfg = config.shared.direnv;
in
  with lib; {
    options.shared.direnv = {
      enable = mkEnableOption "Shared direnv";

      whitelistPrefixes = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["$HOME/Projects" "$HOME/.dotfiles"];
        description = "Directory prefixes direnv loads without asking for `direnv allow`.";
      };
    };

    config = mkIf cfg.enable {
      programs.direnv = {
        enable = true;
        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        # enableFishIntegration = isDarwin; - readonly
        config =
          {
            global = {
              load_dotenv = true;
              warn_timeout = "5s";
            };
          }
          // optionalAttrs (cfg.whitelistPrefixes != []) {
            whitelist.prefix = cfg.whitelistPrefixes;
          };

        nix-direnv.enable = true;
      };

      home.sessionVariables = {
        DIRENV_LOG_FORMAT = ""; # "direnv: %s";
      };
    };
  }
