{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.environment.persistence;
  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths;
in
{
  options = {

    environment.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule {
          options =
            {
              files = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = ''
                  Files in /etc that should be stored in persistent storage.
                '';
              };

              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = ''
                  Directories to bind mount to persistent storage.
                '';
              };
            };
        }
      );
    };

  };

  config = {
    environment.etc =
      let
        link = file:
          pkgs.runCommand
            "${replaceStrings [ "/" "." " " ] [ "-" "" "" ] file}"
            { }
            "ln -s '${file}' $out";

        # Create environment.etc link entry.
        mkLinkNameValuePair = persistentStoragePath: file: {
          name = removePrefix "/etc/" file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        # Create all environment.etc link entries for a specific
        # persistent storage path.
        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            cfg.${persistentStoragePath}.files
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    fileSystems =
      let
        # Create fileSystems bind mount entry.
        mkBindMountNameValuePair = persistentStoragePath: dir: {
          name = concatPaths [ "/" dir ];
          value = {
            device = concatPaths [ persistentStoragePath dir ];
            noCheck = true;
            options = [ "bind" ];
          };
        };

        # Create all fileSystems bind mount entries for a specific
        # persistent storage path.
        mkBindMountsForPath = persistentStoragePath:
          listToAttrs (map
            (mkBindMountNameValuePair persistentStoragePath)
            cfg.${persistentStoragePath}.directories
          );
      in
      foldl' recursiveUpdate { } (map mkBindMountsForPath persistentStoragePaths);

    system.activationScripts =
      let
        # Script to create a directory in persistent storage, so we can bind
        # mount it. The directory structure's mode and ownership mirror those of
        # persistentStoragePath/dir;
        # TODO: Move this script to it's own file, add CI with shfmt/shellcheck.
        createDirectories = pkgs.writeShellScript "impermanence-create-directories"
          ''
            # Given a source directory, /source, and a target directory,
            # /target/foo/bar/bazz, we want to "clone" the target structure
            # from source into the target. Essentially, we want both
            # /source/target/foo/bar/bazz and /target/foo/bar/bazz to exist
            # on the filesystem. More concretely, we'd like to map
            # /state/etc/ssh/example.key to /etc/ssh/example.key
            #
            # To achieve this, we split the target's path into parts -- target, foo,
            # bar, bazz -- and iterate over them while accumulating the path
            # (/target/, /target/foo/, /target/foo/bar, and so on); then, for each of
            # these increasingly qualified paths we:
            #
            #   1. Ensure both /source/qualifiedPath and qualifiedPath exist
            #   2. Copy the ownership of the source path into the target path
            #   3. Copy the mode of the source path into the target path

            # Get inputs from command line arguments
            sourceBase="$1"
            target="$2"

            # trim trailing slashes the root of all evil
            sourceBase="''${sourceBase%/}"
            target="''${target%/}"

            # check that the source exists, if it doesn't exit the underlying
            # scope (the activation script will continue)
            realSource="$(realpath "$sourceBase$target")"
            if [ ! -d "$realSource" ]; then
                printf "\e[1;31mBind source '%s' does not exist; it will be created for you.\e[0m\n" "$realSource"
            fi

            # iterate over each part of the target path, e.g. var, lib, iwd
            previousPath="/"
            for pathPart in $(echo "$target" | tr "/" " "); do
              # construct the incremental path, e.g. /var, /var/lib, /var/lib/iwd
              currentTargetPath="$previousPath$pathPart/"

              # construct the source path, e.g. /state/var, /state/var/lib, ...
              currentSourcePath="$sourceBase$currentTargetPath"

              # create the source and target directories if they don't exist
              [ -d "$currentSourcePath" ] || mkdir "$currentSourcePath"
              [ -d "$currentTargetPath" ] || mkdir "$currentTargetPath"

              # resolve the source path to avoid symlinks
              currentRealSourcePath="$(realpath "$currentSourcePath")"

              # synchronize perms between source and target
              chown --reference="$currentRealSourcePath" "$currentTargetPath"
              chmod --reference="$currentRealSourcePath" "$currentTargetPath"

              # lastly we update the previousPath to continue down the tree
              previousPath="$currentTargetPath"
            done
          '';

        mkDirWithPerms = persistentStoragePath: dir: ''
          ${createDirectories} "${persistentStoragePath}" "${dir}"
        '';

        # Build an activation script which creates all persistent
        # storage directories we want to bind mount.
        mkDirCreationScriptForPath = persistentStoragePath:
          nameValuePair
            "createDirsIn-${replaceStrings [ "/" "." " " ] [ "-" "" "" ] persistentStoragePath}"
            (noDepEntry (concatMapStrings
              (mkDirWithPerms persistentStoragePath)
              cfg.${persistentStoragePath}.directories
            ));
      in
      listToAttrs (map mkDirCreationScriptForPath persistentStoragePaths);

    assertions =
      let
        files = concatMap (p: p.files or [ ]) (attrValues cfg);
        markedNeededForBoot = cond: fs:
          if config.fileSystems ? ${fs} then
            (config.fileSystems.${fs}.neededForBoot == cond)
          else
            cond;
      in
      [
        {
          # Assert that files are put in /etc, a current limitation,
          # since we're using environment.etc.
          assertion = all (hasPrefix "/etc") files;
          message =
            let
              offenders = filter (file: !(hasPrefix "/etc" file)) files;
            in
            ''
              environment.persistence.files:
                  Currently, only files in /etc are supported.

                  Please fix or remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
        {
          # Assert that all persistent storage volumes we use are
          # marked with neededForBoot.
          assertion = all (markedNeededForBoot true) persistentStoragePaths;
          message =
            let
              offenders = filter (markedNeededForBoot false) persistentStoragePaths;
            in
            ''
              environment.persistence:
                  All filesystems used for persistent storage must
                  have the flag neededForBoot set to true.

                  Please fix or remove the following paths:
                    ${concatStringsSep "\n      " offenders}
            '';
        }
      ];
  };

}
