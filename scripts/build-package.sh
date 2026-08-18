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

# Only two answers are safe: the DB says which releases are taken, or it
# demonstrably does not exist yet. Anything else would disarm the pkgrel guard
# and publish over a release that is already out there.
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

# Sourcing is what makepkg does too; the subshell keeps the variables out of
# this script.
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

# The tag a source pins itself to, empty for every other kind of source. The
# fragment is read after sourcing, so $pkgver has already been substituted.
pkgbuild_source_tag() {
    local dir=$1
    (
        set +eu
        # shellcheck source=/dev/null
        source "$dir/PKGBUILD" > /dev/null 2>&1
        local entry
        for entry in "${source[@]}"; do
            case $entry in
                *'#tag='*) printf '%s\n' "${entry##*#tag=}"; return ;;
            esac
        done
    )
}

# Directories this pipeline reads from the checkout rather than from the tag:
# the suites it runs and the workflow that is running. Derived rather than
# assumed — a PKGBUILD that installs out of one of them is reading it from the
# tag after all, and then it is not exempt. The match is on the directory name
# as a whole path component, so a `latest/` in the PKGBUILD is not a `test/`.
checkout_owned_roots() {
    local dir=$1 root pattern
    for root in test .github; do
        # The name goes into an ERE, so its dots are escaped: .github must not
        # match "signature/" through a wildcard and quietly stop exempting it.
        pattern=${root//./\\.}
        grep -qE "(^|[^A-Za-z0-9_.-])$pattern/" "$dir/PKGBUILD" || printf '%s\n' "$root"
    done
}

# What a package built out of a workspace reads from above its own directory.
# Cargo resolves a member against the manifest at the workspace root and the
# lock beside it, so a root that moved past the tag builds a member this
# checkout does not describe — and the diff below is scoped to the package
# directory, which cannot see a file outside it. Derived rather than assumed:
# the root has to declare a workspace and the package has to hold a crate that
# could be in one.
workspace_root_files() {
    local dir=$1 root declared
    root=$(git -C "$dir" rev-parse --show-toplevel) || return 0
    [[ $root != "$dir" ]] || return 0
    # Either side declaring a workspace arms this, and the table header is
    # matched as a line rather than as exact text: a root manifest deleted
    # past the tag, or a comment written after `[workspace]`, would otherwise
    # answer the question with silence. Called after the fetch, so FETCH_HEAD
    # is the tag.
    # Read into one string first: `grep -q` stops at the first match, and a
    # writer killed by that would fail the pipeline under pipefail and read as
    # a repository with no workspace in it.
    declared=$( { cat "$root/Cargo.toml"; git -C "$dir" show FETCH_HEAD:Cargo.toml; } 2> /dev/null )
    grep -qE '^[[:space:]]*\[workspace\][[:space:]]*(#.*)?$' <<<"$declared" || return 0
    [[ -n $(find "$dir" -name Cargo.toml -print -quit) ]] || return 0
    # Named whether or not they are here now. A lock the checkout deleted is a
    # difference the diff can only report if it is asked about the path.
    printf '%s\n' Cargo.toml Cargo.lock
}

# Where the checkout differs from the tag the build will use, one path per line.
# The PKGBUILD and its install scriptlet never count, because makepkg reads both
# from the checkout: the pkgrel guard's own bump moves the PKGBUILD every time
# and it is not lag. Neither do the directories above, for the same reason —
# and without that, a package whose pkgver is pinned to the monolith's has no
# way to answer a test-only refusal, because a new tag name means a new pkgver
# means a parity failure. What the workspace root holds counts the other way:
# it is outside the package directory and the build reads it from the tag like
# any source file. Exit 1 means the tag could not be read at all.
source_tag_divergence() {
    local dir=$1 tag=$2
    local prefix install_file path root exempt up climb
    local -a roots=()

    git -C "$dir" fetch --quiet "$PUSH_REMOTE" "refs/tags/$tag" 2> /dev/null || return 1

    prefix=$(git -C "$dir" rev-parse --show-prefix)
    install_file=$(pkgbuild_field "$dir" install)
    mapfile -t exempt < <(checkout_owned_roots "$dir")

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        path=${path#"$prefix"}
        [[ $path == PKGBUILD ]] && continue
        [[ -n $install_file && $path == "$install_file" ]] && continue
        for root in "${exempt[@]}"; do
            [[ $path == "$root"/* ]] && continue 2
        done
        printf '%s\n' "$path"
    done < <(git -C "$dir" diff --name-only FETCH_HEAD HEAD -- .)

    mapfile -t roots < <(workspace_root_files "$dir")
    (( ${#roots[@]} > 0 )) || return 0

    # Named from the package's own point of view, like every path above.
    up='' climb=$prefix
    while [[ -n $climb ]]; do up+=../; climb=${climb#*/}; done

    while IFS= read -r path; do
        [[ -n $path ]] || continue
        printf '%s%s\n' "$up" "$path"
    done < <(git -C "$dir" diff --name-only FETCH_HEAD HEAD -- "${roots[@]/#/:/}")
}

# A source pinned to a tag is built from the tag, never from the checkout the
# PKGBUILD sits in. A change that lands on the branch with the tag left where it
# was builds green and publishes the old tree — a release nobody can tell apart
# from the one they asked for. So the build that publishes says so and stops.
guard_source_tag() {
    local dir=$1 pkgname=$2 tag=$3
    local -a lagging=()
    local moved

    # Captured rather than piped: a process substitution reports the exit
    # status of the reader, so a tag that could not be read would look like a
    # tag nothing had moved past.
    if ! moved=$(source_tag_divergence "$dir" "$tag"); then
        echo "$pkgname cannot read tag $tag from $PUSH_REMOTE" >&2
        exit 1
    fi
    [[ -z $moved ]] || mapfile -t lagging <<<"$moved"

    if (( ${#lagging[@]} > 0 )); then
        echo "$pkgname builds from tag $tag but ${lagging[*]} moved since — re-cut the tag" >&2
        exit 1
    fi
}

# The same question asked of a build that publishes nothing, which is the only
# lane the guard above is off in. Its answer is printed and never enforced: a
# pull request cannot tag what it has not merged, so lag is not its fault. But a
# green run that never said which tree it built is how a change gets read as
# tested when the tag was built in its place.
note_source_tag() {
    local dir=$1 pkgname=$2 tag=$3
    local -a lagging=()
    local moved

    if ! moved=$(source_tag_divergence "$dir" "$tag"); then
        echo "$pkgname builds from tag $tag, which $PUSH_REMOTE does not carry"
        return 0
    fi
    [[ -z $moved ]] || mapfile -t lagging <<<"$moved"

    if (( ${#lagging[@]} > 0 )); then
        echo "$pkgname builds from tag $tag and this checkout differs at: ${lagging[*]}"
    else
        echo "$pkgname builds from tag $tag, which is this checkout"
    fi
}

# The artifact carries the new release, so a checkout left on the old one
# describes a package nobody can get. A push that does not land is that same
# divergence reached quietly, so it stops the build. Pushing is off until told:
# a pull request builds a merge of the branch into main, and pushing that would
# merge the pull request.
#
# The push goes out with the job's GITHUB_TOKEN and has to keep going out with
# it. A push made with that token starts no workflow run, and a run started
# from here would find in staging the release it had just published, bump
# again, push again, with nothing anywhere to stop it. A PAT or a GitHub App
# token — the usual way past a protected main — does start that run, so a
# package repo that protects main cannot use this guard as it stands: bump
# pkgrel by hand there, never hand the job a stronger token.

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

    # The bump goes out only if it sits on what main is right now: a merge
    # checkout puts something main has never seen underneath it, and a main
    # that moved mid-build is the same divergence.
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
# the same source, or the equivalence check reads every rebuilt object as a
# difference: stock makepkg leaves `debug` on, which appends -C debuginfo=2 to
# RUSTFLAGS, moves cargo's metadata hash and renames every path under a crate's
# target directory. The drop-in goes beside the config makepkg reads so it
# holds for every caller and can be pointed at a scratch config.
wire_makepkg_options() {
    install -d "$MAKEPKG_CONF.d"
    cat > "$MAKEPKG_CONF.d/99-shedos.conf" <<'EOF'
BUILDENV=(!distcc color !check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
MAKEFLAGS="-j$(nproc)"
EOF
}

# The date a build stamps into what it renders. scdoc writes it into every man
# page's .TH line, so without one the same release built either side of
# midnight is different bytes. It comes from the commit the package is built
# from — the tag when the source pins one, the checkout otherwise — so a
# rebuild of a release matches the release however long after it runs.
build_epoch=""
commit_epoch() {
    local dir=$1 tag=$2 rev=HEAD
    if [[ -n $tag ]] \
        && git -C "$dir" fetch --quiet "$PUSH_REMOTE" "refs/tags/$tag" 2> /dev/null; then
        rev=FETCH_HEAD
    fi
    # A package directory outside a repository has no commit to be dated from,
    # and answering with the clock is the whole thing being avoided here.
    git -C "$dir" log -1 --format=%ct "$rev" 2> /dev/null || return 0
}

# NUL-separated, so the dry run and the real one see the same argv. PKGDEST
# pins the output next to the PKGBUILD whatever the host makepkg.conf says, and
# MAKEPKG_CONF names the config the options above were written beside — sudo
# would drop it otherwise.
makepkg_argv() {
    local dir=$1
    local -a cmd=() stamp=()
    [[ $BUILD_USER == "$(id -un)" ]] || cmd=(sudo -u "$BUILD_USER")
    [[ -z $build_epoch ]] || stamp=("SOURCE_DATE_EPOCH=$build_epoch")
    # shellcheck disable=SC2016  # $1 is the inner bash's argument, not ours
    cmd+=(env "${stamp[@]}" "PKGDEST=$dir" "MAKEPKG_CONF=$MAKEPKG_CONF" \
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

# Prints what each package would be built with and stops: the build itself
# needs a container and a build user.
if [[ -n ${SHEDOS_DRY_RUN:-} ]]; then
    for dir in "${dirs[@]}"; do
        dir=$(cd -- "$dir" && pwd)
        build_epoch=$(commit_epoch "$dir" "$(pkgbuild_source_tag "$dir")")
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

    # Before the pkgrel guard, so a lagging tag is not answered with a bump
    # commit pushed for a build that then stops. Keyed off the same question
    # the bump is: is this the build whose packages get published. A pull
    # request cannot tag what it has not merged and publishes nothing.
    source_tag=$(pkgbuild_source_tag "$dir")
    if [[ -n $source_tag ]]; then
        if [[ $PUSH_BUMP == true ]]; then
            guard_source_tag "$dir" "$pkgname" "$source_tag"
        else
            note_source_tag "$dir" "$pkgname" "$source_tag"
        fi
    fi

    # Before the pkgrel guard too: its bump is a commit made while the build
    # runs, and dating the package from that one is dating it from the clock.
    build_epoch=$(commit_epoch "$dir" "$source_tag")

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
