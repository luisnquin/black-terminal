{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux isDarwin;
  cfg = config.shared.aliases;
in
  with lib; {
    options.shared.aliases = {
      enable = mkEnableOption "Shared aliases";
    };

    config = mkIf cfg.enable {
      environment.shellAliases = let
        forLinux = {
          pr = "cd ~/Projects/";
          tmp = "cd /tmp/";

          du = "du --human-readable";
          open = "xdg-open";

          rc = "rclone";
          tt = "ranger";
          poff = "poweroff";
          neofetch = "macchina";
          whoseport = "netstat -tulpln 2> /dev/null | grep :";
          nyancat = "nyancat --no-counter";
          ale = "alejandra --quiet";
          dud = "du --human-readable --summarize";
          man = "tldr";
          py = "python3";
          share = "ngrok http";
          top = "btop";
          unrar = "unar";
        };
      in
        {
          # Instant tp
          down = "cd ~/Downloads/";
          dot = "cd ~/.dotfiles/";
          "~" = "cd /${
            if isDarwin
            then "Users"
            else "home"
          }/$USER/";

          cat = "bat -p";
          rm = "rm -i";

          "........" = "cd ../../../../../../..";
          "......." = "cd ../../../../../..";
          "......" = "cd ../../../../..";
          "....." = "cd ../../../..";
          "...." = "cd ../../..";
          "..." = "cd ../..";
          ".." = "cd ..";

          lsd = "echo 'lsd? lol'";
        }
        // (
          if isLinux
          then forLinux
          else {}
        );
    };
  }
