#!/usr/bin/env bash
# The tab's command: the fish wrapper init.lua hands to Rex.
#
# The wrapper exists so the pane outlives the agent: gws creates the worktree or
# worktrunk switches to it, the agent runs in it, and a login shell stays behind,
# in the worktree, with everything printed above it still readable. It is run
# here for real -- with a stand-in `gws` for a create, a stand-in `wt` that
# answers the way worktrunk does, a stand-in agent, and a stand-in SHELL --
# because what matters is shell behaviour: which directory the agent and the
# shell end up in, which words reach `gws` and `wt switch`, that a failed create
# or switch never starts the agent, and that the answer (a branch, a prompt) is
# data and not program text.
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
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", create = true })
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
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", create = true })
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

bin=$tmp/bin
worktree=$tmp/worktree
start=$tmp/start
mkdir -p "$bin" "$worktree" "$start" "$tmp/functions"

# gws, stood in for: it records the words it was given, writes the path into
# whatever file --path-file names, and exits 0 or 1 the way the real function
# does. It is a fish *function*, found through fish_function_path, because that
# is how the real gws reaches the tab: a program on the PATH would prove a
# different thing.
cat >"$tmp/functions/gws.fish" <<'EOF'
function gws
    printf '%s\n' $argv >$GWS_WORDS
    set -l pf
    set -l i 0
    while test $i -lt (count $argv)
        set i (math $i + 1)
        if test "$argv[$i]" = --path-file
            set pf $argv[(math $i + 1)]
        end
    end
    if test "$GWS_FAIL" = 1
        echo "gws: the stand-in was asked to fail" >&2
        return 1
    end
    # GWS_WRITE=0 is a gws that says it worked and leaves the path file empty:
    # the caller has no path, which is the failure this wrapper has to catch.
    if test "$GWS_WRITE" != 0; and test -n "$pf"
        printf '%s\n' $GWS_PATH >$pf
    end
    echo "gws: $GWS_PATH ready"
end
EOF

# worktrunk, stood in for: it records the words it was given, one per line, then
# answers like `wt switch --no-cd --format=json` -- the switch's result as JSON
# on stdout, hook output on stderr -- or fails the way it does for a branch it
# does not know. It also records the credential-prompt guard it inherited from
# the wrapper.
#
# A fish function and not a program on the PATH, for the same reason gws is: this
# machine's fish start-up files put their own directories in front of anything a
# caller hands over, so a PATH entry would be shadowed by the real worktrunk and
# the words would never be recorded.
cat >"$tmp/functions/wt.fish" <<'EOF'
function wt
    # Every record is optional: a case that does not care about a file leaves its
    # variable out, and a stand-in that died on that would fail the run for a
    # reason of its own.
    set -l env_file /dev/null
    set -q WT_ENV; and set env_file $WT_ENV
    : >"$WT_WORDS"
    if set -q GIT_TERMINAL_PROMPT
        printf 'GIT_TERMINAL_PROMPT=%s\n' "$GIT_TERMINAL_PROMPT" >$env_file
    else
        printf 'GIT_TERMINAL_PROMPT=unset\n' >$env_file
    end
    for word in $argv
        printf '%s\n' $word >>"$WT_WORDS"
    end
    if test "$WT_FAIL" = 1
        printf '✗ No branch named %s\n' "$argv[1]" >&2
        return 1
    end
    printf '{"action":"switched","path":"%s"}\n' "$WT_PATH"
end
EOF

# git, stood in for: nothing in the wrapper runs it any more -- the fetch a new
# branch needs belongs to gws -- so the marker it leaves is how "never" is told
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

# Run the wrapper the way Rex runs the tab: as an argv with no shell in between,
# the tab's own directory as cwd, and the answer under test as its parameters --
# the three positional words (create, branch, base) and then the agent, its
# arguments and the prompt. TEST_SHELL replaces the stand-in shell or
# UNSET_SHELL takes SHELL away, TEST_WT_PATH (explicitly empty included) and
# WT_FAIL choose what worktrunk reports, GWS_PATH, GWS_FAIL and GWS_WRITE choose
# what the stand-in gws does, and STDIN_FROM is what the pane's stdin is (a file
# of commands, for a fallback sh that is not a stub). The stand-ins' records are
# cleared first, so an assertion that something never ran reads that run alone.
# Sets $status and leaves stdout in $tmp/out, stderr in $tmp/err.
run_wrapper() {
  local create=$1 branch=$2 base=$3
  shift 3
  rm -f "$tmp/gws-words" "$tmp/wt-words" "$tmp/git-calls"
  (
    cd "$start" || exit 1
    PATH=$bin:$PATH
    if [ "${UNSET_SHELL:-0}" = 1 ]; then
      unset SHELL
    else
      SHELL=${TEST_SHELL:-$tmp/shell}
      export SHELL
    fi
    # The stand-ins for gws, wt and git are functions, so fish has to be told
    # where functions live; the agents and the shell are programs, reached
    # through PATH.
    fish_function_path=$tmp/functions
    WT_WORDS=$tmp/wt-words WT_PATH=${TEST_WT_PATH-$worktree} WT_FAIL=${WT_FAIL:-0}
    WT_ENV=$tmp/wt-env GIT_CALLS=$tmp/git-calls
    GWS_WORDS=$tmp/gws-words GWS_PATH=${GWS_PATH:-$worktree}
    GWS_FAIL=${GWS_FAIL:-0} GWS_WRITE=${GWS_WRITE:-1}
    export PATH fish_function_path WT_WORDS WT_PATH WT_FAIL WT_ENV GIT_CALLS
    export GWS_WORDS GWS_PATH GWS_FAIL GWS_WRITE
    "$fish_bin" -c "$script" "$create" "$branch" "$base" "$@"
  ) >"$tmp/out" 2>"$tmp/err" <"${STDIN_FROM:-/dev/null}"
  status=$?
}

