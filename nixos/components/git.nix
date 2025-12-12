{
  config,
  lib,
  ...
}: let
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
        prompt.enable = false;

        config =
          sharedGitConfig
          // {
            user = {
              name = cfg.user.name;
              email = cfg.user.email;
            };
          };
      };

      environment.shellAliases = sharedGitShellAliases;
    };
  }
