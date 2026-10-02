{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin;
  cfg = config.shared.zoxide;
in
  with lib; {
    options.shared.zoxide = {
      enable = mkEnableOption "Shared Zoxide";
    };

    config = mkIf cfg.enable {
      programs.zoxide = {
        enable = true;
        # https://github.com/ajeetdsouza/zoxide/pull/1004
        # --forward fails the build once upstream ships it, so the patch gets dropped.
        package = pkgs.zoxide.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./zoxide-acronyms.patch];
          patchFlags = ["-p1" "--forward"];
        });
        enableZshIntegration = true;
        enableBashIntegration = isLinux;
        enableFishIntegration = isDarwin;
        options = ["--cmd cd"];
      };
    };
  }
