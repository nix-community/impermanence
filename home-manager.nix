{ pkgs
, config
, lib
, persistenceModuleImported
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
    ;

  inherit (config) home;

  cfg = config.home.persistence;

  persistentStoragePaths = catAttrs "persistentStoragePath" (attrValues cfg);
in
{
  options.home.persistence = mkOption {
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
  config = {
    _module.args = {
      persistenceModuleImported = false;
    };
    assertions = [
      {
        assertion = config.submoduleSupport.enable;
        message = ''
          home.persistence: Home Manager used standalone!

            Home Manager has to be imported as a module in your NixOS
            configuration for the persistence module to work properly. See
            https://nix-community.github.io/home-manager/#sec-install-nixos-module
            for instructions.
        '';
      }
      {
        assertion = persistenceModuleImported;
        message = ''
          home.persistence: NixOS persistence module missing!

            The Home Manager module requires the NixOS module to work properly. See
            https://github.com/nix-community/impermanence?tab=readme-ov-file#nixos
            for instructions.
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
