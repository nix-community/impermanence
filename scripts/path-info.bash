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
outputs=""
variables=()
has_source=0

for variable in "${@:2}"; do
  # uppercase the variable
  variable="${variable^^}"

  output="$variable"
  # special handling of some names
  case "$variable" in
  *_PCT) output="${variable%_PCT}%" ;;
  SOURCE) has_source=1 ;;
  esac

  variables+=("$variable")
  outputs="$outputs,$output"
done
outputs="${outputs#,}"

IS_MOUNTPOINT=0
IS_SYMLINK=0
IS_DEAD=0

if [[ -L "$mountPoint" ]] ; then
  # shellcheck disable=SC2034
  IS_SYMLINK=1
  SOURCE="$(readlink -f "$mountPoint")"
elif _src="$(findmnt --output "$outputs" --shell --pairs --first-only --mountpoint "$mountPoint")"; then
  eval "$_src"
  # shellcheck disable=SC2034
  IS_MOUNTPOINT=1
  IS_DEAD=0

  if [[ "$has_source" == 1 && "$SOURCE" == *'['*']' ]]; then
    # resolve bind-mounts in [brackets]
    _SOURCE_PARENT="$(findmnt --noheadings --output TARGET --first-only "${SOURCE%%[*}")"
    SOURCE="${SOURCE#*[}"
    SOURCE="${SOURCE%]}"
    SOURCE="$_SOURCE_PARENT$SOURCE"
  fi

  if mountpoint "$mountPoint" |& grep -q 'Transport endpoint is not connected'; then
    # shellcheck disable=SC2034
    IS_DEAD=1
  fi
fi

for varName in IS_DEAD IS_MOUNTPOINT IS_SYMLINK "${variables[@]}"; do
  value="${!varName:-""}"
  echo "$varName=${value@Q}"
done
