{
  outputs = { self }: {
    nixosModules.impermanence = import ./flok.nix;
  };
}
