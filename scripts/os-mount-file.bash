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

eval "$(impermanence-path-info "$mountPoint" SOURCE)"

if [[ "$IS_SYMLINK" == 1 && "$SOURCE" == "$targetFile" ]]; then
  echo "$mountPoint already links to $targetFile, ignoring"
elif [[ "$IS_MOUNTPOINT" == 1 ]]; then
  echo "mount already exists at $mountPoint, ignoring"
elif [[ -e "$mountPoint" ]]; then
  echo "A file already exists at $mountPoint!" >&2
  exit 1
elif [[ -e "$targetFile" ]]; then
  echo "Bind mounting ${targetFile} to ${mountPoint}..."
  touch "$mountPoint"
  mount -o bind "$targetFile" "$mountPoint"
else
  echo "Symlinking ${targetFile} to ${mountPoint}..."
  ln -s "$targetFile" "$mountPoint"
fi
