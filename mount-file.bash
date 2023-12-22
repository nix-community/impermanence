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
    echo "Error: 'mount-file.bash' requires *three* args." >&2
    exit 1
fi

mountPoint="$1"
targetFile="$2"
debug="$3"
method="$4"

trace() {
    if (( "$debug" )); then
      echo "$@"
    fi
}
if (( "$debug" )); then
    set -o xtrace
fi

if [[ "$method" == "bind" ]]; then
   if [[ -L "$mountPoint" && $(readlink -f "$mountPoint") == "$targetFile" ]]; then
       trace "$mountPoint already links to $targetFile, ignoring"
   elif mount | grep -F "$mountPoint"' ' >/dev/null && ! mount | grep -F "$mountPoint"/ >/dev/null; then
       trace "mount already exists at $mountPoint, ignoring"
   elif [[ -e "$mountPoint" ]]; then
       echo "A file already exists at $mountPoint!" >&2
       exit 1
   elif [[ -e "$targetFile" ]]; then
       touch "$mountPoint"
       mount -o bind "$targetFile" "$mountPoint"
   else
       ln -s "$targetFile" "$mountPoint"
   fi
elif [[ "$method" == "symlink" ]]; then
    if [[ -e "$mountPoint" ]] && ! [[ -L "$mountPoint" ]]; then
	echo "symlink requested, but something else than symlink is present at $mountPoint"
	exit 1
    else
	ln -sf "$targetFile" "$mountPoint"
    fi
fi
