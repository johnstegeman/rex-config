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
# shim is that dojjo creates nothing. The stand-in `djo` records what it was
# asked and where, and touches the proof file its hook config names.
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

# Only dojjo is stood in for. Its post-start run leaves `.hook-proof` in the
# directory it ran in -- the file the wrapper's hook config asks for -- so "the
# hooks ran, and they ran in the NEW workspace" is proven by a file in a
# directory no stand-in created.
#
# Two lines per invocation: the arguments as one bare line, so
# `grep -Fxq 'hook post-start'` is an exact answer about what was asked, and a
# `cwd=` line for where it was asked from.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/djo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DJOLOG"
printf 'cwd=%s\n' "$PWD" >>"$DJOLOG"
if [ "$*" = "hook post-start" ]; then
  : >.hook-proof
fi
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
# a PATH that has no djo at all.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# puts the REAL dojjo on the PATH whatever this test sets it to -- which would
# hand the cases below the tool the stand-in exists to replace, and would spend
# the create running the wrapper's real hooks.
run_jws() {
  local dir=$1
  shift
  ran=$((ran + 1))
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
# it too -- which is what makes the stand-in's `.hook-proof` meaningful.
( cd "$tmp/w/main" && jj describe -m seed >/dev/null 2>&1 && jj new >/dev/null 2>&1 )

run_jws "$tmp/w" --path-file path.txt feat/x
if [ "$status" -ne 0 ]; then
  fail "a create exits 0" "exit $status: $(cat "$tmp/err")"
fi
if [ "$(cat "$tmp/w/path.txt" 2>/dev/null || true)" != "$tmp/w/feat-x" ]; then
  fail "--path-file holds the workspace path, resolved against the caller" \
    "wanted $tmp/w/feat-x, got: $(cat "$tmp/w/path.txt" 2>/dev/null || echo '<no file>')"
fi
# awk rather than `wc -l <file`: a redirect onto a file that is not there is
# an error bash prints itself, which no `2>/dev/null` on the command can quiet.
if [ "$(awk 'END { print NR }' "$tmp/w/path.txt" 2>/dev/null || true)" != 1 ]; then
  fail "--path-file is one line" "lines: $(awk 'END { print NR }' "$tmp/w/path.txt" 2>/dev/null)"
fi
if [ ! -d "$tmp/w/feat-x" ]; then
  fail "the workspace directory exists" "no $tmp/w/feat-x"
fi
# feat/x -> feat-x, and the workspace is NAMED for the branch, not the directory
# (the picker and the done flow both look workspaces up by branch name).
if ! ( cd "$tmp/w" && jj --ignore-working-copy bookmark list -T 'name ++ "\n"' ) |
  grep -Fxq 'feat/x'; then
  fail "the create makes a bookmark named for the branch" \
    "$(cd "$tmp/w" && jj --ignore-working-copy bookmark list -T 'name ++ "\n"')"
fi
if [ ! -f "$tmp/w/feat-x/.hook-proof" ]; then
  fail "the post-start hooks ran, in the new workspace" "no $tmp/w/feat-x/.hook-proof"
fi
if ! djo_asked 'hook post-start'; then
  fail "dojjo is asked to run the hooks" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi
if ! djo_ran_in "$tmp/w/feat-x"; then
  fail "the hooks run inside the new workspace" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi
# dojjo is named in exactly two places in this flow, and a create is one of
# them: a second invocation here would be a `djo switch`, which dies on its
# state file in this layout after making the workspace (constraint 15).
if [ "$(grep -vc '^cwd=' "$tmp/djo.log" 2>/dev/null || true)" != 1 ]; then
  fail "a create runs dojjo exactly once, for the hooks" "$(cat "$tmp/djo.log" 2>/dev/null)"
fi

# A destination that is already there is refused, and named: two branches can
# sanitise to one directory (feat/x and feat-x both want <wrapper>/feat-x), and
# adopting the directory that is there would put the new branch in somebody
# else's workspace.
mkdir -p "$tmp/w/feat-y"
run_jws "$tmp/w" --path-file "$tmp/refused-path.txt" feat/y
if [ "$status" -ne 1 ]; then
  fail "an existing destination is refused" "exit $status: $(cat "$tmp/err")"
fi
if ! grep -Fq "$tmp/w/feat-y" "$tmp/err"; then
  fail "the refusal names the destination" "$(cat "$tmp/err")"
fi
if [ -e "$tmp/refused-path.txt" ]; then
  fail "a refusal writes no path file" "$(cat "$tmp/refused-path.txt")"
fi
if [ -e "$tmp/djo.log" ]; then
  fail "a refusal runs no dojjo" "$(cat "$tmp/djo.log")"
fi

# A caller outside any wrapper: the walk finds no .jj/repo and says so, rather
# than making a workspace somewhere up the tree.
mkdir -p "$tmp/outside"
run_jws "$tmp/outside" feat/z
if [ "$status" -ne 1 ]; then
  fail "a caller with no wrapper is refused" "exit $status: $(cat "$tmp/err")"
fi
if ! grep -Fq 'no jj repo' "$tmp/err"; then
  fail "the refusal names the missing jj repo" "$(cat "$tmp/err")"
fi

# A wrapper with no main workspace: the flow has no other notion of where a
# workspace is created from -- asking for one is the failure.
make_wrapper "$tmp/nomain"
rm -rf "$tmp/nomain/main"
run_jws "$tmp/nomain" feat/z
if [ "$status" -ne 1 ]; then
  fail "a wrapper without main is refused" "exit $status: $(cat "$tmp/err")"
fi
if ! grep -Fq "$tmp/nomain/main" "$tmp/err"; then
  fail "the refusal names the base workspace it wanted" "$(cat "$tmp/err")"
fi

# No dojjo on the PATH: refused before anything else, because a workspace whose
# hooks never ran is a workspace the person has to finish by hand. fish is put
# on that PATH alone (with /usr/bin:/bin for dirname) so djo really is absent.
mkdir -p "$tmp/min-bin"
ln -sf "$(command -v fish)" "$tmp/min-bin/fish"
JWS_PATH="$tmp/min-bin:/usr/bin:/bin" run_jws "$tmp/w/main" feat/q
if [ "$status" -ne 1 ]; then
  fail "no djo is refused" "exit $status: $(cat "$tmp/err")"
fi
if ! grep -Fq 'djo' "$tmp/err"; then
  fail "the refusal names djo" "$(cat "$tmp/err")"
fi
if [ -d "$tmp/w/feat-q" ]; then
  fail "no djo refuses before anything is created" "$tmp/w/feat-q exists"
fi

# A path file that cannot be written: the workspace is already made, so this is
# the one failure where the person has a workspace and no way to be told where
# it is -- it has to be loud and non-zero rather than a shell warning.
run_jws "$tmp/w" --path-file "$tmp/no-such-dir/path.txt" feat/w2
if [ "$status" -ne 1 ]; then
  fail "an unwritable path file is refused" "exit $status: $(cat "$tmp/err")"
fi
if ! grep -Fq 'could not write the path' "$tmp/err"; then
  fail "the refusal names the path file" "$(cat "$tmp/err")"
fi

# --attach and --existing start from something that already exists, so a base
# revision beside them is a contradiction -- and it is caught before a workspace
# is made, not after.
for mode in --attach --existing; do
  run_jws "$tmp/w" "$mode" feat/a main
  if [ "$status" -ne 1 ]; then
    fail "$mode with a base revision is refused" "exit $status: $(cat "$tmp/err")"
  fi
  if [ -d "$tmp/w/feat-a" ]; then
    fail "$mode with a base revision creates nothing" "$tmp/w/feat-a exists"
  fi
done

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
