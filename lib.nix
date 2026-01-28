{ lib }:
let
  inherit (lib)
    filter
    concatMap
    concatStringsSep
    hasPrefix
    head
    optionalString
    foldl'
    elem
    take
    length
    last
    ;

  # ["/home/user/" "/.screenrc"] -> ["home" "user" ".screenrc"]
  splitPath = paths:
    (filter
      (s: builtins.typeOf s == "string" && s != "")
      (concatMap (builtins.split "/") paths)
    );

  # `home.username` -> id in `users.users.<id>`
  usernameToUserModuleId = config: username:
    let
      potential_user = lib.filter (set: set.value.name == username) (lib.attrsToList config.users.users);
      modname = lib.throwIf (builtins.length potential_user == 0) ''
        home.persistence (home-manager impermanence):
            The user with username '${username}' is not defined in `users.users`.
            This causes the home-manager impermanence module to be unable to automatically obtain group names for folder permissions!
      ''
        (lib.throwIf (builtins.length potential_user > 1) ''
          home.persistence (home-manager impermanence):
              Multiple users in the system wide `users.users` have the same username ('${username}').
              This might cause further problems with the system.
              In any case causes the home-manager impermanence module to be unable to automatically obtain group names for folder permissions!
        ''
          (lib.head potential_user).name);
    in
    modname;

  # id in `users.users.<id>` -> `users.groups.<group-of-user-with-id>`.name
  moduleUserToGroupName = config: user: config.users.groups.${config.users.users.${user}.group}.name;

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
    dirListToPath
    concatPaths
    parentsOf
    duplicates
    usernameToUserModuleId
    moduleUserToGroupName
    ;
}
