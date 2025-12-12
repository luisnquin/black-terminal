{pkgs, ...}: {
  environment = {
    systemPackages = [pkgs.eza];
    shellAliases = import ../../shared/eza/shell-aliases.nix;
  };
}
