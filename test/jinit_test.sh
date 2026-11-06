#!/usr/bin/env bash
# jinit: the fish function that builds a fresh wrapper with NO git layer.
#
# jinit is ginit's counterpart for a repo whose remote is plain and empty. The
# end state is the shape the whole new-work flow assumes:
#
#   <wrapper>/.jj      one jj repo for the wrapper
#   <wrapper>/main     the base workspace the flow creates from
#   <wrapper>/         the `default` workspace, sparse-cleared and parked on
#                      root(), so a stray snapshot cannot absorb the wrapper
#   <wrapper>/.beads   a beads db at the wrapper root, dolt remote = git remote
#
# ... and `.git` NOWHERE, which is the point: worktrunk needed a git worktree
# per workspace and jj detaches HEAD in these repos, so this flow is rebuilt on
# jj alone (see docs/superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md).
#
# The function under test is the DEVELOPER's file: it lives in
# ~/.config/fish/functions, it is not in this repo and it is not versioned, the
# same way ginit and gws are. The test reads it from
# ${JINIT_FILE:-$HOME/.config/fish/functions/jinit.fish} and FAILS -- it does not
# skip -- when it is not there, naming the path it wanted.
#
# Everything here is real: a real bare git remote (`git init --bare`) is built
# under $tmp, and a real jj repo, a real beads (embedded Dolt) database and a
# real `jws` create are made in the wrapper, because a stand-in would prove
# nothing about the thing this function is for -- that a wrapper with no git in
# it is a wrapper the rest of the flow works in.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
# The physical path: on macOS /var is a symlink to /private/var, so the /var form
# mktemp prints would never equal the paths jj and git answer with, and every
# path assertion below would fail for the wrong reason.
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '  %s\n' "$2"
  fi
}

# A missing tool is a broken machine, not a passing test: say so loudly rather
# than letting the cases below pass for the wrong reason.
for tool in jj fish bd git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'jinit_test: %s is required to run this test and is not on PATH\n' "$tool" >&2
    exit 1
  fi
done

export JINIT_FILE=${JINIT_FILE:-$HOME/.config/fish/functions/jinit.fish}
if [ ! -f "$JINIT_FILE" ]; then
  ran=$((ran + 1))
  fail "jinit.fish is missing" "$JINIT_FILE"
  printf '  the function is a developer file in ~/.config/fish/functions, not a repo file\n'
  exit 1
fi

