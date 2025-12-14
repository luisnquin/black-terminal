# Black Terminal

> [!IMPORTANT]
> This flake was created solely to satisfy my own tastes and share the same config across all my systems.

A set of module options for NixOS, Darwin and Home Manager to create the best(sorry) terminal+shell.

## How to use

First, you need to add the flake in your inputs:

```nix
# flake.nix
{
  # ...
  inputs.black-terminal.url = "github:luisnquin/black-terminal";
  # ...
}
```

Next you'll have to import the necessary module according to the system and preferences:

```nix
{
  # some output examples
  outputs = inputs @ {
    nixpkgs,
    nix-darwin,
    home-manager,
    black-terminal,
    ...
  }: {
    nixosConfigurations."hostname" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        black-terminal.nixosModules.default
        ./configuration.nix
      ];
    };

    darwinConfigurations."hostname" = nix-darwin.lib.darwinSystem {
      modules = [
        black-terminal.darwinModules.default
        ./configuration.nix
      ];
    };
  };

  homeConfigurations."profile" = home-manager.lib.homeManagerConfiguration {
    modules = [
      black-terminal.homeModules.default
      ./home.nix
    ];
  };
  # ...
}

```

## Configuration

Here's an example:

```nix
{
    # ...
    shared = {
        bat.enable = true;
        btop.enable = true;
        direnv.enable = true;
        fzf.enable = true;
        macchina.enable = true;
        ghostty.enable = true;
        git = {
            enable = true;
            user = {
                name = "John Doe";
                email = "john.doe@example.com";
            };
        };
        lazygit.enable = true;
        starship.enable = true;
        tmux.enable = true;
        zoxide.enable = true;
        zsh.enable = true;
    };
}
```

However, you should check [hm](../hm/default.nix), [nixos](../nixos/default.nix) and [darwin](../darwin/default.nix) to have a
full outlook of all the options this flake has on it.
