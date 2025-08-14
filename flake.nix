{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs.lib)
        genAttrs
        makeScope
        ;

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      eachSystem = genAttrs systems;
    in
    {
      nixosModules.default = self.nixosModules.impermanence;
      nixosModules.impermanence = import ./nixos.nix;

      homeManagerModules.default = self.homeManagerModules.impermanence;
      homeManagerModules.impermanence = import ./home-manager.nix;

      # Deprecated
      nixosModule = self.nixosModules.impermanence;

      formatter = eachSystem (system:
        let
          formatterPkgs = makeScope nixpkgs.legacyPackages.${system}.newScope (self:
            let
              inherit (self) callPackage;
            in
            {
              filterByMimeType = callPackage
                ({ file
                 , findutils
                 , lib
                 , writers
                 }: writers.writeBashBin "filter-by-mime-type"
                  {
                    makeWrapperArgs = [
                      "--prefix"
                      "PATH"
                      ":"
                      (lib.makeBinPath [ file findutils ])
                    ];
                  } ''
                  mime_type="''${1?missing require MIME type}"
                  shift &>/dev/null || :

                  xargs -0 "$@" -- file --mime-type --no-pad --print0 --print0 | while read -d $'\0' next; do
                    if [[ -z "''${file:-}" ]]; then
                      file="$next"
                    else
                      if [[ "$next" = "$mime_type" ]]; then
                        printf -- '%s\0' "$file"
                      fi
                      unset file
                    fi
                  done
                '')
                { };

              filterShellScripts = callPackage
                ({ filterByMimeType
                 , lib
                 , writers
                 }: writers.writeBashBin "filter-shell-scripts" ''
                  exec -a "$0" ${lib.getExe filterByMimeType} 'text/x-shellscript'
                '')
                { };

              filterTextFiles = callPackage
                ({ filterByMimeType
                 , lib
                 , writers
                 }: writers.writeBashBin "filter-text-files" ''
                  exec -a "$0" ${lib.getExe filterByMimeType} 'text/plain'
                '')
                { };

              formatter = callPackage
                ({ filterShellScripts
                 , filterTextFiles
                 , findutils
                 , nixpkgs-fmt
                 , shfmt
                 , lib
                 , writers
                 }: writers.writeBashBin "impermanence-flake-formatter"
                  {
                    makeWrapperArgs = [
                      "--prefix"
                      "PATH"
                      ":"
                      (lib.makeBinPath [ filterShellScripts filterTextFiles findutils nixpkgs-fmt shfmt ])
                    ];
                  } ''
                  rc=0

                  if (( "$#" == 0 )); then
                    set -- .
                  fi

                  nix_expressions() {
                    find "$@" -type f -name '*.nix' -print0 | filter-text-files
                  }

                  shell_scripts() {
                    find "$@" -type f -print0 | filter-shell-scripts
                  }

                  { nix_expressions | xargs -0 -- nixpkgs-fmt ; } || rc="$?"

                  { shell_scripts | xargs -0 -- shfmt -i 4 -w ; } || rc="$?"

                  exit "$rc"
                '')
                { };
            });
        in
        formatterPkgs.formatter);
    };
}
