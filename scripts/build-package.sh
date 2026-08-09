#!/usr/bin/env bash
# Build every package directory named in the JSON array argument and collect
# the results under dist/ with a SHA256SUMS manifest. Run from the root of a
# package repository checkout; nothing outside that checkout and dist/ is
# touched.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: build-package.sh '[\"dir\", ...]'" >&2
    exit 2
fi

PACKAGES_JSON=$1
BUILD_USER=${SHEDOS_BUILD_USER:-builder}
STAGING_DB_URL=${SHEDOS_STAGING_DB_URL:-https://repo.shedos.org/staging/test/x86_64/shedos.db}
DIST=$PWD/dist

# Names of every pkgver-pkgrel already published, so a rebuild of a taken
# release can move out of the way instead of colliding at publish time.
staging_entries=""

fetch_staging_db() {
    local db
    db=$(mktemp)
    # -f without -S: a 404 or an unreachable repo is the first-publish case,
    # not an error, so curl's own diagnostic would only be noise.
    if curl -fsL "$STAGING_DB_URL" -o "$db" && [[ -s $db ]]; then
        staging_entries=$(tar -tzf "$db" 2>/dev/null | sed -e 's:^\./::' -e 's:/.*::' | sort -u) \
            || staging_entries=""
    fi
    rm -f "$db"
    [[ -n $staging_entries ]] || echo "staging DB absent — first publish"
}

# pkgname/pkgver/pkgrel straight from the PKGBUILD. Sourcing is what makepkg
# does too; the subshell keeps the variables out of this script.
pkgbuild_field() {
    local dir=$1 field=$2
    (
        set +eu
        # shellcheck source=/dev/null
        source "$dir/PKGBUILD" > /dev/null 2>&1
        case $field in
            pkgname) printf '%s\n' "${pkgname[0]}" ;;
            *) printf '%s\n' "${!field}" ;;
        esac
    )
}

# Move pkgrel past every release the staging DB already carries, and record
# the move so the caller workflow has something to push.
guard_pkgrel() {
    local dir=$1 pkgname=$2 pkgver=$3 pkgrel=$4
    grep -qx "$pkgname-$pkgver-$pkgrel" <<<"$staging_entries" || return 0

    local next=${pkgrel%%.*}
    while grep -qx "$pkgname-$pkgver-$next" <<<"$staging_entries"; do
        next=$((next + 1))
    done

    echo "$pkgver-$pkgrel is already in staging — bumping pkgrel to $next"
    sed -i -E "s/^pkgrel=.*/pkgrel=$next/" "$dir/PKGBUILD"

    git -C "$dir" add PKGBUILD
    git -C "$dir" \
        -c user.name='shedos-ci[bot]' \
        -c user.email='shedos-ci[bot]@users.noreply.github.com' \
        commit -q \
        -m "chore(release): bump pkgrel for $pkgname" \
        -m "Release $pkgver-$pkgrel is already published to the staging repo."
}

run_makepkg() {
    local dir=$1
    # PKGDEST pins the output next to the PKGBUILD whatever the host
    # makepkg.conf says, so the collection step below cannot miss it.
    if [[ $BUILD_USER == "$(id -un)" ]]; then
        (cd "$dir" && PKGDEST=$dir makepkg --syncdeps --noconfirm --force)
    else
        sudo -u "$BUILD_USER" env PKGDEST="$dir" \
            bash -c 'cd "$1" && makepkg --syncdeps --noconfirm --force' _ "$dir"
    fi
}

mapfile -t dirs < <(jq -er '.[]' <<<"$PACKAGES_JSON")
if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "no package directories in $PACKAGES_JSON" >&2
    exit 1
fi

mkdir -p "$DIST"
fetch_staging_db

for dir in "${dirs[@]}"; do
    dir=$(cd -- "$dir" && pwd)
    [[ -f $dir/PKGBUILD ]] || { echo "no PKGBUILD in $dir" >&2; exit 1; }

    pkgname=$(pkgbuild_field "$dir" pkgname)
    pkgver=$(pkgbuild_field "$dir" pkgver)
    pkgrel=$(pkgbuild_field "$dir" pkgrel)
    echo "════════ $pkgname $pkgver-$pkgrel ════════"

    guard_pkgrel "$dir" "$pkgname" "$pkgver" "$pkgrel"
    run_makepkg "$dir"

    for pkg in "$dir"/*.pkg.tar.zst; do
        [[ -e $pkg ]] || { echo "makepkg produced nothing in $dir" >&2; exit 1; }
        case ${pkg##*/} in
            *-debug-*) continue ;;
        esac
        mv "$pkg" "$DIST/"
    done
done

(cd "$DIST" && sha256sum -- *.pkg.tar.zst > SHA256SUMS)
cat "$DIST/SHA256SUMS"
