#!/usr/bin/env bash
# Run every test/<suite>/run.sh in the package repo checkout and roll the
# results up. Run from the root of that checkout, as the unprivileged user the
# suites expect.
#
# A suite that exits clean after printing a skip marker is reported SKIP, not
# PASS. Suites bow out when an optional dependency is missing, and a rollup
# that counts those as tested is how a package ships with its own suite never
# having run. A skip does not fail the job; it just cannot pass for coverage.
set -uo pipefail

# The marker forms the suites use: `SKIP: reason`, `skip: reason`,
# `<suite>: SKIP (reason)`, `skip <check> (reason)`, `<check> skipped`. Matched
# on a word boundary so a flag like --skippgpcheck in an echoed command line
# does not read as one.
SKIP_MARKER='(^|[^[:alnum:]])skip(s|ped|ping)?([^[:alnum:]]|$)'

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
    printf '════════ %s ════════\n' "$suite"

    outcome=PASS
    # A failing suite is FAIL whatever else it printed — a suite that skipped
    # one check and then broke on another has not been skipped.
    bash "$runner" 2>&1 | tee "$log" || outcome=FAIL
    if [[ $outcome == PASS ]] && grep -qEi "$SKIP_MARKER" "$log"; then
        outcome=SKIP
    fi

    case $outcome in
        PASS) pass=$((pass + 1)) ;;
        SKIP) skip=$((skip + 1)) ;;
        FAIL) fail=$((fail + 1)); failed+=("$suite") ;;
    esac
    printf '%s %s\n\n' "$outcome" "$suite"
done

printf '════════ %d passed, %d skipped, %d failed ════════\n' "$pass" "$skip" "$fail"
if (( fail > 0 )); then
    printf 'failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
