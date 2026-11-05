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
    --main /p/demo/main --root /p/demo --project demo \
    --session s1 --window w1 \
    --workspaces test/fixtures/workspaces.txt \
    --wt-json "${DONE_WT:-test/fixtures/done-wt-list.json}" \
    --diff "${DONE_DIFF:-$tmp/clean-diff}" \
    --own-status "${DONE_OWN:-$tmp/clean-own}" \
    --changes "${DONE_CHANGES:-$tmp/clean-changes}" \
    --main-state "${DONE_MAIN:-$tmp/clean-main}" \
    --bd-json "${DONE_BD_JSON:-test/fixtures/ready.json}" \
    --no-fetch --base-bookmarks test/fixtures/bookmarks.txt \
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

# A cwd in a workspace gets past identification. Nothing is printed yet: the
# hand-back arrives in Task 5, and silence is what the clean path prints.
DONE_CWD=/p/demo/feat-6c4 run_done
want_status "a workspace cwd is not refused" 0
want_out "a clean run prints nothing yet" ""

# A subdirectory of a workspace belongs to that workspace.
DONE_CWD=/p/demo/feat-6c4/docs run_done
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
DONE_DIFF=test/fixtures/done-diff.txt DONE_CHANGES=$tmp/changes-3 run_done
want_status "unmerged content is a blocker" 4
want_out "the unmerged block" "can't tear down feat/6c4

  changes not merged into main@origin: 3 changes, 4 paths
    init.lua
    new-work.sh
    docs/plan.md
    test/run.sh

nothing was removed; press any key"

# A working copy with changes of its own.
DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a dirty working copy is a blocker" 4
want_out "the dirty block" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# Both, in the order the audit asks them: the branch's changes first, the
# working copy's after.
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
DONE_CHANGES=$tmp/changes-3 run_done
want_status "a squash-merged branch is not a blocker" 0
want_out "a squash-merged branch prints nothing" ""

# The base is whatever --base-bookmarks and --origin-head resolve, never a
# hard-coded main@origin: this clone tracks develop, and develop is what the
# block names.
printf 'main@\ndevelop@\ndevelop@origin\n' >"$tmp/bookmarks.develop"
DONE_DIFF=test/fixtures/done-diff.txt DONE_CHANGES=$tmp/changes-3 run_done \
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

# --- The programs still running, and the bead the workspace belongs to ---

# A program still running in the tab is a reason not to tear it down, and the
# names come in the order they were given, in one comma-separated line.
run_done --running pi --running node
want_status "a running program is a blocker" 4
want_out "the running block" "can't tear down feat/6c4

  still running in this tab: pi, node

nothing was removed; press any key"

# A blank name is not a program: accumulated it would leave the list empty, so
# the blocker would vanish and a teardown of a tab with work in it would go
# ahead. Refused as the bad argument it is, like every other empty value here.
run_done --running ''
want_status "an empty --running is a usage error" 2

# The bead is information, not a reason: on a clean run it prints nothing at
# all, because a run that removes the workspace has no screen.
DONE_BD_JSON=test/fixtures/done-beads.json run_done
want_status "a claimed bead is not a blocker on its own" 0
want_out "a claimed bead on a clean run prints nothing" ""

# With a blocker it says which bead this workspace is, in a paragraph of its
# own, after the reasons and before the footer.
DONE_BD_JSON=test/fixtures/done-beads.json \
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
DONE_BD_JSON="$tmp/clean-changes" run_done
want_status "an empty bead list on a clean run prints nothing" 0
DONE_BD_JSON=/nonexistent run_done
want_status "an unreadable bead list on a clean run prints nothing" 0

# A bead read that fails.
DONE_BD_JSON=/nonexistent DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "an unreadable bead list is not a bead line, and is no failure" 4
want_out "the dirty block with an unreadable bead list" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# A bead list that is readable and matches nothing: the only bead in it is
# another workspace's.
DONE_BD_JSON=test/fixtures/done-beads-no-match.json \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead list that matches nothing is not a bead line" 4
want_out "the dirty block with a non-matching bead list" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# A row with no status is not a bead line: the block is prose, and a missing
# field would reach it as the word "null".
printf '[{"id":"rex-config-6c4"}]' >"$tmp/beads-no-status"
DONE_BD_JSON="$tmp/beads-no-status" \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead row with no status is still a refusal" 4
want_out "the dirty block with a statusless bead" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# An empty status is no better than a missing one: "is still " with nothing
# after it is a sentence that stopped.
DONE_BD_JSON=test/fixtures/done-beads-empty-status.json \
  DONE_OWN=test/fixtures/done-own-status.txt run_done
want_status "a bead row with an empty status is still a refusal" 4
want_out "the dirty block with an empty-status bead" "can't tear down feat/6c4

  working copy has changes: 2 paths

nothing was removed; press any key"

# Everything at once (Review Focus 4): the pinned order, the bead paragraph
# in its place, and exactly one "nothing was removed" line.
printf 'aaa111\nbbb222\nccc333\n' >"$tmp/changes-3"
DONE_BD_JSON=test/fixtures/done-beads.json \
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

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
