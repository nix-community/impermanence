{
  outputs = { self }: {
    nixosModules.impermanence = import ./nixos.nix;
    nixosModules.home-manager.impermanence = import ./home-manager.nix;
    nixosModule = self.nixosModules.impermanence;
    homeManagerModules.impermanence = import ./home-manager.nix;
  };
}
