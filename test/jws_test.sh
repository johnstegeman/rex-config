#!/usr/bin/env bash
# jws: the fish function the new-work flow makes jj workspaces with.
#
# jws is the one seam between rex-config and dojjo. Creation is jj's business
# (`jj workspace add`, then a bookmark), the post-start hooks are dojjo's
# business (`djo hook post-start`, run inside the new workspace), and the path
# the tab is handed is read back from `jj workspace list` rather than taken from
# anything either tool printed.
#
# The function under test is the DEVELOPER's file: it lives in
# ~/.config/fish/functions, it is not in this repo and it is not versioned, the
# same way gws is. The test reads it from
# ${JWS_FILE:-$HOME/.config/fish/functions/jws.fish} and FAILS -- it does not
# skip -- when it is not there, naming the path it wanted.
#
# Everything here is real except dojjo: a real wrapper is built under $tmp and a
# real `jj workspace add` makes the workspace, because the whole point of this
# shim is that dojjo creates nothing. The stand-in `djo` runs the post-start
# commands out of the hook config it finds in its own directory, one small copy
# of what dojjo does.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
# The physical path, because jj answers `root` resolved: on macOS /var is a
# symlink to /private/var, so the /var form mktemp prints would never equal the
# root jj names, and every path assertion below would fail for the wrong reason.
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '  %s\n' "$2"
  fi
}

# A missing jj or fish is a broken machine, not a passing test: say so loudly
# rather than letting every case below pass for the wrong reason (a refusal
# because nothing could run looks exactly like the refusals under test).
for tool in jj fish; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'jws_test: %s is required to run this test and is not on PATH\n' "$tool" >&2
    exit 1
  fi
done

export JWS_FILE=${JWS_FILE:-$HOME/.config/fish/functions/jws.fish}
if [ ! -f "$JWS_FILE" ]; then
  fail "jws.fish is missing" "$JWS_FILE"
  printf '  the function is a developer file in ~/.config/fish/functions, not a repo file\n'
  exit 1
fi

# Only dojjo is stood in for. Two things are recorded per invocation: the
# arguments as one bare line, so `grep -Fxq 'hook post-start'` is an exact
# answer about what was asked, and a `cwd=` line for where it was asked from.
#
# A post-start run then does dojjo's job in miniature: it reads the `proof`
# command out of the `.config/wt.toml` in ITS OWN directory and runs it. So the
# `.hook-proof` file only appears when the new workspace actually inherited
# main's hook config, and it appears where the hooks ran -- a directory no
# stand-in created, because jj made it.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/djo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DJOLOG"
printf 'cwd=%s\n' "$PWD" >>"$DJOLOG"
[ "$*" = "hook post-start" ] || exit 0
[ -f .config/wt.toml ] || exit 0
sed -n 's/^proof = "\(.*\)"$/\1/p' .config/wt.toml |
  while IFS= read -r command; do eval "$command"; done
EOF
chmod +x "$tmp/bin/djo"

# djo_asked LINE -> the stand-in was invoked with exactly LINE as its
# arguments; djo_ran_in DIR -> it was invoked from exactly DIR. Both answer
# no when nothing ran at all, which is what makes "dojjo was never called" an
# assertion rather than a grep error about a file that is not there.
djo_asked() {
  [ -f "$tmp/djo.log" ] && grep -Fxq "$1" "$tmp/djo.log"
}
djo_ran_in() {
  [ -f "$tmp/djo.log" ] && grep -Fxq "cwd=$1" "$tmp/djo.log"
}

# make_wrapper DIR -> a git-free wrapper with a main workspace. This is the
# shape the flow exists for: a directory-level jj repo at DIR, the real working
# copy at DIR/main, and an inert `default` workspace at DIR itself (sparse
# cleared and parked on root(), so a stray snapshot cannot absorb the wrapper).
make_wrapper() {
  mkdir -p "$1" && ( cd "$1" && jj git init --no-colocate . >/dev/null 2>&1 &&
    printf '*' > .gitignore && jj workspace add --name main main >/dev/null 2>&1 &&
    jj sparse set --clear && jj new 'root()' -m inert >/dev/null 2>&1 )
}

