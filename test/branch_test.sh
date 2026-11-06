#!/usr/bin/env bash
# `new-work.sh branch-default`, `new-work.sh candidates` and `new-work.sh bases`.
#
# branch-default turns a bead's issue_type and id into the branch name the
# picker offers; candidates collects the branch names that already exist -- the
# workspaces jj lists and the local bookmarks -- so the picker can offer them
# too. bases resolves the jj revision a new workspace is started from and the
# short cycle of revisions around it. All three run without fzf.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fails=0
ran=0
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  fails=$((fails + 1))
  printf 'FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '  %s\n' "$2"
  fi
}

# branch-default <type> <id> <expected branch>
branch_default() {
  local type=$1 id=$2 want=$3 got status
  ran=$((ran + 1))
  got=$(./new-work.sh branch-default --type "$type" --id "$id" 2>"$tmp/err")
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "branch-default $type $id" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$got" != "$want" ]; then
    fail "branch-default $type $id" "want $want, got $got"
    return
  fi
  # The picker hands this straight to `wt switch --create`, so it has to be a
  # ref git will accept.
  if ! git check-ref-format "refs/heads/$got"; then
    fail "branch-default $type $id" "$got is not a valid git ref name"
  fi
}

# Every row of the prefix map, plus the fallback for types not in it.
branch_default bug pmm-iris-a4l bug/a4l
branch_default feature pmm-iris-8u1 feat/8u1
branch_default task pmm-iris-58h feat/58h
branch_default chore pmm-iris-p4pip chore/p4pip
branch_default spike x-1 spike/1
branch_default decision x-1 feat/1
# Last dash wins: a three-part id keeps only its final segment.
branch_default bug rex-config-6c4 bug/6c4
branch_default task a-b-c-d-9z9 feat/9z9

run_branch_default_missing() {
  ran=$((ran + 1))
  ./new-work.sh branch-default "$@" >"$tmp/out" 2>"$tmp/err"
  local status=$?
  if [ "$status" -ne 2 ]; then
    fail "branch-default $* exits 2" "exit $status: $(cat "$tmp/err")"
  fi
}
run_branch_default_missing --type bug

# An id ending in a dash leaves no last segment, so the name would be "bug/":
# not a ref, and refused by name rather than handed to worktrunk.
ran=$((ran + 1))
./new-work.sh branch-default --type bug --id pmm-iris- >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 2 ]; then
  fail "an id ending in a dash exits 2" "exit $status: $(cat "$tmp/err")"
elif ! grep -qF 'branch-default: --id pmm-iris- leaves no name to use' "$tmp/err"; then
  fail "an id ending in a dash says why" "stderr: $(cat "$tmp/err")"
fi
run_branch_default_missing --id pmm-iris-a4l
run_branch_default_missing

# Existing branch names, one per line: the branches a jj workspace is already on
# first, then the local bookmarks with no workspace of their own, de-duplicated in
# that order. The listing is the same "name<TAB>root" rendering `done --workspaces`
# reads, so one fixture serves both subcommands, and a bookmark is a name alone.
# The `default` row of the listing is jj's own workspace at the wrapper and is
# never a branch, so feat/6c4, feat/6c4-sub and main are the whole first half.
cat >"$tmp/candidates.expected" <<'EOF'
feat/6c4
feat/6c4-sub
main
bug/a4l
EOF

ran=$((ran + 1))
./new-work.sh candidates --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates listing" "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates listing" "output differs from the expected branch list"
fi

# The same call with neither fzf nor jq on PATH: neither is part of this answer
# any more. There is no JSON document to parse -- jj's rows are already the two
# lists -- so a copy of the script is not needed to read them.
ran=$((ran + 1))
mkdir -p "$tmp/bin"
for tool in bash awk cat; do
  ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
PATH=$tmp/bin ./new-work.sh candidates --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates needs neither fzf nor jq" "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates needs neither fzf nor jq" \
    "output differs from the expected branch list"
