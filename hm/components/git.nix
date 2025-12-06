{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.shared.git;
in
  with lib; {
    options.shared.git = {
      enable = mkEnableOption "Shared git";

      user = {
        name = mkOption {
          type = types.str;
          description = "Git user.name";
        };

        email = mkOption {
          type = types.str;
          description = "Git user.email";
        };
      };
    };

    config = mkIf cfg.enable {
      programs.git = {
        enable = true;

        signing = {
          signByDefault = true;
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

        settings = {
          inherit (cfg) user;

          alias = {
            undo = "reset --soft HEAD^";
            amend = "commit --amend";
          };

          core = {
            editor = "nano -w";
            whitespace = "trailing-space,space-before-tab";
          };

          url = {
            "ssh://git@github.com/" = {
              insteadOf = "https://github.com/";
            };

            "ssh://git@gitlab.com/" = {
              insteadOf = "https://gitlab.com/";
            };
          };

          init.defaultBranch = "main";
          apply.whitespace = "fix";
          branch.sort = "object";
          color.ui = "auto";
          rebase.autoStash = true;
          pull.rebase = true;
          fetch.prune = true;
        };
      };

      home.shellAliases = rec {
        g = "git";
        ga = "git add";
        # Add file fragments
        gap = "${ga} --patch";
        gaa = "${ga} --all";

        gb = "git branch";

        gcp = "git cherry-pick";

        gc = "git commit -v";
        gca = "${gc} --amend";
        gcm = "${gc} --message";

        gd = "git diff";
        gds = "${gd} --staged";

        gl = "git log --oneline";
        gls = "${gl} | head -n 10";
        gl1 = "git log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(bold yellow)%d%C(reset)' --all";
        gl2 = "git log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(bold yellow)%d%C(reset)%n'' %C(white)%s%C(reset) %C(dim white)- %an%C(reset)' --all";

        gck = "git checkout";
        ggc = "git gc --aggressive";

        gf = "git fetch";
        gfa = "${gf} --all";

        # Git garbage collector over all subdirectories, skipping non-directories and non-git repositories
        gmgc = "find . -maxdepth 1 -type d | xargs -I {} bash -c 'if git -C {} rev-parse --git-dir > /dev/null 2>&1; then git -C {} gc --aggressive; fi'";

        # Pull current branch
        gp = "git pull origin $(git branch --show-current)";
        gprb = "git pull --rebase origin $(git branch --show-current)";

        ggpull = gp;
        ggpullrb = gprb;

        # Show current branch in all subdirectories, skipping non-directories and non-git repositories
        gmb = ''find . -maxdepth 1 -type d | xargs -I {} bash -c 'if git -C {} rev-parse --git-dir > /dev/null 2>&1; then printf " ~ \033[0;94m{}\033[0m:"; git -C {} branch --show-current; fi' '';
        # Pull the current branch of all subdirectories, skipping non-directories and non-git repositories
        gmpull = "find . -maxdepth 1 -type d | xargs -I {} bash -c 'if git -C {} rev-parse --git-dir > /dev/null 2>&1; then git -C {} pull; fi'";
        # Push the current branch of all subdirectories, skipping non-directories and non-git repositories
        gmpush = "find . -maxdepth 1 -type d | xargs -I {} bash -c 'if git -C {} rev-parse --git-dir > /dev/null 2>&1; then git -C {} push; fi'";
        # Push current branch
        ggpush = "git push origin $(git branch --show-current)";

        # Show the last commit message before undoing
        gundo = "git log --format=%B -n 1 HEAD | head -n 1 && git undo";

        # Git reset but it doesn't output anything
        gr = "git reset -q";
        grv = "git revert";

        # Lists the authors of a directory/file.
        gauthors = "git shortlog -n -s -- ";
        gss = "git status -s";
        grb = "git rebase";

        gs = "git stash";
        gsiu = "${gs} --include-untracked";
        gsp = "${gs} pop";

        gt = "git tag";
        gtd = "${gt} --delete";
        # Lists last 5 tags
        gts = "${gt} --sort=v:refname | tac | head -n 5";
        gcl = "git clone";

        lg = "lazygit";
      };
    };
  }