# run_jws WORKDIR ARGS... ; stdout in $tmp/out, stderr in $tmp/err, and the
# function's OWN exit status in $status -- which is the whole contract the tab
# reads. JWS_PATH is the PATH the function runs with, so one case can run it on
# a PATH that has no djo at all. Nothing here counts an assertion: every check
# below does that itself, so `ok N assertions` is the number of checks and a
# failure report cannot out-count it.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# puts the REAL dojjo on the PATH whatever this test sets it to -- which would
# hand the cases below the tool the stand-in exists to replace, and would spend
# the create running the wrapper's real hooks.
run_jws() {
  local dir=$1
  shift
  rm -f "$tmp/djo.log"
  ( cd "$dir" && PATH="${JWS_PATH:-$tmp/bin:$PATH}" DJOLOG="$tmp/djo.log" \
    fish --no-config -c 'set -g fish_function_path (dirname "$JWS_FILE"); source "$JWS_FILE"; jws $argv' \
      -- "$@" ) >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# A create from a caller that does not stand in <wrapper>/main, so the relative
# --path-file has to be resolved against the caller's cwd and not against main,
# which is only where the workspace is created from. The wrapper's own root is
# that caller: it is inside the wrapper, it is not main, and its `default`
# workspace is the one place a shim that trusted its cwd would go wrong.
make_wrapper "$tmp/w"
( cd "$tmp/w/main" && jj bookmark create main -r @ >/dev/null 2>&1 )
mkdir -p "$tmp/w/main/.config"
printf '[hooks.post-start]\nproof = "touch .hook-proof"\n' >"$tmp/w/main/.config/wt.toml"
# The seed commit carries the hook config, so the workspace made from main holds
# it too -- which is what makes the stand-in's `.hook-proof` meaningful: it is
# written by a command that only exists in a workspace that inherited the file.
( cd "$tmp/w/main" && jj describe -m seed >/dev/null 2>&1 && jj new >/dev/null 2>&1 )

run_jws "$tmp/w" --path-file path.txt feat/x
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a create exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/path.txt" 2>/dev/null || true)" != "$tmp/w/feat-x" ]; then
  fail "--path-file holds the workspace path, resolved against the caller" \
    "wanted $tmp/w/feat-x, got: $(cat "$tmp/w/path.txt" 2>/dev/null || echo '<no file>')"
fi
# awk rather than `wc -l <file`: a redirect onto a file that is not there is
# an error bash prints itself, which no `2>/dev/null` on the command can quiet.
ran=$((ran + 1))
if [ "$(awk 'END { print NR }' "$tmp/w/path.txt" 2>/dev/null || true)" != 1 ]; then
  fail "--path-file is one line" "lines: $(awk 'END { print NR }' "$tmp/w/path.txt" 2>/dev/null)"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/feat-x" ]; then
  fail "the workspace directory exists" "no $tmp/w/feat-x"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/feat-x/.config/wt.toml" ]; then
  fail "the new workspace inherited main's hook config" "no $tmp/w/feat-x/.config/wt.toml"
fi
# feat/x -> feat-x, and the workspace is NAMED for the branch, not the directory
# (the picker and the done flow both look workspaces up by branch name).
ran=$((ran + 1))
if ! ( cd "$tmp/w" && jj --ignore-working-copy bookmark list -T 'name ++ "\n"' ) |
  grep -Fxq 'feat/x'; then
  fail "the create makes a bookmark named for the branch" \
    "$(cd "$tmp/w" && jj --ignore-working-copy bookmark list -T 'name ++ "\n"')"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/feat-x/.hook-proof" ]; then
  fail "the post-start hooks ran, in the new workspace" "no $tmp/w/feat-x/.hook-proof"
