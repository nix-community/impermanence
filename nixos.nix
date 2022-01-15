{ pkgs, config, lib, ... }:

let
  inherit (lib) attrNames attrValues zipAttrsWith flatten mkOption
    types foldl' unique noDepEntry concatMapStrings listToAttrs
    escapeShellArg escapeShellArgs replaceStrings recursiveUpdate all
    filter concatStringsSep isString;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath
    concatPaths sanitizeName;

  cfg = config.environment.persistence;
  allPersistentStoragePaths = zipAttrsWith (_name: flatten) (attrValues cfg);
  inherit (allPersistentStoragePaths) files directories;
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
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type =
        let
          inherit (types) attrsOf listOf submodule path either str;
        in
        attrsOf (
          submodule (
            { name, ... }:
            let
              persistentStoragePath = name;
              commonOpts = {
                options = {
                  persistentStoragePath = mkOption {
                    type = path;
                    default = persistentStoragePath;
                    description = ''
                      The path to persistent storage where the real
                      file should be stored.
                    '';
                  };
                };
              };
              fileOpts = {
                options = {
                  file = mkOption {
                    type = str;
                    description = ''
                      The path to the file.
                    '';
                  };
                };
              };
              dirOpts = {
                options = {
                  directory = mkOption {
                    type = str;
                    description = ''
                      The path to the directory.
                    '';
                  };
                };
              };
              file = submodule [ commonOpts fileOpts ];
              dir = submodule [ commonOpts dirOpts ];
            in
            {
              options =
                {
                  files = mkOption {
                    type = listOf (either str file);
                    default = [ ];
                    example = [
                      "/etc/machine-id"
                      "/etc/nix/id_rsa"
                    ];
                    description = ''
                      Files that should be stored in persistent storage.
                    '';
                    apply =
                      map (file:
                        if isString file then
                          {
                            inherit file persistentStoragePath;
                          }
                        else
                          file);
                  };

                  directories = mkOption {
                    type = listOf (either str dir);
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
                    apply =
                      map (directory:
                        if isString directory then
                          {
                            inherit directory persistentStoragePath;
                          }
                        else
                          directory);
                  };
                };
            }
          )
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
        mkPersistFileService = { file, persistentStoragePath }:
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
      in
      foldl' recursiveUpdate { } (map mkPersistFileService files);

    fileSystems =
      let
        # Create fileSystems bind mount entry.
        mkBindMountNameValuePair = { directory, persistentStoragePath }: {
          name = concatPaths [ "/" directory ];
          value = {
            device = concatPaths [ persistentStoragePath directory ];
            noCheck = true;
            options = [ "bind" ];
          };
        };

        # Create all fileSystems bind mount entries for a specific
        # persistent storage path.
      in
      listToAttrs (map mkBindMountNameValuePair directories);

    system.activationScripts =
      let
        # Script to create directories in persistent and ephemeral
        # storage. The directory structure's mode and ownership mirror
        # those of persistentStoragePath/dir.
        createDirectories = pkgs.runCommand "impermanence-create-directories" { } ''
          cp ${./create-directories.bash} $out
          patchShebangs $out
        '';

        mkDirWithPerms = { directory, persistentStoragePath }: ''
          ${createDirectories} ${escapeShellArgs [persistentStoragePath directory]}
        '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        dirCreationScripts =
          let
            inherit directories;
            fileDirectories = unique (map
              (f:
                {
                  directory = dirOf f.file;
                  inherit (f) persistentStoragePath;
                })
              files);
          in
          {
            "createPersistentStorageDirs" =
              noDepEntry (concatMapStrings
                mkDirWithPerms
                (directories ++ fileDirectories));
          };

        persistFileScript = { file, persistentStoragePath }:
          let
            targetFile = escapeShellArg (concatPaths [ persistentStoragePath file ]);
            mountPoint = escapeShellArg file;
          in
          {
            "persist-${sanitizeName targetFile}" = {
              deps = [ "createPersistentStorageDirs" ];
              text = mkMountScript mountPoint targetFile;
            };
          };

        persistFileScripts =
          foldl' recursiveUpdate { } (map persistFileScript files);
      in
      dirCreationScripts // persistFileScripts;

    assertions =
      let
        markedNeededForBoot = cond: fs:
          if config.fileSystems ? ${fs} then
            config.fileSystems.${fs}.neededForBoot == cond
          else
            cond;
        persistentStoragePaths = attrNames cfg;
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
