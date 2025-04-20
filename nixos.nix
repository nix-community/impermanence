{ pkgs, config, lib, utils, ... }:

let
  inherit (lib)
    attrNames
    attrValues
    zipAttrsWith
    flatten
    mkAfter
    mkOption
    mkIf
    mkMerge
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
    catAttrs
    optionals
    optionalString
    literalExpression
    elem
    intersectLists
    any
    id
    ;

  inherit (types)
    attrsOf
    submodule
    ;

  inherit (lib.modules)
    importApply
    ;

  inherit (utils)
    escapeSystemdPath
    pathsNeededForBoot
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    parentsOf
    duplicates
    ;

  inherit (config.users) users;

  cfg = config.environment.persistence;
  allPersistentStoragePaths = zipAttrsWith (_name: flatten) (filter (v: v.enable) (attrValues cfg));
  inherit (allPersistentStoragePaths) files directories;
  mountFile = pkgs.runCommand "impermanence-mount-file" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./mount-file.bash} $out
    patchShebangs $out
  '';

  defaultPerms = {
    mode = "0755";
    user = "root";
    group = "root";
  };
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type =
        attrsOf (
          submodule [
            ({ name, config, ... }:
              (importApply ./submodule-options.nix {
                inherit pkgs lib name config;
                user = "root";
                group = "root";
                homeDir = null;
              }))
            ({ name, config, ... }:
              {
                options = {
                  users =
                    let
                      outerName = name;
                      outerConfig = config;
                    in
                    mkOption {
                      type = attrsOf (
                        submodule (
                          { name, config, ... }:
                          importApply ./submodule-options.nix {
                            inherit pkgs lib;
                            config = outerConfig // config;
                            name = outerName;
                            usersOpts = true;
                            user = name;
                            group = users.${name}.group;
                            homeDir = users.${name}.home;
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
                };
                config =
                  let
                    allUsers = zipAttrsWith (_name: flatten) (attrValues config.users);
                  in
                  {
                    files = allUsers.files or [ ];
                    directories = allUsers.directories or [ ];
                  };
              })
          ]
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
  };

  config = mkIf (allPersistentStoragePaths != { })
    (mkMerge [
      {
        systemd.services =
          let
            mkPersistFileService = { filePath, persistentStoragePath, enableDebugging, ... }:
              let
                targetFile = escapeShellArg (concatPaths [ persistentStoragePath filePath ]);
                mountPoint = escapeShellArg filePath;
              in
              {
                "persist-${escapeSystemdPath targetFile}" = {
                  description = "Bind mount or link ${targetFile} to ${mountPoint}";
                  wantedBy = [ "local-fs.target" ];
                  before = [ "local-fs.target" ];
                  path = [ pkgs.util-linux ];
                  unitConfig.DefaultDependencies = false;
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    ExecStart = "${mountFile} ${mountPoint} ${targetFile} ${escapeShellArg enableDebugging}";
                    ExecStop = pkgs.writeShellScript "unbindOrUnlink-${escapeSystemdPath targetFile}" ''
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

        boot.initrd.systemd.mounts =
          let
            mkBindMount = { dirPath, persistentStoragePath, hideMount, ... }: {
              wantedBy = [ "initrd.target" ];
              before = [ "initrd-nixos-activation.service" ];
              where = concatPaths [ "/sysroot" dirPath ];
              what = concatPaths [ "/sysroot" persistentStoragePath dirPath ];
              unitConfig.DefaultDependencies = false;
              type = "none";
              options = concatStringsSep "," ([
                "bind"
              ] ++ optionals hideMount [
                "x-gvfs-hide"
              ]);
            };
            dirs = filter (d: elem d.dirPath pathsNeededForBoot) directories;
          in
          map mkBindMount dirs;

        systemd.mounts =
          let
            mkBindMount = { dirPath, persistentStoragePath, hideMount, ... }: {
              wantedBy = [ "local-fs.target" ];
              before = [ "local-fs.target" ];
              where = concatPaths [ "/" dirPath ];
              what = concatPaths [ persistentStoragePath dirPath ];
              unitConfig.DefaultDependencies = false;
              type = "none";
              options = concatStringsSep "," ([
                "bind"
              ] ++ optionals hideMount [
                "x-gvfs-hide"
              ]);
            };
          in
          map mkBindMount directories;

        system.activationScripts =
          let
            # Script to create directories in persistent and ephemeral
            # storage. The directory structure's mode and ownership mirror
            # those of persistentStoragePath/dir.
            createDirectories = pkgs.runCommand "impermanence-create-directories" { buildInputs = [ pkgs.bash ]; } ''
              cp ${./create-directories.bash} $out
              patchShebangs $out
            '';

            mkDirWithPerms =
              { dirPath
              , persistentStoragePath
              , user
              , group
              , mode
              , enableDebugging
              , ...
              }:
              let
                args = [
                  persistentStoragePath
                  dirPath
                  user
                  group
                  mode
                  enableDebugging
                ];
              in
              ''
                ${createDirectories} ${escapeShellArgs args}
              '';

            # Build an activation script which creates all persistent
            # storage directories we want to bind mount.
            dirCreationScript =
              let
                # The parent directories of files.
                fileDirs = unique (catAttrs "parentDirectory" files);

                # All the directories actually listed by the user and the
                # parent directories of listed files.
                explicitDirs = directories ++ fileDirs;

                # Home directories have to be handled specially, since
                # they're at the permissions boundary where they
                # themselves should be owned by the user and have stricter
                # permissions than regular directories, whereas its parent
                # should be owned by root and have regular permissions.
                #
                # This simply collects all the home directories and sets
                # the appropriate permissions and ownership.
                homeDirs =
                  foldl'
                    (state: dir:
                      let
                        homeDir = {
                          directory = dir.home;
                          dirPath = dir.home;
                          home = null;
                          mode = "0700";
                          user = dir.user;
                          group = users.${dir.user}.group;
                          inherit defaultPerms;
                          inherit (dir) persistentStoragePath enableDebugging;
                        };
                      in
                      if dir.home != null then
                        if !(elem homeDir state) then
                          state ++ [ homeDir ]
                        else
                          state
                      else
                        state
                    )
                    [ ]
                    explicitDirs;

                # Persistent storage directories. These need to be created
                # unless they're at the root of a filesystem.
                persistentStorageDirs =
                  foldl'
                    (state: dir:
                      let
                        persistentStorageDir = {
                          directory = dir.persistentStoragePath;
                          dirPath = dir.persistentStoragePath;
                          persistentStoragePath = "";
                          home = null;
                          inherit (dir) defaultPerms enableDebugging;
                          inherit (dir.defaultPerms) user group mode;
                        };
                      in
                      if dir.home == null && !(elem persistentStorageDir state) then
                        state ++ [ persistentStorageDir ]
                      else
                        state
                    )
                    [ ]
                    (explicitDirs ++ homeDirs);

                # Generate entries for all parent directories of the
                # argument directories, listed in the order they need to
                # be created. The parent directories are assigned default
                # permissions.
                mkParentDirs = dirs:
                  let
                    # Create a new directory item from `dir`, the child
                    # directory item to inherit properties from and
                    # `path`, the parent directory path.
                    mkParent = dir: path: {
                      directory = path;
                      dirPath =
                        if dir.home != null then
                          concatPaths [ dir.home path ]
                        else
                          path;
                      inherit (dir) persistentStoragePath home enableDebugging;
                      inherit (dir.defaultPerms) user group mode;
                    };
                    # Create new directory items for all parent
                    # directories of a directory.
                    mkParents = dir:
                      map (mkParent dir) (parentsOf dir.directory);
                  in
                  unique (flatten (map mkParents dirs));

                persistentStorageDirParents = mkParentDirs persistentStorageDirs;

                # Parent directories of home folders. This is usually only
                # /home, unless the user's home is in a non-standard
                # location.
                homeDirParents = mkParentDirs homeDirs;

                # Parent directories of all explicitly listed directories.
                parentDirs = mkParentDirs explicitDirs;

                # All directories in the order they should be created.
                allDirs =
                  persistentStorageDirParents
                  ++ persistentStorageDirs
                  ++ homeDirParents
                  ++ homeDirs
                  ++ parentDirs
                  ++ explicitDirs;
              in
              pkgs.writeShellScript "impermanence-run-create-directories" ''
                _status=0
                trap "_status=1" ERR
                ${concatMapStrings mkDirWithPerms allDirs}
                exit $_status
              '';

            mkPersistFile = { filePath, persistentStoragePath, enableDebugging, ... }:
              let
                mountPoint = filePath;
                targetFile = concatPaths [ persistentStoragePath filePath ];
                args = escapeShellArgs [
                  mountPoint
                  targetFile
                  enableDebugging
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

        boot.initrd.postMountCommands =
          let
            neededForBootDirs = filter (dir: elem dir.dirPath pathsNeededForBoot) directories;
            mkBindMount = { persistentStoragePath, dirPath, ... }:
              let
                target = concatPaths [ "/mnt-root" persistentStoragePath dirPath ];
              in
              ''
                mkdir -p ${escapeShellArg target}
                mountFS ${escapeShellArgs [ target dirPath ]} bind none
              '';
          in
          mkIf (!config.boot.initrd.systemd.enable)
            (mkAfter (concatMapStrings mkBindMount neededForBootDirs));
      }

      # Work around an issue with persisting /etc/machine-id where the
      # systemd-machine-id-commit.service unit fails if the final
      # /etc/machine-id is bind mounted from persistent storage. For
      # more details, see
      # https://github.com/nix-community/impermanence/issues/229 and
      # https://github.com/nix-community/impermanence/pull/242
      (mkIf (any (f: f == "/etc/machine-id") (catAttrs "filePath" files)) {
        boot.initrd.systemd.suppressedUnits = [ "systemd-machine-id-commit.service" ];
        systemd.services.systemd-machine-id-commit.unitConfig.ConditionFirstBoot = true;
      })

      # Assertions and warnings
      {
        assertions =
          let
            markedNeededForBoot = cond: fs:
              if config.fileSystems ? ${fs} then
                config.fileSystems.${fs}.neededForBoot == cond
              else
                cond;

            persistentStoragePaths = unique (catAttrs "persistentStoragePath" (files ++ directories));
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
              assertion = duplicates (catAttrs "filePath" files) == [ ];
              message =
                let
                  offenders = duplicates (catAttrs "filePath" files);
                in
                ''
                  environment.persistence:
                      The following files were specified two or more
                      times:
                        ${concatStringsSep "\n      " offenders}
                '';
            }
            {
              assertion = duplicates (catAttrs "dirPath" directories) == [ ];
              message =
                let
                  offenders = duplicates (catAttrs "dirPath" directories);
                in
                ''
                  environment.persistence:
                      The following directories were specified two or more
                      times:
                        ${concatStringsSep "\n      " offenders}
                '';
            }
          ];

        warnings =
          let
            usersWithoutUid = attrNames (filterAttrs (n: u: u.uid == null) config.users.users);
            groupsWithoutGid = attrNames (filterAttrs (n: g: g.gid == null) config.users.groups);
            varLibNixosPersistent =
              let
                varDirs = parentsOf "/var/lib/nixos" ++ [ "/var/lib/nixos" ];
                persistedDirs = catAttrs "dirPath" directories;
                mountedDirs = catAttrs "mountPoint" (attrValues config.fileSystems);
                persistedVarDirs = intersectLists varDirs persistedDirs;
                mountedVarDirs = intersectLists varDirs mountedDirs;
              in
              persistedVarDirs != [ ] || mountedVarDirs != [ ];
          in
          mkIf (any id allPersistentStoragePaths.enableWarnings)
            (mkMerge [
              (mkIf (!varLibNixosPersistent && (usersWithoutUid != [ ] || groupsWithoutGid != [ ])) [
                ''
                  environment.persistence:
                      Neither /var/lib/nixos nor any of its parents are
                      persisted. This means all users/groups without
                      specified uids/gids will have them reassigned on
                      reboot.
                      ${optionalString (usersWithoutUid != [ ]) ''
                      The following users are missing a uid:
                            ${concatStringsSep "\n      " usersWithoutUid}
                      ''}
                      ${optionalString (groupsWithoutGid != [ ]) ''
                      The following groups are missing a gid:
                            ${concatStringsSep "\n      " groupsWithoutGid}
                      ''}
                ''
              ])
            ]);
      }
    ]);

}