fi
ran=$((ran + 1))
if ! djo_asked 'hook post-start'; then
  fail "dojjo is asked to run the hooks" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi
ran=$((ran + 1))
if ! djo_ran_in "$tmp/w/feat-x"; then
  fail "the hooks run inside the new workspace" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi
# dojjo is named in exactly two places in this flow, and a create is one of
# them: a second invocation here would be a `djo switch`, which dies on its
# state file in this layout after making the workspace (constraint 15).
ran=$((ran + 1))
if [ "$(grep -vc '^cwd=' "$tmp/djo.log" 2>/dev/null || true)" != 1 ]; then
  fail "a create runs dojjo exactly once, for the hooks" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi

# Both closing lines, because between them they say where the workspace is and
# how to undo it: a shim that printed one and not the other would leave the
# person holding a workspace with no command to remove it by.
ran=$((ran + 1))
if ! grep -Fxq "jws: $tmp/w/feat-x ready (jj workspace 'feat/x', hooks run)" "$tmp/out" ||
  ! grep -Fxq '     remove with: djo remove feat/x -y, or ctrl+space>d' "$tmp/out"; then
  fail "a create prints both closing lines" "$(cat "$tmp/out")"
fi

# A create that was given a base revision starts the workspace there, and `-r`
# is the only thing that makes that true: without it the new working copy is a
# sibling of main's, so a shim that quietly dropped `-r` would still look right
# in every other assertion here. root() is the one revision that cannot be
# arrived at by accident.
root_commit=$( cd "$tmp/w" && jj --ignore-working-copy log --no-graph -r 'root()' -T 'commit_id' )
run_jws "$tmp/w" --path-file base.txt feat/r 'root()'
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a create with a base revision exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/base.txt" 2>/dev/null || true)" != "$tmp/w/feat-r" ]; then
  fail "a create with a base revision reports its path" \
    "wanted $tmp/w/feat-r, got: $(cat "$tmp/w/base.txt" 2>/dev/null || echo '<no file>')"
fi
ran=$((ran + 1))
if [ "$(cd "$tmp/w" && jj --ignore-working-copy log --no-graph -r 'feat/r-' -T 'commit_id')" != "$root_commit" ]; then
  fail "the base revision is where the workspace starts" \
    "feat/r's parent: $(cd "$tmp/w" && jj --ignore-working-copy log --no-graph -r 'feat/r-' -T 'commit_id'), wanted root: $root_commit"
fi

# A destination that is already there is refused, and named: two branches can
# sanitise to one directory (feat/x and feat-x both want <wrapper>/feat-x), and
# adopting the directory that is there would put the new branch in somebody
# else's workspace.
mkdir -p "$tmp/w/feat-y"
run_jws "$tmp/w" --path-file "$tmp/refused-path.txt" feat/y
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "an existing destination is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/w/feat-y" "$tmp/err"; then
  fail "the refusal names the destination" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/refused-path.txt" ]; then
  fail "a refusal writes no path file" "$(cat "$tmp/refused-path.txt")"
fi
ran=$((ran + 1))
if [ -e "$tmp/djo.log" ]; then
  fail "a refusal runs no dojjo" "$(cat "$tmp/djo.log")"
fi

# --attach and --existing are the two halves of `[--attach | --existing]`, so
# asking for both is a caller's mistake rather than a mode: refused before the
# wrapper is even looked for, and certainly before a workspace is made.
run_jws "$tmp/w" --attach --existing feat/b
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--attach with --existing is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -d "$tmp/w/feat-b" ]; then
  fail "--attach with --existing creates nothing" "$tmp/w/feat-b exists"
fi

