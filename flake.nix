{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.impermanence = import ./nixos.nix;
    nixosModules.home-manager.impermanence = import ./home-manager.nix;
    nixosModule = self.nixosModules.impermanence;
    checks =
      let
        importCheck = test:
          import test {
            modules = [ self.nixosModule ];
            inherit nixpkgs;
            system = "x86_64-linux";
          };
      in
      {
        x86_64-linux.nixos = importCheck ./tests/nixos.nix;
        x86_64-linux.modules = importCheck ./tests/modules.nix;
      };
  };
}