fi

# A row ending in /HEAD is dropped rather than offered: git's short refname
# rendering and a detached worktree both used to put one in this list, and it is
# no branch to switch to. The listing here holds nothing but the `default` row,
# so the bookmarks are the whole answer.
printf 'origin/HEAD\nfix/headless\n' >"$tmp/head-bookmarks"
printf 'fix/headless\n' >"$tmp/head.expected"
ran=$((ran + 1))
./new-work.sh candidates \
  --workspaces test/fixtures/workspaces-default-only.txt \
  --bookmarks "$tmp/head-bookmarks" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a /HEAD row is dropped" "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/head.expected" "$tmp/out"; then
  fail "a /HEAD row is dropped" "output: $(cat "$tmp/out")"
fi

# Reading both lists out of a real repository: --main with no fixtures at all.
# The repository is a real one because the one thing a saved listing cannot
# prove is that jj's own rendering parses as rows -- the tab between a workspace
# and its root, the trailing newline, and the `default` workspace that is no
# branch. jj is asked here and nowhere else in this file, so a host without it
# says so once instead of failing every case below.
if ! command -v jj >/dev/null 2>&1; then
  fail 'candidates from a repository' \
    'this host has no jj, so no repository can be made to read'
else
  ran=$((ran + 1))
  mkdir -p "$tmp/jjrepo/main"
  if ( cd "$tmp/jjrepo/main" && jj git init . >/dev/null 2>&1 &&
    jj workspace add --name feat/real-one "$tmp/jjrepo/feat-real-one" \
      >/dev/null 2>&1 &&
    jj bookmark create fix/real-two -r @ >/dev/null 2>&1 ); then
    printf 'feat/real-one\nfix/real-two\n' >"$tmp/repo.expected"
    ./new-work.sh candidates --main "$tmp/jjrepo/main" >"$tmp/out" 2>"$tmp/err"
    status=$?
    if [ "$status" -ne 0 ]; then
      fail "candidates from a repository" "exit $status: $(cat "$tmp/err")"
    elif ! diff -u "$tmp/repo.expected" "$tmp/out"; then
      fail "candidates from a repository" \
        "output differs from the expected branch list"
    fi
  else
    fail 'candidates from a repository' 'the jj fixtures could not be made'
  fi
fi

ran=$((ran + 1))
./new-work.sh candidates >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 2 ]; then
  fail "candidates without --main exits 2" "exit $status: $(cat "$tmp/err")"
fi

# A --main that is not there is refused by name, before anything is read from
# it: left to candidate_rows it surfaces as bash's own `cd` error, which names a
# line of this script rather than a place on the disk.
ran=$((ran + 1))
./new-work.sh candidates --main "$tmp/nowhere" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 1 ]; then
  fail "candidates with a --main that is not there exits 1" \
    "exit $status: $(cat "$tmp/err")"
elif ! grep -qF "new-work.sh: candidates: no such directory: $tmp/nowhere" "$tmp/err"; then
  fail "candidates with a --main that is not there is named" "stderr: $(cat "$tmp/err")"
elif grep -q 'cd:' "$tmp/err"; then
  fail "candidates with a --main that is not there is named" \
    "bash's own cd error is still in: $(cat "$tmp/err")"
fi

# ... but only when it will really be read: --workspaces and --bookmarks are the
# two sources candidates has, so --main is never touched and a directory that is
# not there costs nothing. The same shape pick accepts, since it is how the tests
# and dry runs call both commands.
ran=$((ran + 1))
./new-work.sh candidates --main "$tmp/nowhere" \
  --workspaces test/fixtures/workspaces.txt \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates with both fixtures ignores an unread --main" \
    "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates with both fixtures ignores an unread --main" \
    "output differs from the expected branch list"
fi

