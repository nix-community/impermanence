#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
set -o errtrace

trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

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
#   1. Ensure both /source/qualifiedPath and qualifiedPath exist
#   2. Copy the ownership of the source path to the target path
#   3. Copy the mode of the source path to the target path

# Get inputs from command line arguments
if [[ "$#" != 2 ]]; then
    printf "Error: 'create-directories.bash' requires *two* args.\n" >&2
    exit 1
fi
sourceBase="$1"
target="$2"

# trim trailing slashes the root of all evil
sourceBase="${sourceBase%/}"
target="${target%/}"

# check that the source exists and warn the user if it doesn't
realSource="$(realpath "$sourceBase$target")"
if [[ ! -d "$realSource" ]]; then
    printf "Warning: Source directory '%s' does not exist; it will be created for you. Make sure the permissions are correct!\n" "$realSource"
fi

# iterate over each part of the target path, e.g. var, lib, iwd
previousPath="/"
for pathPart in $(echo "$target" | tr "/" " "); do
    # construct the incremental path, e.g. /var, /var/lib, /var/lib/iwd
    currentTargetPath="$previousPath$pathPart/"

    # construct the source path, e.g. /state/var, /state/var/lib, ...
    currentSourcePath="$sourceBase$currentTargetPath"

    # create the source and target directories if they don't exist
    [[ -d "$currentSourcePath" ]] || mkdir "$currentSourcePath"
    [[ -d "$currentTargetPath" ]] || mkdir "$currentTargetPath"

    # resolve the source path to avoid symlinks
    currentRealSourcePath="$(realpath "$currentSourcePath")"

    # synchronize perms between source and target
    chown --reference="$currentRealSourcePath" "$currentTargetPath"
    chmod --reference="$currentRealSourcePath" "$currentTargetPath"

    # lastly we update the previousPath to continue down the tree
    previousPath="$currentTargetPath"
done
