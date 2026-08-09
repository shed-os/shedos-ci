#!/usr/bin/env bash
# Exercises the pipeline scripts on a normal workstation: no container, no
# root, no network. Every case works in a throwaway directory, builds the
# hello fixture as the invoking user (SHEDOS_BUILD_USER) and points the
# staging-DB lookup at a file:// URL, so nothing here reaches the real repo.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
fixture="$here/fixtures/hello"

pass=0
fail=0
failed=()

check() {
    local name=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        printf '  ok   %s\n' "$name"
    else
        fail=$((fail + 1))
        failed+=("$name")
        printf '  FAIL %s\n' "$name"
    fi
}

# Joins argv with a separator no argument can contain, so a comparison
# cannot be fooled by an element that holds spaces.
join_argv() {
    local IFS=$'\x1f'
    printf '%s' "$*"
}

fixture_repo() {
    local work=$1
    cp "$fixture/PKGBUILD" "$work/PKGBUILD"
    git -C "$work" init -q -b main
    git -C "$work" add PKGBUILD
    git -C "$work" \
        -c user.name=harness -c user.email=harness@shedos.invalid \
        commit -qm 'add the fixture'
}

build_package() {
    local work=$1
    local db_url=$2
    (
        cd "$work" || exit 1
        SHEDOS_STAGING_DB_URL="$db_url" \
        SHEDOS_BUILD_USER="$(id -un)" \
            bash "$repo_root/scripts/build-package.sh" '["."]'
    ) > "$work/build.log" 2>&1
}

# The argv build-package.sh would hand to makepkg for $2, one element per
# line, without running any of it.
dry_run_argv() {
    local work=$1 build_user=$2
    (
        cd "$work" || exit 1
        SHEDOS_DRY_RUN=1 SHEDOS_BUILD_USER="$build_user" \
            bash "$repo_root/scripts/build-package.sh" '["."]'
    ) | sed -n 's/^argv: //p'
}

# python's http.server on a free port, so the 404 path is exercised over the
# protocol the real staging DB is served with. -u because the banner we read
# the port from would otherwise sit in a block buffer. Sets http_server_pid
# and http_server_port; the banner is only printed once the socket listens.
http_server_pid=""
http_server_port=""
start_http_server() {
    local root=$1 log=$2
    (cd "$root" && exec python3 -u -m http.server 0 --bind 127.0.0.1) > "$log" 2>&1 &
    http_server_pid=$!
    http_server_port=""
    for _ in $(seq 1 50); do
        http_server_port=$(sed -n 's/.*port \([0-9]\{1,\}\).*/\1/p' "$log" | head -1)
        [[ -n $http_server_port ]] && break
        sleep 0.1
    done
}

# --- case: a missing staging DB is the first-publish path, and the build
# lands exactly one package plus its checksum file in dist/.
case_build() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    cp "$fixture/PKGBUILD" "$work/PKGBUILD"
    if ! build_package "$work" 'file:///nonexistent'; then
        cat "$work/build.log"
        return 1
    fi

    check 'logs the absent staging DB' \
        grep -qF 'staging DB absent — first publish' "$work/build.log"

    local listing
    listing=$(find "$work/dist" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
    check 'dist holds the package and SHA256SUMS' \
        [ "$listing" = 'SHA256SUMS shedos-ci-hello-1-1-any.pkg.tar.zst ' ]

    check 'recorded hash matches the package' \
        bash -c "cd '$work/dist' && sha256sum --quiet -c SHA256SUMS"
}

# --- case: a staging DB that already carries this pkgver-pkgrel bumps the
# PKGBUILD and records the bump as a commit.
case_pkgrel_guard() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    fixture_repo "$work"

    mkdir -p "$work/db/shedos-ci-hello-1-1"
    : > "$work/db/shedos-ci-hello-1-1/desc"
    tar -czf "$work/staging.db" -C "$work/db" shedos-ci-hello-1-1

    if ! build_package "$work" "file://$work/staging.db"; then
        cat "$work/build.log"
        return 1
    fi

    check 'PKGBUILD moved to the first free pkgrel' \
        grep -qx 'pkgrel=2' "$work/PKGBUILD"

    local subject
    subject=$(git -C "$work" log -1 --format=%s)
    check 'bump is committed' \
        [ "$subject" = 'chore(release): bump pkgrel for shedos-ci-hello' ]

    check 'the bumped package is what got built' \
        [ -f "$work/dist/shedos-ci-hello-1-2-any.pkg.tar.zst" ]
}

