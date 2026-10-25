#!/usr/bin/env bash

# Smoke tests. Where possible we compare against the system's own tools with
# LC_ALL=C (bytewise sorting), so a failure means "differs from the reference".

# NEVER add a test that runs `rm -r /` (or anything that could resolve to it),
# even "expecting a refusal": if the guard ever regressed, the test would eat the machine.

set -u
cd "$(dirname "$0")/.."
BIN=$(cd "${BIN:-bin}" && pwd) # absolute: some tests cd into temp dirs
export LC_ALL=C

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # name expected actual
	if [ "$2" == "$3" ]; then ok "$1"; else
		bad "$1"; printf '        expected: %q\n        actual:   %q\n' "$2" "$3"
	fi
}
exists() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }

T=$(mktemp -d)
trap 'command rm -rf "$T"' EXIT

echo "== yes"
check "default output"    "$(printf 'y\ny\ny')" "$($BIN/yes | head -n 3)"
check "operands joined"   "a b"                 "$($BIN/yes a b | head -n 1)"
check "empty string"      ""                    "$($BIN/yes '' | head -n 1)"
if cmp -s <($BIN/yes foo bar | head -c 300000) <(command yes foo bar | head -c 300000); then
	ok "300 KB identical to system yes"; else bad "300 KB identical to system yes"; fi
$BIN/yes --version >/dev/null; check "--version exits 0"  0 $?
$BIN/yes -x 2>/dev/null;       check "bad option exits 1" 1 $?

echo "== ls"
L="$T/l"
mkdir -p "$L/sub" "$L/.hdir"
touch "$L/b" "$L/a" "$L/.h" "$L/Z" "$L/exe"
chmod +x "$L/exe"
ln -s a "$L/lnk"
mkfifo "$L/fifo"
ref() { command ls "$@"; }
check "default"            "$(ref -1 "$L")"   "$($BIN/ls "$L")"
check "-a"                 "$(ref -1a "$L")"  "$($BIN/ls -a "$L")"
check "-A"                 "$(ref -1A "$L")"  "$($BIN/ls -A "$L")"
check "-r"                 "$(ref -1r "$L")"  "$($BIN/ls -r "$L")"
check "-F"                 "$(ref -1F "$L")"  "$($BIN/ls -F "$L")"
check "-aF"                "$(ref -1aF "$L")" "$($BIN/ls -aF "$L")"
check "-U (as a set)"      "$(ref -1U "$L" | sort)" "$($BIN/ls -U "$L" | sort)"
check "-d dir"             "$(ref -d "$L")"   "$($BIN/ls -d "$L")"
check "-dF dir"            "$(ref -dF "$L")"  "$($BIN/ls -dF "$L")"
check "file operand"       "$(ref "$L/a")"    "$($BIN/ls "$L/a")"
check "two dirs"           "$(ref "$L" "$L/sub")" "$($BIN/ls "$L" "$L/sub")"
check "file + dir"         "$(ref "$L/a" "$L/sub")" "$($BIN/ls "$L/a" "$L/sub")"
check "cwd default"        "$(cd "$L" && ref -1)"   "$(cd "$L" && "$BIN/ls")"
$BIN/ls "$T/nope" 2>/dev/null; check "missing exits 2" 2 $?
check "missing message" "ls: cannot access '$T/nope': No such file or directory" "$($BIN/ls "$T/nope" 2>&1)"
$BIN/ls -Q 2>/dev/null;        check "bad option exits 2" 2 $?
big="$T/big"; mkdir "$big"; for i in $(seq 1 3000); do : > "$big/f$i"; done
check "3000 entries"       "$(ref -1 "$big" | md5sum)" "$($BIN/ls "$big" | md5sum)"

echo "== rm"
R="$T/r"
mkdir -p "$R/tree/a/b" "$R/outside"
touch "$R/tree/a/b/f" "$R/tree/top" "$R/outside/keep"
ln -s "$R/outside" "$R/tree/a/link"            # symlink to a directory OUTSIDE the tree
$BIN/rm -r "$R/tree"
check "tree removed"            no  "$(exists "$R/tree")"
check "symlink target SURVIVES" yes "$(exists "$R/outside/keep")"

touch "$R/file"; $BIN/rm "$R/file"
check "plain file"              no  "$(exists "$R/file")"

touch "$R/-weird"; $BIN/rm -- "$R/-weird"
check "-- ends options"         no  "$(exists "$R/-weird")"

