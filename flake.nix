{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-20.09-small";

  outputs = { self, nixpkgs }: {
    nixosModules.impermanence = import ./nixos.nix;
  };
}
