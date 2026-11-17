#!/usr/bin/env bash
# new-work.sh done: the audit, the refusal screen, the refresh and the
# hand-back behind rex's "I'm done" flow.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then printf '  %s\n' "$2"; fi
}

# Stand-ins record their argv, so "the hand-back never ran" and "the close came
# last" are read from a file rather than inferred from the script's text.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/rex" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$REX_ARGS_FILE"
[ -z "$REX_FAIL" ] || { printf 'rex: %s\n' "$REX_FAIL" >&2; exit 1; }
EOF
cat >"$tmp/bin/jj" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$JJ_ARGS_FILE"
[ -z "$JJ_FAIL" ] || { printf 'jj: %s\n' "$JJ_FAIL" >&2; exit 1; }
EOF
chmod +x "$tmp/bin/rex" "$tmp/bin/jj"

# The answers a clean, merged, idle workspace gives.
: >"$tmp/clean-diff"
: >"$tmp/clean-own"
: >"$tmp/clean-changes"
printf 'contained yes\nat-empty yes\n' >"$tmp/clean-main"

# The two moves run in --main, so a case that reaches them needs a directory
# that is there: /p/demo/main is an answer, not a place. Cases that only
# assert on the main worktree's path keep the /p/demo answer.
mkdir -p "$tmp/real-main"

# A PATH holding bash -- the script's own `#!/usr/bin/env bash` needs it -- with
# jq and cat beside it, and no worktrunk. One case runs there, so "wt is missing"
# is proven rather than left to the developer's machine.
mkdir -p "$tmp/no-wt-bin"
ln -sf "$(command -v bash)" "$tmp/no-wt-bin/bash"
ln -sf "$(command -v jq)" "$tmp/no-wt-bin/jq"
ln -sf "$(command -v cat)" "$tmp/no-wt-bin/cat"

