{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.environment.persistence;
  persistentStoragePaths = attrNames cfg;
  mkMountScript = mountPoint: targetFile: ''
    if [[ -L ${mountPoint} && $(readlink -f ${mountPoint}) == ${targetFile} ]]; then
        echo "${mountPoint} already links to ${targetFile}, ignoring"
    elif mount | grep -F ${mountPoint}' ' >/dev/null && ! mount | grep -F ${mountPoint}/ >/dev/null; then
        echo "mount already exists at ${mountPoint}, ignoring"
    elif [[ -e ${mountPoint} ]]; then
        echo "A file already exists at ${mountPoint}!" >&2
        exit 1
    elif [[ -e ${targetFile} ]]; then
        touch ${mountPoint}
        mount -o bind ${targetFile} ${mountPoint}
    else
        ln -s ${targetFile} ${mountPoint}
    fi
  '';

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths sanitizeName;
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
    systemd.services =
      let
        mkPersistFileService = persistentStoragePath: file:
          let
            targetFile = escapeShellArg (concatPaths [ persistentStoragePath file ]);
            mountPoint = escapeShellArg file;
          in
          {
            "persist-${sanitizeName targetFile}" = {
              description = "Bind mount or link ${targetFile} to ${mountPoint}";
              wantedBy = [ "local-fs.target" ];
              before = [ "local-fs.target" ];
              path = [ pkgs.utillinux ];
              unitConfig.DefaultDependencies = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = pkgs.writeShellScript "bindOrLink-${sanitizeName targetFile}" ''
                  set -eu
                  ${mkMountScript mountPoint targetFile}
                '';
                ExecStop = pkgs.writeShellScript "unbindOrUnlink-${sanitizeName targetFile}" ''
                  set -eu
                  if [[ -L ${mountPoint} ]]; then
                      rm ${mountPoint}
                  else
                      umount ${mountPoint}
                      rm ${mountPoint}
                  fi
                '';
              };
            };
          };

        mkServicesForPersistentStoragePath = persistentStoragePath:
          foldl' recursiveUpdate { } (map (mkPersistFileService persistentStoragePath) cfg.${persistentStoragePath}.files);
      in
      foldl' recursiveUpdate { } (map mkServicesForPersistentStoragePath persistentStoragePaths);

    fileSystems =
      let
        # Create fileSystems bind mount entry.
        mkBindMountNameValuePair = persistentStoragePath: dir: {
          name = concatPaths [ "/" dir ];
          value = {
            device = concatPaths [ persistentStoragePath dir ];
            noCheck = true;
            options = [ "bind" ];
            depends = [ persistentStoragePath ];
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
          {
            "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}" =
              noDepEntry (concatMapStrings
                (mkDirWithPerms persistentStoragePath)
                (directories ++ files));
          };

        dirCreationScripts = foldl' recursiveUpdate { } (map mkDirCreationScriptForPath persistentStoragePaths);

        persistFileScript = persistentStoragePath: file:
          let
            targetFile = escapeShellArg (concatPaths [ persistentStoragePath file ]);
            mountPoint = escapeShellArg file;
          in
          {
            "persist-${sanitizeName targetFile}" = {
              deps = [ "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}" ];
              text = mkMountScript mountPoint targetFile;
            };
          };

        mkPersistFileScripts = persistentStoragePath:
          foldl' recursiveUpdate { } (map (persistFileScript persistentStoragePath) cfg.${persistentStoragePath}.files);

        persistFileScripts =
          foldl' recursiveUpdate { } (map mkPersistFileScripts persistentStoragePaths);
      in
      dirCreationScripts // persistFileScripts;

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
