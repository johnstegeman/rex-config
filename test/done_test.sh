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
    --bd-json test/fixtures/ready.json \
    --no-fetch --base-bookmarks test/fixtures/bookmarks.txt \
    --origin-head refs/remotes/origin/main \
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

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
