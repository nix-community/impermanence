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
      type = with types; attrsOf (
        submodule {
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

        # Create environment.etc link entry.
        mkLinkNameValuePair = persistentStoragePath: file: {
          name = removePrefix "/etc/" file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        # Create all environment.etc link entries for a specific
        # persistent storage path.
        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            cfg.${persistentStoragePath}.files
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    fileSystems =
      let
        # Create fileSystems bind mount entry.
        mkBindMountNameValuePair = persistentStoragePath: dir: {
          name = concatPaths [ "/" dir ];
          value = {
            device = concatPaths [ persistentStoragePath dir ];
            noCheck = true;
            options = [ "bind" ];
          };
        };

        # Create all fileSystems bind mount entries for a specific
        # persistent storage path.
        mkBindMountsForPath = persistentStoragePath:
          listToAttrs (map
            (mkBindMountNameValuePair persistentStoragePath)
            cfg.${persistentStoragePath}.directories
          );
      in
      foldl' recursiveUpdate { } (map mkBindMountsForPath persistentStoragePaths);

    system.activationScripts =
      let
        # Create a directory in persistent storage, so we can bind
        # mount it.
        mkDirCreationSnippet = persistentStoragePath: dir:
          let
            targetDir = concatPaths [ persistentStoragePath dir ];
          in
          ''
            if [[ ! -e "${targetDir}" ]]; then
                mkdir -p "${targetDir}"
            fi
          '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        mkDirCreationScriptForPath = persistentStoragePath:
          nameValuePair
            "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}"
            (noDepEntry (concatMapStrings
              (mkDirCreationSnippet persistentStoragePath)
              cfg.${persistentStoragePath}.directories
            ));
      in
      listToAttrs (map mkDirCreationScriptForPath persistentStoragePaths);

    assertions =
      let
        files = concatMap (p: p.files or [ ]) (attrValues cfg);
        markedNeededForBoot = cond: fs: (config.fileSystems.${fs}.neededForBoot == cond);
      in
      [
        {
          # Assert that files are put in /etc, a current limitation,
          # since we're using environment.etc.
          assertion = all (hasPrefix "/etc") files;
          message =
            let
              offenders = filter (file: !(hasPrefix "/etc" file)) files;
            in
            ''
              environment.persistence.files:
                  Currently, only files in /etc are supported.

                  Please fix or remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
        {
          # Assert that all persistent storage volumes we use are
          # marked with neededForBoot.
          assertion = all (markedNeededForBoot true) persistentStoragePaths;
          message =
            let
              offenders = filter (markedNeededForBoot false) persistentStoragePaths;
            in
            ''
              environment.persistence:
                  All filesystems used for persistent storage must
                  have the flag neededForBoot set to true.

                  Please fix or remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
      ];
  };

}
