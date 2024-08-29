#!/usr/bin/env bash
set -o nounset           # Fail on use of unset variable.
set -o errexit           # Exit on command failure.
set -o pipefail          # Exit on failure of any command in a pipeline.
set -o errtrace          # Trap errors in functions and subshells.
set -o noglob            # Disable filename expansion (globbing), since it could otherwise happen during path splitting.
shopt -s inherit_errexit # Inherit the errexit option status in subshells.
trap 'echo "Error when executing $BASH_COMMAND at line $LINENO!" >&2' ERR
test -z "${DEBUG:=""}" || set -x

mountPoint="$1"
targetDir="$2"
unitName="$3"
bindfsArgs=("${@:4}")
: "${outputPrefix:="OUTPUT:"}"

activationUnitName="activation-${unitName}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-"/run/user/${UID}"}"

unmountCmd="$(command -v impermanence-hm-unmount)"
mountpointCmd="$(command -v mountpoint)"

eval "$(impermanence-hm-mount-info "$mountPoint" FSTYPE SOURCE)"

if [[ "$IS_MOUNTPOINT" == 1 && "$IS_DEAD" == 1 ]]; then
  echo "seems like the process died, remounting $mountPoint..."
  "$unmountCmd" "$mountPoint" 3 1
  eval "$(impermanence-hm-mount-info "$mountPoint" FSTYPE SOURCE)"
fi

mkdir -p "$targetDir"
mkdir -p "$mountPoint"

dumpvars() {
  for var in "$@"; do
    printf "%s=%q " "${var}" "${!var}"
  done
}

bindfs-run() {
  # executing directly inside `home.activation` results in `bindfs` being
  # killed upon `home-manager-<user>.service` restarts
  # we can work around it, by putting `bindfs` inside `background.slice`
  # through `systemd-run`
  local targetDir="$1" mountPoint="$2" args=() run_args=()
  if [[ "${UID}" != 0 ]]; then
    args+=(--user)
    run_args+=(--slice=background)
  fi
  if systemctl "${args[@]}" is-active "${activationUnitName}.service" &>/dev/null; then
    echo "'${activationUnitName}.service' is already running, not starting another one."
    return
  fi
  # ExecCondition serves same purpose as Unit.ConditionPathIsMountPoint
  systemd-run "${args[@]}" "${run_args[@]}" --unit="${activationUnitName}" \
    --service-type=forking \
    --property=ExecCondition="!${mountpointCmd@Q} ${mountPoint@Q}" \
    --property=ExecStop="${unmountCmd@Q} ${targetDir@Q} ${mountPoint@Q}" \
    bindfs "${bindfsArgs[@]}" "${targetDir}" "${mountPoint}"
}

if [[ "$IS_MOUNTPOINT" == 1 && "$FSTYPE" == "fuse" && "$SOURCE" != "$targetDir" ]]; then
  echo "remounting $mountPoint from $SOURCE to $targetDir"
  systemctl --user stop "${unitName}.service" "${activationUnitName}.service"
  bindfs-run "${targetDir}" "${mountPoint}"
  echo "$outputPrefix$mountPoint"
elif [[ "$IS_MOUNTPOINT" == 0 ]]; then
  echo "mounting $targetDir at $mountPoint"
  bindfs-run "${targetDir}" "${mountPoint}"
  echo "$outputPrefix$mountPoint"
else
  echo "${mountPoint@Q} is already a mountpoint: $(dumpvars FSTYPE SOURCE)"
fi
