#!/usr/bin/env bash
set -o nounset  # Fail on use of unset variable.
set -o errexit  # Exit on command failure.
set -o pipefail # Exit on failure of any command in a pipeline.
set -o errtrace # Trap errors in functions and subshells.
set -o noglob   # Disable filename expansion (globbing), since it could otherwise happen during path splitting.
shopt -s inherit_errexit # Inherit the errexit option status in subshells.
trap 'echo "Error when executing $BASH_COMMAND at line $LINENO!" >&2' ERR
test -z "${DEBUG:=""}" || set -x

targetDir="$1"
mountPoint="$2"
bindfsArgs=("${@:3}")

eval "$(impermanence-path-info "$mountPoint" SOURCE)"

if [[ "$IS_MOUNTPOINT" == 1 && "$IS_DEAD" == 1 ]]; then
  impermanence-hm-unmount "$mountPoint" 3 1
  eval "$(impermanence-path-info "$mountPoint" SOURCE)"
fi

if [[ "$IS_MOUNTPOINT" == 0 ]]; then
  mkdir -p "$mountPoint"

  exec bindfs "${bindfsArgs[@]}" "$targetDir" "$mountPoint"
elif [[ "$SOURCE" == "$targetDir" ]]; then
  echo "Mountpoint '$mountPoint' already points at '$targetDir'!" >&2
else
  echo "There is already an active mount at or below '$mountPoint'!" >&2
  exit 1
fi
