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
    };
  config = {
    assertions = [
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
