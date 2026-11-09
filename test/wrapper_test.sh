#!/usr/bin/env bash
# The tab's command: the fish wrapper init.lua hands to Rex.
#
# The wrapper exists so the pane outlives the agent: `jws` switches to, attaches
# or creates the workspace -- one program for all three modes -- the agent runs
# in it, and a login shell stays behind, in the workspace, with everything printed
# above it still readable. It is run here for real -- with a stand-in `jws`, a
# stand-in agent, and a stand-in SHELL -- because what matters is shell
# behaviour: which directory the agent and the shell end up in, which words reach
# `jws`, that a failed or pathless jws never starts the agent, and that the
# answer (a branch, a prompt) is data and not program text.
#
# Neither `wt` nor `jq` has any part in a run, and that is asserted rather than
# assumed: two decoys on the run's function path name themselves in a marker if
# anything calls them, and the script text itself names neither.
#
# The program under test is taken out of the argv the module builds, so this
# file runs exactly the string Rex hands to `fish -c`.
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

# The wrapper, as the tab gets it: element 3 of new_tab_argv is the program that
# follows `fish -c`, and the rest of that argv is what a run below supplies.
ran=$((ran + 1))
script=$(init="$PWD/init.lua" lua -e '
  local M = dofile(os.getenv("init"))
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch" })
  io.write(argv[3] or "")
' 2>"$tmp/lua-err")
if [ -z "$script" ]; then
  fail "the tab's command is a fish program" \
    "init.lua gave nothing for argv[3]: $(cat "$tmp/lua-err")"
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

# The tab has to run this program through fish, and the run below has to prove
# it: a shell that was not fish would pass a wrapper that fish cannot parse. The
# two words that name it come from the module for the same reason the program
# does.
ran=$((ran + 1))
runner=$(init="$PWD/init.lua" lua -e '
  local M = dofile(os.getenv("init"))
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch" })
  io.write(tostring(argv[1]) .. " " .. tostring(argv[2]) .. "\n")
')
if [ "$runner" != "fish -c" ]; then
  fail "the tab is handed to fish -c" "the argv starts with: $runner"
fi

# fish, resolved here because a run may take the whole PATH away: the wrapper
# still has to be fish, whatever else the run hides.
ran=$((ran + 1))
fish_bin=$(command -v fish 2>/dev/null)
if [ -z "$fish_bin" ]; then
  fail "fish is installed" "the wrapper is a fish program and fish is not on the PATH"
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

# The wrapper has to be fish, not just something fish can survive: this is the
# parse check, and the runs below would fail much later and less clearly.
ran=$((ran + 1))
printf '%s\n' "$script" >"$tmp/script.fish"
if ! "$fish_bin" -n "$tmp/script.fish"; then
  fail "the wrapper is fish" "fish could not parse it"
fi

# Neither worktrunk nor jq is named anywhere in the program: the path comes out
# of a file, and jws is the one tool that knows about workspaces. A grep says
# that about the text, which the decoys below cannot -- they catch a call, not a
# `command wt` that a PATH would answer instead of them.
ran=$((ran + 1))
if grep -nE '(^|[^[:alnum:]_-])(wt|jq)([^[:alnum:]_-]|$)' "$tmp/script.fish"; then
  fail "the wrapper names neither wt nor jq" \
    "the script contains the lines above"
fi

bin=$tmp/bin
worktree=$tmp/worktree
start=$tmp/start
# The main workspace of the project under test, which is where the real jws cd's
# before it does anything, and where a create that fails leaves the shell.
main=$tmp/main
mkdir -p "$bin" "$worktree" "$start" "$main" "$tmp/functions"

# jws, stood in for: it records the words it was given and the guard it
# inherited, writes the path into whatever file --path-file names, and exits 0 or
# 1 the way the real function does. It is a fish *function*, found through
# fish_function_path, because that is how the real jws reaches the tab: a program
# on the PATH would prove a different thing.
cat >"$tmp/functions/jws.fish" <<'EOF'
function jws
    printf '%s\n' $argv >$JWS_WORDS
    # Every record is optional here too, and the guard the wrapper exported is
    # one of them: a create or an attach runs the hooks jws runs, so it has to
    # inherit it.
    set -l env_file /dev/null
    set -q JWS_ENV; and set env_file $JWS_ENV
    if set -q GIT_TERMINAL_PROMPT
        printf 'GIT_TERMINAL_PROMPT=%s\n' "$GIT_TERMINAL_PROMPT" >$env_file
    else
        printf 'GIT_TERMINAL_PROMPT=unset\n' >$env_file
    end
    set -l pf
    set -l i 0
    while test $i -lt (count $argv)
        set i (math $i + 1)
        if test "$argv[$i]" = --path-file
            set pf $argv[(math $i + 1)]
        end
    end
    # The real jws walks up to the wrapper and cds into <wrapper>/main before it
    # runs `jj workspace add`, and a fish function's cd stays put when it
    # returns: so a create or an attach that fails has already moved the caller.
    # A case below asserts where that leaves the shell, and a stand-in that never
    # moved would pass for a reason production does not have. --existing is the
    # exception and is stood in for as the exception: it reads jj's rows where it
    # stands, creates nothing and changes no directory before it answers, so a
    # switch that fails leaves the tab's own directory alone. `builtin` because a
    # user's cd is very often a jumper that lands nowhere -- which is also why the
    # wrapper itself has to say `builtin cd`.
    if not contains -- --existing $argv
        if set -q JWS_CD; and test "$JWS_CD" != 0; and test -d "$JWS_MAIN"
            builtin cd $JWS_MAIN
        end
    end
    if test "$JWS_FAIL" = 1
        echo "jws: the stand-in was asked to fail" >&2
        return 1
    end
    # JWS_WRITE=0 is a jws that says it worked and leaves the path file empty:
    # the caller has no path, which is the failure this wrapper has to catch.
    if test "$JWS_WRITE" != 0; and test -n "$pf"
        printf '%s\n' $JWS_PATH >$pf
        # JWS_EXTRA is a second line in the same file -- a jws that said more
        # than the one path. The tab reads the first line and must not move.
        set -q JWS_EXTRA; and test -n "$JWS_EXTRA"; and printf '%s\n' $JWS_EXTRA >>$pf
    end
    echo "jws: $JWS_PATH ready"
end
EOF

# The user's own fish functions are standing in the run's function path, so the
# run cannot see them -- and a wrapper that quietly called one of them would
# look perfect here and fail on a real machine. Two are planted in their place,
# both taken from this machine: `rm` is a `trash` wrapper that rejects -f and
# leaves the file, and `cd` is a directory jumper that changes nothing. A
# wrapper that used either would print on every create and land nowhere.
cat >"$tmp/functions/rm.fish" <<'EOF'
function rm --wraps=trash
    printf '# Un-recognized argument %s at index 1\n' "$argv[1]" >&2
    return 1
end
EOF

cat >"$tmp/functions/cd.fish" <<'EOF'
function cd --description 'alias cd=ze'
    printf 'cd: the jumper took %s\n' "$argv[1]" >&2
    return 0
end
EOF

# worktrunk and jq, stood in for as DECOYS and not as programs to drive: the
# wrapper names neither any more, since jws is the one workspace tool it calls
# and the path comes out of a file rather than out of a JSON reply. A decoy
# records the words it was given and exits 99, so a wrapper that reached for
# either is caught by the marker it left rather than by whatever the real
# program would have done.
#
# Fish functions and not programs on the PATH, for the same reason jws is: this
# machine's fish start-up files put the real worktrunk and the real jq in front
# of anything a caller hands over, so only a function in fish_function_path is
# sure to be the one called.
cat >"$tmp/functions/wt.fish" <<'EOF'
function wt
    printf '%s\n' $argv >>"$WT_WORDS"
    printf 'the wrapper called wt %s\n' "$argv" >&2
    return 99
end
EOF

cat >"$tmp/functions/jq.fish" <<'EOF'
function jq
    printf '%s\n' $argv >>"$JQ_WORDS"
    printf 'the wrapper called jq %s\n' "$argv" >&2
    return 99
end
EOF

# git, stood in for: nothing in the wrapper runs it any more -- the fetch a new
# branch needs belongs to jws -- so the marker it leaves is how "never" is told
# apart from "ran and did nothing".
cat >"$tmp/functions/git.fish" <<'EOF'
function git
    printf '%s\n' "$argv" >>"$GIT_CALLS"
end
EOF

# The agent, stood in for: it says where it is and what it was given, which is
# all this test needs from it.
cat >"$bin/agent" <<'EOF'
#!/bin/sh
printf 'agent pwd: %s\n' "$PWD"
for arg in "$@"; do printf 'agent arg: %s\n' "$arg"; done
EOF

# The login shell the wrapper leaves behind, stood in for by one that says where
# it started and exits: the directory is the point, not the prompt.
cat >"$tmp/shell" <<'EOF'
#!/bin/sh
printf 'shell pwd: %s\n' "$PWD"
printf 'shell args: %s\n' "$*"
EOF

# An agent that keeps running until it is killed, the way a ^C ends a busy agent.
cat >"$bin/agent-killed" <<'EOF'
#!/bin/sh
: >"$READY"
sleep 30
EOF

# An agent that catches the ^C itself and leaves cleanly afterwards. It records
# that the signal reached it, so a wrapper that kept the signal to itself would
# be caught by that as well as by the missing shell.
cat >"$bin/agent-trapping" <<'EOF'
#!/bin/sh
trap ': >"$GOT_INT"; exit 0' INT
: >"$READY"
while :; do sleep 0.1; done
EOF

chmod +x "$bin/agent" "$bin/agent-killed" "$bin/agent-trapping" "$tmp/shell"

# mktemp, stood in for so one case can make it fail: the tab names its path
# file with one, and with no name at all the `head` that reads that file would
# read the pane's stdin instead. It passes through unless MKTEMP_FAIL=1.
real_mktemp=$(command -v mktemp)
cat >"$bin/mktemp" <<EOF
#!/bin/sh
if [ "\${MKTEMP_FAIL:-0}" = 1 ]; then
  echo 'mktemp: failed to create file' >&2
  exit 1
fi
exec "$real_mktemp" "\$@"
EOF
chmod +x "$bin/mktemp"

# Run the wrapper the way Rex runs the tab: as an argv with no shell in between,
# the tab's own directory as cwd, and the answer under test as its parameters --
# the three positional words (mode, branch, base) and then the agent, its
# arguments and the prompt. TEST_SHELL replaces the stand-in shell or
# UNSET_SHELL takes SHELL away, JWS_PATH, JWS_FAIL and JWS_WRITE choose what the
# stand-in jws does and the path it reports, JWS_CD=0 keeps it from moving the
# shell, JWS_MAIN is where it moves to, JWS_EXTRA is a second line for the path
# file, MKTEMP_FAIL=1 makes the tab's own mktemp fail, and STDIN_FROM is what
# the pane's stdin is (a file of commands, for a fallback sh that is not a
# stub). The stand-ins' records are cleared first, so an assertion that
# something never ran reads that run alone.
# Sets $status and leaves stdout in $tmp/out, stderr in $tmp/err.
run_wrapper() {
  local mode=$1 branch=$2 base=$3
  shift 3
  rm -f "$tmp/jws-words" "$tmp/jws-env" "$tmp/wt-words" "$tmp/jq-words" \
    "$tmp/git-calls"
  (
    cd "$start" || exit 1
    PATH=$bin:$PATH
    if [ "${UNSET_SHELL:-0}" = 1 ]; then
      unset SHELL
    else
      SHELL=${TEST_SHELL:-$tmp/shell}
      export SHELL
    fi
    # The stand-ins for jws, wt, jq and git are functions, so fish has to be
    # told where functions live; the agents and the shell are programs, reached
    # through PATH.
    fish_function_path=$tmp/functions
    WT_WORDS=$tmp/wt-words JQ_WORDS=$tmp/jq-words GIT_CALLS=$tmp/git-calls
    JWS_WORDS=$tmp/jws-words JWS_PATH=${JWS_PATH:-$worktree}
    JWS_ENV=$tmp/jws-env JWS_MAIN=${JWS_MAIN:-$main} JWS_CD=${JWS_CD:-1}
    JWS_FAIL=${JWS_FAIL:-0} JWS_WRITE=${JWS_WRITE:-1} JWS_EXTRA=${JWS_EXTRA:-}
    export PATH fish_function_path WT_WORDS JQ_WORDS GIT_CALLS
    export JWS_WORDS JWS_PATH JWS_ENV JWS_MAIN JWS_CD JWS_FAIL JWS_WRITE
    export JWS_EXTRA
    "$fish_bin" -c "$script" "$mode" "$branch" "$base" "$@"
  ) >"$tmp/out" 2>"$tmp/err" <"${STDIN_FROM:-/dev/null}"
  status=$?
}

# No wt, no jq: the decoys on the function path exit 99 and record the words they
# were given, so an absent marker is the proof that the run just made never
# reached for either. It is called after a run of each mode, because "the
# wrapper names neither" is a claim about the whole program and not about one
# branch of it. The record is cleared by each run, so this reads that run alone.
assert_no_wt_no_jq() {
  local what=$1
  ran=$((ran + 1))
  if [ -e "$tmp/wt-words" ]; then
    fail "a $what run never calls wt" "wt was given: $(cat "$tmp/wt-words")"
  fi
  ran=$((ran + 1))
  if [ -e "$tmp/jq-words" ]; then
    fail "a $what run never calls jq" "jq was given: $(cat "$tmp/jq-words")"
  fi
}

# A create run: jws is asked to make the workspace from the base and to write its
# path into a file, the agent runs in the workspace it made, and a login shell is
# left there -- with nothing on stderr, which is what a wrapper that called one
# of the user's own fish functions (`rm` is a `trash` wrapper here, `cd` a
# jumper) would fail: an error-looking line on every create.
ran=$((ran + 1))
run_wrapper create feat/x1 @ agent "/brainstorming for bead p-1"
if [ "$status" -ne 0 ] || [ -s "$tmp/err" ]; then
  fail "a create run finishes without saying anything" \
    "exit $status: stderr: $(cat "$tmp/err")"
fi

# The words, the file they name, and nothing else: the base is passed verbatim,
# the path file is one this wrapper made rather than something it composed from
# the branch, and an extra word would be an argument the real jws would refuse.
ran=$((ran + 1))
if [ "$(wc -l <"$tmp/jws-words" | tr -d ' ')" != 4 ] \
  || [ "$(sed -n 1p "$tmp/jws-words")" != "feat/x1" ] \
  || [ "$(sed -n 2p "$tmp/jws-words")" != "@" ] \
  || [ "$(sed -n 3p "$tmp/jws-words")" != "--path-file" ] \
  || [ -z "$(sed -n 4p "$tmp/jws-words")" ]; then
  fail "a create calls jws with the branch, the base and a path file" \
    "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

# The guard reaches jws as well as the switch: a create runs the project's
# post-start hooks, and a hook that talks to git must not stop on a credential
# prompt either.
ran=$((ran + 1))
if ! grep -qx 'GIT_TERMINAL_PROMPT=0' "$tmp/jws-env"; then
  fail "jws runs with GIT_TERMINAL_PROMPT=0" "recorded: $(cat "$tmp/jws-env" 2>/dev/null)"
fi

ran=$((ran + 1))
path_file=$(sed -n 4p "$tmp/jws-words" 2>/dev/null)
case $path_file in
  /*) : ;;
  *)
    fail "the path file is a file of its own, named absolutely" \
      "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
    ;;
esac

# The path file is this run's litter and nobody else's: the path is read out of
# it, and a create per tab would otherwise leave one behind in /tmp each time.
ran=$((ran + 1))
if [ -n "$path_file" ] && [ -e "$path_file" ]; then
  fail "the path file is cleaned up" "left behind: $path_file"
fi

# The fetch a new branch needs is jws's: it fetches the revision before the
# workspace is made. Nothing here runs git, and the marker is how "nothing" is
# told apart from "ran and did nothing".
ran=$((ran + 1))
if [ -e "$tmp/git-calls" ]; then
  fail "a create does not fetch: the fetch is jws's" \
    "git was given: $(cat "$tmp/git-calls")"
fi

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out"; then
  fail "the agent runs in the workspace jws named" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF "agent arg: /brainstorming for bead p-1" "$tmp/out"; then
  fail "the prompt arrives as one argument" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "the shell lands in the workspace" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell args: -l" "$tmp/out"; then
  fail "the shell is a login shell" "output: $(cat "$tmp/out")"
fi

# And no wt, no jq: a create is jws's work alone now, and the decoys would have
# left their words behind if the wrapper had reached for either.
assert_no_wt_no_jq create

# Creating with no base named: jws's own default (main), so the parameter is
# empty and no base word is sent -- an empty word would be a revision jj has no
# name for.
ran=$((ran + 1))
run_wrapper create feat/x1 "" agent "p"
printf 'feat/x1\n--path-file\n%s\n' "$(sed -n 3p "$tmp/jws-words")" >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/jws-words"; then
  fail "a create with an empty base sends jws no base word" \
    "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

# The base and the credential guard -----------------------------------------
#
# A create that names a real revision: jws receives it as itself, one word, so a
# revision with a slash in it is neither a glob nor two arguments. The fetch it
# buys from the remote is jws's business -- the wrapper reads the revision it is
# handed and never derives a remote from its shape.
ran=$((ran + 1))
run_wrapper create feat/x1 origin/main agent "/brainstorming"
if [ "$(sed -n 2p "$tmp/jws-words")" != "origin/main" ]; then
  fail "the base reaches jws verbatim" "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

# An invisible credential prompt is the hang GIT_TERMINAL_PROMPT=0 exists to
# prevent, and it is exported before any mode runs, so a switch's jws and the
# jj it runs inherit it too -- the guard belongs to the pane, not to a mode.
ran=$((ran + 1))
run_wrapper switch feat/x1 origin/main agent "/brainstorming"
if ! grep -qx 'GIT_TERMINAL_PROMPT=0' "$tmp/jws-env"; then
  fail "a switch's jws runs with GIT_TERMINAL_PROMPT=0" \
    "recorded: $(cat "$tmp/jws-env" 2>/dev/null)"
fi

# A create that fails: jws has said why on stderr, the agent is not started at
# all -- never in the wrong directory -- and the shell still opens, so the pane is
# usable rather than dead. The directory it opens in is jws's own last one: the
# real function cds into the project's main workspace before it runs `jj workspace
# add`, and a fish function's cd stays put when it returns, so a create that
# failed has already moved the caller there. That is the tab's own directory in
# production, which is why nothing is done about it -- but the assertion is that
# directory, not "somewhere".
ran=$((ran + 1))
JWS_FAIL=1 run_wrapper create feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a failing jws starts nothing and leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a failing jws never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $main" "$tmp/out"; then
  fail "after a failing jws the shell is in the workspace jws moved it to" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: jws feat/x1 failed (exit 1); not starting agent' "$tmp/err"; then
  fail "a failing jws names the branch, the exit status and what is not started" \
    "stderr: $(cat "$tmp/err")"
fi

# jws said it worked and the path file is empty -- the workspace is there and
# nothing tells the wrapper where: the agent must not start in the wrong place,
# and the line names the step that lost the path rather than the create. The
# shell opens in the workspace jws moved to, exactly as after a failed create.
ran=$((ran + 1))
JWS_WRITE=0 run_wrapper create feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $main" "$tmp/out"; then
  fail "a create whose path file was never written starts nothing" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "an unreadable path file never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: could not read the workspace path of feat/x1 from the jws path file; not starting agent' \
  "$tmp/err"; then
  fail "an unreadable path file names the branch and the file" "stderr: $(cat "$tmp/err")"
fi

# An existing workspace: jws's --existing, one word in front of the branch, and
# no base word even though the base here is non-empty. --existing switches to a
# workspace jj already lists: it creates nothing, runs no dojjo hooks and takes
# no revision, and a base word beside it would be one the real jws refuses
# outright -- which is why the base is non-empty in this case.
ran=$((ran + 1))
run_wrapper switch feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "an existing-workspace run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf -- '--existing\nfeat/x1\n--path-file\n%s\n' \
  "$(sed -n 4p "$tmp/jws-words" 2>/dev/null)" >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/jws-words"; then
  fail "a switch is jws --existing, with a path file and no base word" \
    "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

# The path file is the same litter whichever mode made it: named by the
# wrapper, read once, removed.
ran=$((ran + 1))
switch_path_file=$(sed -n 4p "$tmp/jws-words" 2>/dev/null)
case $switch_path_file in
  /*) : ;;
  *)
    fail "a switch names a path file of its own, absolutely" \
      "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
    ;;
esac

ran=$((ran + 1))
if [ -n "$switch_path_file" ] && [ -e "$switch_path_file" ]; then
  fail "a switch's path file is cleaned up" "left behind: $switch_path_file"
fi

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out" \
  || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a switch starts the agent and leaves the shell in the workspace jws named" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# And no wt, no jq: the one mode that used to run worktrunk now runs jws like
# the other two, and the decoys would have left their words behind if it had not.
assert_no_wt_no_jq switch

# A local branch with no workspace yet: jws's attach, which makes the workspace
# without creating the branch. It is the second thing jws is asked to do, so it
# is the second set of words pinned -- and it is given no base word, even with
# one handed to the wrapper: the branch exists, so there is nothing to create it
# from, and a revision word would be an argument the real jws reads as the base
# of a branch it was told not to make. The base is non-empty here precisely so
# that a wrapper which passed it on would fail this case.
ran=$((ran + 1))
run_wrapper attach feat/x1 origin/main agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "an attach run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf -- '--attach\nfeat/x1\n--path-file\n%s\n' "$(sed -n 4p "$tmp/jws-words" 2>/dev/null)" >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/jws-words"; then
  fail "an attach never sends a base word" \
    "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

ran=$((ran + 1))
attach_path_file=$(sed -n 4p "$tmp/jws-words" 2>/dev/null)
case $attach_path_file in
  /*) : ;;
  *)
    fail "an attach names a path file of its own, absolutely" \
      "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
    ;;
esac

ran=$((ran + 1))
if [ -n "$attach_path_file" ] && [ -e "$attach_path_file" ]; then
  fail "an attach's path file is cleaned up" "left behind: $attach_path_file"
fi

# And no wt, no jq: the decoys would have left their words behind if the attach
# run above had reached for either.
assert_no_wt_no_jq attach

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out" \
  || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "an attach starts the agent and leaves the shell in the workspace jws named" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# An attach that fails is the same failure a create's is: jws said why on this
# pane, nothing is started in a directory nobody named, and the shell still
# opens so the pane is usable -- in the workspace jws moved to, since an attach
# cds into main before it makes the workspace exactly as a create does.
ran=$((ran + 1))
JWS_FAIL=1 run_wrapper attach feat/x1 origin/main agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a failing attach still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a failing attach never starts the agent" "output: $(cat "$tmp/out")"
fi
ran=$((ran + 1))
if ! grep -qx "shell pwd: $main" "$tmp/out"; then
  fail "after a failing attach the shell is in the workspace jws moved to" \
    "output: $(cat "$tmp/out")"
fi
ran=$((ran + 1))
if ! grep -qxF 'rex-config: jws feat/x1 failed (exit 1); not starting agent' "$tmp/err"; then
  fail "a failing attach names jws, its exit status and what is not started" \
    "stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if ! grep -qx 'GIT_TERMINAL_PROMPT=0' "$tmp/jws-env"; then
  fail "an attach's jws runs with GIT_TERMINAL_PROMPT=0" \
    "recorded: $(cat "$tmp/jws-env" 2>/dev/null)"
fi

# A first word that is none of the three: a caller that does not know the
# contract is refused with the same line too few words get, before any program
# is run -- and the pane still ends in a shell rather than dying.
ran=$((ran + 1))
run_wrapper attachh feat/x1 origin/main agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "an unknown mode still leaves a shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/jws-words" ] || [ -e "$tmp/wt-words" ] || [ -e "$tmp/jq-words" ]; then
  fail "an unknown mode runs nothing" \
    "jws: $(cat "$tmp/jws-words" 2>/dev/null) wt: $(cat "$tmp/wt-words" 2>/dev/null) jq: $(cat "$tmp/jq-words" 2>/dev/null)"
fi
ran=$((ran + 1))
if ! grep -qxF 'rex-config: the tab needs a mode, a branch and a base' "$tmp/err"; then
  fail "an unknown mode names the contract" "stderr: $(cat "$tmp/err")"
fi

# A switch that fails: jws has said why on stderr (or said nothing at all -- the
# wrapper does not assume which), the agent is not started, and the shell still
# opens in the tab's directory. That last one is what --existing buys: it is the
# one mode that changes no directory before it answers, which the stand-in keeps,
# so the assertion is the tab's own directory and not merely "somewhere".
ran=$((ran + 1))
JWS_FAIL=1 run_wrapper switch nope/nothing @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a failed switch still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a failed switch never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "after a failed switch the shell stays in the tab's directory" \
    "output: $(cat "$tmp/out")"
fi

# The switch failed, so the message names the switch as the step that went wrong
# -- not a general "no path": the path-reading half has its own wording,
# asserted below.
ran=$((ran + 1))
if ! grep -qxF 'rex-config: jws nope/nothing failed (exit 1); not starting agent' "$tmp/err"; then
  fail "a failed switch names jws, its exit status and what is not started" "stderr: $(cat "$tmp/err")"
fi
# The switch itself worked and wrote a path file -- but the file is empty, which
# is what a jws that could not name the workspace leaves behind. Nothing tells the
# wrapper which workspace was switched to, so the agent is not started, the shell
# opens in the tab's directory, and the message names the file rather than
# reporting a bare "exit 0" -- which would send a reader looking for a switch
# that never failed.
ran=$((ran + 1))
JWS_WRITE=0 run_wrapper switch feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a switch whose path file was never written still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a switch whose path file was never written never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "an unreadable path file leaves the shell in the tab's directory" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: could not read the workspace path of feat/x1 from the jws path file; not starting agent' \
  "$tmp/err"; then
  fail "a switch whose path file was empty names the branch and the file" \
    "stderr: $(cat "$tmp/err")"
fi

# And a path file that could not even be named: mktemp failing leaves the tab
# with no file to name, and the `head` that reads it would then read the pane's
# stdin and block there -- no agent, no message, a tab that only looks hung. It
# is refused in one line, before jws is asked anything. XDG_CONFIG_HOME is an
# empty directory for this run because the developer's own config.fish puts
# mise's PATH in front of the shim's, which would hide it behind the real
# mktemp.
mkdir -p "$tmp/xdg"
ran=$((ran + 1))
MKTEMP_FAIL=1 XDG_CONFIG_HOME=$tmp/xdg run_wrapper switch feat/x1 "" agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "a mktemp that fails still leaves a shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if [ -e "$tmp/jws-words" ]; then
  fail "a mktemp that fails runs no jws" "jws was given: $(cat "$tmp/jws-words")"
fi
ran=$((ran + 1))
if ! grep -qxF 'rex-config: could not make a path file for feat/x1; not starting agent' \
  "$tmp/err"; then
  fail "a mktemp that fails says so in one line" "stderr: $(cat "$tmp/err")"
fi

# A workspace path that starts with a dash: fish's `cd` reads it as an option and,
# unlike sh's, takes no `--` to end them, so the wrapper has to hand it over in a
# shape that is a path and not a flag.
ran=$((ran + 1))
mkdir -p "$start/-dash"
JWS_PATH=-dash run_wrapper switch feat/x1 "" agent "/brainstorming"
if ! grep -qx "agent pwd: $start/-dash" "$tmp/out"; then
  fail "a workspace path starting with a dash is entered" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The path file is read for its FIRST line and nothing else. jws writes one
# line, but nothing in the file's shape enforces that, and a path taken from
# the wrong line would run the agent in a directory nobody named -- so a second
# line is planted here and the agent and the shell still land on the first.
ran=$((ran + 1))
JWS_EXTRA=/nonexistent/second run_wrapper switch feat/x1 "" agent "/brainstorming"
if ! grep -qx "agent pwd: $worktree" "$tmp/out" \
  || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a second line in the path file is ignored" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# A path jws reported but the shell cannot enter -- the workspace going away
# between the create and the cd. The agent must not run there either, and the pane
# still gets its shell, in the workspace jws moved to.
ran=$((ran + 1))
JWS_PATH=/nonexistent/nope run_wrapper create feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a workspace that cannot be entered still leaves a shell" \
    "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a workspace that cannot be entered never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -q "could not enter /nonexistent/nope" "$tmp/err" \
  || ! grep -qx "shell pwd: $main" "$tmp/out"; then
  fail "a workspace that cannot be entered is named, and the shell stays put" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# A caller that sends too few parameters: the wrapper cannot know what to create
# from what it was not told, and a broken caller is answered with a shell rather
# than with a directory called "". The message names all three words, so a caller
# that sends two learns about the third.
ran=$((ran + 1))
(
  cd "$start" || exit 1
  SHELL=$tmp/shell PATH=$bin:$PATH fish_function_path=$tmp/functions
  export SHELL PATH fish_function_path
  "$fish_bin" -c "$script" 1 feat/x1
) >"$tmp/out" 2>"$tmp/err" </dev/null
status=$?
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "too few parameters still leave a shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: the tab needs a mode, a branch and a base' "$tmp/err"; then
  fail "too few parameters name all three words" "stderr: $(cat "$tmp/err")"
fi

# $SHELL naming a program that is not installed: exec'ing it would leave the pane
# dead with exit 127, so the plain sh is the fallback. That sh is not a stub, so
# it is given a command on stdin: it reads it once it has started.
ran=$((ran + 1))
cat >"$tmp/fallback" <<'EOF'
printf 'fallback shell pwd: %s\n' "$PWD"
EOF
TEST_SHELL=/nonexistent/shell STDIN_FROM=$tmp/fallback run_wrapper switch feat/x1 "" agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "fallback shell pwd: $worktree" "$tmp/out"; then
  fail "a SHELL that is not installed still leaves a shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# And $SHELL not being set at all is the same answer: there is nothing to exec,
# so the fallback is what keeps the pane alive.
ran=$((ran + 1))
cat >"$tmp/fallback-unset" <<'EOF'
printf 'unset-shell pwd: %s\n' "$PWD"
EOF
UNSET_SHELL=1 STDIN_FROM=$tmp/fallback-unset run_wrapper switch feat/x1 "" agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "unset-shell pwd: $worktree" "$tmp/out"; then
  fail "no \$SHELL still leaves a usable login shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The answer is data: a branch and a prompt full of shell syntax reach jws and
# the agent as themselves, and none of it is executed.
ran=$((ran + 1))
run_wrapper switch 'feat/x$(id);echo pwned' "" agent 'p "quotes" $(id) `id`;echo pwned'
if grep -qxF "agent arg: p \"quotes\" \$(id) \`id\`;echo pwned" "$tmp/out" \
  && [ "$(sed -n 2p "$tmp/jws-words")" = 'feat/x$(id);echo pwned' ] \
  && ! grep -q '^pwned$' "$tmp/out" "$tmp/err"; then
  :
else
  fail "the branch and the prompt are arguments, not program text" \
    "words: $(cat "$tmp/jws-words") output: $(cat "$tmp/out")"
fi

# The words the tab really gets, built by the module rather than written out by
# hand: everything from argv[4] on -- what follows `fish -c SCRIPT` -- one per
# line, so a case can run the argv new_tab_argv produced. An argument that is the
# empty string comes back as an empty line, which is exactly how the wrapper
# needs to receive it.
build_tab_words() {
  init="$PWD/init.lua" want_blank=$1 want_prompt=$2 lua -e '
    local M = dofile(os.getenv("init"))
    local args = { branch = "feat/x1", worktree = "switch", agent = "agent",
      prompt = os.getenv("want_prompt") }
    if os.getenv("want_blank") == "1" then args.blank = true end
    local argv = M.new_tab_argv("proj", args)
    for i = 4, #argv do io.write(argv[i], "\n") end
  '
}

# A prompt that starts with "-" would be a flag to the agent if it travelled as
# it was typed. The guard is new_tab_argv's -- one leading space, not two -- and
# this runs the argv it built, so the guard is proven across the whole trip:
# builder, wrapper, agent.
tab_words=()
while IFS= read -r word; do tab_words[${#tab_words[@]}]=$word; done \
  < <(build_tab_words 0 -hello)
ran=$((ran + 1))
run_wrapper "${tab_words[@]}"
if [ "$status" -ne 0 ]; then
  fail "a dash prompt reaches the agent" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
elif ! grep -qxF 'agent arg:  -hello' "$tmp/out"; then
  fail "a prompt starting with a dash keeps its one leading space" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if grep -qxF 'agent arg: -hello' "$tmp/out"; then
  fail "a prompt starting with a dash is not sent as a flag" \
    "output: $(cat "$tmp/out")"
fi

# The blank answer, end to end: no prompt parameter at all, so the agent starts
# bare rather than with an empty argument -- and the pane still ends in a shell.
tab_words=()
while IFS= read -r word; do tab_words[${#tab_words[@]}]=$word; done \
  < <(build_tab_words 1 hello)
ran=$((ran + 1))
run_wrapper "${tab_words[@]}"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a blank answer still starts the agent and leaves a shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi
ran=$((ran + 1))
if grep -q '^agent arg:' "$tmp/out"; then
  fail "a blank answer gives the agent no prompt argument" \
    "output: $(cat "$tmp/out")"
fi

# A ^C in the pane: it goes to the whole process group, so the agent AND this
# wrapper get it, and a wrapper killed by it leaves no shell behind at all --
# the pane dies. Both shapes have to end in a shell: an agent killed by the
# signal, and an agent that catches it and exits cleanly.
#
# Bash's job control puts the run in its own process group, exactly as a terminal
# does, so the INT can be sent to the group; the agent touches $tmp/ready once it
# is running, so the signal arrives while it is.
interrupt_run() {
  local agent_name=$1
  shift
  rm -f "$tmp/ready" "$tmp/got-int" "$tmp/no-group"
  (
    cd "$start" || exit 1
    set -m
    PATH=$bin:$PATH
    SHELL=$tmp/shell
    fish_function_path=$tmp/functions
    WT_WORDS=$tmp/wt-words JQ_WORDS=$tmp/jq-words GIT_CALLS=$tmp/git-calls
    JWS_WORDS=$tmp/jws-words JWS_PATH=$worktree JWS_ENV=$tmp/jws-env
    JWS_MAIN=$main JWS_CD=1 JWS_FAIL=0 JWS_WRITE=1
    READY=$tmp/ready GOT_INT=$tmp/got-int
    export PATH SHELL fish_function_path WT_WORDS JQ_WORDS GIT_CALLS
    export JWS_WORDS JWS_PATH JWS_ENV JWS_MAIN JWS_CD JWS_FAIL JWS_WRITE
    export READY GOT_INT
    "$fish_bin" -c "$script" switch feat/x1 "" "$agent_name" "$@" &
    local child=$! waited=0
    while [ ! -e "$tmp/ready" ] && [ "$waited" -lt 100 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    # The signal has to reach the whole group, the way a terminal's ^C does.
    # Signalling only the process is not a workable fallback -- the wrapper
    # ignores INT, so the run would sit here until the agent's sleep ran out, and
    # then pass for the wrong reason. A group that cannot be signalled means
    # `set -m` did not take, and the run says so by name.
    if ! kill -INT -"$child" 2>/dev/null; then
      printf 'kill -INT -%s failed: set -m did not put the run in its own process group\n' \
        "$child" >"$tmp/no-group"
      exit 1
    fi
    wait "$child"
  ) >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
}

# The run, plus its own precondition: an INT that never reached the group would
# leave the assertions below to fail for whatever the missing signal caused --
# or, worse, to pass because the run finished some other way -- so the delivery
# is asserted by name before they look at the result. The wrapper's own exit
# status is captured here, before any grep runs: a failure report that showed the
# exit of the grep that looked for the shell would name the wrong number.
interrupt() {
  local agent_name=$1
  shift
  interrupt_run "$agent_name" "$@"
  interrupted=$status
  ran=$((ran + 1))
  if [ -e "$tmp/no-group" ]; then
    fail "the ^C reaches the whole process group ($agent_name)" "$(cat "$tmp/no-group")"
  fi
}

ran=$((ran + 1))
interrupt agent-killed "/brainstorming"
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a ^C that kills the agent still leaves the shell" \
    "exit $interrupted: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
interrupt agent-trapping "/brainstorming"
if [ ! -e "$tmp/got-int" ]; then
  fail "the ^C reaches the agent itself" \
    "exit $interrupted: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a ^C the agent catches still leaves the shell" \
    "exit $interrupted: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# No agent: the picker's "none". The pane is the workspace and a login shell, and
# the prompt -- which has nowhere to go -- is printed above that shell rather
# than disappearing with the float that collected it.
ran=$((ran + 1))
run_wrapper switch feat/x1 "" "" "look before you leap"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "no agent still lands in a shell in the workspace" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q 'agent pwd' "$tmp/out"; then
  fail "no agent starts nothing" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -q 'no agent started; the prompt is:' "$tmp/err" \
  || ! grep -qxF 'look before you leap' "$tmp/err"; then
  fail "no agent prints the prompt it could not deliver" \
    "stderr: $(cat "$tmp/err")"
fi

# The create is jws's, not the agent's, so a create still happens -- and with no
# agent there is no agent's arguments to give to anyone.
ran=$((ran + 1))
run_wrapper create feat/x1 @ "" "p"
ran=$((ran + 1))
if [ "$(sed -n 1p "$tmp/jws-words" 2>/dev/null)" != "feat/x1" ]; then
  fail "no agent still asks jws for the workspace" \
    "jws was given: $(cat "$tmp/jws-words" 2>/dev/null)"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a create with no agent still ends in a shell" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# An empty prompt is nothing to say: the pane is the shell, with no line about a
# prompt nobody wrote.
ran=$((ran + 1))
run_wrapper switch feat/x1 "" "" ""
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "no agent and no prompt still lands in the shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
elif grep -q 'the prompt is:' "$tmp/err"; then
  fail "an empty prompt is not announced" "stderr: $(cat "$tmp/err")"
fi

# A create that fails with no agent names what is not started: "not starting "
# followed by nothing is not a sentence.
ran=$((ran + 1))
JWS_FAIL=1 run_wrapper create nope/nothing @ "" "/brainstorming"
if ! grep -q 'jws nope/nothing failed' "$tmp/err"; then
  fail "a failing jws with no agent says why" "stderr: $(cat "$tmp/err")"
elif ! grep -q 'not starting an agent' "$tmp/err"; then
  fail "a failing jws with no agent names what is not started" \
    "stderr: $(cat "$tmp/err")"
fi


if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
