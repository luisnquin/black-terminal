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

  removeCursorCoauthorHook = pkgs.writeShellScript "git-commit-msg-remove-cursor-coauthor" ''
    set -euo pipefail
    msg_file="$1"

    ${lib.getExe pkgs.gnused} -i '/^Co-authored-by: Cursor <cursoragent@cursor\.com>$/d' "$msg_file"

    ${lib.getExe pkgs.perl} -0pi -e 's/\n{3,}\z/\n\n/' "$msg_file"
  '';
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
          commit-msg = removeCursorCoauthorHook;
        };
      };

      home.shellAliases = sharedGitShellAliases;
    };
  }
