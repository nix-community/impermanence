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
if [[ "$#" != 6 ]]; then
    printf "Error: 'create-directories.bash' requires *six* args.\n" >&2
    exit 1
fi
sourceBase="$1"
target="$2"
user="$3"
group="$4"
mode="$5"
debug="$6"

if (( "$debug" )); then
    set -o xtrace
fi

# check that the source exists and warn the user if it doesn't, then
# create them with the specified permissions
realSource="$(realpath -m "$sourceBase$target")"
if [[ ! -d "$realSource" ]]; then
    printf "Warning: Source directory '%s' does not exist; it will be created for you with the following permissions: owner: '%s:%s', mode: '%s'.\n" "$realSource" "$user" "$group" "$mode"
    mkdir "$realSource"
fi

[[ -d "$target" ]] || mkdir "$target"

chown "$user:$group" "$realSource" "$target"
chmod "$mode" "$realSource" "$target"
