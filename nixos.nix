{ pkgs, config, options, lib, utils, ... }:

let
  inherit (lib)
    attrNames
    attrValues
    mapAttrsToList
    zipAttrsWith
    flatten
    mkAfter
    mkOption
    mkIf
    mkMerge
    types
    foldl'
    unique
    concatMap
    concatMapStrings
    escapeShellArg
    escapeShellArgs
    recursiveUpdate
    all
    filter
    filterAttrs
    concatStringsSep
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

  # All persistent storage path submodule values zipped together into
  # one set. This includes paths from the Home Manager persistence
  # module and `users` submodules.
  allPersistentStoragePaths =
    let
      # All enabled system paths
      nixos = filter (v: v.enable) (attrValues cfg);

      # Get the files and directories from the `users` submodules of
      # enabled system paths
      nixosUsers = flatten (map attrValues (catAttrs "users" nixos));

      # Fetch enabled paths from all Home Manager users who have the
      # persistence module loaded
      homeManager =
        let
          paths = flatten
            (mapAttrsToList
              (_name: value:
                attrValues (value.home.persistence or { }))
              config.home-manager.users or { });
        in
        filter (v: v.enable) paths;
    in
    zipAttrsWith (_: flatten) (nixos ++ nixosUsers ++ homeManager);

  inherit (allPersistentStoragePaths) files directories;

  mountFile = pkgs.runCommand "persistence-mount-file" { buildInputs = [ pkgs.bash ]; } ''
    cp ${./mount-file.bash} $out
    patchShebangs $out
  '';

  mkPersistFile = { filePath, persistentStoragePath, method, enableDebugging, ... }:
    let
      mountPoint = filePath;
      targetFile = concatPaths [ persistentStoragePath filePath ];
      args = escapeShellArgs [
        mountPoint
        targetFile
        method
        enableDebugging
      ];
    in
    ''
      ${mountFile} ${args}
    '';

  getHomeUnitName = home: escapeSystemdPath home;
  getUnitTarget = home: if home != null then "home-files-${getHomeUnitName home}.target" else "local-fs.target";
  getInitName = home: "home-persistence-${getHomeUnitName home}";
  homes = unique (map (entry: entry.home) (filter (entry: entry.home != null) (files ++ directories)));
  homeEntries = home: entries: filter (entry: entry.home == home) entries;
  homeSettings = home: config.environment.persistenceHomes.${home};
  atBoot = entry: entry.home == null || (homeSettings entry.home).enableAtBoot;
  directoryScript = import ./directory-creation.nix { inherit pkgs lib users; };
