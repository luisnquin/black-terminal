{pkgs, ...}: {
  environment = {
    systemPackages = [pkgs.eza];
    shellAliases = import ../eza/shell-aliases.nix;
  };
}
