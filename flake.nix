{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
    in
    {
      lib = import ./lib.nix { inherit lib; };

      nixosModules.default = self.nixosModules.impermanence;
      nixosModules.impermanence = import ./nixos.nix;

      # Deprecated
      homeManagerModules.default = self.homeManagerModules.impermanence;
      homeManagerModules.impermanence = {
        assertions = [
          {
            assertion = false;
            message = ''
              home.persistence: The Home Manager flake outputs are deprecated!

                The Home Manager module will be automatically imported by the NixOS
                module. Please remove any manual imports.

                See https://github.com/nix-community/impermanence?tab=readme-ov-file#home-manager
                for updated usage instructions.
            '';
          }
        ];
      };
      nixosModule = self.nixosModules.impermanence;
      nixosModules.home-manager.impermanence = self.homeManagerModules.impermanence;

      devShells = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          {
            default =
              pkgs.mkShell {
                packages = [
                  pkgs.nixpkgs-fmt
                ];
              };
          }
        );

      checks = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            mkTest = { name, configuration }:
              pkgs.testers.runNixOSTest {
                inherit name;
                nodes = {
                  persistence =
                    { config, ... }:
                    {
                      virtualisation.diskImage = "./persistent.qcow2";
                      virtualisation.graphics = false;

                      boot.initrd.verbose = true;

                      imports = [
                        self.nixosModule
                        configuration
                      ];

                      services.openssh.enable = true;

                      users.users.bird = {
                        isNormalUser = true;
                        uid = 1000;
                      };

                      users.users.fish = {
                        isNormalUser = true;
                        uid = 1001;
                      };

                      virtualisation.fileSystems = {
                        "/" = {
                          fsType = lib.mkForce "tmpfs";
                          device = lib.mkForce "none";
                          neededForBoot = true;
                        };
                        "/persistent" = {
                          device = "/dev/vda";
                          fsType = "ext4";
                          neededForBoot = true;
                        };
                      };

                      environment.persistence.main = {
                        persistentStoragePath = "/persistent";
                        enableDebugging = true;
                        files = [
                          "/etc/machine-id"
                          "/etc/ssh/ssh_host_ed25519_key"
                          { file = "/etc/ssh/ssh_host_ed25519_key.pub"; method = "symlink"; }
                          "/etc/ssh/ssh_host_rsa_key"
                          "/etc/ssh/ssh_host_rsa_key.pub"
                        ];
                        directories = [
                          { directory = "/etc/nixos"; mode = "0700"; user = "root"; group = "root"; }
                          "/var/log"
                          "/var/lib/bluetooth"
                          "/var/lib/nixos"
                          "/var/lib/systemd/coredump"
                          "/etc/NetworkManager/system-connections"
                        ];
                      };
                    };
                };

                testScript = { nodes, ... }:
                  let
                    nixos = nodes.persistence.environment.persistence.main;
                    nixos-users = nodes.persistence.environment.persistence.main.users.bird or { };
                    home-manager = nodes.persistence.home-manager.users.bird.home.persistence.main or { };
                    main = lib.zipAttrsWith (_name: lib.flatten) [ nixos nixos-users home-manager ];
                  in
                  ''
                    persistence.start(allow_reboot=True)

                    persistence.wait_for_unit("sshd.service")

                    persistence.succeed("echo potato > '/home/bird/.config/persistence_test'")

                    ${lib.concatMapStrings (file:
                      let
                        targetFile = self.lib.concatPaths [ file.persistentStoragePath file.filePath ];
                      in ''
                        persistence.wait_for_file("${targetFile}", 1)
                        persistence.succeed("diff ${targetFile} ${file.filePath}")
                      '')
                      main.files}

                    ${lib.concatMapStrings (dir:
                      let
                        targetDir = self.lib.concatPaths [ dir.persistentStoragePath dir.dirPath ];
                      in ''
                        persistence.wait_for_file("${targetDir}", 1)
                        persistence.succeed("diff <(stat -c '%Hd %Ld %i' ${targetDir}) <(stat -c '%Hd %Ld %i' ${dir.dirPath})")
                        persistence.succeed("test ${dir.user} = $(stat -c %U ${targetDir})")
                        persistence.succeed("test ${dir.mode} = $(stat -c %#01a ${targetDir})")
                      '')
                      main.directories}

                    persistence.reboot()

                    persistence.wait_for_console_text("reviving user .* with UID")

                    ${lib.concatMapStrings (file:
                      let
                        targetFile = self.lib.concatPaths [ file.persistentStoragePath file.filePath ];
                      in ''
                        persistence.wait_for_file("${targetFile}", 1)
                        ${if file.method == "auto" then ''
                          persistence.succeed("diff <(stat -c '%Hd %Ld %i' ${targetFile}) <(stat -c '%Hd %Ld %i' ${file.filePath})")
                        '' else ''
                          persistence.succeed("test ${targetFile} = $(readlink -f ${file.filePath})")
                        ''}
                        persistence.succeed("diff ${targetFile} ${file.filePath}")
                      '')
                      main.files}
                  '';
              };
          in
          {
            nixos = mkTest {
              name = "nixos-persistence";
              configuration = {
                boot.initrd.systemd.enable = true;

                environment.persistence.main.users.bird = {
                  directories = [
                    "Downloads"
                    "Music"
                    "Pictures"
                    "Documents"
                    "Videos"
                  ];
                  files = [
                    ".config/persistence_test"
                  ];
                };
              };
            };
            home-manager = mkTest {
              name = "hm-persistence";
              configuration = { config, ... }:
                {
                  imports = [
                    home-manager.nixosModules.home-manager
                  ];

                  home-manager.sharedModules = [{ home.stateVersion = config.system.stateVersion; }];

                  home-manager.users.bird =
                    {
                      home.persistence.main = {
                        persistentStoragePath = "/persistent";
                        directories = [
                          "Downloads"
                          "Music"
                          "Pictures"
                          "Documents"
                          "Videos"
                        ];
                        files = [
                          ".config/persistence_test"
                        ];
                      };
                    };

                  home-manager.users.fish =
                    {
                      home.file = {
                        "useless".text = ''
                          a useless file
                        '';
                      };
                    };
                };
            };
          }
        );
    };
}