# run_jinit WORKDIR ARGS... ; stdout in $tmp/out, stderr in $tmp/err, and the
# function's OWN exit status in $status -- which is the whole contract. Nothing
# here counts an assertion: every check below does that itself, so
# `ok N assertions` is the number of checks and a failure report cannot
# out-count it.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# rewrites the PATH; the function is sourced by path instead. jinit calls `take`
# the way ginit does, and `take` is a function in the same directory -- so that
# directory goes on fish_function_path beside jinit's own. stdin is /dev/null
# because bd detects a non-TTY and takes its non-interactive defaults; a pane
# with nobody at the keyboard is exactly that case too.
run_jinit() {
  local dir=$1
  shift
  ( cd "$dir" && fish --no-config -c 'set -g fish_function_path (dirname "$JINIT_FILE") $HOME/.config/fish/functions; source "$JINIT_FILE"; jinit $argv' \
    -- "$@" ) </dev/null >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# ws_names REPO -> the workspace names, one per line (empty when jj could not
# list them at all, which every assertion over it then fails).
ws_names() {
  jj --ignore-working-copy --repository "$1" workspace list -T 'name ++ "\n"' 2>/dev/null
}

# names_has REPO NAME -> yes/no, read from a here-string and not from a pipe:
# `set -o pipefail` is on, and a `grep -Fq` that stops reading early makes the
# producer take SIGPIPE -- which would turn a MATCHING line into a failed
# pipeline for every line but the last one.
names_has() {
  local names
  names=$(ws_names "$1")
  grep -Fxq "$2" <<<"$names"
}

# A real, empty remote: ginit's and jinit's shared assumption.
remote=$tmp/remote.git
git init -q --bare -b main "$remote" || exit 1

# The wrapper under test, from an EMPTY remote, built exactly as a person would
# run it: from $tmp, into a directory that does not exist yet.
run_jinit "$tmp" w "$remote"
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "jinit exits 0 for a fresh wrapper" "exit $status: $(cat "$tmp/err")"
fi

# 1. The jj repo and no git layer anywhere. The second half is the whole point:
#    a `.git` left at the wrapper (bd init makes one, see jinit) would put a git
#    layer back under every workspace in this repo.
ran=$((ran + 1))
if [ ! -d "$tmp/w/.jj/repo" ]; then
  fail "the wrapper is a jj repo" "no $tmp/w/.jj/repo"
fi
ran=$((ran + 1))
local_git=$(find "$tmp/w" -maxdepth 4 -name .git -print -quit 2>/dev/null)
if [ -n "$local_git" ]; then
  fail "there is no .git anywhere in the wrapper" "found $local_git"
fi

# 2. Both workspaces, and the default one inert: sparse-cleared and parked on
#    root(), so nothing a later jj command runs from the wrapper can absorb
#    main/ or .beads/ into a commit.
ran=$((ran + 1))
if ! names_has "$tmp/w" main; then
  fail "the wrapper has a workspace named main" "$(ws_names "$tmp/w")"
fi
ran=$((ran + 1))
if ! names_has "$tmp/w" default; then
  fail "the wrapper keeps its default workspace" "$(ws_names "$tmp/w")"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/main" ]; then
  fail "main is the base workspace directory" "no $tmp/w/main"
fi
# The reason the default workspace is not simply forgotten: a forgotten default
# is resurrected by the next jj command run from a non-workspace directory, and
# that resurrection junk-snapshots the wrapper. Inert is TWO things, and both are
# checked, because each one alone looks fine while the other is missing -- the
# empty diff below is true even in a wrapper where nothing was done at all, so
# on its own it cannot fail.
ran=$((ran + 1))
inert=$(cd "$tmp/w" && jj --ignore-working-copy diff -r 'default@' --summary 2>&1)
if [ -n "$inert" ]; then
  fail "the default workspace holds no files" "default@ holds: $inert"
fi
# (a) sparse-cleared: the pattern set is empty, so a snapshot taken from the
# wrapper sees nothing even if main/ and .beads/ are sitting right beside it.
# `sparse list` with no pattern prints nothing at all -- main's prints `.`, the
# match-anything root pattern, which is what makes this line discriminating.
ran=$((ran + 1))
default_sparse=$(cd "$tmp/w" && jj --ignore-working-copy sparse list 2>&1)
if [ -n "$default_sparse" ]; then
  fail "the default workspace is sparse-cleared" "sparse list holds: [$default_sparse]"
fi
# (b) parked on root(): its @ is a child of the root commit, so even a
# resurrected default has nothing to reuse. The root id is all zeros in jj.
ran=$((ran + 1))
root_id=$(cd "$tmp/w" && jj --ignore-working-copy log -r 'root()' --no-graph -T 'commit_id' 2>&1)
default_parent=$(cd "$tmp/w" && jj --ignore-working-copy log -r 'default@-' --no-graph -T 'commit_id' 2>&1)
if [ "$default_parent" != "$root_id" ]; then
  fail "the default workspace's @ is parked on root()" \
    "default@-: $default_parent, root(): $root_id"
fi
# (c) and DESCRIBED as the design says. This is what separates a default that
# was reparented by hand from one that was never touched: the commit jj hands a
# fresh repo already sits on root(), so the parent check alone passes for a
# function with no `jj new` in it at all -- the message is the only trace the
# step leaves (`jj new 'root()'` creates a NEW empty commit, so even the id
# would do, but the message is the one the design and ginit both name).
ran=$((ran + 1))
default_desc=$(cd "$tmp/w" && jj --ignore-working-copy log -r 'default@' --no-graph -T 'description' 2>&1)
if [ "$default_desc" != 'default workspace: intentionally empty (see jinit)' ]; then
  fail "the default workspace's @ is the intentionally-empty marker commit" \
    "default@ says: [$default_desc]"
fi

# 3. The seed commit, on the remote. Asked of the REMOTE rather than of the
#    working copy, because "the seed was committed and pushed" is what leaves a
#    fresh clone with anything at all -- and it is read with git only because
#    this test needs a second opinion from the other side of the push.
ran=$((ran + 1))
seed_files=$(git -C "$remote" ls-tree -r --name-only main 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')
for want in README.md .gitignore .worktreeinclude .config/wt.toml; do
  ran=$((ran + 1))
  grep -Fq -- "$want " <<<"$seed_files" || {
    fail "the pushed seed commit carries $want" "remote main holds: [$seed_files]"
  }
done
# ... and NOTHING else: the seed is four files. A fifth would mean the wrapper
# directory (main/, .beads/, the default workspace's .gitignore) was snapshotted
# into a commit -- the failure ginit's `printf '*' > .gitignore` and the
# sparse-clear both exist to prevent.
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
# .worktreeinclude is seeded EMPTY, and zero bytes is the whole assertion: dojjo
# reads the file as a LITERAL include list, so any line in it (ginit's `.env*`
# among them, which matches nothing without globbing) turns the copy hook off.
# An empty file is what lets `djo copy-ignored` bring every ignored path across --
# checked twice, because the size alone would pass for a file holding a single
# newline: the file must be in the tree AND hold nothing at all.
ran=$((ran + 1))
seed_include_size=$(git -C "$remote" ls-tree -l main -- .worktreeinclude 2>/dev/null | awk '{ print $4 }')
if [ "$seed_include_size" != 0 ]; then
  fail "the seed .worktreeinclude is empty" \
    "size: [$seed_include_size], remote main holds: [$seed_files]"
fi
ran=$((ran + 1))
seed_include=$(git -C "$remote" show main:.worktreeinclude 2>/dev/null)
if [ -n "$seed_include" ]; then
  fail "the seed .worktreeinclude holds no line" "[$seed_include]"
fi

# 4. The hook config in the table form dojjo actually reads. worktrunk's
#    top-level `[post-start]` is the shape dojjo half-reads, so a file carrying
#    it is worse than no file: the hooks silently never run.
wt_toml=$tmp/w/main/.config/wt.toml
ran=$((ran + 1))
if [ ! -f "$wt_toml" ]; then
  fail "main carries the hook config" "no $wt_toml"
else
  ran=$((ran + 1))
  grep -Fq '[hooks.post-start]' "$wt_toml" ||
    fail "the hook config uses the [hooks.post-start] table" "$(cat "$wt_toml")"
  ran=$((ran + 1))
  if grep -Eq '^\[post-start\]' "$wt_toml"; then
    fail "the hook config has no top-level [post-start]" "$(cat "$wt_toml")"
  fi
  ran=$((ran + 1))
  grep -Fxq 'copy = "djo copy-ignored --from main"' "$wt_toml" ||
    fail "the post-start hook copies the ignored files with dojjo" "$(cat "$wt_toml")"
fi

# 5. The bookmark tracks its remote counterpart, so a later fetch moves it: jj
#    only updates a bookmark a fetch can see as tracked.
bookmarks=$( cd "$tmp/w" && jj --ignore-working-copy bookmark list -a \
  -T 'name ++ "@" ++ remote ++ " " ++ if(tracked, "tracked", "untracked") ++ "\n"' 2>/dev/null )
ran=$((ran + 1))
if ! grep -Fxq 'main@origin tracked' <<<"$bookmarks"; then
  fail "the main bookmark tracks main@origin" "$bookmarks"
fi

# 6. Beads at the WRAPPER root, with its data on the same remote as the code --
#    a wrapper without a beads database is not what the rest of the flow expects,
#    and a database that landed on a parent is the failure the nest guard exists
#    to prevent (checked from the other side, here).
ran=$((ran + 1))
if [ ! -d "$tmp/w/.beads/embeddeddolt" ]; then
  fail "the beads db is at the wrapper root" "no $tmp/w/.beads/embeddeddolt"
fi
ran=$((ran + 1))
if ! bd -C "$tmp/w" list >/dev/null 2>&1; then
  fail "bd answers in the wrapper" "$(bd -C "$tmp/w" list 2>&1 | head -3)"
fi
dolt_remotes=$(bd -C "$tmp/w" dolt remote list 2>/dev/null)
ran=$((ran + 1))
if ! grep -Fq "$remote" <<<"$dolt_remotes"; then
  fail "the dolt remote is the git remote" "$dolt_remotes"
fi
# ... and the dolt history was actually pushed: the monorepo layout (dolt data in
# the same repo as the code, under refs/dolt/data) is the reason the dolt remote
# is allowed to match git origin at all.
ran=$((ran + 1))
if [ -z "$(git -C "$remote" for-each-ref --format='%(refname)' refs/dolt/data 2>/dev/null)" ]; then
  fail "the beads history reached the remote" \
    "$(git -C "$remote" for-each-ref --format='%(refname)')"
fi

# 7. The wrapper is one `jws` can work in. This is the end-to-end assertion the
#    design names: a create lands at <wrapper>/feat-q, with a workspace main
#    made and main's hook config inherited -- in a wrapper with no git in it.
( cd "$tmp/w/main" && fish --no-config -c 'set -g fish_function_path $HOME/.config/fish/functions; jws feat/q' \
  ) </dev/null >"$tmp/jws-out" 2>&1
jws_status=$?
ran=$((ran + 1))
if [ "$jws_status" -ne 0 ]; then
  fail "jws creates a workspace in the fresh wrapper" "exit $jws_status: $(cat "$tmp/jws-out")"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/feat-q" ]; then
  fail "the created workspace is at <wrapper>/feat-q" "no $tmp/w/feat-q"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/feat-q/.config/wt.toml" ]; then
  fail "the created workspace inherited main's hook config" \
    "no $tmp/w/feat-q/.config/wt.toml"
fi
# ... and there is STILL no .git once a workspace has been made in it. The
# design's claim is about the result of a create, and a create is the moment
# something could put a git layer back: jj and dojjo are the two programs that
# run here, and neither may leave one.
ran=$((ran + 1))
local_git=$(find "$tmp/w" -maxdepth 4 -name .git -print -quit 2>/dev/null)
if [ -n "$local_git" ]; then
  fail "a create in the wrapper leaves no .git behind" "found $local_git"
fi

# 8. The two refusals. The first is ginit's usage line; the second is ginit's
#    nest guard, and it matters more here than anywhere: bd init ADOPTS a parent
#    database rather than failing, so a jinit run inside another beads workspace
#    would quietly re-point that workspace's issues at a new prefix.
run_jinit "$tmp" only
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "one argument is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'usage: jinit' "$tmp/err"; then
  fail "the refusal is the usage line" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/only" ]; then
  fail "a usage refusal creates nothing" "$tmp/only exists"
fi

run_jinit "$tmp/w" nested "$remote"
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "a jinit inside another beads workspace is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'refusing to run inside another beads workspace' "$tmp/err"; then
  fail "the nest refusal says what it found" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq "$tmp/w/.beads" "$tmp/err"; then
  fail "the nest refusal names the .beads it found" "$(cat "$tmp/err")"
fi
# Nothing of the refused run survives: the directory `take` made is gone, and the
# wrapper it was refused inside is untouched -- no second .jj, no second db.
ran=$((ran + 1))
if [ -e "$tmp/w/nested" ]; then
  fail "a refused nest removes the directory it made" "$tmp/w/nested still exists"
fi
ran=$((ran + 1))
if [ ! -d "$tmp/w/.jj/repo" ] || [ ! -d "$tmp/w/main" ]; then
  fail "a refused nest leaves the wrapper intact" "$(ls -a "$tmp/w")"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