# --- case: a decimal pkgrel must move forward, never back to its integer part.
case_decimal_pkgrel() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    fixture_repo "$work"
    sed -i 's/^pkgrel=.*/pkgrel=1.1/' "$work/PKGBUILD"
    git -C "$work" \
        -c user.name=harness -c user.email=harness@shedos.invalid \
        commit -qam 'go decimal'

    mkdir -p "$work/db/shedos-ci-hello-1-1.1"
    : > "$work/db/shedos-ci-hello-1-1.1/desc"
    tar -czf "$work/staging.db" -C "$work/db" shedos-ci-hello-1-1.1

    if ! build_package "$work" "file://$work/staging.db"; then
        cat "$work/build.log"
        return 1
    fi

    check 'decimal pkgrel bumps forward' \
        grep -qx 'pkgrel=2' "$work/PKGBUILD"
}

# --- case: the invocation CI actually uses runs through sudo, which this box
# cannot execute, so assert the argv both branches construct instead.
case_makepkg_argv() {
    local root work
    root=$(mktemp -d) || return 1
    trap 'rm -rf "$root"' RETURN

    # A space in the path so a lost quote shows up as an extra argv element
    # rather than passing unnoticed.
    work="$root/pkg dir"
    mkdir -p "$work"
    cp "$fixture/PKGBUILD" "$work/PKGBUILD"
    local dir script
    dir=$(cd "$work" && pwd)
    # shellcheck disable=SC2016  # the literal script build-package.sh passes
    script='cd "$1" && makepkg --syncdeps --noconfirm --force'

    local -a got want
    mapfile -t got < <(dry_run_argv "$work" "$(id -un)")
    want=(env "PKGDEST=$dir" bash -c "$script" _ "$dir")
    check 'workstation argv is seven words' [ "${#got[@]}" -eq 7 ]
    check 'workstation argv matches' \
        [ "$(join_argv "${got[@]}")" = "$(join_argv "${want[@]}")" ]

    mapfile -t got < <(dry_run_argv "$work" builder)
    want=(sudo -u builder env "PKGDEST=$dir" bash -c "$script" _ "$dir")
    check 'sudo argv keeps PKGDEST as one word' [ "${#got[@]}" -eq 10 ]
    check 'sudo argv matches' \
        [ "$(join_argv "${got[@]}")" = "$(join_argv "${want[@]}")" ]
}

# --- case: over HTTP an absent staging DB arrives as a 404, and that is still
# the first-publish path.
case_staging_db_404() {
    local work
    work=$(mktemp -d) || return 1
    trap 'kill "$http_server_pid" 2>/dev/null; rm -rf "$work"' RETURN

    cp "$fixture/PKGBUILD" "$work/PKGBUILD"
    mkdir -p "$work/srv"

    start_http_server "$work/srv" "$work/httpd.log"
    if [[ -z $http_server_port ]]; then
        cat "$work/httpd.log"
        return 1
    fi

    if ! build_package "$work" "http://127.0.0.1:$http_server_port/missing/shedos.db"; then
        cat "$work/build.log"
        return 1
    fi

    check 'HTTP 404 is the first-publish path' \
        grep -qF 'staging DB absent — first publish' "$work/build.log"
    check 'the build ran anyway' \
        [ -f "$work/dist/shedos-ci-hello-1-1-any.pkg.tar.zst" ]
}

