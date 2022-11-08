{ modules ? [ ], nixpkgs, system, ... }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  inherit (nixpkgs.lib) any escapeShellArg nixosSystem runTests;

  inherit (pkgs.callPackage ../lib.nix { }) cleanPath splitPath;

  mkSystem = config: nixosSystem {
    inherit system;
    modules = modules ++ [
      ({ config, ... }: {
        # Slim down the config.
        boot.isContainer = true;

        # Silence unset `stateVersion` warning by pegging it to the current
        # release.
        system.stateVersion = config.system.nixos.release;
      })

      config
    ];
  };

  search = pattern: str: (builtins.match ".*${pattern}.*" str) != null;

  assertionsMatch = pattern: any (assertion: !assertion.assertion && search pattern assertion.message);

  checkAssertionsMatch = pattern: config: {
    expected = true;
    expr = assertionsMatch pattern (mkSystem config).config.assertions;
  };

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

    testNoPathTraversalAllowed = checkEvalError (cleanPath "../foo/bar");

    testCleanPath = {
      expected = "bar";
      expr = cleanPath "foo/../bar";
    };

    testSplitPath = {
      expected = [ "foo" "bar" "bazz" ];
      expr = splitPath [ "././foo/." "/bar/bazz/./" ];
    };
  };
in
# Abort if `tests`(list containing failed tests) is not empty
pkgs.runCommandNoCC "impermanence-module-tests" { } ''
  ${pkgs.jq}/bin/jq 'if . == [] then . else halt_error(1) end' > "$out" <<<${escapeShellArg (builtins.toJSON tests)}
''