# A --workspaces fixture that cannot be opened is the caller's mistake, not a
# repository this machine cannot read, so it is not forgiven the way a failed
# `jj workspace list` is: the run stops at the failed read, naming the file, and
# prints no rows at all -- the bookmark half included, because half a list is a
# guess dressed as an answer.
ran=$((ran + 1))
./new-work.sh candidates --main "$tmp/nowhere" \
  --workspaces "$tmp/no-such-workspaces.txt" \
  --bookmarks test/fixtures/branch-bookmarks.txt \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -eq 0 ]; then
  fail "candidates with an unopenable --workspaces exits non-zero" \
    "exit $status"
elif [ -s "$tmp/out" ]; then
  fail "candidates with an unopenable --workspaces prints no rows" \
    "output: $(cat "$tmp/out")"
elif [ "$(cat "$tmp/err")" != \
  "new-work.sh: could not read the workspaces of $tmp/no-such-workspaces.txt" ]; then
  fail "candidates with an unopenable --workspaces names the file" \
    "stderr: $(cat "$tmp/err")"
fi

# A jj that cannot produce one of the two lists: that half is lost, the other one
# still comes through, and the partial list says so, naming the directory. Only
# this subcommand answers from half of it: a pick given a name missing here is
# refused rather than guessed at, since the guess would be a create (or an
# attach) for a branch that already has a workspace.
mkdir -p "$tmp/half-jj"
cat >"$tmp/half-jj/jj" <<'EOF'
#!/bin/sh
# The listing fails the way a locked working copy or a missing repository makes
# it fail; the bookmarks are answered as jj renders them.
case " $* " in
  *' workspace list '*) printf 'jj: could not read the repository\n' >&2; exit 1 ;;
  *' bookmark list '*) printf 'fix/real-two\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/half-jj/jj"
mkdir -p "$tmp/half-repo"
ran=$((ran + 1))
PATH="$tmp/half-jj:$PATH" ./new-work.sh candidates --main "$tmp/half-repo" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a failed workspace listing still lists the bookmarks" \
    "exit $status: $(cat "$tmp/err")"
elif ! grep -qx 'fix/real-two' "$tmp/out"; then
  fail "a failed workspace listing still lists the bookmarks" \
    "output: $(cat "$tmp/out")"
elif ! grep -qxF \
  "new-work.sh: could not read the workspaces of $tmp/half-repo" "$tmp/err"; then
  fail "a failed workspace listing is said out loud" "stderr: $(cat "$tmp/err")"
fi

# The bookmarks of a pretend repository, as bases reads them: exactly what
#
#   jj bookmark list --all-remotes -T 'name ++ "@" ++ remote ++ "\n"'
#
# prints, one "<name>@<remote>" per line -- and a bare "<name>@" for a bookmark
# no remote has. One argument per row, so a case reads as the bookmarks it
# stands for.
bookmarks_file() { # FILE ROW...
  local file=$1
  shift
  : >"$file"
  while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >>"$file"
    shift
  done
}

# bases <case name> <expected stdout> [args...]
#
# The whole of stdout is compared, so a row gained or lost fails the case. A
# command substitution drops the closing newline, so each expectation ends with
# the last row -- and begins with the first, which an empty line when the
# opening answer is "no revision at all".
run_bases() {
  local name=$1 want=$2 got status
  shift 2
  ran=$((ran + 1))
  got=$(./new-work.sh bases "$@" 2>"$tmp/err")
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "bases: $name" "exit $status: $(cat "$tmp/err")"
    return
  fi
  if [ "$got" != "$want" ]; then
    fail "bases: $name" "want $(printf '%q' "$want"), got $(printf '%q' "$got")"
  fi
}

# The shape most cases start from: the committed fixture, whose jj knows the
# remote-tracking bookmark main, its own mirror of it, the bare local form every
# bookmark also has, and a topic on origin -- but no master, so master is not a
# revision this clone can offer. The mirror and the bare form are never rows.
run_bases 'the default branch on origin opens the cycle' \
  $'main@origin\n@\nmain' \
  --base-bookmarks test/fixtures/bookmarks.txt --origin-head origin/main

