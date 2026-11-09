#!/usr/bin/env bash
# jclone: the fish function that recovers an existing remote into the wrapper
# shape, with NO git layer.
#
# jclone is gclone's counterpart for a repo that has no git layer at all, and
# it has to reach the same end state jinit builds from nothing:
#
#   <wrapper>/.jj      one jj repo for the wrapper
#   <wrapper>/main     the base workspace, at the remote's history
#   <wrapper>/         the `default` workspace, sparse-cleared and parked on
#                      root(), so a stray snapshot cannot absorb the wrapper
#   <wrapper>/.beads   a beads db RECOVERED from origin's refs/dolt/data
#
# ... and `.git` NOWHERE (see docs/superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md).
#
# The function under test is the DEVELOPER's file: it lives in
# ~/.config/fish/functions, it is not in this repo and it is not versioned, the
# same way gclone and ginit are. The test reads it from
# ${JCLONE_FILE:-$HOME/.config/fish/functions/jclone.fish} and FAILS -- it does
# not skip -- when it is not there, naming the path it wanted.
#
# Everything here is real: a real bare git remote with two commits and a real
# `refs/dolt/data` on it (pushed there by bd itself), then a real jj repo, a
# real beads (embedded Dolt) database recovered from that ref, and a real `jws`
# create in the result. A stand-in would prove nothing about the thing this
# function is for -- that a wrapper with no git in it is a wrapper the rest of
# the flow works in, with its issues back.
#
# The ONE stand-in is `rex`: `jclone` ends by renaming the window (as `gclone`
# does), and a test that renamed the developer's real window would be a test
# with a side effect. The stub on PATH records the call instead.
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
# than letting the cases below pass for the wrong reason. `djo` is required by
# the last case, which makes a real workspace with the real `jws`.
for tool in jj fish bd git djo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'jclone_test: %s is required to run this test and is not on PATH\n' "$tool" >&2
    exit 1
  fi
done

export JCLONE_FILE=${JCLONE_FILE:-$HOME/.config/fish/functions/jclone.fish}
if [ ! -f "$JCLONE_FILE" ]; then
  ran=$((ran + 1))
  fail "jclone.fish is missing" "$JCLONE_FILE"
  printf '  the function is a developer file in ~/.config/fish/functions, not a repo file\n'
  exit 1
fi

# The window-rename stand-in, ahead of the real rex on PATH. `command -v` in
# fish still finds it: it is an executable file, which is all `command` looks
# for.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/rex" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$REX_ARGS"
STUB
chmod +x "$tmp/bin/rex"
export REX_ARGS=$tmp/rex-args
: >"$REX_ARGS"