run_done() {
  ran=$((ran + 1))
  rm -f "$tmp/rex-args" "$tmp/jj-args"
  PATH="${DONE_PATH:-$tmp/bin:$PATH}" REX_ARGS_FILE=$tmp/rex-args JJ_ARGS_FILE=$tmp/jj-args \
    ./new-work.sh done \
    --cwd "${DONE_CWD:-/p/demo/feat-6c4}" \
    --main "${DONE_MAIN_DIR:-/p/demo/main}" --root /p/demo --project demo \
    --session s1 --window w1 \
    --workspaces test/fixtures/workspaces.txt \
    --wt-json "${DONE_WT:-test/fixtures/done-wt-list.json}" \
    --diff "${DONE_DIFF:-$tmp/clean-diff}" \
    --own-status "${DONE_OWN:-$tmp/clean-own}" \
    --changes "${DONE_CHANGES:-$tmp/clean-changes}" \
    --main-state "${DONE_MAIN:-$tmp/clean-main}" \
    --bd-json "${DONE_BD_JSON:-test/fixtures/ready.json}" \
    --no-fetch --base-bookmarks test/fixtures/bookmarks.txt \
    --origin-head origin/main \
    "$@" >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

want_status() {
  ran=$((ran + 1))
  [ "$status" -eq "$2" ] ||
    fail "$1" "want exit $2, got $status; stderr: $(cat "$tmp/err")"
}

want_out() {
  ran=$((ran + 1))
  [ "$(cat "$tmp/out")" = "$2" ] ||
    fail "$1" "stdout mismatch; got: $(cat "$tmp/out")"
}

want_out_has() {
  ran=$((ran + 1))
  grep -qF -- "$2" "$tmp/out" || fail "$1" "stdout lacks: $2; got: $(cat "$tmp/out")"
}

want_err_has() {
  ran=$((ran + 1))
  grep -qF -- "$2" "$tmp/err" || fail "$1" "stderr lacks: $2; got: $(cat "$tmp/err")"
}

# A cwd in a workspace gets past identification. The clean path says nothing of
# its own: it hands back to Rex, and the close is what the person sees.
DONE_MAIN_DIR=$tmp/real-main DONE_CWD=/p/demo/feat-6c4 run_done
want_status "a workspace cwd is not refused" 0
want_out "a clean run prints nothing" ""

# A subdirectory of a workspace belongs to that workspace.
DONE_MAIN_DIR=$tmp/real-main DONE_CWD=/p/demo/feat-6c4/docs run_done
want_status "a subdirectory of a workspace is that workspace" 0

# The main worktree, and anywhere inside it, is refused by path.
DONE_CWD=/p/demo/main run_done
want_status "the main worktree is refused" 4
want_out "the main worktree block" "can't tear down the main worktree

  /p/demo/main is the main worktree, not a workspace this flow removes

nothing was removed; press any key"

DONE_CWD=/p/demo/main/src run_done
want_status "a directory inside the main worktree is refused" 4
want_out_has "the inside-main block names the main worktree" "is the main worktree"

# The wrapper root, which is jj's default workspace, is refused the same way.
DONE_CWD=/p/demo run_done
want_status "the wrapper root is refused" 4
want_out "the wrapper root block" "can't tear down the main worktree

  /p/demo is the main worktree, not a workspace this flow removes

nothing was removed; press any key"

# A directory no listed workspace owns.
DONE_CWD=/p/demo/nope run_done
want_status "a cwd outside every workspace is refused" 4
want_out "the no-workspace block" "can't tear down /p/demo/nope

  /p/demo/nope is not inside a jj workspace this wrapper knows about

nothing was removed; press any key"

# /p/demo/feat-6c41 starts with /p/demo/feat-6c4 as text but is not that
# workspace: the match is whole path segments (Review Focus 1).
DONE_CWD=/p/demo/feat-6c41 run_done
want_status "a string-prefix sibling is not a match" 4
want_out_has "the string-prefix sibling is refused as outside" "not inside a jj workspace"

# A trailing slash on --root is the same wrapper, and has to answer the same
# way: roots are compared as strings, so without normalising it the wrapper row
# would not be recognised and this would be a worktrunk disagreement instead.
DONE_CWD=/p/demo/nope run_done --root /p/demo/
want_status "a trailing slash on --root is the same wrapper" 4
want_out "the no-workspace block with --root /p/demo/" "can't tear down /p/demo/nope

  /p/demo/nope is not inside a jj workspace this wrapper knows about

nothing was removed; press any key"

# Two of them are two, not one: stripping a single slash would leave /p/demo/
# and the same broken answer.
DONE_CWD=/p/demo/nope run_done --root /p/demo//
want_status "two trailing slashes on --root are the same wrapper" 4
want_out "the no-workspace block with --root /p/demo//" "can't tear down /p/demo/nope

  /p/demo/nope is not inside a jj workspace this wrapper knows about

nothing was removed; press any key"

# --main is compared the same way, and there it is not an answer to get wrong:
# /p/demo/main/ is the main worktree, and a run that did not recognise it would
# hand the one directory this flow must never remove to the removal step.
DONE_CWD=/p/demo/main run_done --main /p/demo/main/
want_status "a trailing slash on --main is still the main worktree" 4
want_out "the main worktree block with --main /p/demo/main/" "can't tear down the main worktree

  /p/demo/main is the main worktree, not a workspace this flow removes

nothing was removed; press any key"

# The other half of the disagreement: worktrunk has a worktree jj lists no
# workspace for, and the block names both halves.
DONE_WT=test/fixtures/done-wt-list-orphan.json DONE_CWD=/p/demo/orphan run_done
want_status "a worktree jj does not list is refused" 4
want_out "the reverse disagreement block" "can't tear down /p/demo/orphan

  worktrunk has a worktree at /p/demo/orphan, but jj lists no workspace there

nothing was removed; press any key"

# jj lists the row, worktrunk does not.
DONE_WT=test/fixtures/done-wt-list-no-feat.json run_done
want_status "jj and worktrunk disagreeing is refused" 4
want_out "the disagreement block" "can't tear down feat/6c4

  jj lists this workspace at /p/demo/feat-6c4, but worktrunk has no worktree there

nothing was removed; press any key"

# A subdirectory that is a workspace of its own answers to the longer root: the
# longest listed root that owns the cwd wins, not the first one that matches.
DONE_CWD=/p/demo/feat-6c4/sub run_done
want_status "the longest matching root is the workspace" 4
want_out "the nested-workspace block names the nested workspace" "can't tear down feat/6c4-sub

  jj lists this workspace at /p/demo/feat-6c4/sub, but worktrunk has no worktree there

nothing was removed; press any key"

# A relative path cannot mean what it says: Rex resolves it against its own cwd.
DONE_CWD=feat-6c4 run_done
want_status "a relative --cwd is a usage error" 2

# A run that names no session has nothing to close, and no project to hand back.
run_done --session ''
want_status "a missing --session is a usage error" 2

# With no saved workspace list jj is asked from --cwd itself, so a directory
# that is not there is refused by name rather than by bash's own cd error.
run_done --workspaces ''
want_status "a cwd that is not there is refused" 1
want_err_has "a cwd that is not there is named" \
  'done: no such directory: /p/demo/feat-6c4'
ran=$((ran + 1))
grep -q 'cd:' "$tmp/err" &&
  fail "a cwd that is not there is not bash's cd error" "stderr: $(cat "$tmp/err")"

# An option this command does not have is a script that cannot mean what it
# says, not something to ignore.
run_done --nonsense x
want_status "an unknown option is a usage error" 2

# With no saved worktree list worktrunk is asked, and a machine without it says
# so by name -- not by bash's "command not found", which would read as the
# repository's worktrees being unreadable. --main is a real directory here, so
# the run reaches the worktrunk question rather than stopping earlier.
mkdir -p "$tmp/real-main"
DONE_PATH=$tmp/no-wt-bin run_done --wt-json '' --main "$tmp/real-main"
want_status "a missing wt is a missing tool" 1
want_err_has "a missing wt is named" 'wt not found on PATH'
ran=$((ran + 1))
grep -q 'cd:' "$tmp/err" &&
  fail "a missing wt is not bash's cd error" "stderr: $(cat "$tmp/err")"

# --- The store blockers: what the branch has, and what the working copy has ---

# Three changes touch four paths. The change count comes from --changes, the
# paths from --diff, and every path is listed.
printf 'aaa111\nbbb222\nccc333\n' >"$tmp/changes-3"
DONE_MAIN_DIR=$tmp/real-main DONE_DIFF=test/fixtures/done-diff.txt DONE_CHANGES=$tmp/changes-3 run_done
want_status "unmerged content is a blocker" 4
want_out "the unmerged block" "can't tear down feat/6c4

  changes not merged into main@origin: 3 changes, 4 paths
    init.lua
    new-work.sh
    docs/plan.md
    test/run.sh

nothing was removed; press any key"

# A working copy with changes of its own.
DONE_MAIN_DIR=$tmp/real-main DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a dirty working copy is a blocker" 4
want_out "the dirty block" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# Both, in the order the audit asks them: the branch's changes first, the
# working copy's after.
DONE_MAIN_DIR=$tmp/real-main \
  DONE_DIFF=test/fixtures/done-diff.txt DONE_CHANGES=$tmp/changes-3 \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "both store blockers is a refusal" 4
want_out "both store blockers, in order" "can't tear down feat/6c4

  changes not merged into main@origin: 3 changes, 4 paths
    init.lua
    new-work.sh
    docs/plan.md
    test/run.sh
  working copy has changes: 2 paths

nothing was removed; press any key"

# The case a reachability test gets wrong: the range has changes and the
# content diff is empty, which is what a squash merge leaves behind. Nothing
# would be lost, so nothing is refused.
DONE_MAIN_DIR=$tmp/real-main DONE_CHANGES=$tmp/changes-3 run_done
want_status "a squash-merged branch is not a blocker" 0
want_out "a squash-merged branch prints nothing" ""

# The base is whatever --base-bookmarks and --origin-head resolve, never a
# hard-coded main@origin: this clone tracks develop, and develop is what the
# block names.
printf 'main@\ndevelop@\ndevelop@origin\n' >"$tmp/bookmarks.develop"
DONE_MAIN_DIR=$tmp/real-main DONE_DIFF=test/fixtures/done-diff.txt \
  DONE_CHANGES=$tmp/changes-3 run_done \
  --base-bookmarks "$tmp/bookmarks.develop" --origin-head origin/develop
want_status "a develop clone is a blocker too" 4
want_out_has "the base comes from --origin-head, not a fixed name" \
  "changes not merged into develop@origin: 3 changes, 4 paths"

# With no saved diff the comparison is really made, and it is made against
# <branch>@origin. jj is asked from the workspace root, so the two lists point
# at a directory that is there -- the /p/demo ones are answers, not places.
mkdir -p "$tmp/real-ws"
printf 'feat/6c4\t%s\n' "$tmp/real-ws" >"$tmp/ws-real.txt"
printf '{"items":[{"branch":"main","worktree":{"path":"%s","main":true}},{"branch":"feat/6c4","worktree":{"path":"%s","main":false}}]}' \
  "$tmp/real-main" "$tmp/real-ws" >"$tmp/wt-real.json"
run_done --cwd "$tmp/real-ws" --workspaces "$tmp/ws-real.txt" \
  --wt-json "$tmp/wt-real.json" --main "$tmp/real-main" \
  --diff '' --own-status ''
want_status "a run with no saved diff asks jj for it" 0
ran=$((ran + 1))
grep -q 'argv=diff --summary -r main@origin\.\.@$' "$tmp/jj-args" ||
  fail "jj diff runs against <base>..@" "$(cat "$tmp/jj-args")"

# A failed fetch stops the audit before anything is compared: a comparison
# against state this run could not refresh is worse than none. --main is a
# real directory, so jj is reached rather than bash's cd.
mkdir -p "$tmp/failbin"
cp "$tmp/bin/rex" "$tmp/failbin/rex"
cat >"$tmp/failbin/jj" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$JJ_ARGS_FILE"
printf 'jj: no network\n' >&2
exit 1
EOF
chmod +x "$tmp/failbin/rex" "$tmp/failbin/jj"
ran=$((ran + 1))
rm -f "$tmp/jj-args"
PATH="$tmp/failbin:$PATH" REX_ARGS_FILE=$tmp/rex-args JJ_ARGS_FILE=$tmp/jj-args \
  ./new-work.sh done --cwd /p/demo/feat-6c4 --main "$tmp/real-main" --root /p/demo \
  --project demo --session s1 --window w1 \
  --workspaces test/fixtures/workspaces.txt \
  --wt-json test/fixtures/done-wt-list.json \
  --diff "$tmp/clean-diff" --own-status "$tmp/clean-own" \
  --changes "$tmp/clean-changes" --main-state "$tmp/clean-main" \
  --bd-json test/fixtures/ready.json \
  --base-bookmarks test/fixtures/bookmarks.txt \
  --origin-head origin/main \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
want_status "a failed fetch is a refusal" 4
want_out "the fetch block" "can't tear down feat/6c4

  the fetch failed, so nothing was compared: jj: no network

nothing was removed; press any key"
ran=$((ran + 1))
grep -q 'argv=git fetch$' "$tmp/jj-args" ||
  fail "the fetch is one jj git fetch" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
! grep -q 'argv=diff' "$tmp/jj-args" ||
  fail "no comparison runs after a failed fetch" "$(cat "$tmp/jj-args")"

# A --main that cannot be entered fails the fetch's own `cd`, so jj never runs and
# there is no jj output to put after the colon: the block would end in nothing at
# all. It names the place instead. --wt-json is the seam that gets a run this far,
# because without it the worktrunk read needs --main first.
ran=$((ran + 1))
rm -f "$tmp/jj-args"
PATH="$tmp/bin:$PATH" REX_ARGS_FILE=$tmp/rex-args JJ_ARGS_FILE=$tmp/jj-args \
  ./new-work.sh done --cwd /p/demo/feat-6c4 --main "$tmp/no-such-main" --root /p/demo \
  --project demo --session s1 --window w1 \
  --workspaces test/fixtures/workspaces.txt \
  --wt-json test/fixtures/done-wt-list.json \
  --diff "$tmp/clean-diff" --own-status "$tmp/clean-own" \
  --changes "$tmp/clean-changes" --main-state "$tmp/clean-main" \
  --bd-json test/fixtures/ready.json \
  --base-bookmarks test/fixtures/bookmarks.txt \
  --origin-head origin/main \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
want_status "a main the fetch cannot enter is a refusal" 4
want_out "the fetch block names the place when jj says nothing" "can't tear down feat/6c4

  the fetch failed, so nothing was compared: could not run jj in $tmp/no-such-main

nothing was removed; press any key"
ran=$((ran + 1))
[ ! -s "$tmp/jj-args" ] ||
  fail "a fetch that could not be started never runs jj" "$(cat "$tmp/jj-args")"

# --- The programs still running, and the bead the workspace belongs to ---

# A program still running in the tab is a reason not to tear it down, and the
# names come in the order they were given, in one comma-separated line.
DONE_MAIN_DIR=$tmp/real-main run_done --running pi --running node
want_status "a running program is a blocker" 4
want_out "the running block" "can't tear down feat/6c4

  still running in this tab: pi, node

nothing was removed; press any key"

# A blank name is not a program: accumulated it would leave the list empty, so
# the blocker would vanish and a teardown of a tab with work in it would go
# ahead. Refused as the bad argument it is, like every other empty value here.
run_done --running ''
want_status "an empty --running is a usage error" 2

# Whitespace alone is that same defect in a different shape: the value is not
# empty, so a bare emptiness guard would take it, and the block would read
# "still running in this tab: " -- a reason that names nothing.
run_done --running ' '
want_status "a space is not a program" 2
run_done --running ' 	'
want_status "spaces and a tab are not a program" 2

# The bead is information, not a reason: on a clean run it prints nothing at
# all, because a run that removes the workspace has no screen.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=test/fixtures/done-beads.json run_done
want_status "a claimed bead is not a blocker on its own" 0
want_out "a claimed bead on a clean run prints nothing" ""

# With a blocker it says which bead this workspace is, in a paragraph of its
# own, after the reasons and before the footer.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=test/fixtures/done-beads.json \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a claimed bead with a dirty copy is a refusal" 4
want_out "the bead line sits after the blockers" "can't tear down feat/6c4

  working copy has changes: 2 paths

  bead rex-config-6c4 is still in_progress

nothing was removed; press any key"

# Those two clean runs never reach the printer -- a run that removes the
# workspace prints nothing -- so they say nothing about a bead read that fails.
# The evidence for "silence, not a failure" is a refusal, where the bead line is
# asked for: a blocker is still the whole block, and the bead paragraph is
# simply absent.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON="$tmp/clean-changes" run_done
want_status "an empty bead list on a clean run prints nothing" 0
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=/nonexistent run_done
want_status "an unreadable bead list on a clean run prints nothing" 0

# A bead read that fails.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=/nonexistent \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "an unreadable bead list is not a bead line, and is no failure" 4
want_out "the dirty block with an unreadable bead list" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# A bead list that is readable and matches nothing: the only bead in it is
# another workspace's.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=test/fixtures/done-beads-no-match.json \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead list that matches nothing is not a bead line" 4
want_out "the dirty block with a non-matching bead list" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# A row with no status is not a bead line: the block is prose, and a missing
# field would reach it as the word "null".
printf '[{"id":"rex-config-6c4"}]' >"$tmp/beads-no-status"
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON="$tmp/beads-no-status" \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead row with no status is still a refusal" 4
want_out "the dirty block with a statusless bead" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# An empty status is no better than a missing one: "is still " with nothing
# after it is a sentence that stopped.
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=test/fixtures/done-beads-empty-status.json \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead row with an empty status is still a refusal" 4
want_out "the dirty block with an empty-status bead" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# Everything at once (Review Focus 4): the pinned order, the bead paragraph
# in its place, and exactly one "nothing was removed" line.
printf 'aaa111\nbbb222\nccc333\n' >"$tmp/changes-3"
DONE_MAIN_DIR=$tmp/real-main DONE_BD_JSON=test/fixtures/done-beads.json \
  DONE_DIFF=test/fixtures/done-diff.txt DONE_CHANGES=$tmp/changes-3 \
  DONE_OWN=test/fixtures/done-own-status.txt run_done \
  --running pi --running node
want_status "every blocker at once is a refusal" 4
want_out "the whole block" "can't tear down feat/6c4

  changes not merged into main@origin: 3 changes, 4 paths
    init.lua
    new-work.sh
    docs/plan.md
    test/run.sh
  working copy has changes: 2 paths
  still running in this tab: pi, node

  bead rex-config-6c4 is still in_progress

nothing was removed; press any key"

# --- Moving main forward, and only forward, after the fetch ---

# A clean workspace beside a clean, provably empty main: both writes happen,
# both in main, and both after the fetch -- the fetch first because every
# answer the moves decide from is about what origin has, the bookmark before
# the move of the working copy because that is the order the refresh reads.
# The moves run in --main, so --main is a directory that is there; /p/demo/main
# is an answer, not a place.
mkdir -p "$tmp/real-main"
ran=$((ran + 1))
rm -f "$tmp/rex-args" "$tmp/jj-args"
PATH="$tmp/bin:$PATH" REX_ARGS_FILE=$tmp/rex-args JJ_ARGS_FILE=$tmp/jj-args \
  ./new-work.sh done --cwd /p/demo/feat-6c4 --main "$tmp/real-main" --root /p/demo \
  --project demo --session s1 --window w1 \
  --workspaces test/fixtures/workspaces.txt \
  --wt-json test/fixtures/done-wt-list.json \
  --diff "$tmp/clean-diff" --own-status "$tmp/clean-own" \
  --changes "$tmp/clean-changes" --main-state "$tmp/clean-main" \
  --bd-json test/fixtures/ready.json \
  --base-bookmarks test/fixtures/bookmarks.txt \
  --origin-head origin/main \
  >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
want_status "a clean workspace with a clean main carries on" 0
ran=$((ran + 1))
[ "$(sed -n 1p "$tmp/jj-args")" = "cwd=$tmp/real-main argv=git fetch" ] ||
  fail "the fetch comes first, in main" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
[ "$(sed -n 2p "$tmp/jj-args")" = "cwd=$tmp/real-main argv=bookmark set main -r main@origin" ] ||
  fail "the bookmark is set onto the base, after the fetch" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
[ "$(sed -n 3p "$tmp/jj-args")" = "cwd=$tmp/real-main argv=new main@origin" ] ||
  fail "main's working copy is moved in main, after the bookmark" "$(cat "$tmp/jj-args")"
# Three calls and no more: a stray read or a second write in main would show up
# here as a fourth line.
ran=$((ran + 1))
[ "$(wc -l <"$tmp/jj-args")" -eq 3 ] ||
  fail "the clean path makes exactly the three jj calls" "$(cat "$tmp/jj-args")"
# And the clean path still says nothing: it hands back, so there is no screen.
want_out "a clean run with a clean main prints nothing" ""

# main has commits the base does not: setting its bookmark onto the base would
# be a move backwards, so neither move is made -- moving only the working copy
# would leave a main whose checkout is not its branch -- and the block says what
# is left to decide rather than naming a command, because no command clears it:
# the commits are on main's own bookmark, so pushing or abandoning them is the
# person's answer.
printf 'contained no\nat-empty yes\n' >"$tmp/main-ahead"
DONE_MAIN_DIR=$tmp/real-main DONE_MAIN=$tmp/main-ahead run_done
want_status "an ahead main is a blocker" 4
want_out "the ahead-main block" "can't tear down feat/6c4

  main was not moved: it has commits main@origin does not; the bookmark is yours to push or abandon

nothing was removed; press any key"
ran=$((ran + 1))
[ ! -s "$tmp/jj-args" ] ||
  fail "neither move runs on an ahead main, not even the working copy" \
    "$(cat "$tmp/jj-args")"

# A working copy that is not provably empty is not moved either: jj new over
# it would strand whatever is in it. The bookmark guard is its own, and still
# passes.
printf 'contained yes\nat-empty no\n' >"$tmp/main-dirty"
DONE_MAIN_DIR=$tmp/real-main DONE_MAIN=$tmp/main-dirty run_done
want_status "a non-empty main working copy is a blocker" 4
want_out "the dirty-main block" "can't tear down feat/6c4

  main's working copy was not moved: it is not empty; run jj new main@origin in $tmp/real-main

nothing was removed; press any key"
ran=$((ran + 1))
grep -q '^cwd=.* argv=bookmark set main -r main@origin$' "$tmp/jj-args" ||
  fail "a contained main bookmark is still moved" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
! grep -q 'argv=new ' "$tmp/jj-args" ||
  fail "a non-empty main keeps its working copy" "$(cat "$tmp/jj-args")"

# The two main lines join the block after the programs still running in the
# tab and before the bead paragraph: one block, one footer, and the audit
# asked the tab before it asked main.
printf 'contained no\nat-empty no\n' >"$tmp/main-both"
DONE_MAIN_DIR=$tmp/real-main DONE_MAIN=$tmp/main-both \
  DONE_BD_JSON=test/fixtures/done-beads.json run_done --running pi
want_status "both main blockers are a refusal" 4
want_out "the main lines sit after the running line" "can't tear down feat/6c4

  still running in this tab: pi
  main was not moved: it has commits main@origin does not; the bookmark is yours to push or abandon
  main's working copy was not moved: it is not empty; run jj new main@origin in $tmp/real-main

  bead rex-config-6c4 is still in_progress

nothing was removed; press any key"
ran=$((ran + 1))
[ ! -s "$tmp/jj-args" ] ||
  fail "a main that is not provably clean is not touched" "$(cat "$tmp/jj-args")"

# --- When jj itself refuses a move ---

# jj refuses the bookmark write -- a divergent bookmark, another op holding the
# lock. main was not refreshed, so the audit says so instead of handing back as
# though it were; and the working copy must not be moved onto a base its
# bookmark never reached, because that is the half-refresh whose next
# `jj git push -b main` pushes the stale commit.
mkdir -p "$tmp/nobookbin"
cp "$tmp/bin/rex" "$tmp/nobookbin/rex"
cat >"$tmp/nobookbin/jj" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$JJ_ARGS_FILE"
case "$*" in
  "bookmark set "*) printf 'jj: bookmark main is divergent\n' >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$tmp/nobookbin/jj"