# A clone that also has master offers all four: the two bare local revisions are
# exactly what the cycle is for.
bookmarks_file "$tmp/bookmarks.both" \
  main@ main@origin master@ master@origin
run_bases 'both local branches are offered after @' \
  $'main@origin\n@\nmain\nmaster' \
  --base-bookmarks "$tmp/bookmarks.both" --origin-head origin/main

# origin/HEAD is the branch this clone says it tracks, so it is asked before any
# fixed name -- and the answer is that branch on origin, in jj's vocabulary: the
# branch name and the remote it lives on, as one revision. This clone has no main
# and no master, so the opening answer and @ are the whole cycle.
bookmarks_file "$tmp/bookmarks.develop" develop@ develop@origin
run_bases 'origin/HEAD decides the opening answer' \
  $'develop@origin\n@' \
  --base-bookmarks "$tmp/bookmarks.develop" --origin-head origin/develop

# With no origin/HEAD named -- a clone that has none, or a run standing in for
# one -- the fixed names speak, in the order they always have.
bookmarks_file "$tmp/bookmarks.main" main@ main@origin
run_bases 'main@origin opens the cycle when there is no origin/HEAD' \
  $'main@origin\n@\nmain' --base-bookmarks "$tmp/bookmarks.main"

bookmarks_file "$tmp/bookmarks.master" master@ master@origin
run_bases 'master@origin opens it when there is no main on origin' \
  $'master@origin\n@\nmaster' --base-bookmarks "$tmp/bookmarks.master"

# A bookmark a remote has implies the local one jj tracks, so a list with only
# the remote rendering still offers the bare name.
bookmarks_file "$tmp/bookmarks.remote-only" main@origin
run_bases 'a remote bookmark implies the local one' \
  $'main@origin\n@\nmain' --base-bookmarks "$tmp/bookmarks.remote-only"

# Nothing on origin at all -- a bookmark only this machine has -- leaves @ to
# open, because the working copy is always a revision to start from; main is
# still offered, because this clone really has it.
bookmarks_file "$tmp/bookmarks.local-only" main@
run_bases 'a bookmark no remote has opens the cycle on @, and is still offered' \
  $'@\nmain' --base-bookmarks "$tmp/bookmarks.local-only"

# A record with no @ at all is not one of jj's renderings but a fixture typo --
# `main` where `main@` was meant. Read as a local bookmark it would offer a row
# this clone may not have, so it is skipped: the row below is there because
# master@origin is a real record, and the bare main is not.
bookmarks_file "$tmp/bookmarks.no-at" master@origin main
run_bases 'a record with no @ is ignored, not read as a local bookmark' \
  $'master@origin\n@\nmaster' --base-bookmarks "$tmp/bookmarks.no-at"

# A cycle with no main and no master in it at all: the opening answer and @, and
# nothing else. A bare name is a promise jj can resolve it, so it is only made
# where the bookmark list says the branch is there.
bookmarks_file "$tmp/bookmarks.topic-only" topic@origin
run_bases 'a clone with no main and no master offers only @ beside the answer' \
  $'topic@origin\n@' \
  --base-bookmarks "$tmp/bookmarks.topic-only" --origin-head origin/topic

: >"$tmp/bookmarks.none"
run_bases 'no bookmarks at all is @ and nothing else' \
  $'@' --base-bookmarks "$tmp/bookmarks.none"

# jj's own mirror of the remote-tracking refs is not a bookmark anyone starts a
# workspace from, and it is no evidence that one exists: a list holding only the
# mirror offers @.
bookmarks_file "$tmp/bookmarks.git-only" main@git
run_bases 'a @git mirror is neither a row nor evidence of one' \
  $'@' --base-bookmarks "$tmp/bookmarks.git-only"

