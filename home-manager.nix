{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStorageNames = (filter (path: cfg.${path}.enable) (attrNames cfg));

  inherit (pkgs.callPackage ./lib.nix { })
    splitPath
    dirListToPath
    concatPaths
    sanitizeName
    ;

  mount = "${pkgs.util-linux}/bin/mount";
  unmountScript = mountPoint: tries: sleep: ''
    triesLeft=${toString tries}
    if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
        while (( triesLeft > 0 )); do
            if fusermount -u ${mountPoint}; then
                break
            else
                (( triesLeft-- ))
                if (( triesLeft == 0 )); then
                    echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                    fusermount -uz ${mountPoint}
                else
                    sleep ${toString sleep}
                fi
            fi
        done
    fi
  '';
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule ({ name, config, ... }: {
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

              enable = mkOption {
                type = bool;
                default = true;
                description = "Whether to enable this persistent storage location.";
              };

              defaultDirectoryMethod = mkOption {
                type = types.enum [ "bindfs" "symlink" ];
                default = "bindfs";
                description = ''
                  The linking method that should be used for directories.

                  - bindfs is very transparent, and thus used as a safe
                  default. It has, however, a significant performance impact in
                  IO-heavy situations.

                  - symlinks have great performance but may be treated
                  specially by some programs that may e.g. generate
                  errors/warnings, or replace them.

                  This can be overridden on a per entry basis.
                '';
              };

              directories = mkOption {
                type = types.listOf (
                  types.coercedTo types.str (directory: { inherit directory; }) (submodule {
                    options = {
                      directory = mkOption {
                        type = str;
                        description = "The directory path to be linked.";
                      };
                      method = mkOption {
                        type = types.enum [ "bindfs" "symlink" ];
                        default = config.defaultDirectoryMethod;
                        description = ''
                          The linking method to be used for this specific
                          directory entry. See
                          <literal>defaultDirectoryMethod</literal> for more
                          information on the tradeoffs.
                        '';
                      };
                    };
                  })
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
                type = with types; listOf str;
                default = [ ];
                example = [
                  ".screenrc"
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

        mkLinkNameValuePair = persistentStorageName: fileOrDir: {
          name =
            if cfg.${persistentStorageName}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ fileOrDir ]))
            else
              fileOrDir;
          value = { source = link (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath fileOrDir ]); };
        };

        mkLinksToPersistentStorage = persistentStorageName:
          listToAttrs (map
            (mkLinkNameValuePair persistentStorageName)
            (map (v: v.directory) (cfg.${persistentStorageName}.files ++
              (filter (v: v.method == "symlink") cfg.${persistentStorageName}.directories)))
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStorageNames);

    systemd.user.services =
      let
        mkBindMountService = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            name = "bindMount-${sanitizeName targetDir}";
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStorageName}.allowOther) "no-allow-other"
              ++ optional (versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${targetDir}"
            );
            bindfsOptionFlag = optionalString (bindfsOptions != "") (" -o " + bindfsOptions);
            bindfs = "bindfs" + bindfsOptionFlag;
            startScript = pkgs.writeShellScript name ''
              set -eu
              if ! mount | grep -F ${mountPoint}' ' && ! mount | grep -F ${mountPoint}/; then
                  mkdir -p ${mountPoint}
                  exec ${bindfs} ${targetDir} ${mountPoint}
              else
                  echo "There is already an active mount at or below ${mountPoint}!" >&2
                  exit 1
              fi
            '';
            stopScript = pkgs.writeShellScript "unmount-${name}" ''
              set -eu
              ${unmountScript mountPoint 6 5}
            '';
          in
          {
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${targetDir} at ${mountPoint}";

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
              };

              Install.WantedBy = [ "paths.target" ];

              Service = {
                Type = "forking";
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
                Environment = "PATH=${makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.gnugrep pkgs.bindfs ]}:/run/wrappers/bin";
              };
            };
          };

        mkBindMountServicesForPath = persistentStorageName:
          listToAttrs (map
            (mkBindMountService persistentStorageName)
            (map (v: v.directory) (filter (v: v.method == "bindfs") cfg.${persistentStorageName}.directories))
          );
      in
      builtins.foldl'
        recursiveUpdate
        { }
        (map mkBindMountServicesForPath persistentStorageNames);

    home.activation =
      let
        dag = config.lib.dag;
        mount = "${pkgs.util-linux}/bin/mount";

        # The name of the activation script entry responsible for
        # reloading systemd user services. The name was initially
        # `reloadSystemD` but has been changed to `reloadSystemd`.
        reloadSystemd =
          if config.home.activation ? reloadSystemD then
            "reloadSystemD"
          else
            "reloadSystemd";

        mkBindMount = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStorageName}.allowOther) "no-allow-other"
              ++ optional (versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${targetDir}"
            );
            bindfsOptionFlag = optionalString (bindfsOptions != "") (" -o " + bindfsOptions);
            bindfs = "${pkgs.bindfs}/bin/bindfs" + bindfsOptionFlag;
            systemctl = "XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ${config.systemd.user.systemctlPath}";
          in
          ''
            mkdir -p ${targetDir}
            mkdir -p ${mountPoint}

            if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
                if ! ${mount} | grep -F ${mountPoint}' ' | grep -F bindfs; then
                    if ! ${mount} | grep -F ${mountPoint}' ' | grep -F ${targetDir}' ' >/dev/null; then
                        # The target directory changed, so we need to remount
                        echo "remounting ${mountPoint}"
                        ${systemctl} --user stop bindMount-${sanitizeName targetDir}
                        ${bindfs} ${targetDir} ${mountPoint}
                        mountedPaths[${mountPoint}]=1
                    fi
                fi
            elif ${mount} | grep -F ${mountPoint}/ >/dev/null; then
                echo "Something is mounted below ${mountPoint}, not creating bind mount to ${targetDir}" >&2
            else
                ${bindfs} ${targetDir} ${mountPoint}
                mountedPaths[${mountPoint}]=1
            fi
          '';

        mkBindMountsForPath = persistentStorageName:
          concatMapStrings
            (mkBindMount persistentStorageName)
            (map (v: v.directory) (filter (v: v.method == "bindfs") cfg.${persistentStorageName}.directories));

        mkUnmount = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            if [[ -n ''${mountedPaths[${mountPoint}]+x} ]]; then
              ${unmountScript mountPoint 3 1}
            fi
          '';

        mkUnmountsForPath = persistentStorageName:
          concatMapStrings
            (mkUnmount persistentStorageName)
            (map (v: v.directory) (filter (v: v.method == "bindfs") cfg.${persistentStorageName}.directories));

        mkLinkCleanup = persistentStorageName: dir:
          let
            mountDir =
              if cfg.${persistentStorageName}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            # Unmount if it's mounted. Ensures smooth transition: bindfs -> symlink
            ${unmountScript mountPoint 3 1}

            # If it is a directory and it's empty
            if [ -d ${mountPoint} ] && [ -z "$(ls -A ${mountPoint})" ]; then
              echo "Removing empty directory ${mountPoint}"
              rm -d ${mountPoint}
            fi
          '';

        mkLinkCleanupForPath = persistentStorageName:
          concatMapStrings
            (mkLinkCleanup persistentStorageName)
            (map (v: v.directory) (filter (v: v.method == "symlink") cfg.${persistentStorageName}.directories));


      in
      mkMerge [
        (mkIf (any (path: (filter (v: v.method == "symlink") cfg.${path}.directories) != [ ]) persistentStorageNames) {
          # Clean up existing empty directories in the way of links
          cleanEmptyLinkTargets =
            dag.entryBefore
              [ "checkLinkTargets" ]
              ''
                ${concatMapStrings mkLinkCleanupForPath persistentStorageNames}
              '';
        })
        (mkIf (any (path: (filter (v: v.method == "bindfs") cfg.${path}.directories) != [ ]) persistentStorageNames) {
          createAndMountPersistentStoragePaths =
            dag.entryBefore
              [ "writeBoundary" ]
              ''
                declare -A mountedPaths
                ${(concatMapStrings mkBindMountsForPath persistentStorageNames)}
              '';

          unmountPersistentStoragePaths =
            dag.entryBefore
              [ "createAndMountPersistentStoragePaths" ]
              ''
                PATH=$PATH:/run/wrappers/bin
                unmountBindMounts() {
                ${concatMapStrings mkUnmountsForPath persistentStorageNames}
                }

                # Run the unmount function on error to clean up stray
                # bind mounts
                trap "unmountBindMounts" ERR
              '';

          runUnmountPersistentStoragePaths =
            dag.entryBefore
              [ reloadSystemd ]
              ''
                unmountBindMounts
              '';
        })
        (mkIf (any (path: (cfg.${path}.files != [ ]) || ((filter (v: v.method == "symlink") cfg.${path}.directories) != [ ])) persistentStorageNames) {
          createTargetFileDirectories =
            dag.entryBefore
              [ "writeBoundary" ]
              (concatMapStrings
                (persistentStorageName:
                  concatMapStrings
                    (targetFilePath: ''
                      mkdir -p ${escapeShellArg (concatPaths [ cfg.${persistentStorageName}.persistentStoragePath (dirOf targetFilePath) ])}
                    '')
                    (map (v: v.directory) (cfg.${persistentStorageName}.files ++ (filter (v: v.method == "symlink") cfg.${persistentStorageName}.directories))))
                persistentStorageNames);
        })
      ];
  };

}
