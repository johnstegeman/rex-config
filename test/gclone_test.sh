#!/usr/bin/env bash
# gclone: the fish function that clones an existing remote into the wrapper
# shape -- bare .git at the wrapper, main created by worktrunk, beads recovered.
#
# The end state this test holds gclone to:
#
#   <wrapper>/.git     a BARE repo whose origin is the remote
#   <wrapper>/main     main's worktree, created by `wt switch main` (so the
#                      project's post-start hooks run)
#   <wrapper>/.beads   a beads db recovered from the remote's refs/dolt/data
#                      by `bd bootstrap`
#   <wrapper>/         and no .jj anywhere, no setup worktree, no chore/setup
#                      branch left behind
#
# The function under test is the DEVELOPER's file: it lives in
# ~/.config/fish/functions, it is not in this repo and it is not versioned. The
# test reads it from ${GCLONE_FILE:-$HOME/.config/fish/functions/gclone.fish} and
# FAILS -- it does not skip -- when it is not there, naming the path it wanted.
#
# What is real and what is a stand-in:
#
#   real     git, worktrunk (the whole point: `wt switch` must create the
#            worktree and run the project's post-start hooks), fish, and the fish
#            function itself
#   stand-in bd, because a real bootstrap costs seconds and this file runs in the
#            default `bash test/run.sh`. The stand-in records every call (cwd and
#            arguments) and leaves the files bd leaves, so the shape assertions
#            below are about gclone, not about bd. It also refuses to bootstrap
#            unless the wrapper gclone was supposed to build is really there, so
#            a gclone that skipped the bare repo cannot get past it.
#   stand-in rex: gclone ends by renaming the window, and a test that renamed the
#            developer's real window would be a test with a side effect.
#   opt-in   REX_TEST_REAL_BD=1 re-runs gclone with the REAL bd against a fixture
#            whose dolt database was pushed by bd itself, and asserts the issue
#            that came with it -- the one thing a stand-in cannot prove. It is
#            not part of the default path.
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
    printf 'gclone_test: %s is required to run this test and is not on PATH\n' "$tool" >&2
    exit 1
  fi
done

export GCLONE_FILE=${GCLONE_FILE:-$HOME/.config/fish/functions/gclone.fish}
export HIJACK=$tmp/hijack
if [ ! -f "$GCLONE_FILE" ]; then
  ran=$((ran + 1))
  fail "gclone.fish is missing" "$GCLONE_FILE"
  printf '  the function is a developer file in ~/.config/fish/functions, not a repo file\n'
  exit 1
fi

# Stand-ins ahead of the real programs on PATH. `command -v` in fish still finds
# them: they are executable files, which is all `command` looks for.
shim=$tmp/bin
mkdir -p "$shim"
export REX_ARGS=$tmp/rex-args
export BD_LOG=$tmp/bd-log
: >"$REX_ARGS"
: >"$BD_LOG"

cat >"$shim/rex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$REX_ARGS"
STUB

cat >"$shim/bd" <<'STUB'
#!/bin/sh
# stand-in for bd: record the call, then leave the files bd leaves.
printf '%s\t%s\n' "$PWD" "$*" >>"$BD_LOG"
case "$1" in
  bootstrap)
    # bootstrap recovers a database INTO a repository, and in the wrapper layout
    # that repository is the wrapper: the bare .git this worktree belongs to.
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
      printf 'standin bd: not inside a git repository (%s)\n' "$PWD" >&2
      exit 1
    }
    wrapper=$(dirname "$common")
    if [ ! -d "$wrapper/.git" ]; then
      printf 'standin bd: no wrapper at %s\n' "$wrapper" >&2
      exit 1
    fi
    mkdir -p "$wrapper/.beads/embeddeddolt"
    printf '{\n  "database": "dolt",\n  "backend": "dolt",\n  "dolt_mode": "embedded",\n  "dolt_database": "beads"\n}\n' \
      >"$wrapper/.beads/metadata.json"
    printf 'sync:\n    remote: "%s"\n' "$(git -C "$wrapper" config --get remote.origin.url)" \
      >"$wrapper/.beads/config.yaml"
    ;;
  init)
    # bd init anchors at the directory it is run from
    mkdir -p "$PWD/.beads/embeddeddolt"
    printf '{\n  "database": "dolt",\n  "backend": "dolt",\n  "dolt_mode": "embedded",\n  "dolt_database": "beads"\n}\n' \
      >"$PWD/.beads/metadata.json"
    printf 'sync:\n    remote: "%s"\n' "$(git config --get remote.origin.url)" \
      >"$PWD/.beads/config.yaml"
    ;;