touch "$R/after"; $BIN/rm "$R/after" -f
check "option after operand"    no  "$(exists "$R/after")"

$BIN/rm "$R/nope" 2>/dev/null;  check "missing exits 1"      1 $?
$BIN/rm -f "$R/nope";           check "-f missing exits 0"   0 $?
$BIN/rm -f;                     check "-f no operand exits 0" 0 $?
$BIN/rm 2>/dev/null;            check "no operand exits 1"   1 $?
check "missing message" "rm: cannot remove '$R/nope': No such file or directory" "$($BIN/rm "$R/nope" 2>&1)"

mkdir "$R/d"
$BIN/rm "$R/d" 2>/dev/null;     check "dir without -r exits 1" 1 $?
check "dir without -r message" "rm: cannot remove '$R/d': Is a directory" "$($BIN/rm "$R/d" 2>&1)"
check "dir still there"         yes "$(exists "$R/d")"
$BIN/rm -d "$R/d";              check "-d empty dir exits 0" 0 $?
check "-d removed it"           no  "$(exists "$R/d")"
mkdir -p "$R/d/x"
$BIN/rm -d "$R/d" 2>/dev/null;  check "-d non-empty exits 1" 1 $?
$BIN/rm -rf "$R/d"

# '.' and '..' must be refused and must not delete anything
mkdir -p "$R/dot/in"; touch "$R/dot/in/keep"
( cd "$R/dot" && $BIN/rm -r . 2>/dev/null );     check "rm -r . exits 1"  1 $?
( cd "$R/dot/in" && $BIN/rm -r .. 2>/dev/null ); check "rm -r .. exits 1" 1 $?
( cd "$R/dot" && $BIN/rm -r in/. 2>/dev/null );  check "rm -r in/. exits 1" 1 $?
check "nothing deleted by refusals" yes "$(exists "$R/dot/in/keep")"
check "dot message" "rm: refusing to remove '.' or '..' directory: skipping '.'" "$(cd "$R/dot" && $BIN/rm -r . 2>&1)"

# trailing slash on a symlink-to-dir: must never delete the target's contents
mkdir -p "$R/tgt"; touch "$R/tgt/keep"; ln -s tgt "$R/lnk"
$BIN/rm -r "$R/lnk/" 2>/dev/null
check "rm -r link/ keeps target contents" yes "$(exists "$R/tgt/keep")"
command rm -f "$R/lnk"

# -v output (compare as sets: readdir order is filesystem-specific)
mkdir -p "$R/v1/s" "$R/v2/s"; touch "$R/v1/s/f" "$R/v1/g" "$R/v2/s/f" "$R/v2/g"
check "-rv output matches GNU (sorted)" \
	"$(command rm -rv "$R/v1" | sed "s|$R/v1|X|" | sort)" \
	"$($BIN/rm -rv "$R/v2" | sed "s|$R/v2|X|" | sort)"

# deep and wide trees
deep="$R/deep"; mkdir -p "$deep"
p="$deep"; for i in $(seq 1 200); do p="$p/d"; done; mkdir -p "$p"; touch "$p/f"
$BIN/rm -r "$deep"; check "200-level deep tree" no "$(exists "$deep")"
mkdir -p "$R/wide"; for i in $(seq 1 5000); do : > "$R/wide/f$i"; done
$BIN/rm -r "$R/wide"; check "5000-file dir" no "$(exists "$R/wide")"

# --one-file-system on a tree that is all one fs must behave normally
mkdir -p "$R/ofs/x"; touch "$R/ofs/x/f"
$BIN/rm -r --one-file-system "$R/ofs"; check "--one-file-system same fs" no "$(exists "$R/ofs")"

echo "== multicall"
M="$BIN/dubox"
if [ -x "$M" ]; then
	check "dubox ls"          "$($BIN/ls "$L")" "$($M ls "$L")"
	check "dubox yes"         "y" "$($M yes | head -n 1)"
	$M nosuchtool 2>/dev/null; check "unknown tool exits 127" 127 $?
	if [ -d "$BIN/multicall" ]; then
		check "argv[0] dispatch ls" "$($BIN/ls "$L")" "$($BIN/multicall/ls "$L")"
		touch "$R/mc"; $BIN/multicall/rm "$R/mc"
		check "argv[0] dispatch rm" no "$(exists "$R/mc")"
	fi
else
	echo "  (skipped: $M not built)"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
