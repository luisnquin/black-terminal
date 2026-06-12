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

  commitMsgHook =
    pkgs.writeShellScript "git-commit-msg-hook"
    (builtins.readFile ../../shared/git/commit-msg-hook.sh);
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

        hooks = {
          commit-msg = commitMsgHook;
        };
      };

      home.shellAliases = sharedGitShellAliases;
    };
  }
