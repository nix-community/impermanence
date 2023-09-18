{
  outputs = { self }: {
    nixosModules.impermanence = import ./nixos.nix;
    nixosModules.default = self.nixosModules.impermanence;

    homeManagerModules.impermanence = import ./home-manager.nix;
    homeManagerModules.default = self.homeManagerModules.impermanence;

    # Deprecated
    nixosModule = self.nixosModules.impermanence;
    nixosModules.home-manager.impermanence = self.homeManagerModules.impermanence;
  };
}