# A caller outside any wrapper: the walk finds no .jj/repo and says so, rather
# than making a workspace somewhere up the tree.
mkdir -p "$tmp/outside"
run_jws "$tmp/outside" feat/z
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "a caller with no wrapper is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'no jj repo' "$tmp/err"; then
  fail "the refusal names the missing jj repo" "$(cat "$tmp/err")"
fi

# A wrapper with no main workspace: the flow has no other notion of where a
# workspace is created from -- asking for one is the failure.
make_wrapper "$tmp/nomain"
rm -rf "$tmp/nomain/main"
run_jws "$tmp/nomain" feat/z
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "a wrapper without main is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/nomain/main" "$tmp/err"; then
  fail "the refusal names the base workspace it wanted" "$(cat "$tmp/err")"
fi
# The check is mode-independent on purpose -- a wrapper's main workspace is the
# layout's own precondition, not something a create happens to need -- so a
# switch in a wrapper without main is refused by name instead of switching to
# something this flow cannot place workspaces in.
run_jws "$tmp/nomain" --existing main
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--existing in a wrapper without main is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/nomain/main" "$tmp/err"; then
  fail "the switch refusal names the missing base workspace" "$(cat "$tmp/err")"
fi
# ... and says WHY, not just that something failed: a cd that fell over on the
# missing directory would also print the path, so the refusal's own words are
# what distinguishes the layout check from an accident further down.
ran=$((ran + 1))
if ! grep -Fq 'the base workspace' "$tmp/err"; then
  fail "the switch refusal says the base workspace is missing" "$(cat "$tmp/err")"
fi

# No dojjo on the PATH: refused before anything else, because a workspace whose
# hooks never ran is a workspace the person has to finish by hand. fish is put
# on that PATH alone (with /usr/bin:/bin for dirname) so djo really is absent.
mkdir -p "$tmp/min-bin"
ln -sf "$(command -v fish)" "$tmp/min-bin/fish"
JWS_PATH="$tmp/min-bin:/usr/bin:/bin" run_jws "$tmp/w/main" feat/q
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "no djo is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'djo' "$tmp/err"; then
  fail "the refusal names djo" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -d "$tmp/w/feat-q" ]; then
  fail "no djo refuses before anything is created" "$tmp/w/feat-q exists"
fi

# A path file that cannot be written is refused UP FRONT, before anything exists.
# The write itself happens at the end, after the workspace is made, so a shim
# that only discovered the unwritable file there would leave a workspace with no
# tab able to find it -- an orphan nobody asked for. Proven here for all three
# modes: nothing created, no dojjo run, and no path file left behind by the
# probe that decided it.
rm -f "$tmp/djo.log"
run_jws "$tmp/w" --path-file "$tmp/no-such-dir/path.txt" feat/w2
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "an unwritable path file is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'cannot write the path file' "$tmp/err"; then
  fail "the refusal names the path file" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/no-such-dir/path.txt" "$tmp/err"; then
  fail "the refusal names the path file it wanted" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/feat-w2" ]; then
  fail "an unwritable path file creates no workspace" "$tmp/w/feat-w2 exists"
fi
ran=$((ran + 1))
if [ -e "$tmp/djo.log" ]; then
  fail "an unwritable path file runs no dojjo" "$(cat "$tmp/djo.log")"
fi
ran=$((ran + 1))
if [ -e "$tmp/no-such-dir/path.txt" ]; then
  fail "an unwritable path file leaves no file behind" \
    "$tmp/no-such-dir/path.txt exists"
fi
ran=$((ran + 1))
if [ "$(grep -c . "$tmp/err")" -ne 1 ]; then
  fail "an unwritable path file is refused in one line" "$(cat "$tmp/err")"
fi

# ... and the same refusal in the two modes that start from something that
# already exists. An attach would make a workspace on a bookmark and run its
# hooks; the path file is refused before the add, so no workspace appears and
# dojjo is never called.
( cd "$tmp/w/main" && jj bookmark create nofile-attach -r @ >/dev/null 2>&1 )
run_jws "$tmp/w" --attach --path-file "$tmp/no-such-dir/attach.txt" nofile-attach
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--attach with an unwritable path file is refused" \
    "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/nofile-attach" ]; then
  fail "--attach with an unwritable path file creates no workspace" \
    "$tmp/w/nofile-attach exists"
