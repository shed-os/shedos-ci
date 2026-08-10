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

# Only two answers are safe here: the DB says which releases are taken, or it
# demonstrably does not exist yet. Anything else — a refused connection, a
# timeout, a 500, a truncated download — would silently disarm the pkgrel
# guard and publish over a release that is already out there, so it stops the
# build instead.
fetch_staging_db() {
    local db err code rc=0
    db=$(mktemp)
    err=$(mktemp)

    # Cloudflare's managed rules drop datacenter traffic that does not name
    # itself, and a GitHub runner is a datacenter address: without this the
    # repo answers 403 from CI and 404 from a desk.
    code=$(curl -sSL --max-time 60 -A 'shedos-ci (+https://shedos.org)' \
        -o "$db" -w '%{http_code}' "$STAGING_DB_URL" 2> "$err") || rc=$?

    # 37 is curl's "could not read file", i.e. a file:// URL with nothing
    # behind it. Over HTTP the same absence arrives as a 404.
    if (( rc == 37 )) || [[ $code == 404 ]]; then
        rm -f "$db" "$err"
        echo "staging DB absent — first publish"
        return 0
    fi

    if (( rc != 0 )); then
        echo "cannot reach the staging DB at $STAGING_DB_URL: $(tr -d '\n' < "$err") (curl exit $rc)" >&2
        rm -f "$db" "$err"
        exit 1
    fi

    # file:// transfers report no status at all; HTTP has to be a success.
    if [[ $code != 000 && $code != 2?? ]]; then
        echo "staging DB at $STAGING_DB_URL returned HTTP $code" >&2
        rm -f "$db" "$err"
        exit 1
    fi

    if ! staging_entries=$(tar -tzf "$db" 2> "$err" | sed -e 's:^\./::' -e 's:/.*::' | sort -u); then
        echo "staging DB at $STAGING_DB_URL is not readable as a database: $(tr -d '\n' < "$err")" >&2
        rm -f "$db" "$err"
        exit 1
    fi

    rm -f "$db" "$err"
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
    grep -qxF "$pkgname-$pkgver-$pkgrel" <<<"$staging_entries" || return 0

    # A decimal pkgrel like 1.1 truncates to 1, which is behind where we
    # started, so step off it before looking for the first free release.
    local next=${pkgrel%%.*}
    [[ $pkgrel == "$next" ]] || next=$((next + 1))
    while grep -qxF "$pkgname-$pkgver-$next" <<<"$staging_entries"; do
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

# The invocation, NUL-separated, so both the runner and the dry run see the
# same argv. PKGDEST pins the output next to the PKGBUILD whatever the host
# makepkg.conf says, so the collection step below cannot miss it. CI builds
# take the sudo branch; a workstation running the harness takes the other.
makepkg_argv() {
    local dir=$1
    local -a cmd=()
    [[ $BUILD_USER == "$(id -un)" ]] || cmd=(sudo -u "$BUILD_USER")
    # shellcheck disable=SC2016  # $1 is the inner bash's argument, not ours
    cmd+=(env "PKGDEST=$dir" bash -c 'cd "$1" && makepkg --syncdeps --noconfirm --force' _ "$dir")
    printf '%s\0' "${cmd[@]}"
}

run_makepkg() {
    local dir=$1
    local -a cmd
    mapfile -t -d '' cmd < <(makepkg_argv "$dir")
    "${cmd[@]}"
}

mapfile -t dirs < <(jq -er '.[]' <<<"$PACKAGES_JSON")
if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "no package directories in $PACKAGES_JSON" >&2
    exit 1
fi

# Prints what each package would be built with and stops. The build itself
# needs a container and a build user, so this is how the invocation gets
# checked without one.
if [[ -n ${SHEDOS_DRY_RUN:-} ]]; then
    for dir in "${dirs[@]}"; do
        dir=$(cd -- "$dir" && pwd)
        mapfile -t -d '' cmd < <(makepkg_argv "$dir")
        printf 'argv: %s\n' "${cmd[@]}"
    done
    exit 0
fi

fetch_staging_db
mkdir -p "$DIST"

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
