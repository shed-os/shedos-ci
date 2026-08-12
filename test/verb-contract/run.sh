#!/usr/bin/env bash
# Exercises the verb-contract check against real packages: every case writes a
# PKGBUILD, builds it with makepkg as the invoking user, and hands the result
# to the script. Nothing here reaches the network or leaves its work directory.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/../.." && pwd)
CHECK="$repo_root/scripts/check-verb-contract.sh"

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

not() { ! "$@"; }

# A verb that answers everything the contract asks, unless told to skip one of
# the completion modes.
verb_body() {
    local skip=${1:-}
    cat <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --help-summary) echo "a fixture verb" ;;
    --complete-bash|--complete-zsh|--complete-fish)
        [[ "\$1" == "--$skip" ]] && exit 1
        [[ "$skip" == silent ]] && exit 0
        printf '%s\n' --alpha -a ;;
    *) echo invoked ;;
esac
EOF
}

# Build a package with the given verbs, declarations and man pages. Each verb
# is "<name>[:<mode-it-refuses>]"; each declaration is a TOML body keyed by the
# file name it lands under; man pages are bare names.
#
# Leaves the package file in $built.
built=""
# The install lines it writes go into a PKGBUILD, so its variables stay literal.
# shellcheck disable=SC2016
build_pkg() {
    local work=$1 name=$2 depends=$3 verbs=$4 decls=$5 pages=$6
    local dir="$work/$name"
    mkdir -p "$dir"

    {
        printf 'pkgname=%s\npkgver=1\npkgrel=1\n' "$name"
        printf "pkgdesc='verb contract fixture'\narch=('any')\n"
        printf "url='https://shedos.org'\nlicense=('MIT')\n"
        [[ -z $depends ]] || printf "depends=('%s')\n" "$depends"
        # A no-op first line, so a fixture that installs nothing is still a
        # function body makepkg can source.
        printf 'package() {\n    :\n'
        local v verb skip
        for v in $verbs; do
            verb=${v%%:*}
            skip=''
            [[ $v == *:* ]] && skip=${v#*:}
            verb_body "$skip" > "$dir/$verb.sh"
            printf '    install -Dm755 "$startdir/%s.sh" "$pkgdir/usr/libexec/shedman/%s"\n' \
                "$verb" "$verb"
        done
        local d
        for d in $decls; do
            printf '    install -Dm644 "$startdir/%s" "$pkgdir/usr/share/shedman/verbs.d/%s"\n' \
                "$d" "$d"
        done
        local p
        for p in $pages; do
            printf 'placeholder\n' > "$dir/$p"
            printf '    install -Dm644 "$startdir/%s" "$pkgdir/usr/share/man/man1/%s"\n' \
                "$p" "$p"
        done
        printf '}\n'
    } > "$dir/PKGBUILD"

    (cd "$dir" && makepkg --nodeps --force > "$work/$name.build.log" 2>&1) || {
        echo "    fixture $name did not build:"
        tail -5 "$work/$name.build.log" | sed 's/^/      /'
        return 1
    }
    built=$(find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' -print -quit)
    [[ -n $built ]]
}

declare_verb() {
    local dir=$1 file=$2
    shift 2
    printf '%s\n' "$@" > "$dir/$file"
}

out=""
rc=0
run_check() {
    out=$("$CHECK" "$@" 2>&1)
    rc=$?
}

says() { grep -qF -- "$1" <<<"$out"; }

# --- case: a package that honours the contract passes ------------------------

case_complete_package() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/good"
    declare_verb "$work/good" alpha.toml \
        'name = "alpha"' 'package = "good"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" good '' 'alpha' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'a package honouring the contract passes' [ "$rc" -eq 0 ]
    [[ $rc -eq 0 ]] || printf '%s\n' "$out"
    check 'it says what it checked' says '1 verb'
}

# --- case: a verb that shipped without its declaration -----------------------

case_undeclared_verb() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/stowaway"
    declare_verb "$work/stowaway" alpha.toml \
        'name = "alpha"' 'package = "stowaway"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" stowaway '' 'alpha beta' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'an undeclared verb fails the check' [ "$rc" -ne 0 ]
    check 'it names the verb' says 'beta'
    check 'and not the one that is declared' not says 'alpha ships in'
}

# --- case: a declaration whose verb never shipped ----------------------------

case_declaration_without_verb() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/ghost"
    declare_verb "$work/ghost" alpha.toml \
        'name = "alpha"' 'package = "ghost"' 'man = "alpha.1"' 'description = "a verb"'
    declare_verb "$work/ghost" beta.toml \
        'name = "beta"' 'package = "ghost"' 'man = "beta.1"' 'description = "a verb"'
    build_pkg "$work" ghost '' 'alpha' 'alpha.toml beta.toml' 'alpha.1 beta.1' || return 1

    run_check "$built"
    check 'a declaration with no executable fails the check' [ "$rc" -ne 0 ]
    check 'it names the verb that is missing' says 'beta'
}

# --- case: a declaration pointing at a man page the package does not ship ----

case_declaration_without_man() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/unwritten"
    declare_verb "$work/unwritten" alpha.toml \
        'name = "alpha"' 'package = "unwritten"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" unwritten '' 'alpha' 'alpha.toml' '' || return 1

    run_check "$built"
    check 'a declaration with no man page fails the check' [ "$rc" -ne 0 ]
    check 'it names the page it looked for' says 'alpha.1'
}

# --- case: a declaration missing a field the contract requires ---------------

