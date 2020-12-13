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
                example = [
                  "/etc/machine-id"
                  "/etc/nix/id_rsa"
                ];
                description = ''
                  Files in /etc that should be stored in persistent storage.
                '';
              };

              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
                example = [
                  "/var/log"
                  "/var/lib/bluetooth"
                  "/var/lib/systemd/coredump"
                  "/etc/NetworkManager/system-connections"
                ];
                description = ''
                  Directories to bind mount to persistent storage.
                '';
              };
            };
        }
      );
      description = ''
        Persistent storage locations and the files and directories to
        link to them. Each attribute name should be the full path to a
        persistent storage location.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
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
        # Script to create directories in persistent and ephemeral
        # storage. The directory structure's mode and ownership mirror
        # those of persistentStoragePath/dir.
        createDirectories = pkgs.runCommand "impermanence-create-directories" { } ''
          cp ${./create-directories.bash} $out
          patchShebangs $out
        '';

        mkDirWithPerms = persistentStoragePath: dir: ''
          ${createDirectories} "${persistentStoragePath}" "${dir}"
        '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        mkDirCreationScriptForPath = persistentStoragePath:
          let
            directories = cfg.${persistentStoragePath}.directories;
            files = unique (map dirOf cfg.${persistentStoragePath}.files);
          in
          nameValuePair
            "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}"
            (noDepEntry (concatMapStrings
              (mkDirWithPerms persistentStoragePath)
              (directories ++ files)
            ));
      in
      listToAttrs (map mkDirCreationScriptForPath persistentStoragePaths);

    assertions =
      let
        files = concatMap (p: p.files or [ ]) (attrValues cfg);
        markedNeededForBoot = cond: fs:
          if config.fileSystems ? ${fs} then
            (config.fileSystems.${fs}.neededForBoot == cond)
          else
            cond;
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
