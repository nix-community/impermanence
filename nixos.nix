{ pkgs, config, lib, ... }:

let
  inherit (lib) attrNames attrValues zipAttrsWith flatten mkOption
    types foldl' unique noDepEntry concatMapStrings listToAttrs
    escapeShellArg escapeShellArgs replaceStrings recursiveUpdate all
    filter filterAttrs concatStringsSep concatMapStringsSep isString
    catAttrs optional optionals literalExpression genAttrs;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath
    concatPaths sanitizeName duplicates coercedToDir coercedToFile
    toposortDirs extractPersistentStoragePaths recursivePersistentPaths;

  cfg = config.environment.persistence;
  users = config.users.users;
  allPersistentStoragePaths = extractPersistentStoragePaths cfg;
  inherit (allPersistentStoragePaths) files directories;
  mountFile = pkgs.runCommand "impermanence-mount-file" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./mount-file.bash} $out
    patchShebangs $out
  '';

  # Create fileSystems bind mount entry.
  mkBindMountNameValuePair = { destination, source, persistentStoragePath, ... }: {
    name = destination;
    value = {
      device = source;
      noCheck = true;
      options = [ "bind" ]
        ++ optional cfg.${persistentStoragePath}.hideMounts "x-gvfs-hide";
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
      fileDirectories =
        let
          fileDirectory = f:
            let
              dirAttrs = genAttrs [ "relpath" "source" "destination" ] (a: dirOf f.${a});
            in
            {
              inherit (f) persistentStoragePath root;
              directory = dirOf f.file;
              implicit = true;
            } // dirAttrs // f.parentDirectory;
        in
        unique (map fileDirectory files);
    in
    toposortDirs (directories ++ fileDirectories);
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type =
        let
          inherit (types) attrsOf bool listOf submodule path either str
            nonEmptyStr;
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
              commonOpts = attrName: { config, ... }: {
                options = {
                  persistentStoragePath = mkOption {
                    type = path;
                    default = persistentStoragePath;
                    description = ''
                      The path to persistent storage where the real
                      file should be stored.
                    '';
                  };
                  root = mkOption {
                    type = path;
                    default = "/";
                    description = ''
                      The path relative to which the output path will be
                      created.
                    '';
                  };
                  prefix = mkOption {
                    # *not* path -- permit stuff that does not start with "/"
                    type = nonEmptyStr;
                    internal = true;
                    default = "/";
                    description = ''
                      Path fragment prepended to <literal>${attrName}</literal>
                      when expanding it relative to
                      <literal>persistentStorageDirectory</literal> and
                      <literal>root</literal>.  Exists to support the implicit
                      home directory that appears before user file and
                      directory specifications.
                    '';
                  };
                  relpath = mkOption {
                    # *not* path -- permit stuff that does not start with "/"
                    type = nonEmptyStr;
                    internal = true;
                    default = concatPaths [ config.prefix config.${attrName} ];
                    description = ''
                      The file path relative to
                      <literal>persistentStoragePath</literal> and
                      <literal>root</literal>
                    '';
                  };
                  source = mkOption {
                    type = path;
                    internal = true;
                    default = concatPaths [ config.persistentStoragePath config.relpath ];
                    description = ''
                      The fully-qualified and normalized path rooted in
                      <literal>persistentStoragePath</literal>.  That is, given
                      <literal>persistentStoragePath</literal> "/foo/bar",
                      <literal>prefix</literal>bazz/quux</literal>, and
                      <literal>${attrName}</literal> "arr/iffic",
                      <literal>source</literal> will be
                      "/foo/bar/bazz/quux/arr/iffic".
                    '';
                  };
                  destination = mkOption {
                    type = path;
                    internal = true;
                    default = concatPaths [ config.root config.relpath ];
                    description = ''
                      The fully-qualified and normalized path rooted in
                      <literal>root</literal>.  That is, given
                      <literal>root</literal> "/foo/bar",
                      <literal>prefix</literal>bazz/quux</literal>, and
                      <literal>${attrName}</literal> "arr/iffic",
                      <literal>destination</literal> will be
                      "/foo/bar/bazz/quux/arr/iffic".
                    '';
                  };
                };
              };
              dirPermsOpts = { user, group, mode }: {
                user = mkOption {
                  type = str;
                  default = user;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the user
                    specified by this option.
                  '';
                };
                group = mkOption {
                  type = str;
                  default = group;
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created and owned by the
                    group specified by this option.
                  '';
                };
                mode = mkOption {
                  type = str;
                  default = mode;
                  example = "0700";
                  description = ''
                    If the directory doesn't exist in persistent
                    storage it will be created with the mode
                    specified by this option.
                  '';
                };
              };
              fileOpts = perms: {
                options = {
                  file = mkOption {
                    type = nonEmptyStr;
                    description = ''
                      The path to the file.
                    '';
                  };
                  parentDirectory = dirPermsOpts perms;
                };
              };
              dirOpts = perms: {
                options = {
                  directory = mkOption {
                    type = nonEmptyStr;
                    description = ''
                      The path to the directory.
                    '';
                  };

                  implicit = mkOption {
                    type = bool;
                    default = false;
                    internal = true;
                    description = ''
                      Whether the directory is implicit; that is, whether it is
                      created as the parent of an explicitly-specified file.
                      When true, permissions are copied from
                      <literal>destination</literal> to
                      <literal>source</literal>, rather than vice-versa, but
                      only if <literal>source</literal> does not already exist.
                    '';
                  };
                } // (dirPermsOpts perms);
              };
              rootFile = submodule [
                (commonOpts "file")
                (fileOpts defaultPerms)
              ];
              rootDir = submodule [
                (commonOpts "directory")
                (dirOpts defaultPerms)
              ];
            in
            {
              options =
                {
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
                            (commonOpts "file")
                            (fileOpts userDefaultPerms)
                            homePath
                          ];
                          userDir = submodule [
                            (commonOpts "directory")
                            (dirOpts userDefaultPerms)
                            homePath
                          ];
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
        mkPersistFileService = { source, destination, persistentStoragePath, ... }:
          let
            targetFile = escapeShellArg source;
            mountPoint = escapeShellArg destination;
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

        mkDirWithPerms =
          { persistentStoragePath
          , root
          , relpath
          , source
          , destination
          , user
          , group
          , mode
          , implicit ? false
          , ...
          }:
          let
            args = [
              persistentStoragePath
              root
              relpath
              source
              destination
              user
              group
              mode
              implicit
              cfg.${persistentStoragePath}.enableDebugging
            ];
          in
          ''
            createDirs ${escapeShellArgs args}
          '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        dirCreationScript =
          pkgs.writeShellScript "impermanence-run-create-directories" ''
            _status=0
            trap "_status=1" ERR
            source ${createDirectories}
            ${concatMapStrings mkDirWithPerms sortedDirs.result}
            exit $_status
          '';

        mkPersistFile = { source, destination, persistentStoragePath, ... }:
          let
            mountPoint = destination;
            targetFile = source;
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

        recursive = optionals (sortedDirs ? result) (recursivePersistentPaths sortedDirs.result);
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
            in
            ''
              environment.persistence:
                  Unable to topologically sort persistent storage source and destination directories (directories shown below as '<source>:<destination>'):

                  Persistent storage directory dependency path ${showChain " -> " sortedDirs.cycle} loops to ${showChain ", " sortedDirs.loops}.

                  This can happen when the source path of one directory is a prefix of the source path of a second, and the destination path of the second directory is a prefix of the destination path of the first.
                  For instance: '[ { directory = "abc"; root = "/abc/def"; } { directory = "abc/def"; } ]'.

                  It can also happen due to inconsistent permissions.
                  For instance: '[ { file = "abc/def"; parentDirectory.mode = "755"; } { file = "abc/xyz"; parentDirectory.mode = "700"; } ]'.

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
  };

}
