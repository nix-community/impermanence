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

# Given a source base directory, a source suffix, and a target directory, this
# script ensures the target exists and that its ownership and mode match the
# resolved source directory.

# Get inputs from command line arguments
if [[ $# != 7 ]]; then
    printf "Error: 'create-directories.bash' requires *seven* args.\n" >&2
    exit 1
fi
sourceBase="$1"
sourceSuffix="$2"
target="$3"
user="$4"
group="$5"
mode="$6"
debug="$7"

if (( debug )); then
    set -o xtrace
fi

# check that the source exists and warn the user if it doesn't, then
# create them with the specified permissions
realSource="$(realpath -m "$sourceBase$sourceSuffix")"
if [[ ! -d $realSource ]]; then
    printf "Warning: Source directory '%s' does not exist; it will be created for you with the following permissions: owner: '%s:%s', mode: '%s'.\n" "$realSource" "$user" "$group" "$mode"
    mkdir --mode="$mode" "$realSource"
    chown "$user:$group" "$realSource"
fi

if [[ $sourceBase ]]; then
    [[ -d $target ]] || mkdir "$target"

    # synchronize perms between source and target
    chown --reference="$realSource" "$target"
    chmod --reference="$realSource" "$target"
fi
