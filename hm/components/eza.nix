{pkgs, ...}: let
  inherit (pkgs.stdenv) isDarwin isLinux;
in {
  programs.eza = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = isLinux;
    enableFishIntegration = isDarwin;
  };

  home.shellAliases = import ../../shared/eza/shell-aliases.nix;
}
