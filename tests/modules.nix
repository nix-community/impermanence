{ modules ? [ ], nixpkgs, system, ... }:

let
  pkgs = nixpkgs.legacyPackages.${system};

  inherit (nixpkgs.lib) any escapeShellArg nixosSystem runTests;

  mkSystem = config: nixosSystem {
    inherit system;
    modules = modules ++ [
      # slim down the config
      { boot.isContainer = true; }
      config
    ];
  };

  search = pattern: str: (builtins.match ".*${pattern}.*" str) != null;

  assertionsMatch = pattern: any (assertion: !assertion.assertion && search pattern assertion.message);

  checkAssertionsMatch = pattern: config: {
    expected = true;
    expr = assertionsMatch pattern (mkSystem config).config.assertions;
  };

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
  };
in
# Abort if `tests`(list containing failed tests) is not empty
pkgs.runCommandNoCC "impermanence-module-tests" { } ''
  ${pkgs.jq}/bin/jq 'if . == [] then . else halt_error(1) end' > "$out" <<<${escapeShellArg (builtins.toJSON tests)}
''
