#!/usr/bin/env bash
# `new-work.sh branch-default` and `new-work.sh candidates`.
#
# branch-default turns a bead's issue_type and id into the branch name the
# picker offers; candidates collects the branch names that already exist so the
# picker can offer them too. Both run without fzf.
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

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