DONE_PATH="$tmp/nobookbin:$tmp/bin:$PATH" DONE_MAIN_DIR=$tmp/real-main run_done
want_status "a refused bookmark write is a blocker" 4
want_out "the refused-bookmark block" "can't tear down feat/6c4

  main was not moved: jj refused to move its bookmark; run jj bookmark set main -r main@origin in $tmp/real-main

nothing was removed; press any key"
ran=$((ran + 1))
! grep -q 'argv=new ' "$tmp/jj-args" ||
  fail "a bookmark that did not move does not take the working copy with it" \
    "$(cat "$tmp/jj-args")"

# jj takes the bookmark but refuses the working copy: a blocker too, one line
# for the one write that did not happen, and still the 4 of a refusal rather
# than jj's exit code.
mkdir -p "$tmp/nonewbin"
cp "$tmp/bin/rex" "$tmp/nonewbin/rex"
cat >"$tmp/nonewbin/jj" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$JJ_ARGS_FILE"
case "$*" in
  new\ *) printf 'jj: cannot create a new commit\n' >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$tmp/nonewbin/jj"
DONE_PATH="$tmp/nonewbin:$tmp/bin:$PATH" DONE_MAIN_DIR=$tmp/real-main run_done
want_status "a refused working-copy move is a blocker" 4
want_out "the refused-new block" "can't tear down feat/6c4

  main's working copy was not moved; run jj new main@origin in $tmp/real-main

