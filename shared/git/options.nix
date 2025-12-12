{lib}:
with lib; {
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
}
