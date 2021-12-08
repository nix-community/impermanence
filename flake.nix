{
  outputs = { self }: {
    nixosModules.impermanence = import ./nixos.nix;
    nixosModules.home-manager.impermanence = import ./home-manager.nix;
  };
}
