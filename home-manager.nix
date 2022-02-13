{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths sanitizeName;
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule ({ name, ... }: {
          options =
            {
              directories = mkOption {
                type = with types; listOf str;
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
                ];
                description = ''
                  A list of directories in your home directory that
                  you want to link to persistent storage.
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

        mkLinkNameValuePair = persistentStoragePath: file: {
          name =
            if cfg.${persistentStoragePath}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ file ]))
            else
              file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files)
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    systemd.user.services =
      let
        mkBindMountService = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            name = "bindMount-${sanitizeName targetDir}";
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStoragePath}.allowOther) "no-allow-other"
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
              triesLeft=6
              while (( triesLeft > 0 )); do
                  if fusermount -u ${mountPoint}; then
                      exit 0
                  else
                      (( triesLeft-- ))
                      if (( triesLeft == 0 )); then
                          echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                          fusermount -uz ${mountPoint}
                      else
                          sleep 5
                      fi
                  fi
              done
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

        mkBindMountServicesForPath = persistentStoragePath:
          listToAttrs (map
            (mkBindMountService persistentStoragePath)
            cfg.${persistentStoragePath}.directories
          );
      in
      builtins.foldl'
        recursiveUpdate
        { }
        (map mkBindMountServicesForPath persistentStoragePaths);

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

        mkBindMount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            mount = "${pkgs.util-linux}/bin/mount";
            bindfsOptions = concatStringsSep "," (
              optional (!cfg.${persistentStoragePath}.allowOther) "no-allow-other"
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

        mkBindMountsForPath = persistentStoragePath:
          concatMapStrings
            (mkBindMount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

        mkUnmount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            if [[ -n ''${mountedPaths[${mountPoint}]+x} ]]; then
                triesLeft=3
                while (( triesLeft > 0 )); do
                    if fusermount -u ${mountPoint}; then
                        break
                    else
                        (( triesLeft-- ))
                        if (( triesLeft == 0 )); then
                            echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                            fusermount -uz ${mountPoint} || true
                        else
                            sleep 1
                        fi
                    fi
                done
            fi
          '';

        mkUnmountsForPath = persistentStoragePath:
          concatMapStrings
            (mkUnmount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

      in
      mkMerge [
        (mkIf (any (path: cfg.${path}.directories != [ ]) persistentStoragePaths) {
          createAndMountPersistentStoragePaths =
            dag.entryBefore
              [ "writeBoundary" ]
              ''
                declare -A mountedPaths
                ${(concatMapStrings mkBindMountsForPath persistentStoragePaths)}
              '';

          unmountPersistentStoragePaths =
            dag.entryBefore
              [ "createAndMountPersistentStoragePaths" ]
              ''
                unmountBindMounts() {
                ${concatMapStrings mkUnmountsForPath persistentStoragePaths}
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
        (mkIf (any (path: cfg.${path}.files != [ ]) persistentStoragePaths) {
          createTargetFileDirectories =
            dag.entryBefore
              [ "writeBoundary" ]
              (concatMapStrings
                (persistentStoragePath:
                  concatMapStrings
                    (targetFilePath: ''
                      mkdir -p ${escapeShellArg (concatPaths [ persistentStoragePath (dirOf targetFilePath) ])}
                    '')
                    cfg.${persistentStoragePath}.files)
                persistentStoragePaths);
        })
      ];
  };

}