# A create run: gws is asked to make the worktree from the base and to write its
# path into a file, the agent runs in the worktree it made, and a login shell is
# left there.
ran=$((ran + 1))
run_wrapper 1 feat/x1 @ agent "/brainstorming for bead p-1"
if [ "$status" -ne 0 ]; then
  fail "a create run finishes" "exit $status: $(cat "$tmp/err")"
fi

# The words, and the file they name: the base is passed verbatim, and the path
# file is one this wrapper made rather than something it composed from the
# branch.
ran=$((ran + 1))
if [ "$(sed -n 1p "$tmp/gws-words")" != "feat/x1" ] \
  || [ "$(sed -n 2p "$tmp/gws-words")" != "@" ] \
  || [ "$(sed -n 3p "$tmp/gws-words")" != "--path-file" ] \
  || [ -z "$(sed -n 4p "$tmp/gws-words")" ]; then
  fail "a create calls gws with the branch, the base and a path file" \
    "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
fi

ran=$((ran + 1))
path_file=$(sed -n 4p "$tmp/gws-words" 2>/dev/null)
case $path_file in
  /*) : ;;
  *)
    fail "the path file is a file of its own, named absolutely" \
      "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
    ;;
esac

# The path file is this run's litter and nobody else's: the path is read out of
# it, and a create per tab would otherwise leave one behind in /tmp each time.
ran=$((ran + 1))
if [ -n "$path_file" ] && [ -e "$path_file" ]; then
  fail "the path file is cleaned up" "left behind: $path_file"
fi

# The fetch a new branch needs is gws's: it fetches the revision before the
# workspace is made. Nothing here runs git, and the marker is how "nothing" is
# told apart from "ran and did nothing".
ran=$((ran + 1))
if [ -e "$tmp/git-calls" ]; then
  fail "a create does not fetch: the fetch is gws's" \
    "git was given: $(cat "$tmp/git-calls")"
fi

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out"; then
  fail "the agent runs in the worktree gws named" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF "agent arg: /brainstorming for bead p-1" "$tmp/out"; then
  fail "the prompt arrives as one argument" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "the shell lands in the worktree" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell args: -l" "$tmp/out"; then
  fail "the shell is a login shell" "output: $(cat "$tmp/out")"
fi

# Creating with no base named: gws's own default (main), so the parameter is
# empty and no base word is sent -- an empty word would be a revision jj has no
# name for.
ran=$((ran + 1))
run_wrapper 1 feat/x1 "" agent "p"
printf 'feat/x1\n--path-file\n%s\n' "$(sed -n 3p "$tmp/gws-words")" >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/gws-words"; then
  fail "a create with an empty base sends gws no base word" \
    "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
fi

# The base and the credential guard -----------------------------------------
#
# A create that names a real revision: gws receives it as itself, one word, so a
# revision with a slash in it is neither a glob nor two arguments. The fetch it
# buys from the remote is gws's business -- the wrapper reads the revision it is
# handed and never derives a remote from its shape.
ran=$((ran + 1))
run_wrapper 1 feat/x1 origin/main agent "/brainstorming"
if [ "$(sed -n 2p "$tmp/gws-words")" != "origin/main" ]; then
  fail "the base reaches gws verbatim" "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
fi

# An invisible credential prompt is the hang GIT_TERMINAL_PROMPT=0 exists to
# prevent, and it is exported before the switch, so worktrunk and the hooks it
# runs inherit it too.
ran=$((ran + 1))
run_wrapper 0 feat/x1 origin/main agent "/brainstorming"
if ! grep -qx 'GIT_TERMINAL_PROMPT=0' "$tmp/wt-env"; then
  fail "wt runs with GIT_TERMINAL_PROMPT=0" "recorded: $(cat "$tmp/wt-env" 2>/dev/null)"
fi

# A create that fails: gws has said why on stderr, the agent is not started at
# all -- never in the wrong directory -- and the shell still opens, in the tab's
# directory, so the pane is usable rather than dead.
ran=$((ran + 1))
GWS_FAIL=1 run_wrapper 1 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a failing gws starts nothing and leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a failing gws never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "after a failing gws the shell stays in the tab's directory" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: gws feat/x1 failed (exit 1); not starting agent' "$tmp/err"; then
  fail "a failing gws names the branch, the exit status and what is not started" \
    "stderr: $(cat "$tmp/err")"
fi

# gws said it worked and the path file is empty -- the workspace is there and
# nothing tells the wrapper where: the agent must not start in the wrong place,
# and the line names the step that lost the path rather than the create.
ran=$((ran + 1))
GWS_WRITE=0 run_wrapper 1 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "a create whose path file was never written starts nothing" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "an unreadable path file never starts the agent" "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: could not read the worktree path of feat/x1 from the gws path file; not starting agent' \
  "$tmp/err"; then
  fail "an unreadable path file names the branch and the file" "stderr: $(cat "$tmp/err")"
fi

# An existing worktree: worktrunk's switch, with no --base even though the base
# word is non-empty -- --base says what a *new* branch starts from (worktrunk
# answers "--base flag is only used with --create, ignoring" to anything else,
# which would be a line of noise on the pane for nothing).
ran=$((ran + 1))
run_wrapper 0 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "an existing-worktree run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf 'switch\nfeat/x1\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "an existing worktree still goes through wt switch"
fi

# Only a create is gws's: an existing worktree is not made at all, and calling
# gws here would create a second workspace nobody asked for.
ran=$((ran + 1))
if [ -e "$tmp/gws-words" ]; then
  fail "an existing worktree never calls gws" \
    "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "an existing worktree ends in a shell there too" "output: $(cat "$tmp/out")"
fi

# A switch that fails: worktrunk has said why on stderr, the agent is not
# started at all, and the shell still opens in the tab's directory.
ran=$((ran + 1))
WT_FAIL=1 run_wrapper 0 nope/nothing @ agent "/brainstorming"
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
if ! grep -q 'wt switch nope/nothing failed (exit' "$tmp/err"; then
  fail "a failed switch names the switch and its status" "stderr: $(cat "$tmp/err")"
fi

# The switch itself worked, so the failing step is reading the path out of its
# reply -- a reply with no path in it, which is the same empty path a jq that is
# not installed gives. Nothing tells the wrapper where the worktree is, so the
# agent is not started, and the message names that step rather than reporting a
# bare "exit 0", which would send a reader looking for a switch that never
# failed.
#
# (A missing jq itself cannot be stood in for here: fish's own start-up files
# decide the PATH the wrapper sees, so a run cannot take jq away. The empty path
# is the branch of that message that can be reached honestly.)
ran=$((ran + 1))
TEST_WT_PATH= run_wrapper 0 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a reply with no path still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a worktree path that cannot be read never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "an unreadable reply leaves the shell in the tab's directory" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -qxF 'rex-config: could not read the worktree path of feat/x1 from the switch reply (jq missing, or no path in it); not starting agent' \
  "$tmp/err"; then
  fail "a reply with no readable path names the branch and the failing step" \
    "stderr: $(cat "$tmp/err")"
fi

# A worktree path that starts with a dash: fish's `cd` reads it as an option and,
# unlike sh's, takes no `--` to end them, so the wrapper has to hand it over in a
# shape that is a path and not a flag.
ran=$((ran + 1))
mkdir -p "$start/-dash"
TEST_WT_PATH=-dash run_wrapper 0 feat/x1 "" agent "/brainstorming"
if ! grep -qx "agent pwd: $start/-dash" "$tmp/out"; then
  fail "a worktree path starting with a dash is entered" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# A path worktrunk reported but the shell cannot enter -- the worktree going away
# between the create and the cd. The agent must not run there either, and the
# pane still gets its shell, in the tab's directory.
ran=$((ran + 1))
GWS_PATH=/nonexistent/nope run_wrapper 1 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a worktree that cannot be entered still leaves a shell" \
    "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a worktree that cannot be entered never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -q "could not enter /nonexistent/nope" "$tmp/err" \
  || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "a worktree that cannot be entered is named, and the shell stays put" \
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
if ! grep -qxF 'rex-config: the tab needs create, branch and base' "$tmp/err"; then
  fail "too few parameters name all three words" "stderr: $(cat "$tmp/err")"
fi

# $SHELL naming a program that is not installed: exec'ing it would leave the pane
# dead with exit 127, so the plain sh is the fallback. That sh is not a stub, so
# it is given a command on stdin: it reads it once it has started.
ran=$((ran + 1))
cat >"$tmp/fallback" <<'EOF'
printf 'fallback shell pwd: %s\n' "$PWD"
EOF
TEST_SHELL=/nonexistent/shell STDIN_FROM=$tmp/fallback run_wrapper 0 feat/x1 "" agent "/brainstorming"
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
UNSET_SHELL=1 STDIN_FROM=$tmp/fallback-unset run_wrapper 0 feat/x1 "" agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "unset-shell pwd: $worktree" "$tmp/out"; then
  fail "no \$SHELL still leaves a usable login shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The answer is data: a branch and a prompt full of shell syntax reach worktrunk
# and the agent as themselves, and none of it is executed.
ran=$((ran + 1))
run_wrapper 0 'feat/x$(id);echo pwned' "" agent 'p "quotes" $(id) `id`;echo pwned'
if grep -qxF "agent arg: p \"quotes\" \$(id) \`id\`;echo pwned" "$tmp/out" \
  && [ "$(sed -n 2p "$tmp/wt-words")" = 'feat/x$(id);echo pwned' ] \
  && ! grep -q '^pwned$' "$tmp/out" "$tmp/err"; then
  :
else
  fail "the branch and the prompt are arguments, not program text" \
    "words: $(cat "$tmp/wt-words") output: $(cat "$tmp/out")"
fi

# The words the tab really gets, built by the module rather than written out by
# hand: everything from argv[4] on -- what follows `fish -c SCRIPT` -- one per
# line, so a case can run the argv new_tab_argv produced. An argument that is the
# empty string comes back as an empty line, which is exactly how the wrapper
# needs to receive it.
build_tab_words() {
  init="$PWD/init.lua" want_blank=$1 want_prompt=$2 lua -e '
    local M = dofile(os.getenv("init"))
    local args = { branch = "feat/x1", create = false, agent = "agent",
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
    WT_WORDS=$tmp/wt-words WT_PATH=$worktree WT_FAIL=0
    WT_ENV=$tmp/wt-env GIT_CALLS=$tmp/git-calls
    READY=$tmp/ready GOT_INT=$tmp/got-int
    export PATH SHELL fish_function_path WT_WORDS WT_PATH WT_FAIL WT_ENV GIT_CALLS
    export READY GOT_INT
    "$fish_bin" -c "$script" 0 feat/x1 "" "$agent_name" "$@" &
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
# is asserted by name before they look at the result.
interrupt() {
  local agent_name=$1
  shift
  interrupt_run "$agent_name" "$@"
  ran=$((ran + 1))
  if [ -e "$tmp/no-group" ]; then
    fail "the ^C reaches the whole process group ($agent_name)" "$(cat "$tmp/no-group")"
  fi
}

ran=$((ran + 1))
interrupt agent-killed "/brainstorming"
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a ^C that kills the agent still leaves the shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
interrupt agent-trapping "/brainstorming"
if [ ! -e "$tmp/got-int" ]; then
  fail "the ^C reaches the agent itself" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a ^C the agent catches still leaves the shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# No agent: the picker's "none". The pane is the worktree and a login shell, and
# the prompt -- which has nowhere to go -- is printed above that shell rather
# than disappearing with the float that collected it.
ran=$((ran + 1))
run_wrapper 0 feat/x1 "" "" "look before you leap"
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "no agent still lands in a shell in the worktree" \
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

# The create is gws's, not the agent's, so a create still happens -- and with no
# agent there is no agent's arguments to give to anyone.
ran=$((ran + 1))
run_wrapper 1 feat/x1 @ "" "p"
ran=$((ran + 1))
if [ "$(sed -n 1p "$tmp/gws-words" 2>/dev/null)" != "feat/x1" ]; then
  fail "no agent still asks gws for the worktree" \
    "gws was given: $(cat "$tmp/gws-words" 2>/dev/null)"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "a create with no agent still ends in a shell" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# An empty prompt is nothing to say: the pane is the shell, with no line about a
# prompt nobody wrote.
ran=$((ran + 1))
run_wrapper 0 feat/x1 "" "" ""
if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "no agent and no prompt still lands in the shell" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
elif grep -q 'the prompt is:' "$tmp/err"; then
  fail "an empty prompt is not announced" "stderr: $(cat "$tmp/err")"
fi

# A create that fails with no agent names what is not started: "not starting "
# followed by nothing is not a sentence.
ran=$((ran + 1))
GWS_FAIL=1 run_wrapper 1 nope/nothing @ "" "/brainstorming"
if ! grep -q 'gws nope/nothing failed' "$tmp/err"; then
  fail "a failing gws with no agent says why" "stderr: $(cat "$tmp/err")"
elif ! grep -q 'not starting an agent' "$tmp/err"; then
  fail "a failing gws with no agent names what is not started" \
    "stderr: $(cat "$tmp/err")"
fi


if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
