{ lib }:
let
  inherit (lib) filter concatMap concatStringsSep hasPrefix head
    replaceStrings removePrefix foldl' elem toposort genAttrs
    zipAttrsWith flatten attrValues unique;
  inherit (lib.strings) sanitizeDerivationName;
  inherit (lib.types) coercedTo nonEmptyStr;

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

          # `b` depends on `a` if:
          #
          #     1a. `a.source` and `b.source` are identical
          #
          #       *OR*
          #
          #     1b. `a.destination` and `b.destination` are identical
          #
          #   *AND*
          #
          #     2a. `a.implicit` is false and `b.implicit` is true,
          #
          #       *OR*
          #
          #     2b. `a.implicit` and `b.implicit` are identical, and `a` and
          #         `b` specify different permissions.
          #
          # Condition 2a makes sure we prefer user, group, and mode settings
          # from explicitly-specified directories over those from
          # implicitly-specified directories (that is, parent directories of
          # explicitly-specified files).
          #
          # Condition 2b models inconsistent permissions settings as cycles in
          # the directory dependency graph.
          givenIdentical =
            let
              identical = a: b: (a.source == b.source) || (a.destination == b.destination);
              differentPerms = a: b: a.mode != b.mode || a.user != b.user || a.group != b.group;
            in
            a: b:
              (identical a b) && ((!a.implicit && b.implicit) || ((a.implicit == b.implicit) && differentPerms a b));
        in
        a: b:
          strictPrefixOfSource a b
          || strictPrefixOfDestination a b
          || givenIdentical a b;
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

  extractPersistentStoragePaths = cfg: { directories = [ ]; files = [ ]; users = [ ]; }
    // (zipAttrsWith (_name: flatten) (attrValues cfg));
in
{
  inherit splitPath cleanPath dirListToPath concatPaths sanitizeName duplicates
    coercedToDir coercedToFile toposortDirs extractPersistentStoragePaths
    recursivePersistentPaths;
}