# --- case: a staging DB we cannot read is not the same as one that is not
# there, and must stop the build instead of disarming the pkgrel guard.
case_staging_db_unusable() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    cp "$fixture/PKGBUILD" "$work/PKGBUILD"

    # Nothing listens on port 1, so this is a refused connection, not a 404.
    if build_package "$work" 'http://127.0.0.1:1/shedos.db'; then
        echo '   an unreachable staging DB did not stop the build'
        return 1
    fi
    check 'unreachable staging DB stops the build' \
        grep -qF 'cannot reach the staging DB' "$work/build.log"
    check 'nothing was published' [ ! -e "$work/dist/SHA256SUMS" ]

    printf 'not a database\n' > "$work/notadb"
    if build_package "$work" "file://$work/notadb"; then
        echo '   a corrupt staging DB did not stop the build'
        return 1
    fi
    check 'corrupt staging DB stops the build' \
        grep -qF 'not readable as a database' "$work/build.log"
}

# --- case: the dispatch body matches the contract the publisher consumes.
case_payload() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    mkdir -p "$work/bin" "$work/dist"
    cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_STUB_ARGV"
cat > "$GH_STUB_STDIN"
STUB
    chmod +x "$work/bin/gh"

    local pkg=shedos-ci-hello-1-1-any.pkg.tar.zst
    local sum=0000000000000000000000000000000000000000000000000000000000000001
    printf '%s  %s\n' "$sum" "$pkg" > "$work/dist/SHA256SUMS"

    if ! (
        cd "$work" || exit 1
        PATH="$work/bin:$PATH" \
        GH_STUB_ARGV="$work/argv" \
        GH_STUB_STDIN="$work/body.json" \
        GH_TOKEN=stub-token \
        GITHUB_REPOSITORY=shed-os/hello \
        GITHUB_RUN_ID=1 \
        GITHUB_SHA=abc \
            bash "$repo_root/scripts/request-publish.sh"
    ) > "$work/dispatch.log" 2>&1; then
        cat "$work/dispatch.log"
        return 1
    fi

    check 'dispatches to shedos-release' \
        grep -qx 'repos/shed-os/shedos-release/dispatches' "$work/argv"

    local want
    want=$(jq -n --arg pkg "$pkg" --arg sum "$sum" '{
        event_type: "publish-request",
        client_payload: {
            repo: "shed-os/hello",
            run_id: 1,
            sha: "abc",
            artifact: "pkg-abc",
            packages: [{file: $pkg, sha256: $sum}]
        }
    }')
    if ! jq -e --argjson want "$want" '. == $want' "$work/body.json" > /dev/null; then
        printf '   want: %s\n' "$(jq -c . <<<"$want")"
        printf '   got:  %s\n' "$(jq -c . "$work/body.json" 2>/dev/null || cat "$work/body.json")"
        return 1
    fi
    check 'payload matches the frozen contract' true
}

# --- case: without the dispatch secret the publish must stop and say so.
case_missing_secret() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    mkdir -p "$work/dist"
    : > "$work/dist/SHA256SUMS"

    local out rc
    out=$(
        cd "$work" || exit 1
        GH_TOKEN='' \
        GITHUB_REPOSITORY=shed-os/hello \
        GITHUB_RUN_ID=1 \
        GITHUB_SHA=abc \
            bash "$repo_root/scripts/request-publish.sh" 2>&1
    )
    rc=$?

    check 'missing secret fails the job' [ "$rc" -ne 0 ]
    check 'missing secret is named' grep -qF 'SHEDOS_DISPATCH_TOKEN' <<<"$out"
}

for case in case_build case_pkgrel_guard case_decimal_pkgrel case_makepkg_argv \
           case_staging_db_404 case_staging_db_unusable case_payload case_missing_secret; do
    printf '════════ %s ════════\n' "${case#case_}"
    if ! "$case"; then
        fail=$((fail + 1))
        failed+=("${case#case_}")
        printf '  FAIL %s (case aborted)\n' "${case#case_}"
    fi
    echo
done

printf '════════ %d checks passed, %d failed ════════\n' "$pass" "$fail"
if (( fail > 0 )); then
    printf 'failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
