#!/usr/bin/env bash
# ginit: the fish function that builds a fresh wrapper from an EMPTY remote.
#
# The end state this test holds ginit to:
#
#   <wrapper>/.git     a BARE repo whose origin is the remote, HEAD on main
#   <wrapper>/main     main's worktree, created by `wt switch main` (so the
#                      seeded post-start hooks run)
#   <wrapper>/.beads   a fresh beads db at the wrapper root, dolt remote = the
#                      git remote, pushed
#   <wrapper>/         and no .jj anywhere, no setup worktree, no chore/setup
#                      branch left behind
#
# ginit is gclone's sibling: same wrapper shape, but the repo is created here
# rather than recovered, so the first commit is a SEED ginit writes itself
# (README, .gitignore, .worktreeinclude, .config/wt.toml) and beads is minted
# with `bd init` instead of bootstrapped.
#
# The function under test is the DEVELOPER's file: it lives in
# ~/.config/fish/functions, it is not in this repo and it is not versioned. The
# test reads it from ${GINIT_FILE:-$HOME/.config/fish/functions/ginit.fish} and
# FAILS -- it does not skip -- when it is not there, naming the path it wanted.
#
# What is real and what is a stand-in:
#
#   real     git, worktrunk (the whole point: `wt switch` must create the worktree
#            and run its hooks, and a create through `wt switch --create` must
#            inherit them), fish, and the fish function itself
#   stand-in bd, because a real init plus dolt push costs seconds and this file
#            runs in the default `bash test/run.sh`. The stand-in records every
#            call (cwd and arguments) and leaves the files bd leaves, so the shape
#            assertions below are about ginit, not about bd.
#   opt-in   REX_TEST_REAL_BD=1 re-runs ginit with the REAL bd and asserts the db,
#            its dolt remote and the refs/dolt/data the push left on the remote --
#            the one thing a stand-in cannot prove. Not part of the default path.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
# The physical path: on macOS /var is a symlink to /private/var, so the /var form
# mktemp prints would never equal the paths git and worktrunk answer with, and
# every path assertion below would fail for the wrong reason.
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '  %s\n' "$2"
  fi
}

# hook_ran_since LOGROOT MARKER -> prints the log of a post-start hook worktrunk
# ran after MARKER was touched, once one appears (up to ~5 s), else nothing.
# Two reasons for looking rather than naming the file: post-start hooks are
# BACKGROUNDED, so the log can land just after the command that triggered them
# has returned; and worktrunk names the per-worktree log directory itself, so a
# hard-coded path is a guess about its scheme rather than an assertion about the
# hook.
hook_ran_since() {
  local i=0 log
  while [ "$i" -lt 100 ]; do
    log=$(find "$1" -path '*/post-start/copy.log' -newer "$2" -print 2>/dev/null | head -1)
    if [ -n "$log" ]; then
      printf '%s\n' "$log"
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# A missing tool is a broken machine, not a passing test: say so loudly rather
# than letting the cases below pass for the wrong reason.
for tool in fish git wt; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'ginit_test: %s is required to run this test and is not on PATH\n' "$tool" >&2
    exit 1
  fi
done

export GINIT_FILE=${GINIT_FILE:-$HOME/.config/fish/functions/ginit.fish}
export HIJACK=$tmp/hijack
if [ ! -f "$GINIT_FILE" ]; then
  ran=$((ran + 1))
  fail "ginit.fish is missing" "$GINIT_FILE"
  printf '  the function is a developer file in ~/.config/fish/functions, not a repo file\n'
  exit 1
fi

# The bd stand-in ahead of the real one on PATH. `command -v` in fish still finds
# it: it is an executable file, which is all `command` looks for.
shim=$tmp/bin
mkdir -p "$shim"
export BD_LOG=$tmp/bd-log
: >"$BD_LOG"

cat >"$shim/bd" <<'STUB'
#!/bin/sh
# stand-in for bd: record the call, then leave the files bd leaves.
printf '%s\t%s\n' "$PWD" "$*" >>"$BD_LOG"
case "$1" in
  init)
    # bd init anchors at the directory it is run from, and takes the sync remote
    # from that repository's git origin
    mkdir -p "$PWD/.beads/embeddeddolt"
    printf '{\n  "database": "dolt",\n  "backend": "dolt",\n  "dolt_mode": "embedded",\n  "dolt_database": "beads"\n}\n' \
      >"$PWD/.beads/metadata.json"
    printf 'sync:\n    remote: "%s"\n' "$(git config --get remote.origin.url)" \
      >"$PWD/.beads/config.yaml"
    ;;
