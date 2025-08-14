{ lib }:
let
  inherit (lib)
    filter
    concatStringsSep
    hasPrefix
    replaceStrings
    optionalString
    removePrefix
    foldl'
    elem
    take
    length
    last
    toposort
    genAttrs
    zipAttrsWith
    flatten
    attrValues
    unique
    concatMap
    all
    hasAttr
    toList
    listToAttrs
    nameValuePair
    getAttr
    flip
    pipe
    ;
  inherit (lib.strings)
    sanitizeDerivationName
    ;
  inherit (lib.types)
    coercedTo
    nonEmptyStr
    addCheck
    listOf
    attrsOf
    either
    ;

  # ["/home/user/" "/.screenrc"] -> ["home" "user" ".screenrc"]
  splitPath = paths:
    filter builtins.isString (builtins.split "/" (concatPaths paths));

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
  # ["/home/user/" "/.screenrc"] -> "/home/user/.screenrc"
  dirListToPath = dirList: cleanPath (concatStringsSep "/" dirList);

  # Alias of dirListToPath
  concatPaths = dirListToPath;


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

  parentsUntil = parent:
    let
      isAncestorOf' = isAncestorOf parent;
    in
    path:
    if isAncestorOf' path
    then (filter isAncestorOf' (parentsOf path)) ++ [ parent ]
    else throw "path '${toString path}' is not a child of ${toString parent}";

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

  coercedToDir = coercedTo nonEmptyStr (directory: { inherit directory; });
  coercedToFile = coercedTo nonEmptyStr (file: { inherit file; });

  checkedListOf = type: addCheck (listOf type) (all type.check);
  attrsOfWith = type: names: addCheck (attrsOf type) (x: all (flip hasAttr x) (toList names));

  maybeNamed = type: name:
    let
      convertItem = item:
        if builtins.isAttrs item
        then nameValuePair item.${name} item
        else nameValuePair item { ${name} = item; };
    in
    coercedTo (checkedListOf type) (list: listToAttrs (map convertItem list));
  maybeNamedDir = maybeNamed (either nonEmptyStr (attrsOfWith nonEmptyStr "directory")) "directory";
  maybeNamedFile = maybeNamed (either nonEmptyStr (attrsOfWith nonEmptyStr "file")) "file";

  # Append a trailing slash to a path if it does not already have one.
  #
  # Motivated by `normalisePath`, a helper function used by `fsBefore` from
  # `<nixpkgs>/lib/utils.nix` to normalize the representation of paths when
  # toplogically sorting `config.fileSystems`.
  #
  # The comment to `normalisePath` reads:
  #
  #   normalisePath adds a slash at the end of the path if it didn't already
  #   have one.
  #
  #   The reason slashes are added at the end of each path is to prevent `b`
  #   from accidentally depending on `a` in cases like
  #      a = { mountPoint = "/aaa"; ... }
  #      b = { device     = "/aaaa"; ... }
  #   Here a.mountPoint *is* a prefix of b.device even though a.mountPoint is
  #   *not* a parent of b.device. If we add a slash at the end of each string,
  #   though, this is not a problem: "/aaa/" is not a prefix of "/aaaa/".
  #
  # See https://github.com/NixOS/nixpkgs/blob/944270bc35c2558ecd1c0fd078e4cfc2e538da56/nixos/lib/utils.nix#L19-L28
  normalizePath = path: "${cleanPath path}/";

  normalizeDir = dir: dir // {
    normalized = genAttrs [ "source" "destination" "persistentStoragePath" ] (key: normalizePath dir.${key});
  };

  normalizeDirs = map normalizeDir;

  strictPrefix = a: b: (hasPrefix a b) && (a != b);

  isAncestorOf = parent: path: strictPrefix (normalizePath parent) (normalizePath path);

  # Topologically sort the directories we need to create, chown, chmod, etc.
  toposortDirs =
    let
      dirBefore =
        let
          # `b` depends on `a` if `a.source` is a strict prefix of `b.source`;
          # for instance, `a.source` is "/foo/bar" and `b.source` is
          # "/foo/bar/bazz".  This is because, if `b.source` does not exist
          # yet, we want to first ensure that `a.source` exists and has the
          # proper permissions set.
          strictPrefixOfSource = a: b: strictPrefix a.normalized.source b.normalized.source;

          # Similarly, `b` depends on `a` if `a.destination` is a strict prefix
          # of `b.destination`.
          strictPrefixOfDestination = a: b: strictPrefix a.normalized.destination b.normalized.destination;

          siblingBefore =
            let
              isSibling = p: q: (builtins.dirOf p) == (builtins.dirOf q);
            in
            a: b:
              (isSibling a.normalized.source b.normalized.source && a.normalized.source < b.normalized.source)
              ||
              (isSibling a.normalized.destination b.normalized.destination && a.normalized.destination < b.normalized.destination);
        in
        a: b:
          strictPrefixOfSource a b
          || strictPrefixOfDestination a b
          || siblingBefore a b;
    in
    dirs: toposort dirBefore (normalizeDirs dirs);

  recursivePersistentPaths =
    let
      pointsIntoPersistentStoragePath = a: b: strictPrefix b.normalized.persistentStoragePath a.normalized.destination;
      findMatches = dir: dirs: unique (map (match: match.persistentStoragePath) (filter (pointsIntoPersistentStoragePath dir) dirs));
      mapMatches = dir: dirs: map (match: { inherit (dir) destination source; persistentStoragePath = match; }) (findMatches dir dirs);
    in
    dirs:
    let
      normalized = normalizeDirs dirs;
    in
    concatMap (dir: mapMatches dir normalized) normalized;

  extractPersistentStoragePaths = flip pipe [
    attrValues
    (filter (getAttr "enable"))
    (zipAttrsWith (name: values:
      let
        flattened = flatten values;
      in
      if elem name [ "directories" "hierarchy" "files" ] then concatMap attrValues flattened else flattened))
  ];
in
{
  inherit
    splitPath
    cleanPath
    dirListToPath
    concatPaths
    parentsOf
    parentsUntil
    sanitizeName
    duplicates
    coercedToDir
    coercedToFile
    toposortDirs
    extractPersistentStoragePaths
    recursivePersistentPaths
    maybeNamedDir
    maybeNamedFile
    ;
}
