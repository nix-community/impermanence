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
# Arguments: sourceBase target user group mode debug [uid gid]
# uid and gid are optional numeric IDs (required for initrd where usernames don't resolve)
if [[ $# -lt 6 ]]; then
    printf "Error: 'create-directories.bash' requires at least six args.\n" >&2
    exit 1
fi
sourceBase="$1"
target="$2"
user="$3"
group="$4"
mode="$5"
debug="$6"
uid="${7:-}"
gid="${8:-}"

if (( debug )); then
    set -o xtrace
fi

# Check if user exists (may not in initrd environment)
# Returns 0 if user exists, 1 otherwise
user_exists() {
    id "$1" >/dev/null 2>&1
}

# Set ownership using either numeric UID/GID or username/group
# In initrd, usernames don't resolve, so numeric IDs are required
set_ownership() {
    local dir="$1"
    local owner
    if [[ -n "$uid" && -n "$gid" ]] && ! user_exists "$user"; then
        # In initrd or if user doesn't exist, use numeric IDs
        owner="${uid}:${gid}"
    else
        # In main system with user database, use username/group
        owner="${user}:${group}"
    fi
    chown "$owner" "$dir"
}

# check that the source exists and warn the user if it doesn't, then
# create them with the specified permissions
realSource="$(realpath -m "$sourceBase$target")"
if [[ ! -d $realSource ]]; then
    printf "Warning: Source directory '%s' does not exist; it will be created for you with the following permissions: owner: '%s:%s', mode: '%s'.\n" "$realSource" "$user" "$group" "$mode"
    mkdir --mode="$mode" "$realSource"
    set_ownership "$realSource"
else
    # Fix ownership if it was created incorrectly (e.g., during nixos-install)
    # Compare using numeric IDs since in initrd usernames show as UNKNOWN
    current_uid=$(stat -c '%u' "$realSource")
    current_gid=$(stat -c '%g' "$realSource")
    desired_uid="${uid:-}"
    desired_gid="${gid:-}"

    # Only try to fix if we have the desired uid/gid and they differ
    if [[ -n "$desired_uid" && -n "$desired_gid" ]]; then
        if [[ "$current_uid" != "$desired_uid" || "$current_gid" != "$desired_gid" ]]; then
            printf "Fixing ownership of '%s' from uid=%s:gid=%s to %s:%s\n" "$realSource" "$current_uid" "$current_gid" "$desired_uid" "$desired_gid"
            chown "${desired_uid}:${desired_gid}" "$realSource"
        fi
    fi
fi

if [[ $sourceBase ]]; then
    [[ -d $target ]] || mkdir "$target"

    # synchronize perms between source and target
    chown --reference="$realSource" "$target"
    chmod --reference="$realSource" "$target"
fi