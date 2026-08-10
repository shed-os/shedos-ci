# shedos-ci

The CI every ShedOS package repository runs. One reusable workflow lives here,
so a package repo carries a twelve-line caller instead of its own pipeline, and
a change to how packages are built is a change to this repo alone.

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

**test** — `scripts/run-tests.sh` runs every `test/*/run.sh` in the package
repo as the unprivileged `tester` user and fails if any of them fails. A repo
with no suites prints `no test suites` and passes. Set `privileged_tests: true`
if the suites need loop devices or mounts.

Each suite gets an outcome line, and the run ends on
`N passed, M skipped, K failed`. A suite that exits clean after printing a skip
marker counts as `SKIP`, not as a pass: suites bow out when an optional
dependency is missing, and a rollup that reads those as tested is how a package
ships with its own suite never having run. A skip does not fail the job — it
just cannot pass for coverage. Whatever the suites need beyond `base-devel`,
`git`, `sudo` and `jq` goes in `test_packages`.

**publish-request** — on a push to `main` only, downloads the artifact, reads
`dist/SHA256SUMS`, and fires a `publish-request` repository dispatch at
`shed-os/shedos-release`. Nothing is signed or uploaded here; publishing
happens only in shedos-release.

All three jobs run in the same `archlinux:latest` container, publish-request
included even though it only calls an API. It is there so the tools the scripts
call are the versions the harness tests against: on the bare runner this job
found a `jq` a major version behind, and a program that compiled everywhere
else was a syntax error under it.

## Adopting it

Copy `templates/caller.yml` into the package repo as
`.github/workflows/ci.yml`. Set `packages` to the directories holding
PKGBUILDs — `'["."]'` for a repo with one package at its root.

The caller has to pass `SHEDOS_DISPATCH_TOKEN` by name; the pipeline declares
it as a required secret rather than taking whatever `secrets: inherit` hands
over, so a repo that forgets it is told at the top of the run instead of at the
publish step. The token is an organisation secret scoped to selected
repositories — the package repos and shedos-release — not one visible to every
repo in the org.

`ci_ref` picks the shedos-ci ref the pipeline scripts come from, `main` by
default. Nothing in a reusable workflow can see the ref it was called at, so a
caller pinning `package-pipeline.yml@v1` has to pass `ci_ref: v1` as well or it
will run v1's workflow with main's scripts.

`test_packages` is a space-separated list of extra pacman packages to install
in the test job — `'python-pytest scdoc'` and so on. The job installs
`base-devel git sudo jq` on its own and nothing else, so a suite reaching for
anything beyond that skips itself, and the rollup reports it as `SKIP` rather
than letting it pass for tested. The suites run as `tester`, an unprivileged
user in `wheel` with passwordless sudo, mirroring how they run on a
workstation; a suite that needs root has to ask for it.

`needs_network_build: true` marks a package whose build reaches the network —
a Rust or Node vendoring step, say. The container has network either way today,
so the flag changes nothing yet; it records which packages would break if the
build were sealed off, so tightening it later is not a hunt.

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
container, no root, nothing off this machine. It builds a fixture package,
drives the pkgrel guard against a hand-made staging database, serves a 404 and
refuses a connection on loopback to separate a first publish from a broken one,
prints the makepkg invocation for both the sudo and the direct branch without
running either, rolls up stand-in suites that pass, fail and skip, and checks
the dispatch body against the contract above with a stubbed `gh`.

The loopback server records the request header, so the harness asserts the
staging-DB fetch names itself. Cloudflare's managed rules drop datacenter
traffic with no User-Agent, and a GitHub runner is a datacenter address: a
fetch that loses its UA answers 403 in CI while still working from a desk, and
the assertion is what keeps that from being found in production.

`.github/workflows/ci.yml` runs that harness and parses every workflow file on
every push and pull request, so the pipeline the package repos consume is gated
by the same suite.
