{
  outputs = { self }: {
    nixosModules.impermanence = import ./nixos.nix;
  };
}
