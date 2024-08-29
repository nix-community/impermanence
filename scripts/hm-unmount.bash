#!/usr/bin/env bash
set -o nounset  # Fail on use of unset variable.
set -o errexit  # Exit on command failure.
set -o pipefail # Exit on failure of any command in a pipeline.
set -o errtrace # Trap errors in functions and subshells.
set -o noglob   # Disable filename expansion (globbing), since it could otherwise happen during path splitting.
shopt -s inherit_errexit # Inherit the errexit option status in subshells.
trap 'echo "Error when executing $BASH_COMMAND at line $LINENO!" >&2' ERR
test -z "${DEBUG:=""}" || set -x

mountPoint="$1"
triesLeft="$2"
sleep="$3"

eval "$(impermanence-hm-mount-info "$mountPoint" SOURCE)"

if [[ "$IS_MOUNTPOINT" == 1 ]]; then
  while ((triesLeft > 0)); do
    if fusermount -u "$mountPoint"; then
      break
    fi

    ((triesLeft--))
    if ((triesLeft == 0)); then
      echo "Couldn't perform regular unmount of $mountPoint. Attempting lazy unmount."
      fusermount -uz "$mountPoint"
    else
      sleep "$sleep"
    fi
  done
fi
