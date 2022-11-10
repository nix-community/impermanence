{ lib }:
let
  inherit (lib) filter concatMap concatStringsSep hasPrefix head
    replaceStrings removePrefix foldl' elem toposort genAttrs
    zipAttrsWith flatten attrValues;
  inherit (lib.strings) sanitizeDerivationName;
  inherit (lib.types) coercedTo str;

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

  coercedToDir = coercedTo str (directory: { inherit directory; });
  coercedToFile = coercedTo str (file: { inherit file; });

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
        in
        a: b:
          strictPrefixOfSource a b
          || strictPrefixOfDestination a b;
    in
    dirs: toposort dirBefore (normalizeDirs dirs);

  extractPersistentStoragePaths = cfg: { directories = [ ]; files = [ ]; users = [ ]; }
    // (zipAttrsWith (_name: flatten) (attrValues cfg));
in
{
  inherit splitPath cleanPath dirListToPath concatPaths sanitizeName duplicates
    coercedToDir coercedToFile toposortDirs extractPersistentStoragePaths;
}
