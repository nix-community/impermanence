{
  outputs = { self }: {
    nixosModules.default = self.nixosModules.impermanence;
    nixosModules.impermanence = import ./nixos.nix;

    homeManagerModules.default = self.homeManagerModules.impermanence;
    homeManagerModules.impermanence = import ./home-manager.nix;

    # Deprecated
    nixosModule = self.nixosModules.impermanence;
    nixosModules.home-manager.impermanence = self.homeManagerModules.impermanence;
  };
}