fi
ran=$((ran + 1))
if [ -e "$tmp/djo.log" ]; then
  fail "--attach with an unwritable path file runs no dojjo" "$(cat "$tmp/djo.log")"
fi

# --existing writes the same file at the end, so it gets the same up-front
# check -- and its refusal is the path file's rather than jj's, which is the
# difference between "I cannot tell you where it is" and "there is no such
# workspace".
run_jws "$tmp/w" --existing --path-file "$tmp/no-such-dir/existing.txt" feat/x
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--existing with an unwritable path file is refused" \
    "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'cannot write the path file' "$tmp/err"; then
  fail "--existing's refusal is the path file's" "$(cat "$tmp/err")"
fi

# --attach and --existing start from something that already exists, so a base
# revision beside them is a contradiction -- and it is caught before a workspace
# is made, not after.
for mode in --attach --existing; do
  run_jws "$tmp/w" "$mode" feat/a main
  ran=$((ran + 1))
  if [ "$status" -ne 1 ]; then
    fail "$mode with a base revision is refused" "exit $status: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if [ -d "$tmp/w/feat-a" ]; then
    fail "$mode with a base revision creates nothing" "$tmp/w/feat-a exists"
  fi
done

# --attach: the bookmark is there and the workspace is not. jj puts the new
# working copy on a NEW commit on top of the branch and the bookmark stays
# where it was -- exactly what `gws` + `git checkout <branch>` left behind.
# That is the whole difference from a create: a create makes the branch, an
# attach borrows it.
( cd "$tmp/w/main" && jj bookmark create br -r @ >/dev/null 2>&1 )
br_want=$( cd "$tmp/w" && jj --ignore-working-copy log -r br --no-graph -T 'commit_id' )
run_jws "$tmp/w" --attach --path-file attach.txt br
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "--attach exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/attach.txt" 2>/dev/null || true)" != "$tmp/w/br" ]; then
  fail "--attach reports the workspace path" \
    "wanted $tmp/w/br, got: $(cat "$tmp/w/attach.txt" 2>/dev/null || echo '<no file>')"
