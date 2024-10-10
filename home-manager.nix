{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.impermanence;
  persistentStorages = builtins.mapAttrs
    (_: persistentStorage:
      let
        storage = persistentStorage // {
          mkDirCfg = getHomeDirCfg {
            inherit storage pkgs;
            inherit (config.home) homeDirectory;
          };
        };
      in
      storage
    )
    config.home.persistence;

  persistentStoragesList = builtins.attrValues persistentStorages;

  getPath = v: if isString v then v else v.directory or v.file;
  isBindfs = v: v.method == "bindfs";
  isSymlink = v: v.method == "symlink";

  orderedDirs = lib.pipe persistentStorages [
    (lib.attrsets.mapAttrsToList (persistentStorageName: storage: builtins.map
      (dir: {
        inherit persistentStorageName storage dir;
        inherit (dir) method;
        path = dir.directory;
        dirCfg = storage.mkDirCfg dir.directory;
      })
      storage.directories
    ))
    builtins.concatLists
    (builtins.sort (a: b: a.path < b.path))
  ];

  dirsByHomeMountpoint = lib.pipe orderedDirs [
    (builtins.map (e: {
      name = e.dirCfg.mountPoint;
      value = e;
    }))
    builtins.listToAttrs
  ];

  orderedFiles = lib.pipe persistentStorages [
    (lib.attrsets.mapAttrsToList (persistentStorageName: storage: builtins.map
      (file: {
        inherit persistentStorageName storage file;
        inherit (file) method;
        path = file.file;
        dirCfg = storage.mkDirCfg file.file;
      })
      storage.files
    ))
    builtins.concatLists
    (builtins.sort (a: b: a.path < b.path))
  ];

  inherit (pkgs.callPackage ./lib.nix { })
    getHomeDirCfg
    sanitizeName
    ;

  scripts = pkgs.callPackage ./scripts { systemctl = config.systemd.user.systemctlPath; };