nothing was removed; press any key"
ran=$((ran + 1))
grep -q '^cwd=.* argv=bookmark set main -r main@origin$' "$tmp/jj-args" ||
  fail "the refused working copy still had its bookmark moved" "$(cat "$tmp/jj-args")"

# --- main's state read from jj rather than saved ---

# --main-state is the seam; this is the read it stands in for. A jj that
# answers "nothing ahead of the base, nothing in the working copy" is the clean
# answer, and the two writes follow from it.
mkdir -p "$tmp/statebin"
cp "$tmp/bin/rex" "$tmp/statebin/rex"
cat >"$tmp/statebin/jj" <<'EOF'
#!/bin/sh
# main's state as jj would answer it: nothing ahead of the base and nothing in
# the working copy, unless JJ_AHEAD says main carries a commit of its own.
# Every call is recorded, so the reads and the writes can both be read back.
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$JJ_ARGS_FILE"
case "$*" in
  "log -r main ~ ::main@origin"*) [ -z "${JJ_AHEAD:-}" ] || printf '%s\n' "$JJ_AHEAD" ;;
esac
exit 0
EOF
chmod +x "$tmp/statebin/jj"
DONE_PATH="$tmp/statebin:$tmp/bin:$PATH" DONE_MAIN_DIR=$tmp/real-main \
  run_done --main-state ''
