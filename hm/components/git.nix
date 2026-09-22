{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  cfg = config.shared.git;
  sharedGitConfig = import ../../shared/git/config.nix;
  gitOptions = import ../../shared/git/options.nix {inherit lib;};
  sharedGitShellAliases = import ../../shared/git/shell-aliases.nix;

  chainRepoHook = pkgs.writeShellScript "git-chain-repo-hook" ''
    export CHAIN_REPO_HOOK_GIT=${config.programs.git.package}/bin/git

    ${builtins.readFile ../../shared/git/chain-repo-hook.sh}
  '';

  commitMsgScript =
    pkgs.writeShellScript "git-commit-msg-hook"
    (builtins.readFile ../../shared/git/commit-msg-hook.sh);

  commentBudgetScript =
    pkgs.writeText "git-comment-budget.pl"
    (builtins.readFile ../../shared/git/comment-budget.pl);

  mkCommentBudgetHook = mode:
    pkgs.writeShellScript "git-comment-budget-${mode}" ''
      export COMMENT_BUDGET_GIT=${config.programs.git.package}/bin/git

      exec ${pkgs.perl}/bin/perl ${commentBudgetScript} ${mode}
    '';

  deadnixHook = pkgs.writeShellScript "git-deadnix-hook" ''
    export DEADNIX_HOOK_GIT=${config.programs.git.package}/bin/git
    export DEADNIX_HOOK_DEADNIX=${lib.getExe pkgs.deadnix}

    ${builtins.readFile ../../shared/git/deadnix-hook.sh}
  '';

  bannedLanguagesHook = pkgs.writeShellScript "git-banned-languages-hook" ''
    export BANNED_LANGUAGES_GIT=${config.programs.git.package}/bin/git

    ${builtins.readFile ../../shared/git/banned-languages-hook.sh}
  '';

  commitMsgHook = pkgs.writeShellScript "git-commit-msg" ''
    set -e

    ${commitMsgScript} "$@"

    exec ${chainRepoHook} commit-msg "$@"
  '';

  preCommitHook = pkgs.writeShellScript "git-pre-commit" ''
    set -e

    ${bannedLanguagesHook}
    ${deadnixHook}
    ${mkCommentBudgetHook "pre-commit"}

    exec ${chainRepoHook} pre-commit "$@"
  '';

  postCommitHook = pkgs.writeShellScript "git-post-commit" ''
    ${mkCommentBudgetHook "post-commit"}

    exec ${chainRepoHook} post-commit "$@"
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
          commit-msg = commitMsgHook;
          pre-commit = preCommitHook;
          post-commit = postCommitHook;
        };
      };

      home.shellAliases = sharedGitShellAliases;
    };
  }
