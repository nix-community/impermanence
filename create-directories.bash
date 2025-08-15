#!/usr/bin/env bash

set -o nounset  # Fail on use of unset variable.
set -o errexit  # Exit on command failure.
set -o pipefail # Exit on failure of any command in a pipeline.
set -o errtrace # Trap errors in functions and subshells.
set -o noglob   # Disable filename expansion (globbing),
# since it could otherwise happen during
# path splitting.
shopt -s inherit_errexit # Inherit the errexit option status in subshells.

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
if [[ $# != 7 ]]; then
    printf "Error: 'create-directories.bash' requires *seven* args.\n" >&2
    exit 1
fi
src="$1"
target="$2"
user="$3"
group="$4"
mode="$5"
umask="$6"
debug="$7"

if ((debug)); then
    set -o xtrace
fi

# check that the source exists and warn the user if it doesn't, then
# create them with the specified permissions

init_dir() {
    local desc="${1?internal error}"
    shift &>/dev/null || :

    local dir="${1?internal error}"
    shift &>/dev/null || :

    local ref="${1:-}"

    if [[ -d "$dir" ]]; then
        printf "Info: %s '%s' exists; leaving its permissions and ownership as-is.\\n" "$desc" "$dir"
        return
    fi

    printf "Warning: %s '%s' does not exist; it will be created for you\\n" "$desc" "$dir"

    (
        if [[ -n "${umask:-}" ]]; then
            printf "Warning: initializing %s '%s' with umask '%s'.\\n" "$desc" "$dir" "$umask"
            umask "$umask"
        fi

        mkdir -p "$dir"

        if [[ -n "${ref:-}" ]] && [[ -d "$ref" ]]; then
            printf "Warning: initializing %s '%s' with permissions and ownership copied from '%s'.\\n" "$desc" "$dir" "$ref"
            chown --reference="$ref" "$dir"
            chmod --reference="$ref" "$dir"
        fi

        if [[ -n "${user:-}" ]]; then
            printf "Warning: %s setting owner of '%s' to '%s'\\n" "$desc" "$dir" "$user"
            chown "${user}:" "$dir"
        fi

        if [[ -n "${group:-}" ]]; then
            printf "Warning: %s setting group of '%s' to '%s'\\n" "$desc" "$dir" "$group"
            chown ":${group}" "$dir"
        fi

        if [[ -n "${mode:-}" ]]; then
            printf "Warning: %s setting mode of '%s' to '%s'\\n" "$desc" "$dir" "$mode"
            chmod "$mode" "$dir"
        fi
    )
}

rc=0

init_dir 'Source directory' "$src" "$target" || rc="$?"
init_dir 'Target directory' "$target" "$src" || rc="$?"

exit "$rc"
