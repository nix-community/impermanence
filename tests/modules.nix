{ modules ? [ ], nixpkgs, system, ... }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  inherit (nixpkgs.lib) any escapeShellArg nixosSystem runTests toList;

  inherit (pkgs.callPackage ../lib.nix { }) cleanPath splitPath dirListToPath
    concatPaths extractPersistentStoragePaths toposortDirs;

  mkSystem = config: nixosSystem {
    inherit system;
    modules = modules ++ [
      # slim down the config
      { boot.isContainer = true; }
      config
    ];
  };

  search = pattern: str: (builtins.match ".*${pattern}.*" str) != null;

  assertionsMatch = patterns: assertions:
    let
      failed = builtins.filter (assertion: !assertion.assertion) assertions;
      matchAnyPattern = assertion: any (pattern: search pattern assertion.message) (toList patterns);
    in
    any matchAnyPattern failed;

  checkAssertions = expected: patterns: config: {
    inherit expected;
    expr = assertionsMatch patterns (mkSystem config).config.assertions;
  };

  checkAssertionsMatch = checkAssertions true;
  checkAssertionsDoNotMatch = checkAssertions false;

  checkEval = expected: thing:
    let
      result = builtins.tryEval thing;
    in
    {
      inherit expected;
      expr = result.success;
    };

  checkEvalError = checkEval false;

  duplicateDirPattern = "The following directories were specified two or more[^a-z]*times";
  duplicateFilePattern = "The following files were specified two or more[^a-z]*times";
  toposortErrorPattern = "Unable to topologically sort persistent storage source and destination directories";

  # XXX remember that `runTests` only runs test cases when they are associated
  # with an attribute name that starts with `test`!
  tests = runTests {
    testDuplicateRootDirectories = checkAssertionsMatch duplicateDirPattern {
      environment.persistence = {
        "/abc".directories = [ "/same" ];
        "/def".directories = [ "/same" ];
      };
    };

    testDuplicateRootFiles = checkAssertionsMatch duplicateFilePattern {
      environment.persistence = {
        "/abc".files = [ "/same/file" ];
        "/def".files = [ "/same/file" ];
      };
    };

    testDuplicateUserDirectories = checkAssertionsMatch duplicateDirPattern {
      users.users.auser.isNormalUser = true;
      environment.persistence = {
        "/abc".users.auser.directories = [ "/same" ];
        "/def".users.auser.directories = [ "/same" ];
      };
    };

    testDuplicateUserFiles = checkAssertionsMatch duplicateFilePattern {
      users.users.auser.isNormalUser = true;
      environment.persistence = {
        "/abc".users.auser.files = [ "/same/file" ];
        "/def".users.auser.files = [ "/same/file" ];
      };
    };

    testNoSpuriousDuplicateDetection =
      let
        patterns = [
          duplicateFilePattern
          toposortErrorPattern
        ];
      in
      checkAssertionsDoNotMatch patterns {
        environment.persistence."/abc".directories = [
          { directory = "foo"; mode = "0755"; }
          { directory = "foo"; mode = "0755"; root = "/elsewhere"; }
        ];
      };

    testMissingNeededForBoot = checkAssertionsMatch "All filesystems used for persistent storage must[^a-z]*have the flag neededForBoot" {
      fileSystems."/abc" = { fsType = "tmpfs"; neededForBoot = false; };
      environment.persistence."/abc".directories = [ "/hello" ];
    };

    testHomeMismatch = checkAssertionsMatch "Users and home doesn't match" {
      users.users.auser = { isNormalUser = true; home = "/althome/auser"; };
      environment.persistence = {
        "/abc".users.auser.files = [ "/a/file" ];
      };
    };

    testRecursivePersistentPaths = checkAssertionsMatch "Recursive persistent storage paths are not supported" {
      environment.persistence."/abc".directories = [ "/abc/def" ];
    };

    testNoSpuriousSourcePrefixDetection =
      let
        result = mkSystem {
          environment.persistence = {
            "/1".directories = [ "/abc/def/ghi" ];
            "/12".directories = [ "/abc/def" ];
            "/123".directories = [ "/abc" ];
          };
        };

        paths = extractPersistentStoragePaths result.config.environment.persistence;

        sortedDirs = toposortDirs paths.directories;
      in
      {
        expected = [ "/123" "/12" "/1" ];
        expr = map (dir: dir.persistentStoragePath) sortedDirs.result;
      };

    testNoSpuriousDestinationPrefixDetection =
      let
        result = mkSystem {
          environment.persistence = {
            "/abc/def/ghi".directories = [ "/1" ];
            "/abc/def".directories = [ "/12" ];
            "/abc".directories = [ "/123" ];
          };
        };

        paths = extractPersistentStoragePaths result.config.environment.persistence;

        sortedDirs = toposortDirs paths.directories;
      in
      {
        expected = [ "/abc" "/abc/def" "/abc/def/ghi" ];
        expr = map (dir: dir.persistentStoragePath) sortedDirs.result;
      };

    testInconsistentParentDirectoryPermissions = checkAssertionsMatch toposortErrorPattern {
      environment.persistence = {
        "/abc".files = [
          { file = "foo/bar"; parentDirectory = { mode = "0755"; }; }
        ];

        "/def".files = [
          { file = "foo/lsgold"; parentDirectory = { mode = "2700"; }; }
        ];
      };
    };

    testInconsistentDirectoryPermissions = checkAssertionsMatch toposortErrorPattern {
      environment.persistence."/abc".directories = [
        { directory = "foo"; mode = "0755"; }
        { directory = "foo"; mode = "0700"; root = "/elsewhere"; }
      ];
    };

    testNoPathTraversalAllowed = checkEvalError (cleanPath "../foo/bar");

    testCleanPath = {
      expected = "bar";
      expr = cleanPath "foo/../bar";
    };

    testSplitPath = {
      expected = [ "foo" "bar" "bazz" ];
      expr = splitPath [ "././foo/." "/bar/bazz/./" ];
    };

    testDirListToPath = {
      expected = [
        "foo/bar"
        "home/user/.screenrc"
        "/home/user/.screenrc"
      ];

      expr = map dirListToPath [
        [ "foo/./" "./bar/bazz/.." "/quux" ".." ]
        [ "home" "user" ".screenrc" ]
        [ "/home/user" "/.screenrc" ]
      ];
    };

    testConcatPaths = {
      expected = [
        "foo/bar"
        "home/user/.screenrc"
        "/home/user/.screenrc"
      ];
      expr = map concatPaths [
        [ "foo/./" "./bar/bazz/.." "/quux" ".." ]
        [ "home" "user" ".screenrc" ]
        [ "/home/user" "/.screenrc" ]
      ];
    };
  };
in
# Abort if `tests`(list containing failed tests) is not empty
pkgs.runCommandNoCC "impermanence-module-tests" { } ''
  ${pkgs.jq}/bin/jq 'if . == [] then . else halt_error(1) end' > "$out" <<<${escapeShellArg (builtins.toJSON tests)}
''
