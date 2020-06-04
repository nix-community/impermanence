{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.environment.persistence;
  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths;
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type = with types; attrsOf (submodule
        {
          options =
            {
              files = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = ''
                  Files in /etc that should be stored in persistent storage.
                '';
              };

              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = ''
                  Directories to bind mount to persistent storage.
                '';
              };
            };
        }
      );
    };

  };

  config = {
    environment.etc =
      let
        link = file:
          pkgs.runCommand
            "${replaceStrings [ "/" "." " " ] [ "-" "" "" ] file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = persistentStoragePath: file: {
          name = removePrefix "/etc/" file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs
            (map
              (mkLinkNameValuePair persistentStoragePath)
              cfg.${persistentStoragePath}.files);
      in
        foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    fileSystems =
      let
        mkBindMountNameValuePair = persistentStoragePath: dir: {
          name = concatPaths [ "/" dir ];
          value = {
            device = concatPaths [ persistentStoragePath dir ];
            noCheck = true;
            options = [ "bind" ];
          };
        };

        mkBindMountsFromPath = persistentStoragePath:
          listToAttrs
            (map
              (mkBindMountNameValuePair persistentStoragePath)
              cfg.${persistentStoragePath}.directories);
      in
        foldl' recursiveUpdate { } (map mkBindMountsFromPath persistentStoragePaths);

    system.activationScripts =
      let
        mkDirCreationSnippet = persistentStoragePath: dir:
          let
            targetDir = concatPaths [ persistentStoragePath dir ];
          in ''
            if [[ ! -e "${targetDir}" ]]; then
                mkdir -p "${targetDir}"
            fi
          '';

        mkDirCreationScriptForPath = persistentStoragePath:
          nameValuePair
            "createDirsIn-${replaceStrings [ "/" "." ] [ "-" "" ] persistentStoragePath}"
            (noDepEntry
              (concatMapStrings
                (mkDirCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.directories));
      in
        listToAttrs (map mkDirCreationScriptForPath persistentStoragePaths);

    assertions =
      let
        files = concatMap (p: p.files or [ ]) (attrValues cfg);
      in [
        {
          assertion = all (hasPrefix "/etc") files;
          message =
            let
              offenders = filter (file: !(hasPrefix "/etc" file)) files;
            in ''
              environment.persistence.files:
                  Currently, only files in /etc are supported.
                  Please fix / remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
      ];
  };

}