esac
exit 0
STUB
chmod +x "$shim/rex" "$shim/bd"
# the PATH without the stand-ins, for the opt-in pass that wants the real bd
base_path=$PATH
export PATH=$shim:$PATH

# A `cd` that refuses to change directory, ahead of everything else on
# fish_function_path. On this machine the user's `cd` IS a jumper (`ze`) that
# resolves a name to "wherever you probably meant" -- a function that relies on
# it can end up running its next command in a different repository. The functions
# under test therefore say `builtin cd`, and this stub is what makes that a test
# rather than a preference: against the stub, a plain `cd` fails loudly.
mkdir -p "$tmp/hijack"
cat >"$tmp/hijack/cd.fish" <<'FISH'
function cd
    echo "cd: hijacked (a function in this flow must use `builtin cd`)" >&2
    return 1
end
FISH

# run_gclone WORKDIR ARGS... ; stdout in $tmp/out, stderr in $tmp/err, and the
# function's OWN exit status in $status -- which is part of the contract.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# rewrites the PATH; the function is sourced by path instead. Its own directory
# goes on fish_function_path after the refusing `cd` above, and it is also where
# `wt` (worktrunk's shell integration) is autoloaded from -- so the function runs
# here in the namespace it really runs in. stdin is /dev/null
# because bd detects a non-TTY and takes its non-interactive defaults; a pane with
# nobody at the keyboard is that case too.
run_gclone() {
  local dir=$1
  shift
  ( cd "$dir" && fish --no-config -c \
    'set -g fish_function_path "$HIJACK" (dirname "$GCLONE_FILE"); source "$GCLONE_FILE"; gclone $argv' \
    -- "$@" ) </dev/null >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# A real remote with real history: two commits on main, the second carrying the
# files a wrapper's main worktree is expected to hold. The seed is a plain
# `git init`, not an empty clone: an empty clone's branch name is whatever the
# remote HEAD says, and the commits below want a branch they can name.
remote=$tmp/remote.git
git init -q --bare -b main "$remote" || exit 1
seed=$tmp/seed
git init -q -b main "$seed" || exit 1
git -C "$seed" remote add origin "$remote" || exit 1
printf '# recovered\n' >"$seed/README.md"
git -C "$seed" add . || exit 1
git -C "$seed" -c user.name=t -c user.email=t@t commit -qm 'seed one: README' || exit 1
mkdir -p "$seed/.config"
printf '%s\n' \
  '[post-start]' \
  'copy = "wt step copy-ignored --require-include"' \
  >"$seed/.config/wt.toml"
printf '%s\n' .env .worktrees/ .beads/ >"$seed/.gitignore"
printf '%s\n' '.env*' >"$seed/.worktreeinclude"
git -C "$seed" add . || exit 1
git -C "$seed" -c user.name=t -c user.email=t@t commit -qm 'seed two: hooks and ignore' || exit 1
git -C "$seed" push -q -u origin main || exit 1
tip=$(git -C "$seed" rev-parse HEAD)

# The wrapper under test, built the way a clone is: from $tmp, into a directory
# that does not exist yet. The marker is what "a hook ran during this gclone"
# is measured against below.
touch "$tmp/marker"
run_gclone "$tmp" "$remote" w
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "gclone exits 0 for an existing remote" "exit $status: $(cat "$tmp/err")$(cat "$tmp/out")"
fi

# 1. A BARE .git at the wrapper, pointing at the remote, and no jj repo anywhere.
#    Bare is the point: the wrapper is not a working copy, so the .beads database
#    sitting at its root is nobody's untracked noise.
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

# 2. main's worktree, and ONLY main's: the setup worktree gclone makes to run
#    bootstrap in is gone, and so is its branch.
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
  fail "the setup worktree is removed" "$tmp/w/setup still exists"
fi
ran=$((ran + 1))
setup_branch=$(git -C "$tmp/w" branch --list chore/setup 2>/dev/null)
if [ -n "$setup_branch" ]; then
  fail "the setup branch is deleted" "[$setup_branch]"
fi

# 3. The history actually arrived, and it is the remote's.
ran=$((ran + 1))
main_head=$(git -C "$tmp/w/main" rev-parse HEAD 2>/dev/null)
if [ "$main_head" != "$tip" ]; then
  fail "main sits on the remote's tip" "main: $main_head, remote: $tip"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/main/README.md" ]; then
  fail "main's working copy holds the cloned files" "no $tmp/w/main/README.md"
fi
# ... and main tracks origin/main, so a later pull has something to pull from.
ran=$((ran + 1))
upstream=$(git -C "$tmp/w/main" rev-parse --abbrev-ref 'main@{upstream}' 2>/dev/null)
if [ "$upstream" != 'origin/main' ]; then
  fail "main tracks origin/main" "upstream: [$upstream]"
fi

# 4. The project's hooks arrived with the clone, AND RAN: worktrunk created the
#    worktree, which is the whole reason gclone switches with `wt` instead of
#    `git worktree add` -- that call is what reads the hook table and runs it.
#    worktrunk logs each hook it runs inside the bare .git; post-start is
#    backgrounded, hence the wait.
ran=$((ran + 1))
if [ ! -f "$tmp/w/main/.config/wt.toml" ]; then
  fail "main carries the cloned hook config" "no $tmp/w/main/.config/wt.toml"
fi
ran=$((ran + 1))
if ! grep -Fxq 'copy = "wt step copy-ignored --require-include"' "$tmp/w/main/.config/wt.toml" 2>/dev/null; then
  fail "the hook config is the cloned one" "$(cat "$tmp/w/main/.config/wt.toml" 2>&1)"
fi
ran=$((ran + 1))
if ! hook_ran_since "$tmp/w/.git/wt/logs" "$tmp/marker" >/dev/null; then
  fail "worktrunk ran the cloned post-start hook" \
    "no post-start log under $tmp/w/.git/wt/logs"
fi

# 5. Beads at the WRAPPER root, where every other part of the flow reads it (bd
#    walks up from whichever worktree is asking), and not inside main.
ran=$((ran + 1))
if [ ! -d "$tmp/w/.beads/embeddeddolt" ]; then
  fail "the recovered beads db is at the wrapper root" "no $tmp/w/.beads/embeddeddolt"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/main/.beads" ]; then
  fail "main carries no beads db of its own" "$tmp/w/main/.beads exists"
fi
# The config is what a later `bd dolt push` reads: the sync remote has to be the
# git remote, not whatever the clone inherited.
ran=$((ran + 1))
wrapper_config=$(cat "$tmp/w/.beads/config.yaml" 2>/dev/null)
if ! grep -Eq "^[[:space:]]*remote:[[:space:]]*\"?$remote\"?[[:space:]]*$" <<<"$wrapper_config"; then
  fail "the wrapper's beads config names the git remote as its sync remote" "[$wrapper_config]"
fi
# ... and the recovered database is named, not left to whatever bd guessed.
ran=$((ran + 1))
if ! grep -Fq '"dolt_database": "beads"' "$tmp/w/.beads/metadata.json" 2>/dev/null; then
  fail "the recovered database is named beads" "$(cat "$tmp/w/.beads/metadata.json" 2>&1)"
fi
# The db holds issues, so it is not for everyone to read: bd's own
# recommendation, and gclone's `chmod 700`.
ran=$((ran + 1))
beads_mode=$(ls -ld "$tmp/w/.beads" 2>/dev/null | cut -c1-10)
if [ "$beads_mode" != 'drwx------' ]; then
  fail "the beads directory is 0700" "[$beads_mode]"
fi

# 6. bd was bootstrapped from the setup worktree -- once, and with the wrapper as
#    its target. The stand-in logs every call with its cwd.
ran=$((ran + 1))
if ! grep -Fxq "$tmp/w/setup	bootstrap --yes" "$BD_LOG"; then
  fail "bd bootstrap ran from the setup worktree" "bd log: $(tr '\t' ' ' <"$BD_LOG" | paste -sd';' -)"
fi
ran=$((ran + 1))
if [ "$(grep -c . "$BD_LOG")" -ne 1 ]; then
  fail "gclone runs no other bd command" "bd log: $(tr '\t' ' ' <"$BD_LOG" | paste -sd';' -)"
fi

# 7. And it ends where gclone ends: the window is titled for the workspace the
#    person is now in.
ran=$((ran + 1))
if [ "$(cat "$REX_ARGS")" != 'window rename main' ]; then
  fail "gclone renames the window to main" "rex got: [$(cat "$REX_ARGS")]"
fi

# 8. The usage refusal, and the fact that it creates nothing: a clone that starts
#    on a half-typed line must not leave a directory behind.
run_gclone "$tmp" only
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "one argument is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'usage: gclone' "$tmp/err"; then
  fail "the refusal is the usage line" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/only" ]; then
  fail "a usage refusal creates nothing" "$tmp/only exists"
fi

# 9. The opt-in: the same function against the REAL bd, on a fixture whose dolt
#    database was pushed by bd itself. A stand-in cannot prove the recovery, and
#    this is the only coverage the recovery will ever have -- but it costs
#    seconds, so it is not in the default path.
if [ "${REX_TEST_REAL_BD:-0}" = 1 ]; then
  if ! command -v bd >/dev/null 2>&1; then
    printf 'gclone_test: REX_TEST_REAL_BD=1 needs bd on PATH\n' >&2
    exit 1
  fi
  set_path=$PATH
  export PATH=$base_path
  real_remote=$tmp/real-remote.git
  real_seed=$tmp/real-seed
  git init -q --bare -b main "$real_remote" || exit 1
  git init -q -b main "$real_seed" || exit 1
  git -C "$real_seed" remote add origin "$real_remote" || exit 1
  printf '# recovered\n' >"$real_seed/README.md"
  mkdir -p "$real_seed/.config"
  printf '%s\n' '[post-start]' 'copy = "wt step copy-ignored --require-include"' \
    >"$real_seed/.config/wt.toml"
  printf '%s\n' '.env*' >"$real_seed/.worktreeinclude"
  printf '%s\n' .env .beads/ >"$real_seed/.gitignore"
  git -C "$real_seed" add . || exit 1
  git -C "$real_seed" -c user.name=t -c user.email=t@t commit -qm 'seed: README' || exit 1
  git -C "$real_seed" push -q -u origin main || exit 1
  seed_issue='recovered from refs/dolt/data'
  (
    cd "$real_seed" || exit 1
    bd init --skip-hooks --skip-agents >/dev/null 2>&1 || exit 1
    bd create "$seed_issue" --type task -d 'proves the db was recovered' >/dev/null 2>&1 || exit 1
    bd dolt remote add origin "$real_remote" --allow-git-origin >/dev/null 2>&1 || exit 1
    bd dolt push >/dev/null 2>&1 || exit 1
  ) </dev/null || {
    ran=$((ran + 1))
    fail "the real fixture remote carries refs/dolt/data" "bd could not build or push the seed database"
  }
  # the real bd, not the stand-in -- but the rex stand-in stays
  realbin=$tmp/realbin
  mkdir -p "$realbin"
  cp "$shim/rex" "$realbin/rex"
  PATH=$realbin:$base_path run_gclone "$tmp" "$real_remote" rw
  ran=$((ran + 1))
  if [ "$status" -ne 0 ]; then
    fail "gclone exits 0 against the real bd" "exit $status: $(cat "$tmp/err")"
  fi
  ran=$((ran + 1))
  recovered=$( cd "$tmp/rw/main" 2>/dev/null && bd list --json 2>/dev/null )
  if ! grep -Fq "$seed_issue" <<<"$recovered"; then
    fail "the issue from the remote is in the recovered database" "bd list says: [$recovered]"
  fi
  ran=$((ran + 1))
  if [ -z "$(git -C "$real_remote" for-each-ref --format='%(refname)' refs/dolt/data 2>/dev/null)" ]; then
    fail "the fixture remote still holds refs/dolt/data" "no refs/dolt/data on $real_remote"
  fi
  ran=$((ran + 1))
  rw_jj=$(find "$tmp/rw" -maxdepth 3 -name .jj -print -quit 2>/dev/null)
  if [ -n "$rw_jj" ]; then
    fail "the real-bd wrapper has no .jj either" "found $rw_jj"
  fi
  export PATH=$set_path
else
  printf '(skipping the real-bd pass; REX_TEST_REAL_BD=1 runs it)\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