esac
exit 0
STUB
chmod +x "$shim/bd"
export PATH=$shim:$PATH

# A `cd` that refuses to change directory, ahead of everything else on
# fish_function_path. On this machine the user's `cd` IS a jumper (`ze`) that
# resolves a name to "wherever you probably meant" -- a function that relies on it
# can end up creating a worktree in one repository and pushing from another. The
# functions under test therefore say `builtin cd`, and this stub is what makes
# that a test rather than a preference: against the stub, a plain `cd` fails.
mkdir -p "$tmp/hijack"
cat >"$tmp/hijack/cd.fish" <<'FISH'
function cd
    echo "cd: hijacked (a function in this flow must use `builtin cd`)" >&2
    return 1
end
FISH

# run_ginit WORKDIR ARGS... ; stdout in $tmp/out, stderr in $tmp/err, and the
# function's OWN exit status in $status -- which is the whole contract.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# rewrites the PATH; the function is sourced by path instead. Its own directory
# goes on fish_function_path after the refusing `cd` above, and it is also where
# `wt` (worktrunk's shell integration) is autoloaded from -- so the function runs
# here in the namespace it really runs in. stdin is /dev/null
# because bd detects a non-TTY and takes its non-interactive defaults; a pane with
# nobody at the keyboard is that case too.
run_ginit() {
  local dir=$1
  shift
  ( cd "$dir" && fish --no-config -c \
    'set -g fish_function_path "$HIJACK" (dirname "$GINIT_FILE"); source "$GINIT_FILE"; ginit $argv' \
    -- "$@" ) </dev/null >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# A real, EMPTY remote: ginit's assumption, and gclone's opposite.
remote=$tmp/remote.git
git init -q --bare -b main "$remote" || exit 1

# The wrapper under test, from an empty remote, built exactly as a person would
# run it: from $tmp, into a directory that does not exist yet.
touch "$tmp/marker"
run_ginit "$tmp" w "$remote"
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "ginit exits 0 for a fresh wrapper" "exit $status: $(cat "$tmp/err")$(cat "$tmp/out")"
fi

# 1. A BARE .git at the wrapper, pointing at the remote, and no jj repo anywhere.
ran=$((ran + 1))
if [ ! -d "$tmp/w/.git" ]; then
  fail "the wrapper holds .git" "no $tmp/w/.git"
elif [ "$(git -C "$tmp/w" rev-parse --is-bare-repository 2>&1)" != true ]; then
  fail "the wrapper's .git is bare" "git says: $(git -C "$tmp/w" rev-parse --is-bare-repository 2>&1)"
fi
ran=$((ran + 1))
origin=$(git -C "$tmp/w" config --get remote.origin.url 2>/dev/null)
if [ "$origin" != "$remote" ]; then
  fail "the wrapper's origin is the remote" "origin: [$origin]"
fi
ran=$((ran + 1))
jj_dir=$(find "$tmp/w" -maxdepth 3 -name .jj -print -quit 2>/dev/null)
if [ -n "$jj_dir" ]; then
  fail "there is no .jj anywhere in the wrapper" "found $jj_dir"
fi

# 2. main's worktree, made by wt, and only main's.
ran=$((ran + 1))
worktrees=$(git -C "$tmp/w" worktree list --porcelain 2>/dev/null)
if ! grep -Fxq "worktree $tmp/w/main" <<<"$worktrees"; then
  fail "main is a registered worktree at <wrapper>/main" "$worktrees"
fi
ran=$((ran + 1))
if ! grep -Fxq 'branch refs/heads/main' <<<"$worktrees"; then
  fail "main's worktree has main checked out" "$worktrees"
fi
ran=$((ran + 1))
registrations=$(grep -c '^worktree ' <<<"$worktrees")
if [ "$registrations" -ne 2 ]; then
  fail "the wrapper registers the bare repo and main, nothing else" "$worktrees"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/setup" ]; then
  fail "the seed worktree is removed" "$tmp/w/setup still exists"
fi
ran=$((ran + 1))
setup_branch=$(git -C "$tmp/w" branch --list chore/setup 2>/dev/null)
if [ -n "$setup_branch" ]; then
  fail "the seed branch is deleted" "[$setup_branch]"
fi

# 3. The seed commit, read from the REMOTE rather than from the working copy:
#    "the seed was committed and pushed" is what a fresh clone gets, and it is
#    read with git because this is the second opinion from the other side.
ran=$((ran + 1))
seed_files=$(git -C "$remote" ls-tree -r --name-only main 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
for want in README.md .gitignore .worktreeinclude .config/wt.toml; do
  ran=$((ran + 1))
  grep -Fq -- "$want " <<<"$seed_files" || {
    fail "the pushed seed commit carries $want" "remote main holds: [$seed_files]"
  }
done
# ... and NOTHING else: the seed is four files. A fifth would mean the wrapper
# directory (main/, .beads/, the worktree registration) was committed with it.
ran=$((ran + 1))
if [ "$seed_files" != '.config/wt.toml .gitignore .worktreeinclude README.md ' ]; then
  fail "the seed commit carries nothing but the seed" "remote main holds: [$seed_files]"
fi
# The ignore rules themselves: they are this commit's content, and a wrong
# .gitignore means an ignored file (.env, a db) walks into a later commit.
ran=$((ran + 1))
seed_gitignore=$(git -C "$remote" show main:.gitignore 2>/dev/null)
if [ "$seed_gitignore" != $'.env\n.worktrees/\n.beads/' ]; then
  fail "the seed .gitignore is ginit's three entries" "[$seed_gitignore]"
fi
# .worktreeinclude is worktrunk's copy hook's include list, and it is GLOB form
# (`.env*`), which is what `wt step copy-ignored --require-include` matches on.
ran=$((ran + 1))
seed_include=$(git -C "$remote" show main:.worktreeinclude 2>/dev/null)
if [ "$seed_include" != '.env*' ]; then
  fail "the seed .worktreeinclude is the glob form" "[$seed_include]"
fi

# 4. The seed commit is main's tip, main tracks it, and the wrapper's HEAD is
#    main -- so the next `wt switch --create` has a base to branch from.
ran=$((ran + 1))
seed_tip=$(git -C "$remote" rev-parse main 2>/dev/null)
main_head=$(git -C "$tmp/w/main" rev-parse HEAD 2>/dev/null)
if [ "$main_head" != "$seed_tip" ]; then
  fail "main sits on the seed commit" "main: $main_head, remote main: $seed_tip"
fi
ran=$((ran + 1))
upstream=$(git -C "$tmp/w/main" rev-parse --abbrev-ref 'main@{upstream}' 2>/dev/null)
if [ "$upstream" != 'origin/main' ]; then
  fail "main tracks origin/main" "upstream: [$upstream]"
fi

# 5. The hook config in the shape WORKTRUNK reads: a top-level [post-start] table.
#    (The dojjo-era shape, [hooks.post-start], parses but runs nowhere.)
wt_toml=$tmp/w/main/.config/wt.toml
ran=$((ran + 1))
if [ ! -f "$wt_toml" ]; then
  fail "main carries the hook config" "no $wt_toml"
else
  ran=$((ran + 1))
  grep -Fxq '[post-start]' "$wt_toml" ||
    fail "the hook config uses the top-level [post-start] table" "$(cat "$wt_toml")"
  ran=$((ran + 1))
  if grep -Eq '^\[hooks\.' "$wt_toml"; then
    fail "the hook config is not in the dojjo-era [hooks.*] form" "$(cat "$wt_toml")"
  fi
  ran=$((ran + 1))
  grep -Fxq 'copy = "wt step copy-ignored --require-include"' "$wt_toml" ||
    fail "the post-start hook copies the ignored files with worktrunk" "$(cat "$wt_toml")"
  ran=$((ran + 1))
  if grep -Fq 'jj ' "$wt_toml"; then
    fail "the hook config has no jj row" "$(cat "$wt_toml")"
  fi
fi
# ... and worktrunk RAN it when it made main, which is why ginit lets `wt switch`
# create the worktree instead of running `git worktree add` first. The hook is a
# post-start one, so it is backgrounded: wait for the log worktrunk writes.
ran=$((ran + 1))
if ! hook_ran_since "$tmp/w/.git/wt/logs" "$tmp/marker" >/dev/null; then
  fail "worktrunk ran the seeded post-start hook for main" \
    "no post-start log under $tmp/w/.git/wt/logs"
fi

# 6. Beads at the WRAPPER root -- where bd's upward detection finds it from any
#    worktree -- and not inside main.
ran=$((ran + 1))
if [ ! -d "$tmp/w/.beads/embeddeddolt" ]; then
  fail "the beads db is at the wrapper root" "no $tmp/w/.beads/embeddeddolt"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/main/.beads" ]; then
  fail "main carries no beads db of its own" "$tmp/w/main/.beads exists"
fi
ran=$((ran + 1))
wrapper_config=$(cat "$tmp/w/.beads/config.yaml" 2>/dev/null)
if ! grep -Eq "^[[:space:]]*remote:[[:space:]]*\"?$remote\"?[[:space:]]*$" <<<"$wrapper_config"; then
  fail "the wrapper's beads config names the git remote as its sync remote" "[$wrapper_config]"
fi
ran=$((ran + 1))
beads_mode=$(ls -ld "$tmp/w/.beads" 2>/dev/null | cut -c1-10)
if [ "$beads_mode" != 'drwx------' ]; then
  fail "the beads directory is 0700" "[$beads_mode]"
fi

# 7. The three bd calls, in order and from the wrapper: init mints the db where
#    the flow will look for it, then the dolt remote names the git remote, then
#    the first push puts the db's history on it.
bd_calls=$(tr '\t' ' ' <"$BD_LOG")
ran=$((ran + 1))
if [ "$(sed -n 1p "$BD_LOG")" != "$tmp/w	init --skip-hooks --skip-agents" ]; then
  fail "bd init runs from the wrapper" "bd log: [$bd_calls]"
fi
ran=$((ran + 1))
if [ "$(sed -n 2p "$BD_LOG")" != "$tmp/w	dolt remote add origin $remote --allow-git-origin" ]; then
  fail "the dolt remote is the git remote" "bd log: [$bd_calls]"
fi
ran=$((ran + 1))
if [ "$(sed -n 3p "$BD_LOG")" != "$tmp/w	dolt push" ]; then
  fail "the db is pushed before ginit returns" "bd log: [$bd_calls]"
fi
ran=$((ran + 1))
if [ "$(grep -c . "$BD_LOG")" -ne 3 ]; then
  fail "ginit runs exactly three bd commands" "bd log: [$bd_calls]"
fi

# 8. The wrapper is one the flow can work in. This is the end-to-end assertion:
#    a create through worktrunk lands at <wrapper>/feat-q, inherits main's hook
#    config, and there is still no .jj afterwards.
touch "$tmp/create-marker"
( cd "$tmp/w/main" && wt -y switch --create feat/q --format=json ) \
  </dev/null >"$tmp/create-out" 2>"$tmp/create-err"
create_status=$?
ran=$((ran + 1))
if [ "$create_status" -ne 0 ]; then
  fail "wt creates a worktree in the fresh wrapper" "exit $create_status: $(cat "$tmp/create-err")"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/feat-q" ]; then
  fail "the created worktree is at <wrapper>/feat-q" "no $tmp/w/feat-q"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/feat-q/.config/wt.toml" ]; then
  fail "the created worktree inherited main's hook config" "no $tmp/w/feat-q/.config/wt.toml"
fi
ran=$((ran + 1))
if ! hook_ran_since "$tmp/w/.git/wt/logs" "$tmp/create-marker" >/dev/null; then
  fail "the created worktree ran the inherited post-start hook" \
    "no post-start log under $tmp/w/.git/wt/logs"
fi
ran=$((ran + 1))
jj_dir=$(find "$tmp/w" -maxdepth 3 -name .jj -print -quit 2>/dev/null)
if [ -n "$jj_dir" ]; then
  fail "a create in the wrapper leaves no .jj behind" "found $jj_dir"
fi

# 9. The two refusals. The first is the usage line; the second is the nest guard,
#    and it matters more here than anywhere: bd init ADOPTS a parent database
#    rather than failing, so a ginit run inside another beads workspace would
#    quietly re-point that workspace's issues at a new prefix.
run_ginit "$tmp" only
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "one argument is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'usage: ginit' "$tmp/err"; then
  fail "the refusal is the usage line" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/only" ]; then
  fail "a usage refusal creates nothing" "$tmp/only exists"
fi

run_ginit "$tmp/w" nested "$remote"
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "a ginit inside another beads workspace is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'refusing to run inside another beads workspace' "$tmp/err"; then
  fail "the nest refusal says what it found" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/w/.beads" "$tmp/err"; then
  fail "the nest refusal names the .beads it found" "$(cat "$tmp/err")"
fi
# Nothing of the refused run survives: the directory it made is gone, and the
# wrapper it was refused inside is untouched -- no second .git, no second db.
ran=$((ran + 1))
if [ -e "$tmp/w/nested" ]; then
  fail "a refused nest removes the directory it made" "$tmp/w/nested still exists"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/.git" ] || [ ! -d "$tmp/w/main" ] || [ -e "$tmp/w/nested" ]; then
  fail "a refused nest leaves the wrapper intact" "$(ls -a "$tmp/w")"
fi

# 10. The opt-in: the same function against the REAL bd. A stand-in cannot prove
#     that the minted database answers, that its dolt remote is the git remote, or
#     that the first push put refs/dolt/data on it -- but a real init plus push
#     costs seconds, so it is not in the default path.
if [ "${REX_TEST_REAL_BD:-0}" = 1 ]; then
  if ! command -v bd >/dev/null 2>&1; then
    printf 'ginit_test: REX_TEST_REAL_BD=1 needs bd on PATH\n' >&2
    exit 1
  fi
  real_remote=$tmp/real-remote.git
  git init -q --bare -b main "$real_remote" || exit 1
  without_shim=${PATH#"$shim:"}
  PATH=$without_shim run_ginit "$tmp" rw "$real_remote"
  ran=$((ran + 1))
  if [ "$status" -ne 0 ]; then
    fail "ginit exits 0 against the real bd" "exit $status: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  if [ ! -d "$tmp/rw/.beads/embeddeddolt" ]; then
    fail "the real bd put its db at the wrapper root" "no $tmp/rw/.beads/embeddeddolt"
  fi
  ran=$((ran + 1))
  if ! ( cd "$tmp/rw/main" && PATH="$without_shim" bd list >/dev/null 2>&1 ); then
    fail "bd answers from inside main" "$( cd "$tmp/rw/main" && PATH="$without_shim" bd list 2>&1 | head -3 )"
  fi
  ran=$((ran + 1))
  dolt_remotes=$( cd "$tmp/rw" && PATH="$without_shim" bd dolt remote list 2>/dev/null )
  if ! grep -Fq "$real_remote" <<<"$dolt_remotes"; then
    fail "the db's dolt remote is the git remote" "[$dolt_remotes]"
  fi
  ran=$((ran + 1))
  if [ -z "$(git -C "$real_remote" for-each-ref --format='%(refname)' refs/dolt/data 2>/dev/null)" ]; then
    fail "the beads history reached the remote" \
      "$(git -C "$real_remote" for-each-ref --format='%(refname)')"
  fi
  ran=$((ran + 1))
  rw_jj=$(find "$tmp/rw" -maxdepth 3 -name .jj -print -quit 2>/dev/null)
  if [ -n "$rw_jj" ]; then
    fail "the real-bd wrapper has no .jj either" "found $rw_jj"
  fi
else
  printf '(skipping the real-bd pass; REX_TEST_REAL_BD=1 runs it)\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
