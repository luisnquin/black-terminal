{
  description = "Recipe to build a «black terminal»";

  outputs = {...}: {
    homeModules.default.imports = [./hm];
    nixosModules.default.imports = [./nixos];
    darwinModules.default.imports = [./darwin];
  };
}
