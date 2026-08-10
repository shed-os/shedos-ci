#!/usr/bin/env bash
# Run every test/<suite>/run.sh in the package repo checkout and roll the
# results up. Run from the root of that checkout, as the unprivileged user the
# suites expect. A suite directory holding a `needs-root` file is handed to
# sudo instead; every other suite runs as the invoking user.
#
# A suite that exits clean after printing a skip marker is reported SKIP, not
# PASS. Suites bow out when an optional dependency is missing, and a rollup
# that counts those as tested is how a package ships with its own suite never
# having run. A skip passes the job only if the caller named the suite in
# allowed_skips; anything else stops the run, because a suite nobody decided
# could stop running has stopped running.
set -uo pipefail

# The convention every new suite writes: a line opening `SKIP: <reason>`. The
# rest are the phrasings the monolith's suites already use — the word SKIP in
# capitals anywhere in a line, a line opening with `skip` or `skip:`, or
# skipped/skipping. Bare lowercase `skip` only counts at the start of a line,
# and a hyphen or underscore either side disqualifies the word — a check called
# oversized-skipped is a check that ran, and a rollup that always says SKIP
# says nothing.
announced_a_skip() {
    grep -qE '^[[:space:]]*SKIP: ' "$1" && return 0
    grep -qE '(^|[^[:alnum:]_-])SKIP([^[:alnum:]_-]|$)' "$1" ||
        grep -qiE '^[[:space:]]*skip[[:space:]:]|(^|[^[:alnum:]_-])skipp(ed|ing)([^[:alnum:]_-]|$)' "$1"
}

allowed=()
allowed_skips=${ALLOWED_SKIPS:-}
if [[ -n ${allowed_skips//[[:space:]]/} && ${allowed_skips//[[:space:]]/} != '[]' ]]; then
    if ! names=$(jq -r 'if type == "array" then .[] else
            "not a JSON array" | halt_error end' <<<"$allowed_skips" 2>&1); then
        printf 'allowed_skips takes a JSON array of suite names: %s\n' "$names" >&2
        exit 1
    fi
    while IFS= read -r name; do
        [[ -n $name ]] && allowed+=("$name")
    done <<<"$names"
fi

is_allowed() {
    local name
    for name in "${allowed[@]}"; do
        [[ $name == "$1" ]] && return 0
    done
    return 1
}

# The caller's test_env, one KEY=VALUE per line. They are passed to each suite
# rather than exported here, because sudo resets the environment on the way
# into the root lane and a suite that silently lost its configuration is the
# kind of pass this whole script exists to stop.
assignments=()
while IFS= read -r line; do
    [[ -n ${line//[[:space:]]/} ]] || continue
    if [[ ! $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        printf 'test_env takes KEY=VALUE lines, one per line: %s\n' "$line" >&2
        exit 1
    fi
    assignments+=("$line")
done <<<"${TEST_ENV:-}"

shopt -s nullglob
runners=(test/*/run.sh)
if (( ${#runners[@]} == 0 )); then
    echo "no test suites"
    exit 0
fi

pass=0
skip=0
fail=0
failed=()

log=$(mktemp)
trap 'rm -f "$log"' EXIT

for runner in "${runners[@]}"; do
    suite=$(basename "$(dirname "$runner")")

    lane=()
    lane_note=""
    if [[ -f $(dirname "$runner")/needs-root ]]; then
        lane=(sudo)
        lane_note=' (root)'
    fi
    if (( ${#assignments[@]} > 0 )); then
        lane+=(env "${assignments[@]}")
    fi

    printf '════════ %s%s ════════\n' "$suite" "$lane_note"

    outcome=PASS
    # A failing suite is FAIL whatever else it printed — a suite that skipped
    # one check and then broke on another has not been skipped.
    "${lane[@]}" bash "$runner" 2>&1 | tee "$log" || outcome=FAIL
    if [[ $outcome == PASS ]] && announced_a_skip "$log"; then
        outcome=SKIP
    fi

    case $outcome in
        PASS) pass=$((pass + 1)) ;;
        SKIP)
            if is_allowed "$suite"; then
                skip=$((skip + 1))
            else
                outcome='SKIP (not allowed)'
                fail=$((fail + 1))
                failed+=("$suite")
            fi
            ;;
        FAIL) fail=$((fail + 1)); failed+=("$suite") ;;
    esac
    printf '%s %s%s\n\n' "$outcome" "$suite" "$lane_note"
done

printf '════════ %d passed, %d skipped(allowed), %d failed ════════\n' \
    "$pass" "$skip" "$fail"
if (( fail > 0 )); then
    printf 'failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
