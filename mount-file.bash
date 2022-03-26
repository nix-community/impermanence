#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Get inputs from command line arguments
if [[ "$#" != 4 ]]; then
    echo "Error: 'mount-file.bash' requires *four* args." >&2
    exit 1
fi

mountPoint="$1"
targetFile="$2"
debug="$3"
force="$4"

if (( "$debug" )); then
    set -o xtrace
fi

if [[ -L "$mountPoint" && $(readlink -f "$mountPoint") == "$targetFile" ]]; then
    echo "$mountPoint already links to $targetFile, ignoring"
elif mount | grep -F "$mountPoint"' ' >/dev/null && ! mount | grep -F "$mountPoint"/ >/dev/null; then
    echo "mount already exists at $mountPoint, ignoring"
elif [[ -z "$force" ]] && [[ -e "$mountPoint" ]]; then
    echo "A file already exists at $mountPoint!" >&2
    exit 1
elif [[ -e "$targetFile" ]]; then
    if [[ -f "$mountPoint" ]]; then
        truncate -s 0 "$mountPoint"
    else
        rm -f "$mountPoint"
        touch "$mountPoint"
    fi
    mount -o bind "$targetFile" "$mountPoint"
else
    if [[ -n "$force" ]]; then
        ln -sf "$targetFile" "$mountPoint"
    else
        ln -s "$targetFile" "$mountPoint"
    fi
fi
