#!/usr/bin/env bash
# `new-work.sh branch-default`, `new-work.sh candidates` and `new-work.sh bases`.
#
# branch-default turns a bead's issue_type and id into the branch name the
# picker offers; candidates collects the branch names that already exist so the
# picker can offer them too. bases resolves the jj revision a new workspace is
# started from and the short cycle of revisions around it. All three run
# without fzf.
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

# Existing branch names, one per line: worktree branches first, then local
# branches, de-duplicated in that order, and never a ref ending in /HEAD.
cat >"$tmp/refs" <<'EOF'
feat/abc123
main
origin/HEAD
johnstegeman/k1ier
fix/cleanup
EOF

cat >"$tmp/candidates.expected" <<'EOF'
main
chore/p4pip
feat/abc123
johnstegeman/k1ier
fix/cleanup
EOF

ran=$((ran + 1))
./new-work.sh candidates --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates listing" "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates listing" "output differs from the expected branch list"
fi

# The same call with no fzf anywhere on PATH: the script must not need it.
ran=$((ran + 1))
mkdir -p "$tmp/bin"
for tool in bash jq awk cat; do
  ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
PATH=$tmp/bin ./new-work.sh candidates --wt-json test/fixtures/wt-list.json \
  --refs "$tmp/refs" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates needs no fzf" "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates needs no fzf" "output differs from the expected branch list"
fi

# Reading the branches out of a real repository: --main with no fixtures.
ran=$((ran + 1))
git init -q "$tmp/repo" && git -C "$tmp/repo" -c user.email=t@example.com \
  -c user.name=t commit -q --allow-empty -m init &&
  git -C "$tmp/repo" branch feat/real-one && git -C "$tmp/repo" branch fix/real-two
./new-work.sh candidates --main "$tmp/repo" >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates from a repository" "exit $status: $(cat "$tmp/err")"
else
  for want in feat/real-one fix/real-two; do
    if ! grep -qx "$want" "$tmp/out"; then
      fail "candidates from a repository" "missing $want in: $(cat "$tmp/out")"
    fi
  done
  if sort "$tmp/out" | uniq -d | grep -q .; then
    fail "candidates from a repository" "duplicate rows in: $(cat "$tmp/out")"
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

# ... but only when it will really be read: with both fixtures --wt-json and
# --refs are the two sources candidates has, so --main is never touched and a
# directory that is not there costs nothing. The same shape pick accepts, since
# it is how the tests and dry runs call both commands.
ran=$((ran + 1))
./new-work.sh candidates --main "$tmp/nowhere" \
  --wt-json test/fixtures/wt-list.json --refs "$tmp/refs" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "candidates with both fixtures ignores an unread --main" \
    "exit $status: $(cat "$tmp/err")"
elif ! diff -u "$tmp/candidates.expected" "$tmp/out"; then
  fail "candidates with both fixtures ignores an unread --main" \
    "output differs from the expected branch list"
fi

# A worktrunk that cannot read the repository: its worktree rows are lost, but
# git's branches still come through -- and the partial list says so, naming the
# directory, because a branch missing from it is one the picker would offer to
# create rather than switch to.
mkdir -p "$tmp/bad-wt"
cat >"$tmp/bad-wt/wt" <<'EOF'
#!/bin/sh
printf 'wt: not a worktrunk repository\n' >&2
exit 1
EOF
chmod +x "$tmp/bad-wt/wt"
ran=$((ran + 1))
PATH="$tmp/bad-wt:$PATH" ./new-work.sh candidates --main "$tmp/repo" \
  >"$tmp/out" 2>"$tmp/err"
status=$?
if [ "$status" -ne 0 ]; then
  fail "a failed wt list still lists git's branches" "exit $status: $(cat "$tmp/err")"
elif ! grep -qx 'feat/real-one' "$tmp/out"; then
  fail "a failed wt list still lists git's branches" "output: $(cat "$tmp/out")"
elif ! grep -qF "could not read the worktrees of $tmp/repo" "$tmp/err"; then
  fail "a failed wt list is said out loud" "stderr: $(cat "$tmp/err")"
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

# The shape most cases start from: a clone of origin/main, whose jj knows the
# remote-tracking bookmark, jj's own mirror of it, and the bare local form that
# every bookmark also has. The last two are what the cycle must never offer.
run_bases 'the default branch on origin opens the cycle' \
  $'main@origin\n@\nmain\nmaster' \
  --base-bookmarks test/fixtures/bookmarks.txt --origin-head origin/main

# origin/HEAD is the branch this clone says it tracks, so it is asked before any
# fixed name -- and the answer is that branch on origin, in jj's vocabulary: the
# branch name and the remote it lives on, as one revision.
bookmarks_file "$tmp/bookmarks.develop" develop@ develop@ origin@
run_bases 'origin/HEAD decides the opening answer' \
  $'develop@origin\n@\nmain\nmaster' \
  --base-bookmarks "$tmp/bookmarks.develop" --origin-head origin/develop

# With no origin/HEAD named -- a clone that has none, or a run standing in for
# one -- the fixed names speak, in the order they always have.
bookmarks_file "$tmp/bookmarks.main" main@ main@origin
run_bases 'main@origin opens the cycle when there is no origin/HEAD' \
  $'main@origin\n@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.main"

bookmarks_file "$tmp/bookmarks.master" master@ master@origin
run_bases 'master@origin opens it when there is no main on origin' \
  $'master@origin\n@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.master"

# Nothing on origin at all -- a bookmark only this machine has, or none -- leaves
# @ to open: the working copy is always a revision to start from.
bookmarks_file "$tmp/bookmarks.local-only" main@
run_bases 'a bookmark no remote has opens the cycle on @' \
  $'@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.local-only"

: >"$tmp/bookmarks.none"
run_bases 'no bookmarks at all still offers @, main and master' \
  $'@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.none"

# The two renderings jj adds around the bookmarks a person cares about: `<name>@`
# for a bookmark no remote has, and `<name>@git` for jj's own mirror of the
# remote-tracking refs. Neither is somewhere a new workspace can be started
# from, so neither is ever a row.
bookmarks_file "$tmp/bookmarks.git-only" main@git
run_bases 'a @git mirror is no base at all' \
  $'@\nmain\nmaster' --base-bookmarks "$tmp/bookmarks.git-only"

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
  $'main@origin\n@\nmain\nmaster' \
  --base-bookmarks test/fixtures/bookmarks.txt --base main@origin
run_bases 'an --base that resolves to nothing is still the answer' \
  $'refresh\n@\nmain\nmaster' \
  --base-bookmarks test/fixtures/bookmarks.txt --base refresh

# The configured default is @, and the cycle offers @ once: an opening answer is
# a row like any other, not a second copy of one.
run_bases '--base @ is the opening answer and appears once' \
  $'@\nmain\nmaster' --base-bookmarks test/fixtures/bookmarks.txt --base '@'

# --no-base is "no revision at all": an empty first line, then the same cycle,
# because ctrl-r still moves off it.
run_bases '--no-base opens on an empty line' \
  $'\n@\nmain\nmaster' --base-bookmarks test/fixtures/bookmarks.txt --no-base

# --base-bookmarks is the whole source, so --main is never opened -- and a
# directory that is not there therefore costs nothing. The mirror of the
# candidates case.
run_bases '--base-bookmarks is read instead of --main' \
  $'main@origin\n@\nmain\nmaster' \
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
printf 'main@\nmain@git\nmain@origin\n'
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

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