fi
# The new working copy's parent is the bookmark's commit: the workspace starts
# ON the branch rather than beside it, which is what `-r=<branch>` on the add
# means and what a copy of the create's arguments would not have done.
ran=$((ran + 1))
attached_parent=$( cd "$tmp/w/br" && jj --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' )
if [ "$attached_parent" != "$br_want" ]; then
  fail "--attach starts the workspace on the branch" \
    "@- in the new workspace: $attached_parent, wanted $br_want"
fi
# ... and the bookmark did not move. `jj bookmark create` would have failed on
# the existing name and `jj bookmark move` would have rewritten the branch, so
# an attach that quietly did either is caught right here.
ran=$((ran + 1))
br_now=$( cd "$tmp/w" && jj --ignore-working-copy log -r br --no-graph -T 'commit_id' )
if [ "$br_now" != "$br_want" ]; then
  fail "--attach leaves the bookmark where it was" \
    "br: $br_now, wanted $br_want"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/br/.hook-proof" ]; then
  fail "an attach runs the post-start hooks too" "no $tmp/w/br/.hook-proof"
fi
ran=$((ran + 1))
if ! djo_ran_in "$tmp/w/br"; then
  fail "an attach's hooks run inside the new workspace" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi

# --attach where the bookmark is NOT there: jj refuses the revision, and jws has
# nothing to fall back on -- it does not quietly create the workspace beside the
# branch instead. jj leaves no half-made workspace, so the assertion is that
# the refusal is non-zero, nothing is on disk, and no path is handed over.
run_jws "$tmp/w" --attach --path-file "$tmp/nobr.txt" nobr
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--attach refuses a bookmark that does not exist" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -d "$tmp/w/nobr" ]; then
  fail "a refused --attach leaves no workspace behind" "$tmp/w/nobr exists"
fi
ran=$((ran + 1))
if [ -e "$tmp/nobr.txt" ]; then
  fail "a refused --attach writes no path file" "$(cat "$tmp/nobr.txt")"
fi

# --existing: a workspace that is already there. The path comes back, and
# NOTHING is made: no workspace, no bookmark, no hook -- it is the mode a
# switch runs, not a mode that creates.
# rows_now FILE -> the number of workspace rows, after writing the listing to
# FILE. A listing jj could not produce is a broken test, not a zero: with
# `$() | awk 'END { print NR }'` a jj that failed counts 0, and "--existing
# creates no workspace" would then compare 0 with 0 and pass for the wrong
# reason. The emptiness is checked by the caller (listing_read), because
# anything counted inside a command substitution counts nowhere: `fails` and
# `ran` would be incremented in the subshell and thrown away with it.
rows_now() {
  ( cd "$tmp/w" && jj --ignore-working-copy workspace list -T 'name ++ "\n"' ) >"$1"
  awk 'END { print NR }' "$1"
}

# listing_read FILE -> one assertion that the listing can be read at all.
listing_read() {
  ran=$((ran + 1))
  [ -s "$1" ] && return 0
  fail "the workspace listing could be read" "jj wrote nothing to $1"
}
rows_before=$(rows_now "$tmp/rows-before.txt")
listing_read "$tmp/rows-before.txt"
rm -f "$tmp/w/feat-x/.hook-proof"
run_jws "$tmp/w" --existing --path-file switch.txt feat/x
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "--existing exits 0 for a workspace jj lists" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/switch.txt" 2>/dev/null || true)" != "$tmp/w/feat-x" ]; then
  fail "--existing reports the workspace path" \
    "wanted $tmp/w/feat-x, got: $(cat "$tmp/w/switch.txt" 2>/dev/null || echo '<no file>')"
fi
ran=$((ran + 1))
if [ -e "$tmp/djo.log" ]; then
  fail "--existing runs no dojjo at all" "$(cat "$tmp/djo.log")"
fi
ran=$((ran + 1))
if [ -f "$tmp/w/feat-x/.hook-proof" ]; then
  fail "--existing runs no hooks" "$tmp/w/feat-x/.hook-proof came back"
fi
ran=$((ran + 1))
rows_after=$(rows_now "$tmp/rows-after.txt")
listing_read "$tmp/rows-after.txt"
if [ "$rows_after" != "$rows_before" ]; then
  fail "--existing creates no workspace" "rows were $rows_before, now $rows_after"
fi

# --existing for a name jj does not list: refused, in one line, BEFORE dojjo is
# even looked for. dojjo asks `Create it? [y/N]` for a name it does not know,
# and in a pane nobody can type into that is an invisible hang -- so the
# guard, not dojjo, is what answers a stale name.
run_jws "$tmp/w" --existing --path-file "$tmp/nope.txt" nope
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "--existing refuses a name jj does not list" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'lists no workspace' "$tmp/err"; then
  fail "the refusal says jj lists no such workspace" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/djo.log" ]; then
  fail "a refused --existing calls no dojjo" "$(cat "$tmp/djo.log")"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/nope" ]; then
  fail "a refused --existing creates nothing" "$tmp/w/nope exists"
fi
ran=$((ran + 1))
if [ -e "$tmp/nope.txt" ]; then
  fail "a refused --existing writes no path file" "$(cat "$tmp/nope.txt")"
fi