case_declaration_incomplete() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/terse"
    declare_verb "$work/terse" alpha.toml 'name = "alpha"' 'package = "terse"'
    build_pkg "$work" terse '' 'alpha' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'a declaration missing a field fails the check' [ "$rc" -ne 0 ]
    check 'it names the field' says 'man'
}

# --- case: a verb that does not answer the completion contract ---------------

case_verb_without_completions() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/silent"
    declare_verb "$work/silent" alpha.toml \
        'name = "alpha"' 'package = "silent"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" silent '' 'alpha:complete-fish' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'a verb that refuses a completion mode fails the check' [ "$rc" -ne 0 ]
    check 'it names the mode' says '--complete-fish'
}

# --- case: silence has to be declared before it counts as an answer ----------

case_verb_with_no_flags() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/flagless"
    declare_verb "$work/flagless" alpha.toml \
        'name = "alpha"' 'package = "flagless"' 'man = "alpha.1"' \
        'description = "a verb"' 'completes = false'
    build_pkg "$work" flagless '' 'alpha:silent' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'a verb that declared it has nothing to complete passes' [ "$rc" -eq 0 ]
    [[ $rc -eq 0 ]] || printf '%s\n' "$out"
}

case_undeclared_silence() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/mute"
    declare_verb "$work/mute" alpha.toml \
        'name = "alpha"' 'package = "mute"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" mute '' 'alpha:silent' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'silence nobody declared fails the check' [ "$rc" -ne 0 ]
    check 'it names the mode' says '--complete-bash'
}

case_declared_silence_that_speaks() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/talkative"
    declare_verb "$work/talkative" alpha.toml \
        'name = "alpha"' 'package = "talkative"' 'man = "alpha.1"' \
        'description = "a verb"' 'completes = false'
    build_pkg "$work" talkative '' 'alpha' 'alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'a verb that declared silence and then speaks fails the check' [ "$rc" -ne 0 ]
    check 'it says the declaration is the thing that is wrong' says 'completes = false'
}


# --- case: an internal verb is not asked for completions ---------------------

case_internal_verb() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/internal"
    declare_verb "$work/internal" _helper.toml \
        'name = "_helper"' 'package = "internal"' 'man = "alpha.1"' \
        'description = "an internal helper"'
    build_pkg "$work" internal '' '_helper:complete-bash' '_helper.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'an internal verb is not held to the completion contract' [ "$rc" -eq 0 ]
    [[ $rc -eq 0 ]] || printf '%s\n' "$out"
}

# --- case: a package with no verbs at all is not the check's business --------

case_no_verbs() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    build_pkg "$work" plain '' '' '' '' || return 1

    run_check "$built"
    check 'a package shipping no verbs passes' [ "$rc" -eq 0 ]
    check 'and is reported as having none' says 'no verbs'
}

# --- case: a verb shipped by a package outside the contract ------------------

case_outside_the_contract() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    build_pkg "$work" legacy '' 'alpha' '' '' || return 1

    run_check "$built"
    check 'a package that never joined the contract is not failed by it' \
        [ "$rc" -eq 0 ]
    [[ $rc -eq 0 ]] || printf '%s\n' "$out"
    check 'but the pipeline says it ships a verb from outside' says 'outside the verb contract'

    # Declaring the dependency is what joins it, and then it is held to it.
    build_pkg "$work" joined shedman 'alpha' '' '' || return 1
    run_check "$built"
    check 'depending on shedman joins the contract' [ "$rc" -ne 0 ]
    check 'and the undeclared verb is now a failure' says 'alpha'
}

# --- case: two declarations in one package claiming one verb -----------------

case_collision_within_package() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/twice"
    declare_verb "$work/twice" alpha.toml \
        'name = "alpha"' 'package = "twice"' 'man = "alpha.1"' 'description = "a verb"'
    declare_verb "$work/twice" also-alpha.toml \
        'name = "alpha"' 'package = "twice"' 'man = "alpha.1"' 'description = "the same verb"'
    build_pkg "$work" twice '' 'alpha' 'alpha.toml also-alpha.toml' 'alpha.1' || return 1

    run_check "$built"
    check 'one name claimed twice in one package fails the check' [ "$rc" -ne 0 ]
    check 'it names the verb' says 'alpha'
    check 'and both declarations' says 'also-alpha.toml'
}

# --- case: several packages are all reported, not just the first -------------

case_reports_every_package() {
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' RETURN
    mkdir -p "$work/first" "$work/second"
    declare_verb "$work/first" alpha.toml \
        'name = "alpha"' 'package = "first"' 'man = "alpha.1"' 'description = "a verb"'
    build_pkg "$work" first '' 'alpha beta' 'alpha.toml' 'alpha.1' || return 1
    local one=$built
    declare_verb "$work/second" gamma.toml \
        'name = "gamma"' 'package = "second"' 'man = "gamma.1"' 'description = "a verb"'
    build_pkg "$work" second '' 'gamma delta' 'gamma.toml' 'gamma.1' || return 1

    run_check "$one" "$built"
    check 'the check fails' [ "$rc" -ne 0 ]
    check 'the first package is reported' says 'beta'
    check 'and so is the second' says 'delta'
}

for c in case_complete_package case_undeclared_verb case_declaration_without_verb \
         case_declaration_without_man case_declaration_incomplete \
         case_verb_without_completions case_verb_with_no_flags \
         case_undeclared_silence case_declared_silence_that_speaks \
         case_internal_verb case_no_verbs case_collision_within_package \
         case_outside_the_contract case_reports_every_package; do
    printf '\n── %s\n' "${c#case_}"
    "$c" || { fail=$((fail + 1)); failed+=("${c#case_}"); printf '  FAIL %s (harness)\n' "${c#case_}"; }
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
    printf 'failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
