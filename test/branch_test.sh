#!/usr/bin/env bash
# `new-work.sh branch-default`, `new-work.sh candidates` and `new-work.sh bases`.
#
# branch-default turns a bead's issue_type and id into the branch name the
# picker offers; candidates collects the branch names that already exist so the
# picker can offer them too. bases resolves the ref a new branch starts from and
# the short cycle of bases around it. All three run without fzf.
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

# The refs of a pretend repository, as bases reads them: exactly what
#
#   git for-each-ref --format='%(refname)%00%(symref)' refs/remotes refs/heads
#
# prints, one record per line -- the refname, a NUL, then that ref's symref
# target, empty for everything but origin/HEAD. Arguments come in pairs, the
# refname then the symref.
base_refs_file() {
  local file=$1
  shift
  : >"$file"
  while [ $# -gt 0 ]; do
    printf '%s\0%s\n' "$1" "$2" >>"$file"
    shift 2
  done
}

# bases <case name> <expected stdout> [args...]
#
# The whole of stdout is compared, so a row gained or lost fails the case. A
# command substitution drops the closing newline, so each expectation ends with
# the last row's two fields, and %q prints the tabs it holds as \t.
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

# The shape most cases start from: a clone of origin/main with both of the local
# branches the cycle's tail offers.
base_refs_file "$tmp/refs.base" \
  refs/remotes/origin/main '' refs/heads/main '' refs/heads/master ''

# origin/HEAD is the clone's own idea of the branch it tracks, so it is asked
# before any fixed name.
base_refs_file "$tmp/refs.head" \
  refs/remotes/origin/HEAD refs/remotes/origin/trunk \
  refs/remotes/origin/trunk '' refs/heads/main '' refs/heads/master ''
run_bases 'origin/HEAD decides the opening answer' \
  $'origin/trunk\torigin\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.head"

# A symref written straight at a local branch is no base this clone tracks, so
# it is a miss like any other and the fixed chain speaks: a full refname would
# otherwise reach `wt switch --base` as a literal word.
base_refs_file "$tmp/refs.head-local" \
  refs/remotes/origin/HEAD refs/heads/main \
  refs/remotes/origin/main '' refs/heads/main '' refs/heads/master ''
run_bases 'an origin/HEAD pointing out of refs/remotes falls back to the chain' \
  $'origin/main\torigin\n@\t\nmain\t\nmaster\t' \
  --base-refs "$tmp/refs.head-local"

# The target the symref names can be gone from the dump -- a branch deleted
# upstream -- and then no record says which remote it lives on. The name still
# says it, and the tab still has something to fetch.
base_refs_file "$tmp/refs.head-gone" \
  refs/remotes/origin/HEAD refs/remotes/origin/trunk refs/heads/main ''
run_bases 'a dangling origin/HEAD still knows its remote' \
  $'origin/trunk\torigin\n@\t\nmain\t' --base-refs "$tmp/refs.head-gone"

# Without origin/HEAD the order is origin/main, origin/master, main, master.
base_refs_file "$tmp/refs.origin-main" \
  refs/remotes/origin/master '' refs/remotes/origin/main '' \
  refs/heads/main '' refs/heads/master ''
run_bases 'origin/main comes before origin/master' \
  $'origin/main\torigin\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.origin-main"

base_refs_file "$tmp/refs.origin-master" \
  refs/remotes/origin/master '' refs/heads/main '' refs/heads/master ''
run_bases 'origin/master is the opening answer when there is no origin/main' \
  $'origin/master\torigin\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.origin-master"

# A clone with no remotes at all: the last two fixed names are the local main
# and master, and the cycle does not repeat the one it opened on.
base_refs_file "$tmp/refs.local-main" refs/heads/main '' refs/heads/master ''
run_bases 'a local main opens the cycle when the clone has no remotes' \
  $'main\t\n@\t\nmaster\t' --base-refs "$tmp/refs.local-main"

base_refs_file "$tmp/refs.local-master" refs/heads/master ''
run_bases 'a local master opens it when there is no main at all' \
  $'master\t\n@\t' --base-refs "$tmp/refs.local-master"

# The candidates are compared as whole refnames, so a branch that merely looks
# like main -- or sits under it -- leaves nothing resolvable and @ opens.
base_refs_file "$tmp/refs.maint" refs/heads/maint ''
run_bases 'a local maint is not the main entry' \
  $'@\t' --base-refs "$tmp/refs.maint"

base_refs_file "$tmp/refs.topic" refs/heads/main/topic ''
run_bases 'refs/heads/main/topic is not main' \
  $'@\t' --base-refs "$tmp/refs.topic"

base_refs_file "$tmp/refs.none"
run_bases 'no refs at all opens on @, and @ is the whole cycle' \
  $'@\t' --base-refs "$tmp/refs.none"

# A configured base is the opening answer whatever it names, and the remote it
# carries comes from the ref record -- upstream/main is on upstream, not origin.
base_refs_file "$tmp/refs.upstream" \
  refs/remotes/upstream/main '' refs/heads/main '' refs/heads/master ''
run_bases '--base is the opening answer, on its own remote' \
  $'upstream/main\tupstream\n@\t\nmain\t\nmaster\t' \
  --base-refs "$tmp/refs.upstream" --base upstream/main

# A slash is not what makes a ref remote-tracking: feat/x is a local branch and
# carries no remote, so the tab does not try to fetch it.
base_refs_file "$tmp/refs.feat" refs/heads/feat/x '' refs/heads/main '' refs/heads/master ''
run_bases 'a local branch keeps an empty remote, slash or no slash' \
  $'feat/x\t\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.feat" --base feat/x

# --base can also be the refname it really is. Every row here speaks the short
# name, and a base left whole matches no ref record: it would read as local and
# the tab would skip the fetch it needs.
run_bases 'a full refname --base resolves to its short name and remote' \
  $'origin/main\torigin\n@\t\nmain\t\nmaster\t' \
  --base-refs "$tmp/refs.base" --base refs/remotes/origin/main
run_bases 'a refs/heads --base resolves to the local branch' \
  $'main\t\n@\t\nmaster\t' --base-refs "$tmp/refs.base" --base refs/heads/main

# ... and a local name stays local even when a remote has a branch of the same
# name: what makes a base remote-tracking is its ref record, not a name a remote
# happens to share, so nothing is fetched.
base_refs_file "$tmp/refs.feat-shared" \
  refs/remotes/origin/feat/x '' refs/heads/feat/x '' refs/heads/main ''
run_bases 'a local --base a remote also has stays local' \
  $'feat/x\t\n@\t\nmain\t' --base-refs "$tmp/refs.feat-shared" --base feat/x

# A base this clone has not fetched, or has just deleted, is still the answer:
# the picker does not get to refuse it, and main and master are still offered.
run_bases 'an --base that resolves to nothing is still the answer' \
  $'refresh\t\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.base" --base refresh

# --no-base is the wt default sentinel: an empty ref field, then the same
# cycle, because ctrl-r still moves off it.
run_bases '--no-base opens on an empty ref' \
  $'\t\n@\t\nmain\t\nmaster\t' --base-refs "$tmp/refs.base" --no-base

# --base-refs is the whole source, so --main is never opened -- and a directory
# that is not there therefore costs nothing. The mirror of the candidates case.
run_bases '--base-refs is read instead of --main' \
  $'origin/main\torigin\n@\t\nmain\t\nmaster\t' \
  --main "$tmp/nowhere" --base-refs "$tmp/refs.base"

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

bases_dies 'an unreadable --base-refs' \
  "bases: could not read the refs of $tmp/no-such-refs" \
  --base-refs "$tmp/no-such-refs"
bases_dies 'a --main that is not there' \
  "bases: no such directory: $tmp/nowhere" --main "$tmp/nowhere"
bases_refuses 'neither --main nor --base-refs' \
  'bases: need --main DIR (or --base-refs FILE)'
bases_refuses '--base with --no-base' \
  'bases: --base and --no-base answer the same question' \
  --base-refs "$tmp/refs.base" --base refresh --no-base

# Reading the refs out of a real repository: --main with no fixture. Its one
# branch is trunk, which is none of the names the chain knows.
ran=$((ran + 1))
git init -q "$tmp/base-repo" && git -C "$tmp/base-repo" -c user.email=t@example.com \
  -c user.name=t commit -q --allow-empty -m init &&
  git -C "$tmp/base-repo" branch -m trunk
printf '@\t\n' >"$tmp/base.expected"
./new-work.sh bases --main "$tmp/base-repo" >"$tmp/out" 2>"$tmp/err"
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
