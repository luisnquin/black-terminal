{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv) isLinux;
  cfg = config.shared.aliases;
in
  with lib; {
    options.shared.aliases = {
      enable = mkEnableOption "Shared aliases";
    };

    config = mkIf cfg.enable {
      environment.shellAliases = let
        forLinux = {
          down = "cd ~/Downloads/";
          pr = "cd ~/Projects/";
          tmp = "cd /tmp/";

          rm = "rm --interactive";
          du = "du --human-readable";
          ls = "exa --icons";
          sls = "exa --icons -Ta -I=.git";
          ll = "exa -l";
          la = "exa -a";
          cat = "bat -p";

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
          # Instant tp to some directories
          dot = "cd ~/.dotfiles/";

          "........" = "cd ../../../../../../..";
          "......." = "cd ../../../../../..";
          "......" = "cd ../../../../..";
          "....." = "cd ../../../..";
          "...." = "cd ../../..";
          "..." = "cd ../..";
          ".." = "cd ..";
          "~" = "cd /home/$USER/";

          lsd = "echo 'lsd? lol'";
        }
        // (
          if isLinux
          then forLinux
          else {}
        );
    };
  }
