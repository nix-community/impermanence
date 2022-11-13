{ pkgs, config, lib, ... }:

let
  inherit (lib)
    attrNames
    attrValues
    zipAttrsWith
    flatten
    mkOption
    mkDefault
    mapAttrsToList
    types
    foldl'
    unique
    concatMapStrings
    listToAttrs
    escapeShellArg
    escapeShellArgs
    recursiveUpdate
    all
    filter
    filterAttrs
    concatStringsSep
    concatMapStringsSep
    isString
    catAttrs
    optional
    literalExpression
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    splitPath
    dirListToPath
    concatPaths
    sanitizeName
    duplicates
    ;

  cfg = config.environment.persistence;
  users = config.users.users;
  allPersistentStoragePaths = { directories = [ ]; files = [ ]; users = [ ]; }
    // (zipAttrsWith (_name: flatten) (attrValues cfg));
  inherit (allPersistentStoragePaths) files directories;
  mountFile = pkgs.runCommand "impermanence-mount-file" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./mount-file.bash} $out
    patchShebangs $out
  '';

  # Create fileSystems bind mount entry.
  mkBindMountNameValuePair = { dirPath, persistentStoragePath, ... }: {
    name = concatPaths [ "/" dirPath ];
    value = {
      device = concatPaths [ persistentStoragePath dirPath ];
      noCheck = true;
      options = [ "bind" ]
        ++ optional cfg.${persistentStoragePath}.hideMounts "x-gvfs-hide";
      depends = [ persistentStoragePath ];
    };
  };

  # Create all fileSystems bind mount entries for a specific
  # persistent storage path.
  bindMounts = listToAttrs (map mkBindMountNameValuePair directories);
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type =
        let
          inherit (types)
            attrsOf
            bool
            listOf
            submodule
            nullOr
            path
            either
            str
            coercedTo
            ;
        in
        attrsOf (
          submodule (
            { name, config, ... }:
            let
              persistentStoragePath = name;
              defaultPerms = {
                mode = "0755";
                user = "root";
                group = "root";
              };
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
                  home = mkOption {
                    type = nullOr path;
                    default = null;
                    internal = true;
                    description = ''
                      The path to the home directory the file is
                      placed within.
                    '';
                  };
                };
              };
              dirPermsOpts = {
                user = mkOption {
                  type = str;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the user
                    specified by this option.
                  '';
                };
                group = mkOption {
                  type = str;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the
                    group specified by this option.
                  '';
                };
                mode = mkOption {
                  type = str;
                  example = "0700";
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created with the mode
                    specified by this option.
                  '';
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
                  parentDirectory = dirPermsOpts;
                  filePath = mkOption {
                    type = path;
                    internal = true;
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
                  dirPath = mkOption {
                    type = path;
                    internal = true;
                  };
                } // dirPermsOpts;
              };
              rootFile = submodule [
                commonOpts
                fileOpts
                ({ config, ... }: {
                  parentDirectory = mkDefault defaultPerms;
                  filePath = mkDefault config.file;
                })
              ];
              rootDir = submodule ([
                commonOpts
                dirOpts
                ({ config, ... }: {
                  dirPath = mkDefault config.directory;
                })
              ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) defaultPerms));
            in
            {
              options =
                {
                  users = mkOption {
                    type = attrsOf (
                      submodule (
                        { name, config, ... }:
                        let
                          userDefaultPerms = {
                            inherit (defaultPerms) mode;
                            user = name;
                            group = users.${userDefaultPerms.user}.group;
                          };
                          fileConfig =
                            { config, ... }:
                            {
                              filePath =
                                if config.home != null then
                                  concatPaths [ config.home config.file ]
                                else
                                  config.file;
                            };
                          userFile = submodule [
                            commonOpts
                            fileOpts
                            { parentDirectory = mkDefault userDefaultPerms; }
                            { inherit (config) home; }
                            fileConfig
                          ];
                          dirConfig =
                            { config, ... }:
                            {
                              dirPath =
                                if config.home != null then
                                  concatPaths [ config.home config.directory ]
                                else
                                  config.directory;
                            };
                          userDir = submodule ([
                            commonOpts
                            dirOpts
                            { inherit (config) home; }
                            dirConfig
                          ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) userDefaultPerms));
                        in
                        {
                          options =
                            {
                              # Needed because defining fileSystems
                              # based on values from users.users
                              # results in infinite recursion.
                              home = mkOption {
                                type = path;
                                default = "/home/${userDefaultPerms.user}";
                                defaultText = "/home/<username>";
                                description = ''
                                  The user's home directory. Only
                                  useful for users with a custom home
                                  directory path.

                                  Cannot currently be automatically
                                  deduced due to a limitation in
                                  nixpkgs.
                                '';
                              };

                              files = mkOption {
                                type = listOf (coercedTo str (f: { file = f; }) userFile);
                                default = [ ];
                                example = [
                                  ".screenrc"
                                ];
                                description = ''
                                  Files that should be stored in
                                  persistent storage.
                                '';
                              };

                              directories = mkOption {
                                type = listOf (coercedTo str (d: { directory = d; }) userDir);
                                default = [ ];
                                example = [
                                  "Downloads"
                                  "Music"
                                  "Pictures"
                                  "Documents"
                                  "Videos"
                                ];
                                description = ''
                                  Directories to bind mount to
                                  persistent storage.
                                '';
                              };
                            };
                        }
                      )
                    );
                    default = { };
                    description = ''
                      A set of user submodules listing the files and
                      directories to link to their respective user's
                      home directories.

                      Each attribute name should be the name of the
                      user.

                      For detailed usage, check the <link
                      xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
                    '';
                    example = literalExpression ''
                      {
                        talyz = {
                          directories = [
                            "Downloads"
                            "Music"
                            "Pictures"
                            "Documents"
                            "Videos"
                            "VirtualBox VMs"
                            { directory = ".gnupg"; mode = "0700"; }
                            { directory = ".ssh"; mode = "0700"; }
                            { directory = ".nixops"; mode = "0700"; }
                            { directory = ".local/share/keyrings"; mode = "0700"; }
                            ".local/share/direnv"
                          ];
                          files = [
                            ".screenrc"
                          ];
                        };
                      }
                    '';
                  };

                  files = mkOption {
                    type = listOf (coercedTo str (f: { file = f; }) rootFile);
                    default = [ ];
                    example = [
                      "/etc/machine-id"
                      "/etc/nix/id_rsa"
                    ];
                    description = ''
                      Files that should be stored in persistent storage.
                    '';
                  };

                  directories = mkOption {
                    type = listOf (coercedTo str (d: { directory = d; }) rootDir);
                    default = [ ];
                    example = [
                      "/var/log"
                      "/var/lib/bluetooth"
                      "/var/lib/nixos"
                      "/var/lib/systemd/coredump"
                      "/etc/NetworkManager/system-connections"
                    ];
                    description = ''
                      Directories to bind mount to persistent storage.
                    '';
                  };

                  hideMounts = mkOption {
                    type = bool;
                    default = false;
                    example = true;
                    description = ''
                      Whether to hide bind mounts from showing up as mounted drives.
                    '';
                  };

                  enableDebugging = mkOption {
                    type = bool;
                    default = false;
                    internal = true;
                    description = ''
                      Enable debug trace output when running
                      scripts. You only need to enable this if asked
                      to.
                    '';
                  };
                };
              config =
                let
                  allUsers = zipAttrsWith (_name: flatten) (attrValues config.users);
                in
                {
                  files = allUsers.files or [ ];
                  directories = allUsers.directories or [ ];
                };
            }
          )
        );
      description = ''
        A set of persistent storage location submodules listing the
        files and directories to link to their respective persistent
        storage location.

        Each attribute name should be the full path to a persistent
        storage location.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
      example = literalExpression ''
        {
          "/persistent" = {
            directories = [
              "/var/log"
              "/var/lib/bluetooth"
              "/var/lib/nixos"
              "/var/lib/systemd/coredump"
              "/etc/NetworkManager/system-connections"
              { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
            ];
            files = [
              "/etc/machine-id"
              { file = "/etc/nix/id_rsa"; parentDirectory = { mode = "u=rwx,g=,o="; }; }
            ];
          };
          users.talyz = { ... }; # See the dedicated example
        }
      '';
    };

    # Forward declare a dummy option for VM filesystems since the real one won't exist
    # unless the VM module is actually imported.
    virtualisation.fileSystems = mkOption { };
  };

  config = {
    systemd.services =
      let
        mkPersistFileService = { filePath, persistentStoragePath, ... }:
          let
            targetFile = escapeShellArg (concatPaths [ persistentStoragePath filePath ]);
            mountPoint = escapeShellArg filePath;
            enableDebugging = escapeShellArg cfg.${persistentStoragePath}.enableDebugging;
          in
          {
            "persist-${sanitizeName targetFile}" = {
              description = "Bind mount or link ${targetFile} to ${mountPoint}";
              wantedBy = [ "local-fs.target" ];
              before = [ "local-fs.target" ];
              path = [ pkgs.util-linux ];
              unitConfig.DefaultDependencies = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${mountFile} ${mountPoint} ${targetFile} ${enableDebugging}";
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

    fileSystems = bindMounts;
    # So the mounts still make it into a VM built from `system.build.vm`
    virtualisation.fileSystems = bindMounts;

    system.activationScripts =
      let
        # Script to create directories in persistent and ephemeral
        # storage. The directory structure's mode and ownership mirror
        # those of persistentStoragePath/dir.
        createDirectories = pkgs.runCommand "impermanence-create-directories" { buildInputs = [ pkgs.bash ]; } ''
          cp ${./create-directories.bash} $out
          patchShebangs $out
        '';

        mkDirWithPerms = { dirPath, persistentStoragePath, user, group, mode, ... }:
          let
            args = [
              persistentStoragePath
              dirPath
              user
              group
              mode
              cfg.${persistentStoragePath}.enableDebugging
            ];
          in
          ''
            ${createDirectories} ${escapeShellArgs args}
          '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        dirCreationScript =
          let
            fileDirectories = unique (map
              (f:
                rec {
                  directory = dirOf f.file;
                  dirPath =
                    if f.home != null then
                      concatPaths [ f.home directory ]
                    else
                      directory;
                  inherit (f) persistentStoragePath home;
                } // f.parentDirectory)
              files);
          in
          pkgs.writeShellScript "impermanence-run-create-directories" ''
            _status=0
            trap "_status=1" ERR
            ${concatMapStrings mkDirWithPerms (directories ++ fileDirectories)}
            exit $_status
          '';

        mkPersistFile = { filePath, persistentStoragePath, ... }:
          let
            mountPoint = filePath;
            targetFile = concatPaths [ persistentStoragePath filePath ];
            args = escapeShellArgs [
              mountPoint
              targetFile
              cfg.${persistentStoragePath}.enableDebugging
            ];
          in
          ''
            ${mountFile} ${args}
          '';

        persistFileScript =
          pkgs.writeShellScript "impermanence-persist-files" ''
            _status=0
            trap "_status=1" ERR
            ${concatMapStrings mkPersistFile files}
            exit $_status
          '';
      in
      {
        "createPersistentStorageDirs" = {
          deps = [ "users" "groups" ];
          text = "${dirCreationScript}";
        };
        "persist-files" = {
          deps = [ "createPersistentStorageDirs" ];
          text = "${persistFileScript}";
        };
      };

    assertions =
      let
        markedNeededForBoot = cond: fs:
          if config.fileSystems ? ${fs} then
            config.fileSystems.${fs}.neededForBoot == cond
          else
            cond;
        persistentStoragePaths = attrNames cfg;
        usersPerPath = allPersistentStoragePaths.users;
        homeDirOffenders =
          filterAttrs
            (n: v: (v.home != config.users.users.${n}.home));
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
        {
          assertion = all (users: (homeDirOffenders users) == { }) usersPerPath;
          message =
            let
              offendersPerPath = filter (users: (homeDirOffenders users) != { }) usersPerPath;
              offendersText =
                concatMapStringsSep
                  "\n      "
                  (offenders:
                    concatMapStringsSep
                      "\n      "
                      (n: "${n}: ${offenders.${n}.home} != ${config.users.users.${n}.home}")
                      (attrNames offenders))
                  offendersPerPath;
            in
            ''
              environment.persistence:
                  Users and home doesn't match:
                    ${offendersText}

                  You probably want to set each
                  environment.persistence.<path>.users.<user>.home to
                  match the respective user's home directory as
                  defined by users.users.<user>.home.
            '';
        }
        {
          assertion = duplicates (catAttrs "file" files) == [ ];
          message =
            let
              offenders = duplicates (catAttrs "file" files);
            in
            ''
              environment.persistence:
                  The following files were specified two or more
                  times:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
        {
          assertion = duplicates (catAttrs "directory" directories) == [ ];
          message =
            let
              offenders = duplicates (catAttrs "directory" directories);
            in
            ''
              environment.persistence:
                  The following directories were specified two or more
                  times:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
      ];
  };

}
