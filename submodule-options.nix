{ pkgs
, lib
, name
, config
, usersOpts ? false  # Are the options used as users.<username> submodule options?
, user               # Default user name
, group              # Default user group
}:
let
  inherit (lib)
    mkOption
    mkDefault
    mkIf
    mapAttrsToList
    types
    mapAttrs
    optionalAttrs
    ;

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    ;

  inherit (types)
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
    inherit user group;
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
  file = submodule [
    commonOpts
    fileOpts
    (mkIf usersOpts { inherit (config) home; })
    {
      parentDirectory = mkDefault defaultPerms;
    }
    ({ config, ... }:
      let
        home = if config.home != null then config.home else "/";
        directory = dirOf config.file;
      in
      {
        parentDirectory = {
          dirPath = concatPaths [ home directory ];
          inherit directory defaultPerms home;
          inherit (config) persistentStoragePath;
        };
        filePath = concatPaths [ home config.file ];
      })
  ];
  dir = submodule ([
    commonOpts
    dirOpts
    (mkIf usersOpts { inherit (config) home; })
    ({ config, ... }:
      let
        home = if config.home != null then config.home else "/";
      in
      {
        defaultPerms = mkDefault defaultPerms;
        dirPath = concatPaths [ home config.directory ];
      })
  ] ++ (mapAttrsToList (n: v: { ${n} = mkDefault v; }) defaultPerms));

in
{
  options =
    {
      files = mkOption {
        type = listOf (coercedTo str (f: { file = f; }) file);
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
        type = listOf (coercedTo str (d: { directory = d; }) dir);
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
    } //
    optionalAttrs (!usersOpts)
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
      } //
    optionalAttrs usersOpts {
      # Needed because defining fileSystems
      # based on values from users.users
      # results in infinite recursion.
      home = mkOption {
        type = path;
        default = "/home/${user}";
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
    };
}