in
{
  options = {

    impermanence.defaultDirectoryMethod = lib.mkOption {
      type = with types; enum [ "bindfs" "symlink" "external" ];
      default = "bindfs";
      description = ''
        The linking method that should be used by default for directories:
        - `bindfs` is the default (for non-root user) and works for most use cases,
        - `symlink` is there for the programs misbehaving with `bindfs`,
        - `external` allows you to handle the setup in your own code, this is default for `root`,
      '';
    };

    impermanence.defaultFileMethod = lib.mkOption {
      type = with types; enum [ "symlink" "external" ];
      default = "symlink";
      description = ''
        The linking method that should be used for files:
        - `symlink` is the default (for non-root user),
        - `external` allows you to handle the setup in your own code, this is default for `root`,
      '';
    };

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule ({ name, ... }@persistenceArgs: {
          options =
            {
              persistentStoragePath = mkOption {
                type = path;
                default = name;
                description = ''
                  The path to persistent storage where the real
                  files and directories should be stored.
                '';
              };

              defaultDirectoryMethod = lib.mkOption {
                type = with types; enum [ "bindfs" "symlink" "external" ];
                default = cfg.defaultDirectoryMethod;
                description = ''
                  The linking method that should be used for directories,
                  see `impermanence.defaultDirectoryMethod` for details.
                '';
              };

              defaultFileMethod = lib.mkOption {
                type = with types; enum [ "symlink" "external" ];
                default = cfg.defaultFileMethod;
                description = ''
                  The linking method that should be used for files,
                  see `impermanence.defaultFileMethod` for details.
                '';
              };

              directories = mkOption {
                type =
                  let
                    directoryType = types.submodule {
                      options = {
                        directory = mkOption {
                          type = with types; str;
                          default = null;
                          description = "The directory path to be linked.";
                        };
                        method = mkOption {
                          type = with types; enum [ "bindfs" "symlink" "external" ];
                          default = persistenceArgs.config.defaultDirectoryMethod;
                          description = ''
                            The linking method that should be used for this directory,
                            see `impermanence.defaultDirectoryMethod` for details.
                          '';
                        };
                      };
                    };
                  in
                  with types; listOf (
                    coercedTo
                      (either str directoryType)
                      (value: if builtins.isString value then { directory = value; } else value)
                      directoryType
                  );
                default = [ ];
                example = [
                  "Downloads"
                  "Music"
                  "Pictures"
                  "Documents"
                  "Videos"
                  "VirtualBox VMs"
                  ".gnupg"
                  ".ssh"
                  ".local/share/keyrings"
                  ".local/share/direnv"
                  {
                    directory = ".local/share/Steam";
                    method = "symlink";
                  }
                ];
                description = ''
                  A list of directories in your home directory that
                  you want to link to persistent storage. You may optionally
                  specify the linking method each directory should use.
                '';
              };

              files = mkOption {
                type =
                  let
                    fileType = types.submodule {
                      options = {
                        file = mkOption {
                          type = with types; str;
                          default = null;
                          description = "The file path to be linked.";
                        };
                        method = mkOption {
                          type = with types; enum [ "symlink" "external" ];
                          default = persistenceArgs.config.defaultFileMethod;
                          description = ''
                            The linking method that should be used for this file,
                            see `impermanence.defaultFileMethod` for details.
                          '';
                        };
                      };
                    };
                  in
                  with types; listOf (
                    coercedTo
                      (either str fileType)
                      (value: if builtins.isString value then { file = value; } else value)
                      fileType
                  );
                default = [ ];
                example = [
                  ".screenrc"
                  {
                    directory = ".bashrc";
                    method = "external";
                  }
                ];
                description = ''
                  A list of files in your home directory you want to
                  link to persistent storage.
                '';
              };

              allowOther = mkOption {
                type = with types; nullOr bool;
                default = null;
                example = true;
                apply = x:
                  if x == null then
                    warn ''
                      home.persistence."${name}".allowOther not set; assuming 'false'.
                      See https://github.com/nix-community/impermanence#home-manager for more info.
                    ''
                      false
                  else
                    x;
                description = ''
                  Whether to allow other users, such as
                  <literal>root</literal>, access to files through the
                  bind mounted directories listed in
                  <literal>directories</literal>. Requires the NixOS
                  configuration parameter
                  <literal>programs.fuse.userAllowOther</literal> to
                  be <literal>true</literal>.
                '';
              };

              removePrefixDirectory = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = ''
                  Note: This is mainly useful if you have a dotfiles
                  repo structured for use with GNU Stow; if you don't,
                  you can likely ignore it.

                  Whether to remove the first directory when linking
                  or mounting; e.g. for the path
                  <literal>"screen/.screenrc"</literal>, the
                  <literal>screen/</literal> is ignored for the path
                  linked to in your home directory.
                '';
              };
            };
        })
      );
      description = ''
        A set of persistent storage location submodules listing the
        files and directories to link to their respective persistent
        storage location.

        Each attribute name should be the path relative to the user's
        home directory.

        For detailed usage, check the <link
        xlink:href="https://github.com/nix-community/impermanence">documentation</link>.
      '';
      example = literalExpression ''
        {
          "/persistent/home/talyz" = {
            directories = [
              "Downloads"
              "Music"
              "Pictures"
              "Documents"
              "Videos"
              "VirtualBox VMs"
              ".gnupg"
              ".ssh"
              ".nixops"
              ".local/share/keyrings"
              ".local/share/direnv"
              {
                directory = ".local/share/Steam";
                method = "symlink";
              }
            ];
            files = [
              ".screenrc"
            ];
            allowOther = true;
          };
        }
      '';
    };

  };

  config = {
    home.file =
      let
        link = file:
          pkgs.runCommand
            "${sanitizeName file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = storage: fileOrDir:
          let
            dirCfg = storage.mkDirCfg fileOrDir;
          in
          {
            name = dirCfg.mountDir;
            value = { source = link dirCfg.targetDir; };
          };

        mkLinksToPersistentStorage = storage:
          listToAttrs (map
            (mkLinkNameValuePair storage)
            (map getPath (builtins.filter isSymlink (storage.files ++ storage.directories)))
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragesList);

    systemd.user.services =
      let
        mkBindMountService = storage: dir:
          let
            dirCfg = storage.mkDirCfg dir;
            name = dirCfg.unitName;
          in
          {
            # try to keep those changes in sync with scripts scripts/hm-bind-mount-activation.bash:bindfs-run()
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${dirCfg.escaped.targetDir} at ${dirCfg.escaped.mountPoint}";

                # Don't restart the unit, it could corrupt data and
                # crash programs currently reading from the mount.
                X-RestartIfChanged = false;

                # Don't add an implicit After=basic.target.
                DefaultDependencies = false;

                Before = [
                  "bluetooth.target"
                  "basic.target"
                  "default.target"
                  "paths.target"
                  "sockets.target"
                  "timers.target"
                ];

                After = lib.pipe dir [
                  # generate all system path prefixes
                  (lib.strings.splitString "/")
                  (pcs: builtins.map (i: lib.lists.sublist 0 i pcs) (lib.lists.range 0 (builtins.length pcs - 1)))
                  (builtins.map (lib.strings.concatStringsSep "/"))

                  # try to find an existing mountpoint for each generated path, skip those not found
                  (builtins.map (path: let inherit (storage.mkDirCfg path) mountPoint; in dirsByHomeMountpoint.${mountPoint} or null))
                  (builtins.filter (e: e != null))

                  (builtins.map (orderedDir: "${orderedDir.dirCfg.unitName}.service"))
                ];

                ConditionPathIsMountPoint = [ "!${dirCfg.mountPoint}" ];
              };

              Install.WantedBy = [ "paths.target" ];

              Service = {
                Type = "forking";
                ExecStart = escapeShellArgs ([
                  (lib.getExe scripts.hm.bind-mount-service)
                  dirCfg.targetDir
                  dirCfg.mountPoint
                ] ++ dirCfg.runBindfsArgs);

                ExecStop = escapeShellArgs [
                  (lib.getExe scripts.hm.unmount)
                  dirCfg.mountPoint
                  "6"
                  "5"
                ];
                Slice = "background.slice";
              };
            };
          };

        mkBindMountServicesForPath = storage:
          listToAttrs (map
            (mkBindMountService storage)
            (map getPath (filter isBindfs storage.directories))
          );
      in
      builtins.foldl' recursiveUpdate { } (map mkBindMountServicesForPath persistentStoragesList);

    home.activation =
      let
        dag = config.lib.dag;

        # The name of the activation script entry responsible for
        # reloading systemd user services. The name was initially
        # `reloadSystemD` but has been changed to `reloadSystemd`.
        reloadSystemd =
          if config.home.activation ? reloadSystemD then
            "reloadSystemD"
          else
            "reloadSystemd";

        mkBindMount = orderedDir:
          let
            dirCfg = orderedDir.dirCfg;
            scriptArgs = [
              (lib.getExe scripts.hm.bind-mount-activation)
              dirCfg.mountPoint
              dirCfg.targetDir
              dirCfg.unitName
            ] ++ dirCfg.runBindfsArgs;
          in
          ''
            # ${dirCfg.escaped.mountPoint} <- ${dirCfg.escaped.targetDir}
            while read -r line; do
              echo "$line"
              if [[ "$line" == ${escapeShellArg scripts.outputPrefix}ERROR:* ]] ; then
                bindMountErrors+=("''${line#${escapeShellArg scripts.outputPrefix}ERROR:}")
              elif [[ "$line" == ${escapeShellArg scripts.outputPrefix}* ]] ; then
                mountedPaths["''${line#${escapeShellArg scripts.outputPrefix}}"]="1"
              fi
            done < <(${escapeShellArgs scriptArgs} || echo ${escapeShellArg scripts.outputPrefix}ERROR:$? )
          '';

        mkUnmount = orderedDir:
          let
            dirCfg = orderedDir.dirCfg;
          in
          ''
            # ${dirCfg.escaped.mountPoint} <- ${dirCfg.escaped.targetDir}
            if [[ -n "''${mountedPaths[${dirCfg.escaped.mountPoint}]+x}" ]]; then
              ${lib.getExe scripts.hm.unmount} ${dirCfg.escaped.mountPoint} 3 1
            fi
          '';

        mkLinkCleanup = orderedDir:
          let
            dirCfg = orderedDir.dirCfg;
          in
          ''
            # ${dirCfg.escaped.mountPoint} <- ${dirCfg.escaped.targetDir}
            # Unmount if it's mounted. Ensures smooth transition: bindfs -> symlink
            ${lib.getExe scripts.hm.unmount} ${dirCfg.escaped.mountPoint} 3 1

            # If it is a directory and it's empty
            if [ -d ${dirCfg.escaped.mountPoint} ] && [ -z "$(ls -A ${dirCfg.escaped.mountPoint})" ]; then
              echo "Removing empty directory ${dirCfg.mountPoint}"
              rm -d ${dirCfg.escaped.mountPoint}
            fi
          '';

        mkDirScripts = { filterFn, mapFn, reverse ? false }: lib.pipe orderedDirs [
          (builtins.filter (orderedDir: filterFn orderedDir.dir))
          (builtins.map (orderedDir: mapFn orderedDir))
          (if reverse then lib.lists.reverseList else (x: x))
          (x: if x == [ ] then [ ": # nothing returned frmo mkDirScripts" ] else x)
          (builtins.concatStringsSep "\n")
        ];
      in
      {
        # Clean up existing empty directories in the way of links
        impermanenceCleanEmptyLinkTargets =
          dag.entryBefore
            [ "checkLinkTargets" ]
            (mkDirScripts { filterFn = isSymlink; mapFn = mkLinkCleanup; reverse = true; });

        impermanenceCreateAndMountPersistentStoragePaths =
          dag.entryBefore
            [ "writeBoundary" ]
            ''
              declare -A mountedPaths
              bindMountErrors=()
              ${mkDirScripts {filterFn = isBindfs; mapFn = mkBindMount; reverse = false; }}
              test "''${#bindMountErrors[@]}" == 0
            '';

        impermanenceUnmountPersistentStoragePaths =
          dag.entryBefore
            [ "impermanenceCreateAndMountPersistentStoragePaths" ]
            ''
              unmountBindMounts() {
              ${mkDirScripts {filterFn = isBindfs; mapFn = mkUnmount; reverse = true; }}
              }

              # Run the unmount function on error to clean up stray
              # bind mounts
              trap "unmountBindMounts" ERR
            '';

        impermanenceRunUnmountPersistentStoragePaths =
          dag.entryBefore
            [ reloadSystemd ]
            ''
              unmountBindMounts
            '';

        impermanenceCreateTargetFileDirectories =
          dag.entryBefore
            [ "writeBoundary" ]
            (lib.pipe (builtins.filter isSymlink (orderedFiles ++ orderedDirs)) [
              (builtins.map (ordered: builtins.dirOf ordered.dirCfg.targetDir))
              (builtins.sort (a: b: a < b))
              lib.lists.unique
              (builtins.map (path: ''${pkgs.coreutils}/bin/mkdir -p ${escapeShellArg path}''))
              (builtins.concatStringsSep "\n")
            ]);
      };
  };

}
