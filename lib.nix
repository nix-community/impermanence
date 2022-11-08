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
      (s: builtins.typeOf s == "string" && s != "" && s != ".")
      (concatMap (builtins.split "/") paths)
    );

  # Remove duplicate "/" elements, "/./", "foo/..", etc., from a path
  cleanPath = path:
    let
      dummy = builtins.placeholder path;
      prefix = "${dummy}/";
      expanded = toString (/. + "${prefix}${path}");
    in
    if lib.hasPrefix "/" path then
      toString (/. + path)
    else if expanded == dummy then
      "."
    else if lib.hasPrefix prefix expanded then
      removePrefix prefix expanded
    else
      throw "illegal path traversal in `${path}`";

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
in
{
  inherit
    splitPath
    cleanPath
    dirListToPath
    concatPaths
    parentsOf
    sanitizeName
    duplicates
    ;
}
