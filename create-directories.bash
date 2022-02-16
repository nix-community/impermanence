#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
set -o noglob             # Disable filename expansion (globbing),
                          # since it could otherwise happen during
                          # path splitting.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
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
if [[ "$#" != 5 ]]; then
    printf "Error: 'create-directories.bash' requires *five* args.\n" >&2
    exit 1
fi
sourceBase="$1"
target="$2"
user="$3"
group="$4"
mode="$5"

# trim trailing slashes the root of all evil
sourceBase="${sourceBase%/}"
target="${target%/}"

# check that the source exists and warn the user if it doesn't
realSource="$(realpath -m "$sourceBase$target")"
if [[ ! -d "$realSource" ]]; then
    printf "Warning: Source directory '%s' does not exist; it will be created for you with the following permissions: owner: '%s:%s', mode: '%s'.\n" "$realSource" "$user" "$group" "$mode"
fi

# iterate over each part of the target path, e.g. var, lib, iwd
previousPath="/"

OLD_IFS=$IFS
IFS=/ # split the path on /
for pathPart in $target; do
    IFS=$OLD_IFS

    # skip empty parts caused by the prefix slash and multiple
    # consecutive slashes
    [[ $pathPart == "" ]] && continue

    # construct the incremental path, e.g. /var, /var/lib, /var/lib/iwd
    currentTargetPath="$previousPath$pathPart/"

    # construct the source path, e.g. /state/var, /state/var/lib, ...
    currentSourcePath="$sourceBase$currentTargetPath"

    # create the source and target directories if they don't exist
    if [[ ! -d "$currentSourcePath" ]]; then
        mkdir --mode="$mode" "$currentSourcePath"
        chown "$user:$group" "$currentSourcePath"
    fi
    [[ -d "$currentTargetPath" ]] || mkdir "$currentTargetPath"

    # resolve the source path to avoid symlinks
    currentRealSourcePath="$(realpath -m "$currentSourcePath")"

    # synchronize perms between source and target
    chown --reference="$currentRealSourcePath" "$currentTargetPath"
    chmod --reference="$currentRealSourcePath" "$currentTargetPath"

    # lastly we update the previousPath to continue down the tree
    previousPath="$currentTargetPath"
done
