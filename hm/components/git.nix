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

  codeGuardrailScript =
    pkgs.writeText "git-code-guardrail.pl"
    (builtins.readFile ../../shared/git/code-guardrail.pl);

  mkCodeGuardrailHook = mode:
    pkgs.writeShellScript "git-code-guardrail-${mode}" ''
      export CODE_GUARDRAIL_GIT=${config.programs.git.package}/bin/git

      exec ${pkgs.perl}/bin/perl ${codeGuardrailScript} ${mode}
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

  preCommitHook = pkgs.writeShellScript "git-pre-commit" ''
    set -e

    ${bannedLanguagesHook}
    ${deadnixHook}
    ${mkCodeGuardrailHook "pre-commit"}
    ${mkCommentBudgetHook "pre-commit"}
  '';

  postCommitHook = pkgs.writeShellScript "git-post-commit" ''
    POST_COMMIT_HEAD=$(${config.programs.git.package}/bin/git rev-parse HEAD)
    export POST_COMMIT_HEAD

    ${mkCodeGuardrailHook "post-commit"}
    ${mkCommentBudgetHook "post-commit"}
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
            hook = {
              black-terminal-commit-msg = {
                event = "commit-msg";
                command = "${commitMsgScript}";
              };
              black-terminal-pre-commit = {
                event = "pre-commit";
                command = "${preCommitHook}";
              };
              black-terminal-post-commit = {
                event = "post-commit";
                command = "${postCommitHook}";
              };
            };
          };
      };

      home.shellAliases = sharedGitShellAliases;
    };
  }