# The djo requirement belongs to the modes that run dojjo: --existing is jj's
# alone, so a machine with no dojjo on the PATH can still switch. min-bin is
# fish, jj and the OS, and no dojjo.
ln -sf "$(command -v jj)" "$tmp/min-bin/jj"
JWS_PATH="$tmp/min-bin:/usr/bin:/bin" run_jws "$tmp/w" --existing --path-file nodjo.txt feat/x
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "--existing works with no djo on the PATH" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/nodjo.txt" 2>/dev/null || true)" != "$tmp/w/feat-x" ]; then
  fail "--existing without djo still reports the path" \
    "wanted $tmp/w/feat-x, got: $(cat "$tmp/w/nodjo.txt" 2>/dev/null || echo '<no file>')"
fi

# The bounded fetch. dojjo never fetches -- there is no `jj git fetch` in its
# source -- and the base revision the picker names is a REMOTE answer, so a
# create that was given one refreshes first: bounded, because the pane is a
# terminal nobody can type into, and forgivably, because offline is not a
# failed create.
#
# Two stand-ins prove both halves: a `jj` that passes everything through to the
# real jj except `git fetch`, where it logs and fails, and a `timeout` that
# logs what it was handed before running it. So the log says the fetch was
# attempted AND that it was bounded by 30 seconds.
real_jj=$(command -v jj)
mkdir -p "$tmp/fetchbin"
cat >"$tmp/fetchbin/jj" <<EOF
#!/bin/sh
if [ "\$1" = git ] && [ "\$2" = fetch ]; then
  # Ordering as well as occurrence: a fetch that ran after the workspace was
  # made is still a fetch, so the log also records whether the workspace was
  # already on disk when the fetch was asked for.
  [ -e "$tmp/w/feat-fetched" ] && printf 'fetch-after-the-workspace\n' >>"$tmp/fetch.log"
  printf 'fetch\n' >>"$tmp/fetch.log"
  exit 1
fi
exec "$real_jj" "\$@"
EOF
cat >"$tmp/fetchbin/timeout" <<EOF
#!/bin/sh
printf 'bounded: %s\n' "\$*" >>"$tmp/fetch.log"
shift
exec "\$@"
EOF
chmod +x "$tmp/fetchbin/jj" "$tmp/fetchbin/timeout"
rm -f "$tmp/fetch.log"
JWS_PATH="$tmp/fetchbin:$tmp/bin:$PATH" run_jws "$tmp/w" --path-file fetched.txt feat/fetched 'root()'
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a failed fetch does not fail the create" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fxq 'fetch' "$tmp/fetch.log" 2>/dev/null; then
  fail "a base revision is fetched at all" \
    "$(cat "$tmp/fetch.log" 2>/dev/null || echo '<no fetch>') / $(cat "$tmp/err")"
fi
# ... and BEFORE the workspace is made: being fetched at all is not the same
# thing, and the stand-in noted whether the workspace was already on disk when
# it was asked.
ran=$((ran + 1))
if grep -Fxq 'fetch-after-the-workspace' "$tmp/fetch.log" 2>/dev/null; then
  fail "a base revision is fetched before the workspace is made" \
    "$(cat "$tmp/fetch.log")"
fi
ran=$((ran + 1))
if ! grep -Fxq 'bounded: 30 jj git fetch' "$tmp/fetch.log" 2>/dev/null; then
  fail "the fetch is bounded by 30 seconds" \
    "$(cat "$tmp/fetch.log" 2>/dev/null || echo '<no fetch>')"
fi
# The failure is ONE line, and it is jws's own: jj reports what it then made
# (`Created workspace in ...`) on STDERR as well, and the notice comes before
# the workspace exists, so everything stderr says before that report IS the
# notice. One line means the notice is one line -- a second explanatory line,
# or a paragraph of them, would be sitting right here beside it.
fetch_notice=$(awk '/^Created workspace/ { exit } { print }' "$tmp/err")
ran=$((ran + 1))
if [ "$(printf '%s\n' "$fetch_notice" | grep -c .)" != 1 ]; then
  fail "a failed fetch says so, in one line" "stderr before jj's report: [$fetch_notice]"
