{ pkgs, config, lib, utils, ... }:

let
  inherit (lib)
    attrNames
    attrValues
    zipAttrsWith
    flatten
    mkAfter
    mkOption
    mkDefault
    mkIf
    mkMerge
    types
    foldl'
    unique
    concatMap
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
    optional
    optionalString
    literalExpression
    elem
    mapAttrs
    intersectLists
    any
    id
    head
    const
    ;

  inherit (utils)
    escapeSystemdPath
    fsNeededForBoot
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    splitPath
    concatPaths
    parentsOf
    duplicates
    coercedToDir
    coercedToFile
    toposortDirs
    extractPersistentStoragePaths
    recursivePersistentPaths
    ;

  cfg = config.environment.persistence;
  users = config.users.users;
  allPersistentStoragePaths = extractPersistentStoragePaths cfg;
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

  # Create fileSystems bind mount entry.
  mkBindMountNameValuePair = { destination, source, persistentStoragePath, hideMount, ... }: {
    name = concatPaths [ "/" destination ];
    value = {
      device = source;
      noCheck = true;
      options = [ "bind" "X-fstrim.notrim" ]
        ++ optional hideMount "x-gvfs-hide";
      depends = [ persistentStoragePath ];
    };
  };

  # Create all fileSystems bind mount entries for a specific
  # persistent storage path.
  bindMounts = listToAttrs (map mkBindMountNameValuePair directories);

  # Topologically sort the directories we need to create, chown, chmod, etc.
  # The idea is to handle more "fundamental" directories (fewer "/" elements)
  # first, and also to prefer explicitly-defined directories over
  # implicitly-defined ones (<- created as parent directories of
  # explicitly-specified files).
  sortedDirs =
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
              homeDir =
                let
                  relpath = concatPaths [ dir.prefix dir.home ];
                in
                {
                  directory = dir.home;
                  home = null;
                  mode = "0700";
                  user = dir.user;
                  group = users.${dir.user}.group;
                  source = concatPaths [ dir.persistentStoragePath relpath ];
                  destination = concatPaths [ "/" relpath ];
                  inherit defaultPerms relpath;
                  inherit (dir) persistentStoragePath enableDebugging prefix;
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
              relpath = concatPaths [ dir.prefix dir.persistentStoragePath ];
              persistentStorageDir = {
                directory = dir.persistentStoragePath;
                persistentStoragePath = "";
                home = null;
                destination = concatPaths [ "/" relpath ];
                source = concatPaths [ "/" relpath ];
                inherit (dir) defaultPerms enableDebugging root prefix;
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
          mkParent = dir: path:
            let
              relpath = concatPaths [ dir.prefix path ];
            in
            {
              inherit relpath;
              directory = path;
              source = concatPaths [ dir.persistentStoragePath relpath ];
              destination = concatPaths [ "/" relpath ];
              inherit (dir) persistentStoragePath home root enableDebugging;
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
    toposortDirs allDirs;
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
            str
            nonEmptyStr
            ;
        in
        attrsOf (
          submodule (
            { name, config, ... }:
            let
              commonOpts = { pathType }: common: {
                options = {
                  persistentStoragePath = mkOption {
                    type = path;
                    default = config.persistentStoragePath;
                    defaultText = "environment.persistence.‹name›.persistentStoragePath";
                    description = ''
                      The path to persistent storage where the real
                      file or directory should be stored.
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
                  enableDebugging = mkOption {
                    type = bool;
                    default = config.enableDebugging;
                    defaultText = "environment.persistence.‹name›.enableDebugging";
                    internal = true;
                    description = ''
                      Enable debug trace output when running
                      scripts. You only need to enable this if asked
                      to.
                    '';
                  };
                  prefix = mkOption {
                    # *not* path -- permit stuff that does not start with "/"
                    type = nonEmptyStr;
                    internal = true;
                    default = "/";
                    description = ''
                      Path fragment prepended to {option}`${pathType}` when
                      expanding it relative to
                      {option}`persistentStorageDirectory` and `/`.  Exists to
                      support the implicit home directory that appears before
                      user file and directory specifications.
                    '';
                  };
                  relpath = mkOption {
                    # *not* path -- permit stuff that does not start with "/"
                    type = nonEmptyStr;
                    internal = true;
                    default = concatPaths [ common.config.prefix common.config.${pathType} ];
                    description = ''
                      The file path relative to {option}`persistentStoragePath`
                      and `/`.
                    '';
                  };
                  source = mkOption {
                    type = path;
                    internal = true;
                    default = concatPaths [ common.config.persistentStoragePath common.config.relpath ];
                    description = ''
                      The fully-qualified and normalized path rooted in
                      {option}`persistentStoragePath`.  That is, given
                      {option}`persistentStoragePath` "/foo/bar",
                      {option}`prefix` "bazz/quux", and {option}`${pathType}`
                      "arr/iffic", {option}source` will be
                      "/foo/bar/bazz/quux/arr/iffic".
                    '';
                  };
                  destination = mkOption {
                    type = path;
                    internal = true;
                    default = concatPaths [ "/" common.config.relpath ];
                    description = ''
                      The fully-qualified and normalized path rooted in `/`.
                      That is, given {option}`prefix` "bazz/quux" and
                      {option}`${pathType}` "arr/iffic", {option}`destination`
                      will be "/bazz/quux/arr/iffic".
                    '';
                  };
                };
              };
              dirPermsOpts = { internal ? false }: {
                options = {
                  user = mkOption {
                    inherit internal;
                    type = str;
                    description = ''
                      If the directory doesn't exist in persistent
                      storage it will be created and owned by the user
                      specified by this option.
                    '';
                  };
                  group = mkOption {
                    inherit internal;
                    type = str;
                    description = ''
                      If the directory doesn't exist in persistent
                      storage it will be created and owned by the
                      group specified by this option.
                    '';
                  };
                  mode = mkOption {
                    inherit internal;
                    type = str;
                    example = "0700";
                    description = ''
                      If the directory doesn't exist in persistent
                      storage it will be created with the mode
                      specified by this option.
                    '';
                  };
                };
              };
              fileOpts = {
                imports = [ (commonOpts { pathType = "file"; }) ];
                options = {
                  file = mkOption {
                    type = nonEmptyStr;
                    description = ''
                      The path to the file.
                    '';
                  };
                  parentDirectory = mkOption {
                    description = "Options pertaining to this file's parent directory";
                    default = { };
                    type = submodule (dirOpts { internal = true; });
                  };
                };
              };
              dirOpts = { internal ? false }: {
                imports = [
                  (commonOpts { pathType = "directory"; })
                  (dirPermsOpts { })
                ];
                options = {
                  directory = mkOption {
                    inherit internal;
                    type = nonEmptyStr;
                    description = ''
                      The path to the directory.
                    '';
                  };
                  hideMount = mkOption {
                    inherit internal;
                    type = bool;
                    default = config.hideMounts;
                    defaultText = "environment.persistence.‹name›.hideMounts";
                    example = true;
                    description = ''
                      Whether to hide bind mounts from showing up as
                      mounted drives.
                    '';
                  };
                  defaultPerms = mkOption {
                    type = submodule (dirPermsOpts { internal = true; });
                    default = { };
                    description = ''
                      The default permissions at the level the directory
                      resides. This used when creating its parent directories,
                      giving them reasonable default permissions unaffected by
                      the directory's own.
                    '';
                  };
                };
              };
              rootFile = submodule [
                fileOpts
                {
                  parentDirectory = mapAttrs (const mkDefault) defaultPerms;
                }
                ({ config, ... }: {
                  parentDirectory = {
                    directory = dirOf config.file;
                    inherit (config) persistentStoragePath home prefix;
                    defaultPerms = mapAttrs (const mkDefault) defaultPerms;
                  };
                })
              ];
              rootDir = submodule ([
                (dirOpts { })
                {
                  defaultPerms = mkDefault defaultPerms;
                }
                (mapAttrs (const mkDefault) defaultPerms)
              ]);
            in
            {
              options =
                {
                  enable = mkOption {
                    type = bool;
                    default = true;
                    description = "Whether to enable this persistent storage location.";
                  };

                  persistentStoragePath = mkOption {
                    type = path;
                    default = name;
                    defaultText = "‹name›";
                    description = ''
                      The path to persistent storage where the real
                      files and directories should be stored.
                    '';
                  };

                  users = mkOption {
                    type = attrsOf (
                      submodule (
                        { name, config, ... }:
                        let
                          homePath = {
                            prefix = config.home;
                          };
                          userDefaultPerms = {
                            inherit (defaultPerms) mode;
                            user = name;
                            group = users.${userDefaultPerms.user}.group;
                          };
                          userFile = submodule [
                            fileOpts
                            homePath
                            { inherit (config) home; }
                            {
                              parentDirectory = mapAttrs (const mkDefault) userDefaultPerms;
                            }
                            ({ config, ... }:
                              {
                                parentDirectory = {
                                  directory = dirOf config.file;
                                  inherit (config) persistentStoragePath home prefix;
                                  defaultPerms = userDefaultPerms;
                                };
                              })
                          ];
                          dirConfig =
                            {
                              defaultPerms = mkDefault userDefaultPerms;
                            };
                          userDir = submodule ([
                            (dirOpts { })
                            homePath
                            { inherit (config) home; }
                            dirConfig
                            (mapAttrs (const mkDefault) userDefaultPerms)
                          ]);
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
                                type = listOf (coercedToFile userFile);
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
                                type = listOf (coercedToDir userDir);
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
                    type = listOf (coercedToFile rootFile);
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
                    type = listOf (coercedToDir rootDir);
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

                  enableWarnings = mkOption {
                    type = bool;
                    default = true;
                    description = ''
                      Enable non-critical warnings.
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

  config = mkIf (allPersistentStoragePaths != { })
    (mkMerge [
      {
        systemd.services =
          let
            mkPersistFileService = { source, destination, enableDebugging, ... }:
              let
                targetFile = escapeShellArg source;
                mountPoint = escapeShellArg destination;
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

        fileSystems = mkIf (directories != [ ]) bindMounts;
        # So the mounts still make it into a VM built from `system.build.vm`
        virtualisation.fileSystems = mkIf (directories != [ ]) bindMounts;

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
              { persistentStoragePath
              , destination
              , user
              , group
              , mode
              , enableDebugging
              , ...
              }:
              let
                args = [
                  persistentStoragePath
                  destination
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
              pkgs.writeShellScript "impermanence-run-create-directories" ''
                _status=0
                trap "_status=1" ERR
                ${concatMapStrings mkDirWithPerms sortedDirs.result}
                exit $_status
              '';

            mkPersistFile = { source, destination, enableDebugging, ... }:
              let
                mountPoint = destination;
                targetFile = source;
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

        # Create the mountpoints of directories marked as needed for boot
        # which are also persisted. For this to work, it has to run at
        # early boot, before NixOS' filesystem mounting runs. Without
        # this, initial boot fails when for example /var/lib/nixos is
        # persisted but not created in persistent storage.
        boot.initrd =
          let
            neededForBootFs = catAttrs "mountPoint" (filter fsNeededForBoot (attrValues config.fileSystems));
            neededForBootDirs = filter (dir: elem dir.directory neededForBootFs) directories;
            getDevice = fs:
              if fs.device != null then
                fs.device
              else if fs.label != null then
                "/dev/disk/by-label/${fs.label}"
              else
                "none";
            mkMount = fs:
              let
                mountPoint = concatPaths [ "/persist-tmp-mnt" fs.mountPoint ];
                device = getDevice fs;
                options = filter (o: (builtins.match "(x-.*\.mount)" o) == null) fs.options;
                optionsFlag = optionalString (options != [ ]) ("-o " + escapeShellArg (concatStringsSep "," options));
              in
              ''
                mkdir -p ${escapeShellArg mountPoint}
                mount -t ${escapeShellArgs [ fs.fsType device mountPoint ]} ${optionsFlag}
              '';
            mkDir = { destination, ... }: ''
              mkdir -p ${escapeShellArg (concatPaths [ "/persist-tmp-mnt" destination ])}
            '';
            mkUnmount = fs: ''
              umount ${escapeShellArg (concatPaths [ "/persist-tmp-mnt" fs.mountPoint ])}
            '';
            fileSystems =
              let
                persistentStoragePaths = unique (catAttrs "persistentStoragePath" directories);
                all = config.fileSystems // config.virtualisation.fileSystems;
                matchFileSystems = fs: attrValues (filterAttrs (_: v: v.mountPoint or null == fs) all);
              in
              concatMap matchFileSystems persistentStoragePaths;
            deviceUnits = unique
              (concatMap
                (fs:
                  # If the device path starts with “dev” or “sys”,
                  # it's a real device and should have an associated
                  # .device unit. If not, it's probably either a
                  # temporary file system lacking a backing device, a
                  # ZFS pool or a bind mount.
                  let
                    device = getDevice fs;
                  in
                  if elem (head (splitPath [ device ])) [ "dev" "sys" ] then
                    [ "${escapeSystemdPath device}.device" ]
                  else if device == "none" || device == fs.fsType then
                    [ ]
                  else if fs.fsType == "zfs" then
                    [ "zfs-import.target" ]
                  else
                    [ "${escapeSystemdPath device}.mount" ])
                fileSystems);
            createNeededForBootDirs = ''
              ${concatMapStrings mkMount fileSystems}
              ${concatMapStrings mkDir neededForBootDirs}
              ${concatMapStrings mkUnmount fileSystems}
            '';
          in
          {
            systemd.services = mkIf config.boot.initrd.systemd.enable {
              create-needed-for-boot-dirs = {
                wantedBy = [ "initrd-root-device.target" ];
                requires = deviceUnits;
                after = deviceUnits;
                before = [ "sysroot.mount" ];
                serviceConfig.Type = "oneshot";
                unitConfig.DefaultDependencies = false;
                script = createNeededForBootDirs;
              };
            };
            postResumeCommands = mkIf (!config.boot.initrd.systemd.enable)
              (mkAfter createNeededForBootDirs);
          };
      }

      # Work around an issue with persisting /etc/machine-id where the
      # systemd-machine-id-commit.service unit fails if the final
      # /etc/machine-id is bind mounted from persistent storage. For
      # more details, see
      # https://github.com/nix-community/impermanence/issues/229 and
      # https://github.com/nix-community/impermanence/pull/242
      (mkIf (any (f: f == "/etc/machine-id") (catAttrs "destination" files)) {
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
            persistentStoragePaths = attrNames cfg;
            usersPerPath = allPersistentStoragePaths.users;
            homeDirOffenders =
              filterAttrs
                (n: v: (v.home != config.users.users.${n}.home));

            recursive = recursivePersistentPaths (sortedDirs.result or [ ]);
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
              assertion = duplicates (catAttrs "destination" files) == [ ];
              message =
                let
                  offenders = duplicates (catAttrs "destination" files);
                in
                ''
                  environment.persistence:
                      The following files were specified two or more
                      times:
                        ${concatStringsSep "\n      " offenders}
                '';
            }
            {
              assertion = duplicates (catAttrs "destination" directories) == [ ];
              message =
                let
                  offenders = duplicates (catAttrs "destination" directories);
                in
                ''
                  environment.persistence:
                      The following directories were specified two or more
                      times:
                        ${concatStringsSep "\n      " offenders}
                '';
            }
            {
              assertion = !(sortedDirs ? cycle);
              message =
                let
                  showChain = sep: concatMapStringsSep sep (dir: "'${dir.source}:${dir.destination}'");
                  dummyDir = { source = "<none>"; destination = "<none>"; };
                  cycle = showChain " -> " (sortedDirs.cycle or [ dummyDir ]);
                  loops = showChain ", " (sortedDirs.loops or [ dummyDir ]);
                in
                ''
                  environment.persistence:
                      Unable to topologically sort persistent storage source and destination directories (directories shown below as '<source>:<destination>'):

                      Persistent storage directory dependency path ${cycle} loops to ${loops}.

                      This can happen when the source path of one directory is a prefix of the source path of a second, and the destination path of the second directory is a prefix of the destination path of the first.

                      Issues like these prevent the 'environment.persistence' module from creating source and destination directories and setting their permissions in a stable and consistent order.
                '';
            }
            {
              assertion = recursive == [ ];
              message = ''
                environment.persistence:
                    Recursive persistent storage paths are not supported.
                      ${concatMapStringsSep "\n" (loop: ''
                      Destination path '${loop.destination}' for source '${loop.source}' is under persistent storage path '${loop.persistentStoragePath}'
                      '') recursive}
              '';
            }
          ];

        warnings =
          let
            usersWithoutUid = attrNames (filterAttrs (_n: u: u.uid == null) config.users.users);
            groupsWithoutGid = attrNames (filterAttrs (_n: g: g.gid == null) config.users.groups);
            varLibNixosPersistent =
              let
                varDirs = parentsOf "/var/lib/nixos" ++ [ "/var/lib/nixos" ];
                persistedDirs = catAttrs "destination" directories;
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