in
{
  options = {
    environment.persistenceHomes = mkOption {
      default = { };
      description = "Activation settings for per-home persistence targets.";
      type = attrsOf (submodule {
        options.enableAtBoot = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Initialize and start this home's persistence during boot and system
            activation. Disable this when its storage is mounted after login.
          '';
        };
      });
    };

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

  config =
    mkMerge [
      (lib.optionalAttrs (options ? home-manager.sharedModules) {
        home-manager.sharedModules = [
          ./home-manager.nix
          {
            home._nixosModuleImported = true;
          }
        ];
      })
      (mkIf (allPersistentStoragePaths != { })
        (mkMerge [
          {
            environment.persistenceHomes = lib.genAttrs homes (_: { });

            systemd.services =
              let
                mkPersistFileService = { filePath, persistentStoragePath, home, ... }@args:
                  let
                    targetFile = concatPaths [ persistentStoragePath filePath ];
                    mountPoint = escapeShellArg filePath;
                  in
                  {
                    "persist-${escapeSystemdPath targetFile}" =
                      {
                        description = "Bind mount or link ${targetFile} to ${mountPoint}";
                        wantedBy = [ (getUnitTarget home) ];
                        before = [ (getUnitTarget home) ];
                        requires = optionals (home != null) [ "${getInitName home}.service" ];
                        after = optionals (home != null) [ "${getInitName home}.service" ];
                        path = [ pkgs.util-linux ];
                        unitConfig.DefaultDependencies = false;
                        serviceConfig = {
                          Type = "oneshot";
                          RemainAfterExit = true;
                          ExecStart = mkPersistFile args;
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
              foldl' recursiveUpdate { } (map mkPersistFileService files)
              // builtins.listToAttrs (map
                (home: {
                  name = getInitName home;
                  value = {
                    description = "Initialize persistence directories for ${home}";
                    before = [ (getUnitTarget home) ];
                    serviceConfig = {
                      Type = "oneshot";
                      RemainAfterExit = true;
                      ExecStart = directoryScript
                        (homeEntries home directories)
                        (homeEntries home files);
                    };
                  };
                })
                homes);

            boot.initrd.systemd.mounts =
              let
                mkBindMount = { dirPath, persistentStoragePath, hideMount, allowTrash, ... }: {
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
                  ] ++ optionals allowTrash [
                    "x-gvfs-trash"
                  ]);
                };
                dirs = filter (d: elem d.dirPath pathsNeededForBoot) directories;
              in
              map mkBindMount dirs;

            systemd.mounts =
              let
                mkBindMount = { dirPath, persistentStoragePath, hideMount, allowTrash, home, ... }:
                  {
                    wantedBy = [ (getUnitTarget home) ];
                    before = [ (getUnitTarget home) ];
                    requires = optionals (home != null) [ "${getInitName home}.service" ];
                    after = optionals (home != null) [ "${getInitName home}.service" ];
                    where = concatPaths [ "/" dirPath ];
                    what = concatPaths [ persistentStoragePath dirPath ];
                    unitConfig.DefaultDependencies = false;
                    type = "none";
                    options = concatStringsSep "," ([
                      "bind"
                    ] ++ optionals hideMount [
                      "x-gvfs-hide"
                    ] ++ optionals allowTrash [
                      "x-gvfs-trash"
                    ]);
                  };
              in
              map mkBindMount directories;

            systemd.targets = builtins.listToAttrs (builtins.map
              (home: {
                name = "home-files-${getHomeUnitName home}";
                value = {
                  description = "Target for persisted directories and files under ${home}";
                  wantedBy = optionals (homeSettings home).enableAtBoot [ "local-fs.target" ];
                  requires = [ "${getInitName home}.service" ];
                  after = [ "${getInitName home}.service" ];
                };
              })
              homes);

            system.activationScripts =
              let
                files = filter atBoot allPersistentStoragePaths.files;
                directories = filter atBoot allPersistentStoragePaths.directories;
                dirCreationScript = directoryScript directories files;

                persistFileScript =
                  pkgs.writeShellScript "persistence-persist-files" ''
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

                submoduleAssertions = flatten allPersistentStoragePaths.assertions;

                fileAssertions = flatten (catAttrs "assertions" files);

                directoryAssertions = flatten (catAttrs "assertions" directories);

                filePaths = catAttrs "filePath" files;
                duplicateFiles = duplicates filePaths;

                dirPaths = catAttrs "dirPath" directories;
                duplicateDirs = duplicates dirPaths;

                allPaths = unique (concatMap parentsOf (filePaths ++ dirPaths));
              in
              submoduleAssertions
              ++ fileAssertions
              ++ directoryAssertions
              ++ [
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
                          have the option "neededForBoot" set to true.

                          Please fix the following filesystems:
                            ${concatStringsSep "\n      " offenders}
                    '';
                }
                {
                  # Assert that all ephemeral storage volumes we
                  # create links into are marked with neededForBoot.
                  assertion = all (markedNeededForBoot true) allPaths;
                  message =
                    let
                      offenders = filter (markedNeededForBoot false) allPaths;
                    in
                    ''
                      environment.persistence:
                          All filesystems used for ephemeral storage must
                          have the option "neededForBoot" set to true.

                          Please fix the following filesystems:
                            ${concatStringsSep "\n      " offenders}
                    '';
                }
                {
                  assertion = duplicateFiles == [ ];
                  message = ''
                    environment.persistence:
                        The following files were specified two or more
                        times:
                          ${concatStringsSep "\n      " duplicateFiles}
                  '';
                }
                {
                  assertion = duplicateDirs == [ ];
                  message = ''
                    environment.persistence:
                        The following directories were specified two or more
                        times:
                          ${concatStringsSep "\n      " duplicateDirs}
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
        ]))
    ];

}
