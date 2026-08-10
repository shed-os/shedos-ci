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

On a push to `main` that bump is pushed back to the package repo before
anything is built, and a push that does not land stops the build. The artifact
carries the new release, so a repo left on the old one describes a package
nobody can get. Nothing is pushed from a pull request build:
`pull_request` checks out a merge of the branch into `main`, and pushing that
would merge the pull request. The bump still happens there, it just stays in
the checkout. The push is refused outright unless the bump sits on what the
remote's `main` is at that moment, so a checkout that is not `main` — or a
`main` that moved mid-build — stops the build instead of pushing.

That push goes out with the job's `GITHUB_TOKEN`, and it has to keep going out
with it. A push made with that token starts no workflow run, and that is the
only thing standing between this guard and a loop with no end: a run started by
the bump would find the release it had just published sitting in staging, bump
again and push again. A personal access token or a GitHub App token does start
that run. So a package repo that protects `main` cannot use the pipeline as it
stands — the push is refused, the build goes red, and the answer is to lift the
protection or move `pkgrel` by hand, never to hand the job a stronger token.

**test** — `scripts/run-tests.sh` runs every `test/*/run.sh` in the package
repo as the unprivileged `tester` user and fails if any of them fails. A suite
directory holding a `needs-root` file is handed to `sudo` instead. A repo with
no suites prints `no test suites` and passes. Set `privileged_tests: true` if
the suites need loop devices or mounts — a privileged container does not make
an unprivileged user root, so the suite still needs the `needs-root` marker.

Each suite gets an outcome line, the root lane marked `(root)`, and the run
ends on `N passed, M skipped(allowed), K failed`. A suite that exits clean
after printing a skip marker counts as `SKIP`, not as a pass: suites bow out
when an optional dependency is missing, and a rollup that reads those as tested
is how a package ships with its own suite never having run. A skip passes the
job only if the caller named that suite in `allowed_skips`; any other skip
fails it, so no suite stops running without someone deciding it could. Whatever
the suites need beyond `base-devel`, `git`, `sudo` and `jq` goes in
`test_packages`, and whatever they read out of the environment goes in
`test_env`.

**publish-request** — on a push to `main` only, downloads the artifact, reads
`dist/SHA256SUMS`, and fires a `publish-request` repository dispatch at
`shed-os/shedos-release`. Nothing is signed or uploaded here; publishing
happens only in shedos-release.

All three jobs run in the same `archlinux:latest` container, publish-request
included even though it only calls an API. It is there so the tools the scripts
call are the versions the harness tests against: on the bare runner this job
found a `jq` a major version behind, and a program that compiled everywhere
else was a syntax error under it.

## Build parity

Before anything is built, `scripts/build-package.sh` writes a makepkg drop-in
next to the config makepkg reads:

```
BUILDENV=(!distcc color !check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
MAKEFLAGS="-j$(nproc)"
```

These are the options the ShedOS monolith's CI builds with, and a package built
here has to record the same `buildenv` and `options` in its `.BUILDINFO`,
because a carved package is signed off by comparing it against the monolith's
own build of the same source. Stock makepkg leaves `debug` on, which appends
`-C debuginfo=2` to `RUSTFLAGS`; that moves cargo's metadata hash, renames every
path under a crate's target directory, and the comparison then reports thousands
of differences that have nothing to do with the carve. `!check` matches the
monolith too, and `!sign` costs nothing here — the pipeline never signs, the
publisher does.

There is nothing to opt into and no way out: a package repo that chose its own
build options would stop being comparable, which is the one thing the carve
depends on. `MAKEPKG_CONF` names the config the drop-in is written beside,
`/etc/makepkg.conf` unless something says otherwise — the harness points it at a
scratch copy, which is how it asserts what a fixture package records without
writing into the machine's `/etc`.

## Adopting it

Copy `templates/caller.yml` into the package repo as
`.github/workflows/ci.yml`. Set `packages` to the directories holding
PKGBUILDs — `'["."]'` for a repo with one package at its root.

The caller keeps the template's `permissions: contents: write`. That is what
the pkgrel bump is pushed with: a reusable workflow can only narrow the
permissions it was called with, never widen them, so the grant has to come from
the caller. Only the build job takes the write; the test and publish-request
jobs are declared `contents: read`.

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

A suite asks by leaving a file called `needs-root` next to its `run.sh`. That
suite alone runs as `sudo bash run.sh`, and its outcome line says `(root)` so
the log shows which lane each suite ran in. Nothing else changes lane, because
a suite that only ever runs as root stops proving anything about the machines
it ships to.

A new suite that has to bow out prints `SKIP: <reason>` on a line of its own.
The rollup also still reads the older phrasings the suites carved out of the
monolith use, but `SKIP:` is the convention to write.

`allowed_skips` is a JSON array of the suite names whose skip the repo accepts
— `'["rotation-drill"]'`. Those count in the tally as `skipped(allowed)`; a
skip from any other suite is a failure and its line reads
`SKIP (not allowed)`. An allowed skip is a named debt, not a way to mute a
suite.

`test_env` is newline-separated `KEY=VALUE` lines, put into every suite's
environment:

```yaml
      test_env: |
        SHEDOS_FIXTURE_ROOT=/tmp/fixtures
```

They are passed to each suite rather than exported around it, so the root lane
keeps them: `sudo` resets the environment, and a suite that quietly lost its
configuration is exactly the kind of pass the rollup exists to stop.

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

The fixture package repo has a bare repo as its `origin`, so the bump push is
asserted against a real remote: one new commit on a bump, an untouched head
when nothing bumped or the build is not the one publishing, a refusal naming
both commits when the bump does not sit on the remote's `main`, and a build
that stops before makepkg when the push cannot land. The harness also reads the
two copies of the publish condition out of `package-pipeline.yml` and fails if
they have drifted, since nothing else here can see a workflow file.

The root lane is asserted the same way the makepkg invocation is: `sudo` is a
stub on `PATH` that records how it was called and then runs the command as the
invoking user, so the harness proves the rollup reaches for sudo for the suite
that asked and no other, with the `test_env` assignments carried across. The
transition into root itself is proven live by the first `needs-root` suite,
which is the keyring repo's rotation drill.

The loopback server records the request header, so the harness asserts the
staging-DB fetch names itself. Cloudflare's managed rules drop datacenter
traffic with no User-Agent, and a GitHub runner is a datacenter address: a
fetch that loses its UA answers 403 in CI while still working from a desk, and
the assertion is what keeps that from being found in production.

`.github/workflows/ci.yml` runs that harness and parses every workflow file on
every push and pull request, so the pipeline the package repos consume is gated
by the same suite.