ran=$((ran + 1))
if ./new-work.sh bases --base-bookmarks test/fixtures/bookmarks.txt \
  --origin-head origin/main 2>"$tmp/err" | grep -q '@git'; then
  fail '@git appears in no output' \
    "stdout: $(./new-work.sh bases --base-bookmarks test/fixtures/bookmarks.txt \
      --origin-head origin/main 2>/dev/null)"
fi

# A configured base is the opening answer whatever it names: the picker does not
# get to refuse a revision it cannot resolve, because the workspace is made
# later, in the tab, where jj will answer for it.
run_bases '--base is the opening answer, verbatim' \
  $'main@origin\n@\nmain' \
  --base-bookmarks test/fixtures/bookmarks.txt --base main@origin
run_bases 'an --base that resolves to nothing is still the answer' \
  $'refresh\n@\nmain' \
  --base-bookmarks test/fixtures/bookmarks.txt --base refresh

# The configured default is @, and the cycle offers @ once: an opening answer is
# a row like any other, not a second copy of one.
run_bases '--base @ is the opening answer and appears once' \
  $'@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.both" --base '@'

# --no-base is "no revision at all": an empty first line, then the same cycle,
# because ctrl-r still moves off it.
run_bases '--no-base opens on an empty line' \
  $'\n@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.both" --no-base

# --base-bookmarks is the whole source, so --main is never opened -- and a
# directory that is not there therefore costs nothing. The mirror of the
# candidates case.
run_bases '--base-bookmarks is read instead of --main' \
  $'main@origin\n@\nmain' \
  --main "$tmp/nowhere" --base-bookmarks test/fixtures/bookmarks.txt \
  --origin-head origin/main

# The refusals. An unreadable fixture is a read that failed, and it says so once
# and under the verb that ran: the shell's own `line NNN: ... No such file or
# directory` would be a second line, and it names a line of this script rather
# than the file.
#
# bases_dies <case name> <expected line> [args...]
bases_dies() {
  local name=$1 want=$2
  shift 2
  ran=$((ran + 1))
  ./new-work.sh bases "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
  if [ "$status" -ne 1 ]; then
    fail "bases: $name exits 1" "exit $status: $(cat "$tmp/err")"
  elif [ "$(cat "$tmp/err")" != "new-work.sh: $want" ]; then
    fail "bases: $name says so, once" "stderr: $(cat "$tmp/err")"
  fi
}

# bases_refuses <case name> <expected first line> [args...]
#
# A usage refusal: exit 2, the message first and the usage after it.
bases_refuses() {
  local name=$1 want=$2
  shift 2
  ran=$((ran + 1))
  ./new-work.sh bases "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
  if [ "$status" -ne 2 ]; then
    fail "bases: $name exits 2" "exit $status: $(cat "$tmp/err")"
  elif [ "$(sed -n 1p "$tmp/err")" != "new-work.sh: $want" ]; then
    fail "bases: $name says why" "stderr: $(sed -n 1p "$tmp/err")"
  fi
}

bases_dies 'an unreadable --base-bookmarks' \
  "bases: could not read the bookmarks of $tmp/no-such-bookmarks" \
  --base-bookmarks "$tmp/no-such-bookmarks"
bases_dies 'a --main that is not there' \
  "bases: no such directory: $tmp/nowhere" --main "$tmp/nowhere"
bases_refuses 'neither --main nor --base-bookmarks' \
  'bases: need --main DIR (or --base-bookmarks FILE)'
bases_refuses '--base with --no-base' \
  'bases: --base and --no-base answer the same question' \
  --base-bookmarks test/fixtures/bookmarks.txt --base refresh --no-base

