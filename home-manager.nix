{ pkgs
, config
, lib
, ...
}:

let
  inherit (lib)
    mkOption
    types
    catAttrs
    any
    hasInfix
    attrValues
    ;

  inherit (types)
    attrsOf
    submodule
    bool
    ;

  inherit (config) home;

  cfg = config.home.persistence;

  persistentStoragePaths = catAttrs "persistentStoragePath" (attrValues cfg);
in
{
  options =
    {
      home.persistence = mkOption {
        default = { };
        type = attrsOf (
          submodule (
            { name, config, ... }:
            import ./submodule-options.nix {
              inherit pkgs lib name config;

              user = home.username;
              homeDir = home.homeDirectory;

              # Home Manager doesn't seem to know about the user's group,
              # so we default it to null here and fill it in in the NixOS
              # module instead
              group = null;
            }
          ));
      };
      home._nixosModuleImported = mkOption {
        default = false;
        type = bool;
        internal = true;
        description = ''
          Internal option to signal whether the NixOS persistence
          module was properly imported. Do not set this!
        '';
      };
    };
  config = {
    assertions = [
      {
        assertion = config.home._nixosModuleImported;
        message = ''
          home.persistence: Module was imported manually!

            The Home Manager persistence module should not be imported
            manually. It will be imported by the NixOS module
            automatically. See
            https://github.com/nix-community/impermanence?tab=readme-ov-file#home-manager
            for instructions and examples.
        '';
      }
      {
        assertion = !(any (hasInfix home.homeDirectory) persistentStoragePaths);
        message = ''
          home.persistence: persistentStoragePath contains home directory path!

            The API has changed - the persistent storage path should no longer
            contain the path to the user's home directory, as it will be added
            automatically.
        '';
      }
    ];
  };
}
