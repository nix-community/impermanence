#!/usr/bin/env bash
set -o nounset  # Fail on use of unset variable.
set -o errexit  # Exit on command failure.
set -o pipefail # Exit on failure of any command in a pipeline.
set -o errtrace # Trap errors in functions and subshells.
set -o noglob   # Disable filename expansion (globbing), since it could otherwise happen during path splitting.
shopt -s inherit_errexit # Inherit the errexit option status in subshells.
trap 'echo "Error when executing $BASH_COMMAND at line $LINENO!" >&2' ERR
test -z "${DEBUG:=""}" || set -x

# Get inputs from command line arguments
if [[ "$#" != 2 ]]; then
  echo "Error: 'mount-file.bash' requires *two* args." >&2
  exit 1
fi

mountPoint="$1"
targetFile="$2"

trace() {
  if (("$DEBUG")); then
    echo "$@"
  fi
}

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
