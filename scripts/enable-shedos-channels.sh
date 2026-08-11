#!/usr/bin/env bash
# Put the ShedOS channels in front of the container's pacman, so a package
# whose depends name other ShedOS packages can be built and tested here at all.
#
# Staging is listed first because pacman takes the first repository carrying a
# name: a carved repo's own package wins the moment it publishes to staging,
# and anything not carved yet still resolves from the published channel behind
# it. That ordering is what lets the carve happen one repository at a time.
set -euo pipefail

PACMAN_CONF=${PACMAN_CONF:-/etc/pacman.conf}
KEY_URL=${SHEDOS_KEY_URL:-https://repo.shedos.org/shedos.gpg}
STAGING_SERVER=${SHEDOS_STAGING_SERVER:-https://repo.shedos.org/staging/test/\$arch}
PUBLISHED_SERVER=${SHEDOS_PUBLISHED_SERVER:-https://repo.shedos.org/test/\$arch}

# Cloudflare's managed rules drop datacenter traffic that does not name itself,
# and a runner is a datacenter address: a bare curl answers 403 from CI while
# working perfectly from a desk.
USER_AGENT='shedos-ci (+https://shedos.org)'

# Rotations append the new fingerprint here together with the keyring. Every
# primary key in the download has to be on this list — one rogue key smuggled
# in beside a valid one is a refusal, not a warning.
KEY_FPRS=(
    56C3F7528D42C4E526556CE2DAF4230B5648D916
)

die() { printf 'shedos-channels: %s\n' "$*" >&2; exit 1; }

fpr_pinned() {
    local fp=$1 known
    for known in "${KEY_FPRS[@]}"; do
        [[ $fp == "$known" ]] && return 0
    done
    return 1
}

key=$(mktemp)
trap 'rm -f "$key"' EXIT

curl -fsSL --max-time 60 -A "$USER_AGENT" -o "$key" "$KEY_URL" \
    || die "could not download the signing key from $KEY_URL"

fprs=$(gpg --show-keys --with-colons "$key" 2> /dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
[[ -n $fprs ]] || die "no keys in the downloaded keyring"

while IFS= read -r fp; do
    fpr_pinned "$fp" || die "unexpected key $fp in the keyring — refusing to trust it"
done <<< "$fprs"

pacman-key --add "$key" || die 'pacman-key --add failed'
while IFS= read -r fp; do
    pacman-key --lsign-key "$fp" || die "pacman-key --lsign-key $fp failed"
done <<< "$fprs"

cat >> "$PACMAN_CONF" <<EOF

[shedostest]
SigLevel = Required DatabaseRequired
Server = $STAGING_SERVER

[shedos]
SigLevel = Required DatabaseRequired
Server = $PUBLISHED_SERVER
EOF

pacman -Sy --noconfirm
