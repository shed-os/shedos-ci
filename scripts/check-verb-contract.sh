#!/usr/bin/env bash
# check-verb-contract.sh <package.pkg.tar.zst>...
#
# Hold every built package to shedman's verb contract, reading the package
# rather than the tree it was built from: a verb ships because a declaration
# names it, so the question "did this verb actually ship" is one the artifact
# answers and the source cannot.
#
# For each package under the contract:
#   * every executable in /usr/libexec/shedman has a declaration naming it
#   * every declaration names an executable the package ships
#   * every declaration carries name, package, man and description
#   * every declaration's man page is one the package ships
#   * every verb whose name is not internal answers --complete-bash, zsh and
#     fish with something, because that is what the completers ask it
#
# A package is under the contract once it says so: it ships a declaration, it
# depends on shedman, or it is shedman. One that ships a verb without ever
# saying so is named and left alone — the contract cannot reach back past the
# release that introduced it.
#
# Every finding in every package is reported; the exit code is the verdict.
set -uo pipefail

die() { printf 'verb-contract: %s\n' "$*" >&2; exit 2; }

(( $# > 0 )) || die 'usage: check-verb-contract.sh <package.pkg.tar.zst>...'
command -v bsdtar > /dev/null || die 'bsdtar is not on this machine'

LIBEXEC=usr/libexec/shedman
VERBS=usr/share/shedman/verbs.d
MAN=usr/share/man/man1

findings=0

field() {
    # One `key = "value"` line out of a declaration.
    sed -n "s/^[[:space:]]*${2}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "$1" | head -1
}

report() { printf '  %s\n' "$*"; findings=$((findings + 1)); }

check_package() {
    local pkg=$1 root=$2 pkgname declared_by_dep name owner man desc
    local -a verbs=() decls=()

    pkgname=$(sed -n 's/^pkgname = //p' "$root/.PKGINFO" | head -1)
    grep -qx 'depend = shedman' "$root/.PKGINFO" && declared_by_dep=yes

    [[ -d $root/$LIBEXEC ]] && mapfile -t verbs < <(cd "$root/$LIBEXEC" && ls -1)
    [[ -d $root/$VERBS ]] && mapfile -t decls < <(cd "$root/$VERBS" && ls -1 ./*.toml)

    printf '%s:\n' "$pkgname"

    if (( ${#verbs[@]} == 0 && ${#decls[@]} == 0 )); then
        printf '  no verbs\n'
        return
    fi

    if (( ${#decls[@]} == 0 )) && [[ $pkgname != shedman && -z ${declared_by_dep:-} ]]; then
        printf '  %d verb(s) from outside the verb contract: %s\n' \
            "${#verbs[@]}" "${verbs[*]}"
        return
    fi

    # name -> declaration file, and the reverse question at the same time.
    local -A owner_of=()
    local decl file
    for decl in "${decls[@]}"; do
        file=$root/$VERBS/${decl#./}
        name=$(field "$file" name)
        owner=$(field "$file" package)
        man=$(field "$file" man)
        desc=$(field "$file" description)

        if [[ -z $name ]]; then
            report "${decl#./} declares no name"
            continue
        fi
        owner_of[$name]=${decl#./}

        [[ -n $owner ]] || report "$name declares no package"
        [[ -n $desc ]] || report "$name declares no description"
        if [[ -z $man ]]; then
            report "$name declares no man page"
        elif [[ ! -e $root/$MAN/$man && ! -e $root/$MAN/$man.gz ]]; then
            report "$name declares the man page $man and $pkgname ships no such page"
        fi

        if [[ ! -x $root/$LIBEXEC/$name ]]; then
            report "$name is declared and $pkgname ships no executable for it"
            continue
        fi

        # Internal helpers are not offered by the completers, so nothing asks
        # them what they complete with.
        [[ $name == _* ]] && continue
        local mode
        for mode in --complete-bash --complete-zsh --complete-fish; do
            if ! timeout 30 "$root/$LIBEXEC/$name" "$mode" 2>/dev/null | grep -q .; then
                report "$name answers nothing to $mode"
            fi
        done
    done

    local verb
    for verb in "${verbs[@]}"; do
        [[ -n ${owner_of[$verb]:-} ]] && continue
        report "$verb ships in $LIBEXEC and no declaration names it"
    done

    printf '  %d verb(s), %d declaration(s)\n' "${#verbs[@]}" "${#decls[@]}"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for pkg in "$@"; do
    [[ -f $pkg ]] || die "$pkg does not exist"
    root=$work/$(basename "$pkg")
    mkdir -p "$root"
    bsdtar -xf "$pkg" -C "$root" || die "$pkg could not be unpacked"
    check_package "$pkg" "$root"
done

if (( findings > 0 )); then
    printf '\n%d verb contract finding(s)\n' "$findings" >&2
    exit 1
fi
printf '\nthe verb contract holds\n'
