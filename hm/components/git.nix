{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux;
  cfg = config.shared.git;
  sharedGitConfig = import ../../shared/git/config.nix;
  gitOptions = import ../../shared/git/options.nix {inherit lib;};
  sharedGitShellAliases = import ../../shared/git/shell-aliases.nix;
in
  with lib; {
    options.shared.git = gitOptions;

    config = mkIf cfg.enable {
      programs.git = {
        enable = true;

        signing = {
          signByDefault = isLinux;
          key = null;
          signer = lib.getExe pkgs.gnupg;
        };

        ignores = [
          "**/.cache/"
          "**/.idea/"
          "**/.~lock*"
          "**/.direnv/"
          "**/node_modules"
          "**/result"
          "**/result-*"
        ];

        settings =
          sharedGitConfig
          // {
            inherit (cfg) user;
          };
      };

      home.shellAliases = sharedGitShellAliases;
    };
  }
