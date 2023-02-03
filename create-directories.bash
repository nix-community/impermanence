#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
set -o noglob             # Disable filename expansion (globbing),
                          # since it could otherwise happen during
                          # path splitting.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Given a source directory, /source, and a target directory,
# /target/foo/bar/bazz, we want to "clone" the target structure
# from source into the target. Essentially, we want both
# /source/target/foo/bar/bazz and /target/foo/bar/bazz to exist
# on the filesystem. More concretely, we'd like to map
# /state/etc/ssh/example.key to /etc/ssh/example.key
#
# To achieve this, we split the target's path into parts -- target, foo,
# bar, bazz -- and iterate over them while accumulating the path
# (/target/, /target/foo/, /target/foo/bar, and so on); then, for each of
# these increasingly qualified paths we:
#   1. Ensure both /source/qualifiedPath and qualifiedPath exist
#   2. Copy the ownership of the source path to the target path (subject to
#      some exceptions described in the `createDirs` function)
#   3. Copy the mode of the source path to the target path (again subject to
#      some exceptions described in `createDirs`)

printMsg() {
    printf "create-directories.bash: %s\n" "$*"
}

initDir() {
    # `user`, `group`, and `mode` options use `types.str`, so empty strings are
    # permitted.  Treat empty strings as signifying that we should omit the
    # relevant `install` flags.
    printMsg "Warning: directory '${1?}' does not exist; creating it with these permissions: owner: '${user:-<unspecified>}:${group:-<unspecified>}', mode: '${mode:-<unspecified>}'." >&2

    install -d ${mode:+--mode="$mode"} ${user:+--owner "$user"} ${group:+--group "$group"} "${1?}"
}

atomicDir() {
    local dir="$1"
    shift

    local cmd="$1"
    shift

    local parent
    parent="$(dirname "$dir")"

    if ! [[ -d "$parent" ]]; then
        initDir "$parent"
    fi

    # Create temporary directory in the parent directory of the target/final
    # directory; this helps ensure the final `mv -f` is an atomic rename (and
    # not, e.g., a cross-device copy).
    tmp="$(mktemp -d "${parent}/.$(basename "$dir").XXXXXXXXXX")"

    "$cmd" "$tmp" "$@" || {
        local rc="$?"
        rm -rf "${tmp?}"
        return "$rc"
    }

    # `-T` (`--no-target-directory`) to avoid copying `$tmp` into `$dir`,
    # should `$dir` have been created by something other than this run of this
    # function.
    mv -T -f "$tmp" "$dir"
}

permsFromReference() {
    chown --reference="${2?}" "${1?}"
    chmod --reference="${2?}" "${1?}"
}

atomicDirFromReference() {
    atomicDir "${1?}" permsFromReference "${2?}"
}

