#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Get inputs from command line arguments
if [[ "$#" != 3 ]]; then
    echo "Error: 'mount-file.bash' requires *three* args." >&2
    exit 1
fi

mountPoint="$1"
targetFile="$2"
debug="$3"

if (( "$debug" )); then
    set -o xtrace
fi

if [[ -L "$mountPoint" && $(readlink -f "$mountPoint") == "$targetFile" ]]; then
    echo "$mountPoint already links to $targetFile, ignoring"
elif mount | grep -F "$mountPoint"' ' >/dev/null && ! mount | grep -F "$mountPoint"/ >/dev/null; then
    echo "mount already exists at $mountPoint, ignoring"
elif [[ -e "$mountPoint" ]]; then
    echo "a file already exists at $mountPoint, turning it into symlink"
    cp "$mountPoint" "$targetFile"
    ln -s "$targetFile" "$mountPoint"
elif [[ -e "$targetFile" ]]; then
    touch "$mountPoint"
    mount -o bind "$targetFile" "$mountPoint"
else
    ln -s "$targetFile" "$mountPoint"
fi
