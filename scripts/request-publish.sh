#!/usr/bin/env bash
# Ask shedos-release to publish the packages this run built. Nothing is
# signed or uploaded here: the request carries the artifact name and the
# checksums, and the publisher does the rest.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
: "${GITHUB_SHA:?GITHUB_SHA is not set}"

SUMS=${SHEDOS_SUMS_FILE:-dist/SHA256SUMS}
# What tree each package was built from, written by build-package.sh. The run's
# own sha is the commit it was triggered at, which is the parent of the build
# whenever the pkgrel guard bumped, so the two are different facts and the
# request carries both.
COMMITS=${SHEDOS_BUILD_COMMITS_FILE:-dist/BUILD_COMMITS}

if [[ -z ${GH_TOKEN:-} ]]; then
    echo "SHEDOS_DISPATCH_TOKEN is missing — cannot ask shedos-release to publish" >&2
    exit 1
fi

if [[ ! -s $SUMS ]]; then
    echo "$SUMS is missing or empty — nothing to publish" >&2
    exit 1
fi

payload=$(mktemp)
trap 'rm -f "$payload"' EXIT

# The build commit rides beside each package rather than at the top of the
# payload, because one run can build several packages and bump them one at a
# time. A run with no record of them says nothing rather than guessing: the
# field is absent and the payload is the one this has always sent.
packages=$(awk -v commits="$COMMITS" '
    BEGIN {
        while ((getline line < commits) > 0) {
            split(line, f, "\t")
            if (f[1] != "") built[f[1]] = f[2]
        }
    }
    NF {
        file = $NF
        name = file
        sub(/-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$/, "", name)
        print file "\t" $1 "\t" (name in built ? built[name] : "")
    }' "$SUMS" \
    | jq -Rn '[inputs | split("\t")
               | {file: .[0], sha256: .[1]}
                 + (if .[2] == "" then {} else {build_sha: .[2]} end)]')

# Written to a file rather than piped into gh: a jq that fails to compile the
# program still leaves gh running on the other end of a pipe, and a broken
# payload reaches the API as an empty body. The concatenation is parenthesized
# because jq 1.7 rejects a bare + as an object value and 1.8 does not — the
# unparenthesized form works on a workstation and breaks on a runner.
jq -n \
    --arg repo "$GITHUB_REPOSITORY" \
    --argjson run_id "$GITHUB_RUN_ID" \
    --arg sha "$GITHUB_SHA" \
    --argjson packages "$packages" \
    '{event_type: "publish-request",
      client_payload: {
          repo: $repo,
          run_id: $run_id,
          sha: $sha,
          artifact: ("pkg-" + $sha),
          packages: $packages
      }}' > "$payload"

gh api "repos/shed-os/shedos-release/dispatches" --method POST --input "$payload"

echo "publish requested for $GITHUB_REPOSITORY@$GITHUB_SHA"
