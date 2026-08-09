# shedos-ci

The CI every ShedOS package repository runs. One reusable workflow lives here,
so a package repo carries a six-line caller instead of its own pipeline, and a
change to how packages are built is a change to this repo alone.

## What the pipeline does

**build** — an `archlinux:latest` container marks itself as a build environment
(`/.shedos-build-environment`) and strips any ShedOS repo fence from
`/etc/pacman.conf` before the first `pacman` call, so a ShedOS package that
lands as a build dependency cannot repoint the container at the production
repo. It then builds every directory listed in `packages` as the unprivileged
`builder` user and uploads `dist/` as `pkg-<sha>`.

Before each build, `scripts/build-package.sh` checks the staging database for
the package's `pkgver-pkgrel`. If that release is already published, it moves
`pkgrel` to the first free value and commits the change as
`chore(release): bump pkgrel for <pkgname>`. A missing staging database means
first publish, and the build carries on.

**test** — runs every `test/*/run.sh` in the package repo and fails if any of
them fails. A repo with no suites prints `no test suites` and passes. Set
`privileged_tests: true` if the suites need loop devices or mounts.

**publish-request** — on a push to `main` only, downloads the artifact, reads
`dist/SHA256SUMS`, and fires a `publish-request` repository dispatch at
`shed-os/shedos-release`. Nothing is signed or uploaded here; publishing
happens only in shedos-release.

## Adopting it

Copy `templates/caller.yml` into the package repo as
`.github/workflows/ci.yml`. Set `packages` to the directories holding
PKGBUILDs — `'["."]'` for a repo with one package at its root.

`secrets: inherit` is required: the publish request authenticates with
`SHEDOS_DISPATCH_TOKEN`, and without inheritance that secret arrives empty and
the job stops with a message naming it.

## The dispatch contract

```json
{"event_type": "publish-request",
 "client_payload": {"repo": "shed-os/<name>", "run_id": 0, "sha": "<commit>",
   "artifact": "pkg-<sha>",
   "packages": [{"file": "<name>-<ver>-<rel>-x86_64.pkg.tar.zst", "sha256": "<hex>"}]}}
```

shedos-release consumes these field names verbatim. Changing one is a change to
both repos at once.

## Tests

`bash test/pipeline/run.sh` exercises the scripts on a workstation — no
container, no root, no network. It builds a fixture package, drives the pkgrel
guard against a hand-made staging database, and checks the dispatch body
against the contract above with a stubbed `gh`.
