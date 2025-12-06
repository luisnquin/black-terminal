{
  description = "Recipe to build a «black terminal»";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {...}: {
    homeModules.default.imports = [./hm];
    nixosModules.default.imports = [./systems/nixos];
    darwinModules.default.imports = [./systems/darwin];
  };
}