createDirs() {
    # Get inputs from command line arguments
    if [[ "$#" != 10 ]]; then
        printf "Error: 'create-directories.bash' requires *10* args.\n" >&2
        return 1
    fi

    local persistentStoragePath="$1"
    shift

    local root="$1"
    shift

    local relpath="$1"
    shift

    local source="${1:-${persistentStoragePath}/${relpath}}"
    shift

    local destination="${1:-${root}/${relpath}}"
    shift

    local user="$1"
    shift

    local group="$1"
    shift

    local mode="$1"
    shift

    local implicit="$1"
    shift

    local debug="$1"
    shift

    if (( debug )); then
        set -o xtrace

        diag() {
            printMsg "$@"
        }
    else
        diag() {
            :
        }
    fi

    local realSource
    realSource="$(realpath -m "$source")"

    local realSourceResolved
    realSourceResolved="$(realpath -m "${persistentStoragePath}/${relpath}")"

    if [[ "$realSource" != "$realSourceResolved" ]]; then
        printMsg "internal error: real path of source '${source}' ('${realSource}') does not match real path of joined persistent storage path '${persistentStoragePath}' and relative path '${relpath}' ('${realSourceResolved}')" >&2
        return 1
    fi

    local realDestination
    realDestination="$(realpath -m "$destination")"

    local realDestinationResolved
    realDestinationResolved="$(realpath -m "${root}/${relpath}")"

    if [[ "$realDestination" != "$realDestinationResolved" ]]; then
        printMsg "internal error: real path of destination '${destination}' ('${realDestination}') does not match real path of joined root path '${root}' and relative path '${relpath}' ('${realDestinationResolved}')" >&2
        return 1
    fi

    if [[ "$realSource" == "$realDestination" ]]; then
        printMsg "internal error: real path of source '${source}' ('${realSource}') is identical to real path of destination '${destination}' ('${realDestination}')" >&2
        return 1
    fi

    # Iterate over each part of the relative path, e.g. var, lib, etc.
    local -a pathParts
    mapfile -d / -t pathParts < <(printf "%s" "${relpath#/}") || :

    local pathPart currentPath previousPath
    local currentDestinationPath currentSourcePath
    local currentRealDestinationPath currentRealSourcePath

    # XXX global associative array -- tracks which destination directories
    # we've created, chowned, and/or chmodded.  Used to short-circuit if a
    # destination was already processed; prevents later/lower-precedence
    # directory settings from clobbering permissions set on the basis of
    # earlier/higher-precedence directories.
    declare -gA destinationsProcessed

    # Whether we've already processed the destination directories (== path
    # exists in `destinationsProcessed`).
    local -i destinationProcessedAlready

    # Whether to copy permissions from the destination directory to the source
    # directory (given that the destination directory exists, and that the
    # source directory does not exist).
    local -i copyPermsFromDestination

    local -i pathPartsIdx
    local -i pathPartsSize="${#pathParts[@]}"

    for (( pathPartsIdx=0 ; pathPartsIdx < pathPartsSize ; pathPartsIdx++ )); do
        pathPart="${pathParts[pathPartsIdx]}"

        case "$pathPart" in
            '')
                continue
                ;;
            ..)
                # All lexically-resolvable `..` elements should already have
                # been resolved by the impermanence module
                printMsg "internal error: illegal path traversal in '${relpath}'" 1>&2
                return 1
                ;;
        esac

        currentPath="${previousPath:+${previousPath}/}${pathPart}"

        # construct the incremental path, e.g. /var, /var/lib, /var/lib/iwd
        currentDestinationPath="${root}/${currentPath}"

        # construct the source path, e.g. /state/var, /state/var/lib, ...
        currentSourcePath="${persistentStoragePath}/${currentPath}"

        # resolve the output path
        currentRealDestinationPath="$(realpath -m "$currentDestinationPath")"

        # resolve the source path to avoid symlinks
        currentRealSourcePath="$(realpath -m "$currentSourcePath")"

        if [[ -n "${destinationsProcessed[${currentRealDestinationPath}]:-}" ]]; then
            destinationProcessedAlready=1
        else
            destinationProcessedAlready=0
        fi

        # If we're on the last part of the path, copy the permissions from the
        # destination directory if the caller told us that this directory is
        # being created implicitly (i.e. as the parent directory of an
        # explicitly-specified persistent file).
        #
        # Otherwise, copy permissions from the destination if and only if we
        # haven't already processed the destination path.
        #
        # This is meant to deal with the case where we have one or more
        # persistent storage paths, as well as directories under those storage
        # paths that are partial prefix matches for one another.
        #
        # For instance, consider this configuration:
        #
        #   {
        #     environment.persistence = {
        #       "/abc".directories = [
        #         { directory = "/foo/bar/bazz/quux"; user = "alex"; group = "alex"; }
        #       ];
        #
        #       "/def".directories = [
        #         { directory = "/foo/bar/bazz"; user = "benny"; group = "benny"; }
        #       ];
        #     };
        #   }
        #
        # Assume that we're creating the *source* directories.  Because
        # `/foo/bar/bazz` is a prefix of `/foo/bar/bazz/quux`, we're going to
        # create the destination directory `/foo/bar/bazz` with owner `benny`
        # and group `benny`, and do so *before* creating the source directory
        # `/abc/foo/bar/bazz/quux`.
        #
        # Presumably we want to create `/abc/foo/bar/bazz` (the parent
        # directory of `/abc/foo/bar/bazz/quux`) with owner `alex` and group
        # `alex`.  That is what this logic enforces -- by detecting that we're
        # responsible for having created the destination path `/foo/bar/bazz`,
        # we know that we should not copy its permissions to a source path.
        if (( pathPartsIdx == (pathPartsSize - 1) )); then
            copyPermsFromDestination="$implicit"
        elif (( destinationProcessedAlready )); then
            copyPermsFromDestination=0
        else
            copyPermsFromDestination=1
        fi

        # create the source directory if it does not exist
        if ! [[ -d "$currentRealSourcePath" ]]; then
            if (( copyPermsFromDestination )) && [[ -d "$currentRealDestinationPath" ]]; then
                diag "[source] creating directory '$currentRealSourcePath' using permissions from '$currentRealDestinationPath'"
                atomicDirFromReference "$currentRealSourcePath" "$currentRealDestinationPath"
            else
                diag "[source] creating directory '$currentRealSourcePath' using supplied permissions"
                initDir "$currentRealSourcePath"
            fi
        fi

        # create the destination directory, if necessary, and copy permissions
        # from the source directory
        if [[ -d "$currentRealDestinationPath" ]]; then
            if (( destinationProcessedAlready )); then
                diag "[destination] '$currentRealDestinationPath' already processed"
            else
                diag "[destination] setting permissions on '$currentRealDestinationPath' using permissions from '$currentRealSourcePath'"
                permsFromReference "$currentRealDestinationPath" "$currentRealSourcePath"
                destinationsProcessed[${currentRealDestinationPath}]=1
            fi
        else
            diag "[destination] creating directory '$currentRealDestinationPath' using permissions from '$currentRealSourcePath'"
            atomicDirFromReference "$currentRealDestinationPath" "$currentRealSourcePath"
            destinationsProcessed[${currentRealDestinationPath}]=1
        fi

        # lastly we update the previousPath to continue down the tree
        previousPath="$currentPath"
    done
}

# if `return 0` succeeds, this script is being sourced
if ! (return 0) &>/dev/null; then
    createDirs "$@"
fi