want_status "main's state read from jj, both answers clean, carries on" 0
want_out "a clean main read from jj prints nothing" ""
ran=$((ran + 1))
grep -q 'argv=log -r main ~ ::main@origin --no-graph' "$tmp/jj-args" ||
  fail "the containment question is asked of jj" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
grep -q 'argv=diff --from @- --to @ --name-only$' "$tmp/jj-args" ||
  fail "the working copy is asked for its diff" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
grep -q 'argv=log -r @ --no-graph -T description$' "$tmp/jj-args" ||
  fail "the working copy is asked for its description" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
grep -q '^cwd=.* argv=bookmark set main -r main@origin$' "$tmp/jj-args" ||
  fail "a clean answer from jj still moves the bookmark" "$(cat "$tmp/jj-args")"
ran=$((ran + 1))
grep -q '^cwd=.* argv=new main@origin$' "$tmp/jj-args" ||
  fail "a clean answer from jj still moves the working copy" "$(cat "$tmp/jj-args")"

# A change id from the containment read is main carrying a commit the base does
# not have, and that is the blocker -- read from jj rather than passed in.
export JJ_AHEAD=aaa111
DONE_PATH="$tmp/statebin:$tmp/bin:$PATH" DONE_MAIN_DIR=$tmp/real-main \
  run_done --main-state ''
