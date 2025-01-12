{ pkgs, lib, name, config, users, ... }:
let
  inherit (lib)
    attrValues
    zipAttrsWith
    flatten
    mkOption
    mkDefault
    mapAttrsToList
    types
    literalExpression
    mapAttrs
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    ;

  inherit (types)
    attrsOf
    bool
    listOf
    submodule
    nullOr
    path
    str
    coercedTo
    ;

  defaultPerms = {
    mode = "0755";
    user = "root";
    group = "root";
  };

  commonOpts = {
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
      parentDirectory =
        commonOpts.options //
        mapAttrs
          (_: x:
            if x._type or null == "option" then
              x // { internal = true; }
            else
              x)
          dirOpts.options;
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
      hideMount = mkOption {
        type = bool;
        default = config.hideMounts;
        defaultText = "environment.persistence.‹name›.hideMounts";
        example = true;
        description = ''
          Whether to hide bind mounts from showing up as
          mounted drives.
        '';
      };
      # Save the default permissions at the level the
      # directory resides. This used when creating its
      # parent directories, giving them reasonable
      # default permissions unaffected by the
      # directory's own.
      defaultPerms = mapAttrs (_: x: x // { internal = true; }) dirPermsOpts;
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
      parentDirectory = mkDefault (defaultPerms // rec {
        directory = dirOf config.file;
        dirPath = directory;
        inherit (config) persistentStoragePath;
        inherit defaultPerms;
      });
      filePath = mkDefault config.file;
    })
  ];
  rootDir = submodule ([
    commonOpts
    dirOpts
    ({ config, ... }: {
      defaultPerms = mkDefault defaultPerms;
      dirPath = mkDefault config.directory;
    })
  ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) defaultPerms));
in
{
  systemOpts = {
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
                userDefaultPerms = {
                  inherit (defaultPerms) mode;
                  user = name;
                  group = users.${userDefaultPerms.user}.group;
                };
                fileConfig =
                  { config, ... }:
                  {
                    parentDirectory = rec {
                      directory = dirOf config.file;
                      dirPath = concatPaths [ config.home directory ];
                      inherit (config) persistentStoragePath home;
                      defaultPerms = userDefaultPerms;
                    };
                    filePath = concatPaths [ config.home config.file ];
                  };
                userFile = submodule [
                  commonOpts
                  fileOpts
                  { inherit (config) home; }
                  {
                    parentDirectory = mkDefault userDefaultPerms;
                  }
                  fileConfig
                ];
                dirConfig =
                  { config, ... }:
                  {
                    defaultPerms = mkDefault userDefaultPerms;
                    dirPath = concatPaths [ config.home config.directory ];
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
  };
}