fi
ran=$((ran + 1))
if [ "$fetch_notice" != "jws: could not fetch; feat/fetched starts from root() as it is" ]; then
  fail "the fetch notice names the branch and the revision it fell back to" \
    "[$fetch_notice]"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/fetched.txt" 2>/dev/null || true)" != "$tmp/w/feat-fetched" ]; then
  fail "the create after a failed fetch still reports its path" \
    "wanted $tmp/w/feat-fetched, got: $(cat "$tmp/w/fetched.txt" 2>/dev/null || echo '<no file>')"
fi
# ... and the base revision is still the base: a fetch that failed changes
# nothing about the revision that was named.
ran=$((ran + 1))
fetched_parent=$( cd "$tmp/w" && jj --ignore-working-copy log -r 'feat/fetched-' --no-graph -T 'commit_id' )
if [ "$fetched_parent" != "$root_commit" ]; then
  fail "a failed fetch keeps the base revision" \
    "feat/fetched's parent: $fetched_parent, wanted root: $root_commit"
fi

# The other half of "only when a base revision was given": a create with no
# base has nothing to refresh, so it does not go to the network at all.
rm -f "$tmp/fetch.log"
JWS_PATH="$tmp/fetchbin:$tmp/bin:$PATH" run_jws "$tmp/w" --path-file nobase.txt feat/nobase
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a create with no base revision still exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/fetch.log" ]; then
  fail "a create with no base revision does not fetch" "$(cat "$tmp/fetch.log")"
fi

# The other two fetch forms. The bound is a convenience, not a requirement: on
# a machine with neither `timeout` nor `gtimeout` the fetch still happens,
# unbounded. Nothing above reaches that branch -- the fetchbin has a `timeout`
# what jws and the two stand-ins need and neither bound. That is the only way
# to see the plain `jj git fetch`: with no `timeout` and no `gtimeout` on that
# PATH, a fetch in the log is a fetch the unbounded form made.
mkdir -p "$tmp/notimeout-bin"
# `touch` and `rm` are here because jws proves --path-file writable with them
# before it makes anything; this case is about the ABSENT timeout/gtimeout, not
# about a machine with no coreutils.
for tool in dirname tee sed touch rm; do
  ln -sf "$(command -v "$tool")" "$tmp/notimeout-bin/$tool"
done
ln -sf "$(command -v fish)" "$tmp/notimeout-bin/fish"
# Its own copy, not the fetchbin one: that one also records whether
# feat-fetched is on disk, which is another case's question.
cat >"$tmp/notimeout-bin/jj" <<EOF
#!/bin/sh
if [ "\$1" = git ] && [ "\$2" = fetch ]; then
  printf 'fetch\n' >>"$tmp/fetch.log"
  exit 1
fi
exec "$real_jj" "\$@"
EOF
chmod +x "$tmp/notimeout-bin/jj"
ln -sf "$tmp/bin/djo" "$tmp/notimeout-bin/djo"
rm -f "$tmp/fetch.log"
JWS_PATH="$tmp/notimeout-bin" run_jws "$tmp/w" --path-file unbounded.txt feat/unbounded 'root()'
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "a create with no bound on the PATH still exits 0" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fxq 'fetch' "$tmp/fetch.log" 2>/dev/null; then
  fail "the fetch happens with no timeout and no gtimeout on the PATH" \
    "$(cat "$tmp/fetch.log" 2>/dev/null || echo '<no fetch>') / $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ "$(cat "$tmp/w/unbounded.txt" 2>/dev/null || true)" != "$tmp/w/feat-unbounded" ]; then
  fail "the unbounded create reports its path" \
    "wanted $tmp/w/feat-unbounded, got: $(cat "$tmp/w/unbounded.txt" 2>/dev/null || echo '<no file>')"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
