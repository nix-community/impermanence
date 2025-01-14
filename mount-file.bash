#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Get inputs from command line arguments
if [[ $# != 3 ]]; then
    echo "Error: 'mount-file.bash' requires *three* args." >&2
    exit 1
fi

mountPoint="$1"
targetFile="$2"
debug="$3"

trace() {
    if (( debug )); then
      echo "$@"
    fi
}
if (( debug )); then
    set -o xtrace
fi

if [[ -L $mountPoint && $(readlink -f "$mountPoint") == "$targetFile" ]]; then
    trace "$mountPoint already links to $targetFile, ignoring"
elif findmnt "$mountPoint" >/dev/null; then
    trace "mount already exists at $mountPoint, ignoring"
elif [[ -s $mountPoint ]]; then
    echo "A file already exists at $mountPoint!" >&2
    exit 1
elif [[ -e $targetFile ]]; then
    touch -h "$mountPoint"
    mount -o bind "$targetFile" "$mountPoint"
elif [[ $mountPoint == "/etc/machine-id" ]]; then
    # Work around an issue with persisting /etc/machine-id. For more
    # details, see https://github.com/nix-community/impermanence/pull/242
    echo "Creating initial /etc/machine-id"
    echo "uninitialized" > "$targetFile"
    touch "$mountPoint"
    mount -o bind "$targetFile" "$mountPoint"
else
    ln -s "$targetFile" "$mountPoint"
fi
