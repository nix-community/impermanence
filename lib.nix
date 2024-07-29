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
    escapeShellArg
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

  # "/home/user/.screenrc" -> ["/home", "/home/user"]
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

  # ["a", "b", "a"] -> ["a"]
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

  mkMountPath = root: child: escapeShellArg (concatPaths [ root child ]);

  mkServiceName = root: child: "bindMount-${sanitizeName (mkMountPath root child)}";
in
{
  inherit
    splitPath
    dirListToPath
    concatPaths
    parentsOf
    sanitizeName
    duplicates
    mkMountPath
    mkServiceName
    ;
}