# run_jclone WORKDIR ARGS... ; stdout in $tmp/out, stderr in $tmp/err, and the
# function's OWN exit status in $status -- which is part of the contract.
# Nothing here counts an assertion: every check below does that itself, so
# `ok N assertions` is the number of checks and a failure report cannot
# out-count it.
#
# `fish --no-config` because the developer's own config.fish activates mise and
# rewrites the PATH; the function is sourced by path instead. stdin is /dev/null
# because bd detects a non-TTY and takes its non-interactive defaults; a pane
# with nobody at the keyboard is exactly that case too.
run_jclone() {
  local dir=$1
  shift
  ( cd "$dir" && PATH="$tmp/bin:$PATH" fish --no-config -c 'source "$JCLONE_FILE"; jclone $argv' \
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

# rev REPO REVSET TEMPLATE -> one line of jj's answer, stderr swallowed.
rev() {
  jj --ignore-working-copy --repository "$1" log -r "$2" --no-graph -T "$3" 2>/dev/null
}

# A real remote with real history: two commits on main, the second carrying the
# files a wrapper's main workspace is expected to hold. The seed is a plain
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
  '[hooks.post-start]' \
  'copy = "djo copy-ignored --from main"' \
  >"$seed/.config/wt.toml"
printf '%s\n' .env .beads/ >"$seed/.gitignore"
git -C "$seed" add . || exit 1
git -C "$seed" -c user.name=t -c user.email=t@t commit -qm 'seed two: hooks and ignore' || exit 1
git -C "$seed" push -q -u origin main || exit 1

# ... and a beads database ON that remote, pushed with the real bd, so the
# clone has something to RECOVER rather than to mint. The issue is the proof:
# only a recovered database carries an issue this wrapper never created.
seed_issue='recovered from refs/dolt/data'
(
  cd "$seed" || exit 1
  bd init --skip-hooks --skip-agents >/dev/null 2>&1 || exit 1
  bd create "$seed_issue" --type task -d 'proves the db was recovered' >/dev/null 2>&1 || exit 1
  bd dolt remote add origin "$remote" --allow-git-origin >/dev/null 2>&1 || exit 1
  bd dolt push >/dev/null 2>&1 || exit 1
) </dev/null || {
  ran=$((ran + 1))
  fail "the fixture remote carries refs/dolt/data" "bd could not build or push the seed database"
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
}

# The wrapper under test, built the way a clone is: from $tmp, into a directory
# that does not exist yet.
run_jclone "$tmp" "$remote" w
ran=$((ran + 1))
if [ "$status" -ne 0 ]; then
  fail "jclone exits 0 for an existing remote" "exit $status: $(cat "$tmp/err")$(cat "$tmp/out")"
fi

# 1. The jj repo, and no git layer anywhere. The second half is the whole point
#    of jclone over gclone: a `.git` at the wrapper would put a git layer back
#    under every workspace in this repo.
ran=$((ran + 1))
if [ ! -d "$tmp/w/.jj/repo" ]; then
  fail "the wrapper is a jj repo" "no $tmp/w/.jj/repo"
fi
ran=$((ran + 1))
local_git=$(find "$tmp/w" -maxdepth 4 -name .git -print -quit 2>/dev/null)
if [ -n "$local_git" ]; then
  fail "there is no .git anywhere in the wrapper" "found $local_git"
fi

# 2. Both workspaces, with main at <wrapper>/main: that is where jws creates
#    from, and the name is the branch name every other part of the flow uses.
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

# 3. The history actually arrived, and it is the remote's: main's @ sits on the
#    remote tip, and main's working copy holds that commit's files. `@-` because
#    a workspace's own working-copy commit is the empty one on top.
ran=$((ran + 1))
main_parent=$(rev "$tmp/w" 'main@-' 'description.first_line()')
if [ "$main_parent" != 'seed two: hooks and ignore' ]; then
  fail "main's working copy sits on the remote's history" "main@- says: [$main_parent]"
fi
ran=$((ran + 1))
if [ ! -f "$tmp/w/main/README.md" ]; then
  fail "main's working copy holds the cloned files" "no $tmp/w/main/README.md"
fi

# ... and the bookmark the clone brought tracks its remote counterpart, so a
# later fetch moves it -- the same invariant jinit has to set up by hand.
ran=$((ran + 1))
bookmarks=$( cd "$tmp/w" && jj --ignore-working-copy bookmark list -a \
  -T 'name ++ "@" ++ remote ++ " " ++ if(tracked, "tracked", "untracked") ++ "\n"' 2>/dev/null )
if ! grep -Fxq 'main@origin tracked' <<<"$bookmarks"; then
  fail "the main bookmark tracks main@origin" "$bookmarks"
fi
# ... and the LOCAL bookmark is there too, not only the remote one it tracks: a
# clone that left `main@origin` tracking nothing local would satisfy the line
# above while `jj bookmark list` named no branch at all, and a --branch-style
# change to how the clone is made is the way that happens quietly.
ran=$((ran + 1))
local_bookmarks=$( cd "$tmp/w" && jj --ignore-working-copy bookmark list -T 'name ++ "\n"' 2>/dev/null )
if ! grep -Fxq main <<<"$local_bookmarks"; then
  fail "the clone leaves a local main bookmark" "jj bookmark list: [$local_bookmarks]"
fi

# 4. main inherited the FULL sparse patterns. This is the add-before-the-clear
#    rule: a workspace added after the clear inherits an empty pattern set and
#    sees no files at all. `.` is the match-anything root pattern `sparse list`
#    prints for a workspace whose patterns are untouched.
ran=$((ran + 1))
main_sparse=$( cd "$tmp/w/main" && jj --ignore-working-copy sparse list 2>&1 )
if [ "$main_sparse" != '.' ]; then
  fail "main inherited the full sparse patterns" "sparse list in main: [$main_sparse]"
fi

# 5. The default workspace is inert -- and the clone's files were dematerialized
#    out of the wrapper, so nothing else is at the wrapper root. Inert is TWO
#    things plus the marker, all three checked, because each alone looks fine
#    while another is missing: the empty diff is true even in a wrapper where
#    nothing was done at all.
ran=$((ran + 1))
inert=$( cd "$tmp/w" && jj --ignore-working-copy diff -r 'default@' --summary 2>&1 )
if [ -n "$inert" ]; then
  fail "the default workspace holds no files" "default@ holds: $inert"
fi
# (a) sparse-cleared: the pattern set is empty, so a snapshot taken from the
# wrapper sees nothing even with main/ and .beads/ sitting right beside it.
ran=$((ran + 1))
default_sparse=$( cd "$tmp/w" && jj --ignore-working-copy sparse list 2>&1 )
if [ -n "$default_sparse" ]; then
  fail "the default workspace is sparse-cleared" "sparse list holds: [$default_sparse]"
fi
# (b) parked on root(): its @ is a child of the root commit, so even a
# resurrected default has nothing to reuse.
ran=$((ran + 1))
root_id=$(rev "$tmp/w" 'root()' 'commit_id')
default_parent=$(rev "$tmp/w" 'default@-' 'commit_id')
if [ "$default_parent" != "$root_id" ]; then
  fail "the default workspace's @ is parked on root()" \
    "default@-: $default_parent, root(): $root_id"
fi
# (c) and DESCRIBED as the design says -- the marker is the only trace the step
# leaves, and it is what separates a default reparented on purpose from one jj
# happened to hand a fresh workspace.
ran=$((ran + 1))
default_desc=$(rev "$tmp/w" 'default@' 'description')
if [ "$default_desc" != 'default workspace: intentionally empty (see jclone)' ]; then
  fail "the default workspace's @ is the intentionally-empty marker commit" \
    "default@ says: [$default_desc]"
fi
# ... and the clone's files are GONE from the wrapper root: the clear
# dematerializes them, and a wrapper that still materialized README.md is a
# wrapper whose default would snapshot it on the next stray jj command.
ran=$((ran + 1))
if [ -e "$tmp/w/README.md" ]; then
  fail "the clone's files are dematerialized from the wrapper root" \
    "$tmp/w/README.md is still there"
fi

# 6. Beads at the WRAPPER root, recovered rather than minted. The db beside
# main and not inside it, because that is the layout every other part of the
# flow reads (bd walks up to .beads from whichever workspace is asking).
ran=$((ran + 1))
if [ ! -d "$tmp/w/.beads/embeddeddolt" ]; then
  fail "the recovered beads db is at the wrapper root" "no $tmp/w/.beads/embeddeddolt"
fi
ran=$((ran + 1))
if [ -e "$tmp/w/main/.beads" ]; then
  fail "main carries no beads db of its own" "$tmp/w/main/.beads exists"
fi
# The config is what made the bootstrap possible at all: in a git-less wrapper
# bd answers "No active beads workspace found" without a sync.remote to clone
# from, so the config comes first and this is the file that proves it.
ran=$((ran + 1))
wrapper_config=$(cat "$tmp/w/.beads/config.yaml" 2>/dev/null)
# Quoted or not: bd rewrites this file to its own taste as it goes, and the
# assertion is about the VALUE (the git remote), not about the quoting this
# function writes before the bootstrap normalizes it.
if ! grep -Eq "^[[:space:]]*remote:[[:space:]]*\"?$remote\"?[[:space:]]*$" <<<"$wrapper_config"; then
  fail "the wrapper's beads config names the git remote as its sync remote" \
    "[$wrapper_config]"
fi
# ... and the recovered database is named, not left to whatever bd guessed.
ran=$((ran + 1))
if ! grep -Fq '"dolt_database": "beads"' "$tmp/w/.beads/metadata.json" 2>/dev/null; then
  fail "the recovered database is named beads" \
    "$(cat "$tmp/w/.beads/metadata.json" 2>&1)"
fi
# The db holds recovered issues, so it is not for everyone to read: bd's own
# recommendation, and jinit's and gclone's `chmod 700`.
ran=$((ran + 1))
beads_mode=$(ls -ld "$tmp/w/.beads" 2>/dev/null | cut -c1-10)
if [ "$beads_mode" != 'drwx------' ]; then
  fail "the beads directory is 0700" "[$beads_mode]"
fi

# 7. RECOVERED, not minted: an issue this wrapper never created is there, and
#    the recovered db answers from inside main -- which is where the flow asks.
ran=$((ran + 1))
recovered=$(cd "$tmp/w/main" && bd list --json 2>/dev/null)
if ! grep -Fq "$seed_issue" <<<"$recovered"; then
  fail "the issue from the remote is in the recovered database" "bd list says: [$recovered]"
fi
ran=$((ran + 1))
if ! ( cd "$tmp/w/main" && bd ready --json >/dev/null 2>&1 ); then
  fail "bd answers from inside main" "$( cd "$tmp/w/main" && bd ready 2>&1 | head -3 )"
fi
# The dolt remote came from the config above: without it the recovered database
# is a local dead end nobody can push to.
ran=$((ran + 1))
dolt_remotes=$(bd -C "$tmp/w" dolt remote list 2>/dev/null)
if ! grep -Fq "$remote" <<<"$dolt_remotes"; then
  fail "the recovered db's dolt remote is the git remote" "[$dolt_remotes]"
fi

# 8. The wrapper is one `jws` can work in: a create lands at <wrapper>/feat-q
#    with main's hook config inherited, and there is STILL no .git afterwards.
#    This is the end-to-end assertion the design names.
( cd "$tmp/w/main" && fish --no-config -c 'set -g fish_function_path $HOME/.config/fish/functions; jws feat/q' \
  ) </dev/null >"$tmp/jws-out" 2>&1
jws_status=$?
ran=$((ran + 1))
if [ "$jws_status" -ne 0 ]; then
  fail "jws creates a workspace in the cloned wrapper" "exit $jws_status: $(cat "$tmp/jws-out")"
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
# ... and in the shape dojjo reads. Inheriting the file is not enough: worktrunk's
# top-level `[post-start]` is a file dojjo parses and runs nowhere, so a clone
# that brought a repo's hooks across without their `[hooks.post-start]` head
# would pass the line above and never run a hook.
ran=$((ran + 1))
if ! grep -Fq '[hooks.post-start]' "$tmp/w/feat-q/.config/wt.toml" 2>/dev/null; then
  fail "the inherited hook config is in dojjo's table" \
    "$(cat "$tmp/w/feat-q/.config/wt.toml" 2>&1)"
fi
ran=$((ran + 1))
local_git=$(find "$tmp/w" -maxdepth 4 -name .git -print -quit 2>/dev/null)
if [ -n "$local_git" ]; then
  fail "a create in the wrapper leaves no .git behind" "found $local_git"
fi

# 9. And it ends where gclone ends: the window is titled for the workspace the
#    person is now in.
ran=$((ran + 1))
if [ "$(cat "$REX_ARGS")" != 'window rename main' ]; then
  fail "jclone renames the window to main" "rex got: [$(cat "$REX_ARGS")]"
fi

# 10. The usage refusal, and the fact that it creates nothing: a clone that
#     starts on a half-typed line must not leave a directory behind.
run_jclone "$tmp" only
ran=$((ran + 1))
if [ "$status" -ne 1 ]; then
  fail "one argument is refused" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -Fq 'usage: jclone' "$tmp/err"; then
  fail "the refusal is the usage line" "$(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/only" ]; then
  fail "a usage refusal creates nothing" "$tmp/only exists"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
