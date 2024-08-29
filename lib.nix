{ lib }:
let
  inherit (lib)
    filter
    concatMap
    concatStringsSep
    hasPrefix
    head
    replaceStrings
    optionalString
    removePrefix
    foldl'
    elem
    take
    length
    last
    ;
  inherit (lib.strings)
    sanitizeDerivationName
    ;

  # ["/home/user/" "/.screenrc"] -> ["home" "user" ".screenrc"]
  splitPath = paths:
    (filter
      (s: builtins.typeOf s == "string" && s != "")
      (concatMap (builtins.split "/") paths)
    );

  # ["home" "user" ".screenrc"] -> "home/user/.screenrc"
  dirListToPath = dirList: (concatStringsSep "/" dirList);

  # ["/home/user/" "/.screenrc"] -> "/home/user/.screenrc"
  concatPaths = paths:
    let
      prefix = optionalString (hasPrefix "/" (head paths)) "/";
      path = dirListToPath (splitPath paths);
    in
    prefix + path;


  parentsOf = path:
    let
      prefix = optionalString (hasPrefix "/" path) "/";
      split = splitPath [ path ];
      parents = take ((length split) - 1) split;
    in
    foldl'
      (state: item:
        state ++ [
          (concatPaths [
            (if state != [ ] then last state else prefix)
            item
          ])
        ])
      [ ]
      parents;

  sanitizeName = name:
    replaceStrings
      [ "." ] [ "" ]
      (sanitizeDerivationName (removePrefix "/" name));

  duplicates = list:
    let
      result =
        foldl'
          (state: item:
            if elem item state.items then
              {
                items = state.items ++ [ item ];
                duplicates = state.duplicates ++ [ item ];
              }
            else
              state // {
                items = state.items ++ [ item ];
              })
          { items = [ ]; duplicates = [ ]; }
          list;
    in
    result.duplicates;

  getHomeDirCfg = { pkgs, homeDirectory, storage }: dir:
    let
      dirCfg.storage = storage;

      dirCfg.mountDir =
        if dirCfg.storage.removePrefixDirectory then
          dirListToPath (builtins.tail (splitPath [ dir ]))
        else
          dir;


      dirCfg.mountPoint = concatPaths [ homeDirectory dirCfg.mountDir ];
      dirCfg.targetDir = concatPaths [ dirCfg.storage.persistentStoragePath dir ];

      dirCfg.escaped.mountPoint = lib.escapeShellArg dirCfg.mountPoint;
      dirCfg.escaped.targetDir = lib.escapeShellArg dirCfg.targetDir;

      dirCfg.sanitized.targetDir = sanitizeName dirCfg.targetDir;
      dirCfg.sanitized.mountPoint = sanitizeName dirCfg.mountPoint;
      dirCfg.sanitized.mountDir = sanitizeName dirCfg.mountDir;

      dirCfg.unitName = "bindMount--${dirCfg.sanitized.mountDir}";

      dirCfg.runBindfsArgs =
        let
          bindfsOptions =
            lib.lists.optional (!dirCfg.storage.allowOther) "no-allow-other"
            ++ lib.lists.optional (lib.versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${dirCfg.targetDir}"
          ;
        in
        lib.lists.optionals (bindfsOptions != [ ]) [ "-o" (concatStringsSep "," bindfsOptions) ]
      ;
    in
    dirCfg;
in
{
  inherit
    concatPaths
    dirListToPath
    duplicates
    getHomeDirCfg
    parentsOf
    sanitizeName
    splitPath
    ;
}