unset JJ_AHEAD
want_status "an ahead answer from jj is a blocker" 4
want_out "the ahead block read from jj" "can't tear down feat/6c4

  main was not moved: it has commits main@origin does not; the bookmark is yours to push or abandon

nothing was removed; press any key"
ran=$((ran + 1))
! grep -q 'argv=new main@origin' "$tmp/jj-args" ||
  fail "an ahead answer from jj moves nothing" "$(cat "$tmp/jj-args")"


# --- The hand-back, and the close that comes last ---

# A clean workspace: one hand-back carrying the five keys, then the close, and
# nothing else. --main is a directory that is there, because the flow moves it
# before it hands back and because the close runs in it; /p/demo/main is an
# answer, not a place, and cd would fail there after the workspace is gone.
# The payload carries the path for worktrunk and the workspace name for the
# tab, both as cmd_done resolved them.
want_line="rex do work_done_go --args '{\"project\":\"demo\",\"root\":\"/p/demo\",\"main\":\"$tmp/real-main\",\"workspace\":\"feat/6c4\",\"path\":\"/p/demo/feat-6c4\"}'"
DONE_MAIN_DIR=$tmp/real-main run_done --dry-run
want_status "a clean dry run exits 0" 0
want_out "the dry run prints the one hand-back" "$want_line"
ran=$((ran + 1))
[ ! -s "$tmp/rex-args" ] || fail "a dry run closes nothing" "$(cat "$tmp/rex-args")"
# What a dry run leaves out is the hand-back, not the audit: the two moves main
# gets are made exactly as a real run makes them, which is what the usage text
# says and what this pins.
ran=$((ran + 1))
[ "$(cat "$tmp/jj-args")" = "cwd=$tmp/real-main argv=bookmark set main -r main@origin
cwd=$tmp/real-main argv=new main@origin" ] ||
  fail "a dry run still refreshes main" "$(cat "$tmp/jj-args")"

# The same run for real: the hand-back first, then the close, and no third
# rex call. The close runs in --main, the one directory that is still there
# once the workspace under the script's own cwd is gone.
DONE_MAIN_DIR=$tmp/real-main run_done
want_status "a clean run exits 0" 0
want_out "a clean run prints nothing" ""
ran=$((ran + 1))
[ "$(wc -l <"$tmp/rex-args")" -eq 2 ] ||
  fail "exactly the hand-back and the close" "$(cat "$tmp/rex-args")"
ran=$((ran + 1))
# The hand-back runs where the float runs, not in main: the payload says
# where everything is, and this script has not moved yet.
[ "$(sed -n 1p "$tmp/rex-args")" = "cwd=$PWD argv=do work_done_go --args {\"project\":\"demo\",\"root\":\"/p/demo\",\"main\":\"$tmp/real-main\",\"workspace\":\"feat/6c4\",\"path\":\"/p/demo/feat-6c4\"}" ] ||
  fail "the hand-back is the first rex call, from the float's own cwd" "$(cat "$tmp/rex-args")"
ran=$((ran + 1))
[ "$(sed -n 2p "$tmp/rex-args")" = "cwd=$tmp/real-main argv=window close -s s1 w1" ] ||
  fail "the close is the second and last rex call, run in main" "$(cat "$tmp/rex-args")"

# A refused run never reaches rex at all: nothing was removed, so there is
# nothing to hand back and no tab to close.
DONE_MAIN_DIR=$tmp/real-main DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a refusal exits 4" 4
ran=$((ran + 1))
[ ! -s "$tmp/rex-args" ] || fail "a refusal never reaches rex" "$(cat "$tmp/rex-args")"

# A hand-back Rex refuses is one line, and closes nothing: the tab stays, so
# the person can read what rex said and try again.
REX_FAIL=boom DONE_MAIN_DIR=$tmp/real-main run_done
want_status "a failed hand-back exits 1" 1
want_err_has "a failed hand-back is named" "could not finish the hand-back"
ran=$((ran + 1))
[ "$(wc -l <"$tmp/rex-args")" -eq 1 ] ||
  fail "a failed hand-back closes nothing" "$(cat "$tmp/rex-args")"

# The close is the last step and the only one that has to enter main, and it
# comes after the hand-back -- which is what removes a worktree, so main can be
# gone by then. The failure has to be a line of this script's rather than bash
# naming a line of it, and the tab stays open: a close that could not run is not
# a close. The stand-in rex takes main away on the hand-back, which is how a run
# that was fine a moment ago reaches the close without a directory.
mkdir -p "$tmp/vanish-bin" "$tmp/pass-away"
cat >"$tmp/vanish-bin/rex" <<'EOF'
#!/bin/sh
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >>"$REX_ARGS_FILE"
[ -z "${REX_VANISH:-}" ] || rmdir "$REX_VANISH" 2>/dev/null
EOF
chmod +x "$tmp/vanish-bin/rex"
export REX_VANISH=$tmp/pass-away
DONE_PATH="$tmp/vanish-bin:$tmp/bin:$PATH" DONE_MAIN_DIR=$tmp/pass-away run_done
unset REX_VANISH
want_status "a main that is gone at the close exits 1" 1
want_err_has "a close that cannot enter main names the place" \
  "could not enter $tmp/pass-away to close the tab"
ran=$((ran + 1))
[ "$(wc -l <"$tmp/rex-args")" -eq 1 ] ||
  fail "a close that could not run closes nothing" "$(cat "$tmp/rex-args")"


if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