# Both reads out of a real place: --main with no fixture at all. jj is stood in
# for -- the suite does not require it, and its rendering is the one thing this
# script takes on trust -- while origin/HEAD is a real symref in a real
# repository. That it points at trunk, and not at the main its bookmarks hold,
# is what proves git was asked rather than guessed from the bookmark list.
mkdir -p "$tmp/jj-bin"
cat >"$tmp/jj-bin/jj" <<'EOF'
#!/bin/sh
printf 'main@\nmain@git\nmain@origin\nmaster@\nmaster@origin\n'
EOF
chmod +x "$tmp/jj-bin/jj"
ran=$((ran + 1))
git init -q "$tmp/base-repo" && git -C "$tmp/base-repo" \
  -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init &&
  git -C "$tmp/base-repo" update-ref refs/remotes/origin/trunk HEAD &&
  git -C "$tmp/base-repo" symbolic-ref refs/remotes/origin/HEAD \
    refs/remotes/origin/trunk
printf 'trunk@origin\n@\nmain\nmaster\n' >"$tmp/base.expected"
PATH="$tmp/jj-bin:$PATH" ./new-work.sh bases --main "$tmp/base-repo" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'bases from a repository' "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'bases from a repository' 'output differs from the expected cycle'
fi

# The same read in a repository that names no origin/HEAD at all -- a clone whose
# remote was renamed, or one that never had a symref. git exits non-zero, and
# that is an empty answer rather than a failure: the cycle falls through to the
# bookmarks, the run still succeeds, and nothing is said about a lookup that is
# allowed to miss.
ran=$((ran + 1))
git init -q "$tmp/base-repo-headless" && git -C "$tmp/base-repo-headless" \
  -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
printf 'main@origin\n@\nmain\nmaster\n' >"$tmp/base.expected"
PATH="$tmp/jj-bin:$PATH" ./new-work.sh bases --main "$tmp/base-repo-headless" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'no origin/HEAD falls through to the bookmarks' \
    "exit $status: $(cat "$tmp/err")"
elif [ -s "$tmp/err" ]; then
  fail 'no origin/HEAD is not a failure' "stderr: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'no origin/HEAD falls through to the bookmarks' \
    'output differs from the expected cycle'
fi

# --base-bookmarks stands in for the repository as a whole, so a run that has
# both reads the fixture for the bookmarks and never asks git for origin/HEAD:
# this repository's symref points at trunk, and the fixture's main@origin is what
# opens the cycle.
ran=$((ran + 1))
printf 'main@origin\n@\nmain\n' >"$tmp/base.expected"
PATH="$tmp/jj-bin:$PATH" ./new-work.sh bases --main "$tmp/base-repo" \
  --base-bookmarks test/fixtures/bookmarks.txt >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'a bookmark fixture beside a real --main' "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'a bookmark fixture beside a real --main' \
    'the fixture does not win the opening row'
fi

# A wrapper with no `.git` anywhere -- what `jj git init --no-colocate` makes, and
# the state this cut is for -- still opens the base cycle on the branch the
# project treats as its default. jj records no remote-HEAD symref of its own, so
# with nothing for git to read the cycle answers from the fixed pair: main, then
# master, then @.
#
# git is stood in for by a liar, not left off PATH: the point is that it is never
# *asked*. A stand-in that answers `trunk` is an answer nobody should take (the
# wrapper has no .git to have read it from), and the mark it leaves says whether
# the question was put at all.
mkdir -p "$tmp/git-bin"
cat >"$tmp/git-bin/git" <<'EOF'
#!/bin/sh
touch "$GIT_MARKER"
printf 'trunk\n'
EOF
chmod +x "$tmp/git-bin/git"
mkdir -p "$tmp/nogit/main" "$tmp/nogit/.jj/repo"

# Both fixed names present: the first of them opens the cycle.
ran=$((ran + 1))
printf 'main@origin\n@\nmain\nmaster\n' >"$tmp/base.expected"
rm -f "$tmp/git-asked"
GIT_MARKER=$tmp/git-asked PATH="$tmp/git-bin:$tmp/jj-bin:$PATH" \
  ./new-work.sh bases --main "$tmp/nogit/main" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'a wrapper with no .git opens on main@origin' \
    "exit $status: $(cat "$tmp/err")"
