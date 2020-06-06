{ pkgs, config, lib, ... }:
let
  cfg = config.environment.impermanence;

  persistentStoragePaths = lib.attrNames cfg;
in
{
  options.environment.impermanence = lib.mkOption {
    default = { };
    type = with lib.types; attrsOf (
      submodule {
        options = {
          files = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Files to bind mount to persistent storage.";
          };

          directories = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Directories to bind mount to persistent storage.";
          };
        };
      }
    );
  };

  config = {
    fileSystems =
      let
        # Function to create fileSystem bind mount entries
        mkBindMountNameValuePair = persistentStoragePath: path: {
          name = "${path}";
          value = {
            device = "${persistentStoragePath}${path}";
            options = [ "bind" ];
          };
        };

        # Function to build the bind mounts for files and directories
        mkBindMounts = persistentStoragePath:
          lib.listToAttrs (map
            (mkBindMountNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files ++
              cfg.${persistentStoragePath}.directories)
          );
      in
      lib.foldl' lib.recursiveUpdate { } (map mkBindMounts persistentStoragePaths);

    system.activationScripts =
      let
        # Function to create a directory in both the place where we want
        # to bind mount it as well as making sure it exists in the location
        # where persistence is located.
        mkDirCreationSnippet = persistentStoragePath: dir:
          ''
            mkdir -p "${dir}" "${persistentStoragePath}${dir}"
          '';

        # Function to create a file in both the place where we want to bind
        # mount it as well as making sure it exists in the location where
        # persistence is located.
        mkFileCreationSnippet = persistentStoragePath: file:
          let
            targetFile = "${persistentStoragePath}${file}";
          in
          ''
            mkdir -p $(dirname "${file}") $(dirname "${targetFile}") &&
              touch "${file}" "${targetFile}"
          '';

        # Function to build the activation script string for creating files
        # and directories as part of the activation script.
        mkFileActivationScripts = persistentStoragePath:
          lib.nameValuePair
            "createFilesAndDirsIn-${lib.replaceStrings [ "/" "." " " ] [ "-" "-" "-" ] persistentStoragePath}"
            (lib.noDepEntry (lib.concatStrings [
              # Create activation scripts for files
              (lib.concatMapStrings
                (mkFileCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.files
              )

              # Create activation scripts for directories
              (lib.concatMapStrings
                (mkDirCreationSnippet persistentStoragePath)
                cfg.${persistentStoragePath}.directories
              )
            ]));

      in
      lib.listToAttrs (map mkFileActivationScripts persistentStoragePaths);

    # Assert that all filesystems that we used are marked with neededForBoot.
    assertions =
      let
        assertTest = cond: fs: (config.fileSystems.${fs}.neededForBoot == cond);
      in
      [{
        assertion = lib.all (assertTest true) persistentStoragePaths;
        message =
          let
            offenders = lib.filter (assertTest false) persistentStoragePaths;
          in
          ''
            environment.impermanence:
              All filesystems used to back must have the flag neededForBoot
              set to true.

            Please fix / remove the following paths:
              ${lib.concatStringsSep "\n      " offenders}
          '';
      }];
  };
}
