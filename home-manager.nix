{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths;
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule {
          options =
            {
              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              files = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              removePrefixDirectory = mkOption {
                type = types.bool;
                default = false;
              };
            };
        }
      );
    };

  };

  config = {
    home.file =
      let
        link = file:
          pkgs.runCommand
            "${replaceStrings [ "/" "." " " ] [ "-" "" "" ] file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = persistentStoragePath: fileOrDir: {
          name =
            if cfg.${persistentStoragePath}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ fileOrDir ]))
            else
              fileOrDir;
          value = { source = link (concatPaths [ persistentStoragePath fileOrDir ]); };
        };

        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files ++ cfg.${persistentStoragePath}.directories)
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    home.activation =
      let
        dag = config.lib.dag;

        mkDirCreationSnippet = persistentStoragePath: dir:
          let
            targetDir = concatPaths [ persistentStoragePath dir ];
          in
          ''
            if [[ ! -e "${targetDir}" ]]; then
                mkdir -p "${targetDir}"
            fi
          '';

        mkDirCreationScriptForPath = persistentStoragePath: {
          name = "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}";
          value =
            dag.entryAfter
              [ "writeBoundary" ]
              (concatMapStrings
                (mkDirCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.directories
              );
        };
      in
      listToAttrs (map mkDirCreationScriptForPath persistentStoragePaths);
  };

}