elif [ -s "$tmp/err" ]; then
  fail 'a wrapper with no .git is not a failure' "stderr: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'a wrapper with no .git opens on main@origin' \
    'output differs from the expected cycle'
fi
ran=$((ran + 1))
if [ -e "$tmp/git-asked" ]; then
  fail 'a wrapper with no .git never asks git' 'git was run'
fi

# Only master, which is the whole of the fall-through: a project whose default
# was never renamed answers master@origin.
mkdir -p "$tmp/jj-master-bin"
cat >"$tmp/jj-master-bin/jj" <<'EOF'
#!/bin/sh
printf 'master@\nmaster@origin\n'
EOF
chmod +x "$tmp/jj-master-bin/jj"
ran=$((ran + 1))
printf 'master@origin\n@\nmaster\n' >"$tmp/base.expected"
GIT_MARKER=$tmp/git-asked PATH="$tmp/git-bin:$tmp/jj-master-bin:$PATH" \
  ./new-work.sh bases --main "$tmp/nogit/main" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'a wrapper with no .git and no main opens on master@origin' \
    "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'a wrapper with no .git and no main opens on master@origin' \
    'output differs from the expected cycle'
fi

# Neither, and the run still succeeds: an unanswerable default is a
# fall-through, not a failure, and the cycle is the working copy alone.
mkdir -p "$tmp/jj-topic-bin"
cat >"$tmp/jj-topic-bin/jj" <<'EOF'
#!/bin/sh
printf 'topic@\ntopic@origin\n'
EOF
chmod +x "$tmp/jj-topic-bin/jj"
ran=$((ran + 1))
printf '@\n' >"$tmp/base.expected"
GIT_MARKER=$tmp/git-asked PATH="$tmp/git-bin:$tmp/jj-topic-bin:$PATH" \
  ./new-work.sh bases --main "$tmp/nogit/main" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'no default branch at all still answers the cycle' \
    "exit $status: $(cat "$tmp/err")"
elif [ -s "$tmp/err" ]; then
  fail 'no default branch at all says nothing' "stderr: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'no default branch at all still answers the cycle' \
    'output differs from the expected cycle'
fi

# And the guard from the other side: the `.git` that is not in the base
# directory but in the wrapper above it. <wrapper>/main is how a ginit'd wrapper
# is laid out, so this is the shape the flow really meets, and the symref is a
# question git can answer there.
mkdir -p "$tmp/gitwrap"
git init -q "$tmp/gitwrap" && git -C "$tmp/gitwrap" \
  -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init &&
  git -C "$tmp/gitwrap" update-ref refs/remotes/origin/trunk HEAD &&
  git -C "$tmp/gitwrap" symbolic-ref refs/remotes/origin/HEAD \
    refs/remotes/origin/trunk
mkdir -p "$tmp/gitwrap/main"
ran=$((ran + 1))
printf 'trunk@origin\n@\nmain\nmaster\n' >"$tmp/base.expected"
PATH="$tmp/jj-bin:$PATH" ./new-work.sh bases --main "$tmp/gitwrap/main" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail 'a .git beside main is a question for git' \
    "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/base.expected" "$tmp/out"; then
  fail 'a .git beside main is a question for git' \
    'output differs from the expected cycle'
fi

# The branch-name rule, applied where a person's typed name actually meets it:
# `pick` refuses a name it could not create while the float is still on screen.
# Every name in the refused table below is one `git check-ref-format --branch`
# also refused, checked one by one against git while this rule was being written
# -- the rule is git's, re-expressed in the shell now that the flow runs where
# there may be no git to ask. `@` is the one name this flow refuses and git
# accepts: in jj's language `@` is the working copy, so a bookmark named `@`
# would be read as an answer to a different question -- it always has been.
#
# git is answered here by a stand-in that refuses every question and leaves a
# mark when it was asked one. That is the whole point of the table: a name must
# be accepted or refused by the rule in this script, and never by git. The mark
# is how 'git was not asked' is proven rather than argued.
#
# An empty name never reaches the rule: a pick with no branch is no branch, and
# it is refused a step earlier, with the one line that has always said so.
mkdir -p "$tmp/gitless-bin"
cat >"$tmp/gitless-bin/git" <<'EOF'
#!/bin/sh
touch "$GIT_MARKER"
exit 1
EOF
chmod +x "$tmp/gitless-bin/git"
printf 'main\t/p/demo/main\n' >"$tmp/name-ws"
printf 'main\n' >"$tmp/name-br"
printf 'main@origin\n' >"$tmp/name-base"
printf '[]\n' >"$tmp/name-beads"
mkdir -p "$tmp/name-state"

