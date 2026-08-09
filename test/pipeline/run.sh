#!/usr/bin/env bash
# Exercises the pipeline scripts on a normal workstation: no container, no
# root, nothing off this machine. Every case works in a throwaway directory,
# builds the hello fixture as the invoking user (SHEDOS_BUILD_USER) and points
# the staging-DB lookup at a file:// URL or a loopback server, so nothing here
# reaches the real repo.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
fixture_dir="$here/fixtures"
fixture="$fixture_dir/hello"

# Cloudflare's managed rules drop datacenter traffic with no User-Agent, so
# the staging-DB fetch has to name itself. This is the string it must send.
expected_ua='shedos-ci (+https://shedos.org)'

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

# Deep JSON comparison that does not go through jq, so the tool under test
# cannot vouch for its own output.
json_equal() {
    python3 -c 'import json, os, sys
for path in sys.argv[1:]:
    if not os.path.exists(path):
        print("   missing: " + path)
        sys.exit(1)
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
if a != b:
    print("   got:  " + json.dumps(a, sort_keys=True))
    print("   want: " + json.dumps(b, sort_keys=True))
    sys.exit(1)' "$1" "$2"
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

# The stand-in staging repo on a free port, so the 404 path is exercised over
# the protocol the real one is served with. Sets http_server_pid and
# http_server_port; the banner only prints once the socket listens.
http_server_pid=""
http_server_port=""
start_http_server() {
    local capture=$1 log=$2
    python3 "$fixture_dir/staging-db-server.py" "$capture" > "$log" 2>&1 &
    http_server_pid=$!
    http_server_port=""
    for _ in $(seq 1 50); do
        http_server_port=$(sed -n 's/^port \([0-9]\{1,\}\)$/\1/p' "$log" | head -1)
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

    start_http_server "$work/ua.txt" "$work/httpd.log"
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
    check 'the fetch names itself to the CDN' \
        [ "$(head -1 "$work/ua.txt" 2>/dev/null)" = "$expected_ua" ]
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
# The expected side is a literal below, never built with the jq program under
# test, and the comparison runs through python so a broken jq cannot make a
# mismatch look like a match.
case_payload() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    mkdir -p "$work/bin" "$work/dist"
    cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_STUB_ARGV"
: > "$GH_STUB_BODY"
prev=
for arg in "$@"; do
    [[ $prev == --input ]] && cp "$arg" "$GH_STUB_BODY"
    prev=$arg
done
STUB
    chmod +x "$work/bin/gh"

    local pkg=shedos-ci-hello-1-1-any.pkg.tar.zst
    local sum=0000000000000000000000000000000000000000000000000000000000000001
    printf '%s  %s\n' "$sum" "$pkg" > "$work/dist/SHA256SUMS"

    cat > "$work/expected.json" <<EOF
{"event_type": "publish-request",
 "client_payload": {"repo": "shed-os/hello", "run_id": 1, "sha": "abc",
   "artifact": "pkg-abc",
   "packages": [{"file": "$pkg", "sha256": "$sum"}]}}
EOF

    local rc=0
    (
        cd "$work" || exit 1
        PATH="$work/bin:$PATH" \
        GH_STUB_ARGV="$work/argv" \
        GH_STUB_BODY="$work/body.json" \
        GH_TOKEN=stub-token \
        GITHUB_REPOSITORY=shed-os/hello \
        GITHUB_RUN_ID=1 \
        GITHUB_SHA=abc \
            bash "$repo_root/scripts/request-publish.sh"
    ) > "$work/dispatch.log" 2>&1 || rc=$?
    (( rc == 0 )) || cat "$work/dispatch.log"

    check 'the dispatch exits clean' [ "$rc" -eq 0 ]
    check 'a body was actually written' [ -s "$work/body.json" ]
    check 'dispatches to shedos-release' \
        grep -qx 'repos/shed-os/shedos-release/dispatches' "$work/argv"
    check 'payload matches the frozen contract' \
        json_equal "$work/body.json" "$work/expected.json"
}

# --- case: a payload that cannot be built must stop before the API call, not
# hand an empty body to gh and let the server reject it.
case_payload_build_failure() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    mkdir -p "$work/bin" "$work/dist"
    cat > "$work/bin/jq" <<'STUB'
#!/usr/bin/env bash
echo 'jq: 1 compile error' >&2
exit 3
STUB
    cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_STUB_ARGV"
STUB
    chmod +x "$work/bin/jq" "$work/bin/gh"

    printf '%s  %s\n' \
        0000000000000000000000000000000000000000000000000000000000000001 \
        shedos-ci-hello-1-1-any.pkg.tar.zst > "$work/dist/SHA256SUMS"

    local rc=0
    (
        cd "$work" || exit 1
        PATH="$work/bin:$PATH" \
        GH_STUB_ARGV="$work/argv" \
        GH_TOKEN=stub-token \
        GITHUB_REPOSITORY=shed-os/hello \
        GITHUB_RUN_ID=1 \
        GITHUB_SHA=abc \
            bash "$repo_root/scripts/request-publish.sh"
    ) > "$work/dispatch.log" 2>&1 || rc=$?

    check 'a payload that will not build fails the job' [ "$rc" -ne 0 ]
    check 'and gh is never reached' [ ! -e "$work/argv" ]
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
           case_staging_db_404 case_staging_db_unusable case_payload \
           case_payload_build_failure case_missing_secret; do
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
