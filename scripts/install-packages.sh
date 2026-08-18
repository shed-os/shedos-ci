#!/usr/bin/env bash
# Install the named packages against a package database the mirror can still
# serve.
#
# The container's mirrorlist is a pair of CDN fronts, and a CDN node can go on
# handing out a repository database for hours after the pool behind it dropped
# the releases that database names. pacman then resolves a version every mirror
# answers 404 for, because a mirror keeps only the current one. Refreshing from
# the same host returns the same held database, so the way out is to take the
# database from the next mirror instead.
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: install-packages.sh <package>..." >&2
    exit 2
fi

MIRRORLIST=${SHEDOS_MIRRORLIST:-/etc/pacman.d/mirrorlist}

# Move the first mirror to the back. Comments and anything else in the file
# keep their place; only the order pacman reads Server lines in changes.
rotate_mirrorlist() {
    local first rest
    first=$(grep -m1 '^[[:space:]]*Server[[:space:]]*=' "$MIRRORLIST") || return 1
    rest=$(grep -vxF "$first" "$MIRRORLIST")
    printf '%s\n%s\n' "$rest" "$first" > "$MIRRORLIST"
}

mirrors=$(grep -c '^[[:space:]]*Server[[:space:]]*=' "$MIRRORLIST" 2> /dev/null)
(( mirrors > 0 )) || mirrors=1

# One transaction refreshes, upgrades and installs: resolving against a
# database older than the system the packages land on is the partial upgrade
# Arch does not support.
refresh=-Syu
attempt=1
while :; do
    pacman "$refresh" --needed --noconfirm "$@"
    rc=$?
    (( rc == 0 )) && exit 0
    (( attempt < mirrors )) || exit "$rc"
    echo 'install-packages: retrying from the next mirror' >&2
    rotate_mirrorlist || exit "$rc"
    # The held database is on disk now, and pacman would keep it: the second
    # y is what makes the next mirror's copy replace it.
    refresh=-Syyu
    attempt=$((attempt + 1))
done
