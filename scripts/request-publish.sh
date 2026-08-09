#!/usr/bin/env bash
# Ask shedos-release to publish the packages this run built. Nothing is
# signed or uploaded here: the request carries the artifact name and the
# checksums, and the publisher does the rest.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
: "${GITHUB_SHA:?GITHUB_SHA is not set}"

SUMS=${SHEDOS_SUMS_FILE:-dist/SHA256SUMS}

if [[ -z ${GH_TOKEN:-} ]]; then
    echo "SHEDOS_DISPATCH_TOKEN is missing — cannot ask shedos-release to publish" >&2
    exit 1
fi

if [[ ! -s $SUMS ]]; then
    echo "$SUMS is missing or empty — nothing to publish" >&2
    exit 1
fi

packages=$(awk 'NF {print $1 "\t" $NF}' "$SUMS" \
    | jq -Rn '[inputs | split("\t") | {file: .[1], sha256: .[0]}]')

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
          artifact: "pkg-" + $sha,
          packages: $packages
      }}' \
    | gh api "repos/shed-os/shedos-release/dispatches" --method POST --input -

echo "publish requested for $GITHUB_REPOSITORY@$GITHUB_SHA"
