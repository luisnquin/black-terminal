{
  config,
  lib,
  ...
}: let
  aliases = lib.filterAttrs (_: v: v != null) config.environment.shellAliases;
in {
  # The home-manager side sets no_global_rcs and sources this file instead of /etc/zshrc.
  config = lib.mkIf config.shared.zsh.enable {
    environment.etc."zsh/global-rc.zsh".text = ''
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "alias -- ${k}=${lib.escapeShellArg v}") aliases)}

      ${config.environment.interactiveShellInit}
    '';
  };
}
