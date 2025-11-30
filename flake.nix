{
  description = "Recipe to build a «black terminal»";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {...}: {
    homeModules = {
      default = {
        imports = [
          ./hm/default.nix
        ];
      };
    };
  };
}
