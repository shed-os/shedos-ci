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

# --- case: the staging entry is matched literally. A pkgrel carrying a dot
# read as a regex would match a release nobody published and bump off a free
# one.
case_pkgrel_literal_match() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    fixture_repo "$work"
    sed -i 's/^pkgrel=.*/pkgrel=1.1/' "$work/PKGBUILD"

    # Differs from shedos-ci-hello-1-1.1 in one character, where the dot is.
    mkdir -p "$work/db/shedos-ci-hello-1-1X1"
    : > "$work/db/shedos-ci-hello-1-1X1/desc"
    tar -czf "$work/staging.db" -C "$work/db" shedos-ci-hello-1-1X1

    if ! build_package "$work" "file://$work/staging.db"; then
        cat "$work/build.log"
        return 1
    fi

    check 'a near-miss staging entry does not bump' \
        grep -qx 'pkgrel=1.1' "$work/PKGBUILD"
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

# A package repo checkout holding one suite, whose run.sh is the given body.
# Every suite touches a sentinel first, so a suite the rollup never reached
# can be told apart from one that ran and said nothing.
make_suite() {
    local work=$1 name=$2 body=$3
    mkdir -p "$work/test/$name"
    cat > "$work/test/$name/run.sh" <<EOF
#!/usr/bin/env bash
: > "\$SENTINEL_DIR/$name"
$body
EOF
}

# The rollup over those suites, output in $rollup_out and status in $rollup_rc.
rollup_out=""
rollup_rc=0
run_rollup() {
    local work=$1
    mkdir -p "$work/ran"
    rollup_rc=0
    rollup_out=$(
        cd "$work" || exit 1
        SENTINEL_DIR="$work/ran" bash "$repo_root/scripts/run-tests.sh" 2>&1
    ) || rollup_rc=$?
}

# --- case: every suite passing is a clean rollup that says so once per suite.
case_rollup_all_pass() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    make_suite "$work" a-first 'echo "a-first: 3 checks passed"'
    make_suite "$work" b-second 'echo "b-second: 1 check passed"'
    run_rollup "$work"

    check 'a clean rollup exits zero' [ "$rollup_rc" -eq 0 ]
    check 'the suite output is in the log' \
        grep -qF 'a-first: 3 checks passed' <<<"$rollup_out"
    check 'each suite gets an outcome line' \
        bash -c "grep -qx 'PASS a-first' <<<\"\$1\" && grep -qx 'PASS b-second' <<<\"\$1\"" _ "$rollup_out"
    check 'the tally counts both' \
        grep -qF '2 passed, 0 skipped, 0 failed' <<<"$rollup_out"
}

# --- case: one failing suite fails the job without cutting the run short —
# the suite after it still has to run, or a second defect rides out on the
# fix for the first.
case_rollup_failure() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    make_suite "$work" a-pass 'echo "a-pass: fine"'
    make_suite "$work" b-fail 'echo "b-fail: broke"; exit 1'
    make_suite "$work" c-pass 'echo "c-pass: fine"'
    run_rollup "$work"

    check 'a failing suite fails the job' [ "$rollup_rc" -ne 0 ]
    check 'the suite after the failure still ran' [ -e "$work/ran/c-pass" ]
    check 'the failure is the only one counted' \
        grep -qF '2 passed, 0 skipped, 1 failed' <<<"$rollup_out"
    check 'the failing suite is named' grep -qF 'failed: b-fail' <<<"$rollup_out"
}

# --- case: a repo with no suites is not a failure, and says why it passed.
case_rollup_no_suites() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    run_rollup "$work"

    check 'no suites is a pass' [ "$rollup_rc" -eq 0 ]
    check 'and it is stated' grep -qx 'no test suites' <<<"$rollup_out"
}

# --- case: a suite that bowed out is reported as skipped, never as passed. It
# exits zero either way, so the marker in its output is the only thing that
# keeps it from counting as coverage it did not deliver. The third suite is
# named for the word and reports a check that is too — both real shapes, both
# from suites that ran everything. A rollup that reads those as markers would
# report SKIP forever and stop meaning anything.
case_rollup_skip() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN

    make_suite "$work" widget 'echo "widget: SKIP (missing losetup)"'
    make_suite "$work" x-gadget 'echo "skip T4_needs_zsh (zsh not installed)"'
    make_suite "$work" skip-list 'printf "PASS oversized-skipped\nskip-list: 3 checks passed\n"'
    run_rollup "$work"

    check 'a skipped suite does not fail the job' [ "$rollup_rc" -eq 0 ]
    check 'a capitalised marker is caught' grep -qx 'SKIP widget' <<<"$rollup_out"
    check 'a line-opening marker is caught' grep -qx 'SKIP x-gadget' <<<"$rollup_out"
    check 'a suite named for the word still passes' \
        grep -qx 'PASS skip-list' <<<"$rollup_out"
    check 'the tally separates skips from passes' \
        grep -qF '1 passed, 2 skipped, 0 failed' <<<"$rollup_out"
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

for case in case_build case_pkgrel_guard case_decimal_pkgrel \
           case_pkgrel_literal_match case_makepkg_argv \
           case_staging_db_404 case_staging_db_unusable case_payload \
           case_payload_build_failure case_rollup_all_pass \
           case_rollup_failure case_rollup_no_suites case_rollup_skip \
           case_missing_secret; do
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
