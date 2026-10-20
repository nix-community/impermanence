{ pkgs, lib, users }:
directories: files:
let
  inherit (pkgs.callPackage ./lib.nix { }) concatPaths parentsOf;
  defaultPerms = { mode = "0755"; user = "root"; group = "root"; };
  explicitDirs = directories ++ lib.unique (map (entry: entry.parentDirectory) files);
  homeDirs = lib.unique (map
    (dir: {
      directory = dir.home;
      dirPath = dir.home;
      home = null;
      mode = "0700";
      user = dir.user;
      group = users.${dir.user}.group;
      inherit defaultPerms;
      inherit (dir) persistentStoragePath enableDebugging;
    })
    (builtins.filter (dir: dir.home != null) explicitDirs));
  storageDirs = lib.unique (map
    (dir: {
      directory = dir.persistentStoragePath;
      dirPath = dir.persistentStoragePath;
      persistentStoragePath = "";
      home = null;
      inherit (dir) defaultPerms enableDebugging;
      inherit (dir.defaultPerms) user group mode;
    })
    (builtins.filter (dir: dir.home == null) (explicitDirs ++ homeDirs)));
  parentDirs = dirs: lib.unique (lib.concatMap
    (dir: map
      (path: {
        directory = path;
        dirPath = if dir.home != null then concatPaths [ dir.home path ] else path;
        inherit (dir) persistentStoragePath home enableDebugging;
        inherit (dir.defaultPerms) user group mode;
      })
      (parentsOf dir.directory))
    dirs);
  ordered = parentDirs storageDirs ++ storageDirs ++ parentDirs homeDirs
    ++ homeDirs ++ parentDirs explicitDirs ++ explicitDirs;
in
pkgs.writeShellScript "persistence-create-directories" ''
  _status=0
  trap '_status=1' ERR
  export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
  ${lib.concatMapStringsSep "\n" (dir:
    "${lib.getExe pkgs.bash} ${./create-directories.bash} " + lib.escapeShellArgs [
      dir.persistentStoragePath dir.dirPath dir.user
      (if dir.group == null then users.${dir.user}.group else dir.group)
      dir.mode dir.enableDebugging
    ]
  ) ordered}
  exit "$_status"
''