# pick_name <name>: one dry pick whose branch answer is NAME, with every read
# saved, so nothing here needs a repository or a terminal. Not on either list,
# so NAME is always a branch to create -- the only mode the rule checks. The
# state directory is one of its own, so no name is remembered for the next run.
pick_name() {
  ran=$((ran + 1))
  rm -f "$tmp/git-asked"
  GIT_MARKER=$tmp/git-asked PATH="$tmp/gitless-bin:$PATH" \
    XDG_STATE_HOME=$tmp/name-state ./new-work.sh pick \
    --main /p/demo/main --root /p/demo --project demo \
    --bd-json "$tmp/name-beads" \
    --workspaces "$tmp/name-ws" --bookmarks "$tmp/name-br" \
    --base-bookmarks "$tmp/name-base" \
    --bead '' --branch "$1" --dry-run >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

for name in '@' '-x' 'a..b' 'a.' 'a/b/' 'a b' 'a~b' 'a^b' 'a:b' 'a?b' 'a*b' \
  'a[b' 'a\b' 'a//b' 'feat/x..y' 'feat/x.' '-feat/x' $'a\001b'; do
  pick_name "$name"
  # Quoted for the message: one of these holds a byte no terminal draws, and a
  # failure on it has to say which name it was.
  shown=$(printf '%q' "$name")
  if [ "$status" -ne 2 ]; then
    fail "the name $shown is refused" "exit $status: $(cat "$tmp/err")"
  elif ! grep -qxF "new-work.sh: not a valid branch name: $name" "$tmp/err"; then
    fail "the name $shown says why" "stderr: $(cat "$tmp/err")"
  elif [ -s "$tmp/out" ]; then
    fail "the name $shown starts nothing" "stdout: $(cat "$tmp/out")"
  elif [ -e "$tmp/git-asked" ]; then
    fail "the name $shown is refused without git" 'git was asked'
  fi
done

pick_name ''
if [ "$status" -ne 3 ]; then
  fail 'an empty name starts nothing' "exit $status: $(cat "$tmp/err")"
elif [ "$(cat "$tmp/err")" != 'new-work.sh: no branch given, nothing to start' ]; then
  fail 'an empty name says why' "stderr: $(cat "$tmp/err")"
fi

# And the names that do get through: `feat/xxx` is what a bead derives and the
# rest are the shapes a hand types -- a backtick among them, which git never had
# a quarrel with and this rule refused once. Each is a create, so each reaches the
# rule. A refusal among these is the regression this table exists to catch, and a
# mark left by the stand-in is the same regression seen from the other side: it is
# a question a git-free wrapper could never have had answered.
for name in 'feat/x' 'feat-x' 'v1.2' 'feat/x-1_2' 'fix-it' 'aeiou' 'feat/2ow' 'a`b'; do
  pick_name "$name"
  if [ "$status" -ne 0 ]; then
    fail "the name '$name' is a branch to create" \
      "exit $status: $(cat "$tmp/err")"
  elif grep -q 'not a valid branch name' "$tmp/err"; then
    fail "the name '$name' is not refused" "stderr: $(cat "$tmp/err")"
  elif [ -e "$tmp/git-asked" ]; then
    fail "the name '$name' is accepted without git" 'git was asked'
  fi
done

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
