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
PUSH_REMOTE=${SHEDOS_PKGREL_PUSH_REMOTE:-origin}
PUSH_BUMP=${SHEDOS_PKGREL_PUSH:-false}
MAKEPKG_CONF=${MAKEPKG_CONF:-/etc/makepkg.conf}
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

# Put the bump back where it came from: the artifact carries the new release,
# and a checkout left on the old one describes a package nobody can get. A push
# that does not land is that same divergence reached quietly, so it stops the
# build. Only the build whose packages will be published pushes, and it is off
# until told — a pull request builds a merge of the branch into main, and
# pushing that would merge the pull request.
#
# The push goes out with the job's GITHUB_TOKEN and has to keep going out with
# it. A push made with that token starts no workflow run, and a run started
# from here would find in staging the release it had just published, bump
# again, push again, with nothing anywhere to stop it. A PAT or a GitHub App
# token — the usual way past a protected main — does start that run, so a
# package repo that protects main cannot use this guard as it stands: bump
# pkgrel by hand there, never hand the job a stronger token.

# Anything that keeps the bump from reaching the remote ends the same way, so
# it is worth saying in the same words.
push_failed() {
    local err=$1 rc=$2
    echo "cannot push the pkgrel bump to $PUSH_REMOTE: $(tr '\n' ' ' < "$err") (git exit $rc)" >&2
    rm -f "$err"
    exit 1
}

push_bump() {
    local dir=$1 err parent remote_head

    if [[ $PUSH_BUMP != true ]]; then
        echo "SHEDOS_PKGREL_PUSH is not 'true' — the bump stays in this checkout"
        return 0
    fi

    # Whatever the workflow said, the bump goes out only if it sits on what
    # main is right now. A pull request checkout is a merge of the branch into
    # main, so the commit under the bump is that merge and not main's tip, and
    # this refuses it there without the gate above having to be right. It
    # catches a main that moved mid-build too.
    err=$(mktemp)
    remote_head=$(git -C "$dir" ls-remote "$PUSH_REMOTE" refs/heads/main 2> "$err" | cut -f1) \
        || push_failed "$err" $?
    parent=$(git -C "$dir" rev-parse HEAD~1)
    if [[ $parent != "$remote_head" ]]; then
        echo "refusing to push the pkgrel bump: it sits on $parent but $PUSH_REMOTE main is ${remote_head:-absent}" >&2
        rm -f "$err"
        exit 1
    fi

    git -C "$dir" push "$PUSH_REMOTE" HEAD:main 2> "$err" || push_failed "$err" $?

    rm -f "$err"
    echo "pushed the bump to $PUSH_REMOTE"
}

# Move pkgrel past every release the staging DB already carries, and put the
# move back on the branch it was built from.
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

    push_bump "$dir"
}

# The build options the monolith's CI uses. A package built here has to record
# the same BUILDENV and OPTIONS in its .BUILDINFO as the monolith's build of
# the same source, or the equivalence gate that compares the two reads every
# rebuilt object as a difference: stock makepkg leaves `debug` on, which
# appends -C debuginfo=2 to RUSTFLAGS, moves cargo's metadata hash and renames
# every path under a crate's target directory. The drop-in goes beside the
# config makepkg reads rather than into the workflow, so it holds for every
# caller with nothing to opt into, and so the harness can point the whole thing
# at a scratch config instead of writing into the machine's /etc.
wire_makepkg_options() {
    install -d "$MAKEPKG_CONF.d"
    cat > "$MAKEPKG_CONF.d/99-shedos.conf" <<'EOF'
BUILDENV=(!distcc color !check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
MAKEFLAGS="-j$(nproc)"
EOF
}

# The invocation, NUL-separated, so both the runner and the dry run see the
# same argv. PKGDEST pins the output next to the PKGBUILD whatever the host
# makepkg.conf says, so the collection step below cannot miss it, and
# MAKEPKG_CONF names the config the options above were just written beside —
# sudo would drop it otherwise. CI builds take the sudo branch; a workstation
# running the harness takes the other.
makepkg_argv() {
    local dir=$1
    local -a cmd=()
    [[ $BUILD_USER == "$(id -un)" ]] || cmd=(sudo -u "$BUILD_USER")
    # shellcheck disable=SC2016  # $1 is the inner bash's argument, not ours
    cmd+=(env "PKGDEST=$dir" "MAKEPKG_CONF=$MAKEPKG_CONF" \
        bash -c 'cd "$1" && makepkg --syncdeps --noconfirm --force' _ "$dir")
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

wire_makepkg_options
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
