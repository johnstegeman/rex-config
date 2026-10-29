#!/usr/bin/env bash
# The tab's command: the POSIX sh wrapper init.lua hands to Rex.
#
# The wrapper exists so the pane outlives the agent: worktrunk switches the
# worktree, the agent runs in it, and a login shell stays behind, in the
# worktree, with everything printed above it still readable. It is run here for
# real -- with a stand-in `wt` that answers the way worktrunk does, a stand-in
# agent, and a stand-in SHELL -- because what matters is shell behaviour: which
# directory the agent and the shell end up in, which words reach `wt switch`,
# that a failed switch never starts the agent, and that the answer (a branch, a
# prompt) is data and not program text.
#
# The program under test is taken out of the argv the module builds, so this
# file runs exactly the string Rex hands to `sh -c`.
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
# follows `sh -c`, and the rest of that argv is what a run below supplies.
ran=$((ran + 1))
script=$(init="$PWD/init.lua" lua -e '
  local M = dofile(os.getenv("init"))
  local argv = M.new_tab_argv("proj", { branch = "feat/x1", create = true })
  io.write(argv[3] or "")
' 2>"$tmp/lua-err")
if [ -z "$script" ]; then
  fail "the tab's command is a shell program" \
    "init.lua gave nothing for argv[3]: $(cat "$tmp/lua-err")"
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

# The wrapper has to be POSIX sh, not bash: it runs on whatever `sh` the machine
# has. dash is the strictest parser to hand; where it is not installed, `sh`'s
# own check is what is left.
ran=$((ran + 1))
printf '%s\n' "$script" >"$tmp/script.sh"
if ! sh -n "$tmp/script.sh" \
  || { command -v dash >/dev/null 2>&1 && ! dash -n "$tmp/script.sh"; }; then
  fail "the wrapper is POSIX sh" "sh or dash could not parse it"
fi

bin=$tmp/bin
worktree=$tmp/worktree
start=$tmp/start
mkdir -p "$bin" "$worktree" "$start"

# worktrunk, stood in for: it records the words it was given, one per line, then
# answers like `wt switch --no-cd --format=json` -- the switch's result as JSON
# on stdout, hook output on stderr -- or fails the way it does for a branch it
# does not know.
cat >"$bin/wt" <<'EOF'
#!/bin/sh
: >"$WT_WORDS"
for word in "$@"; do printf '%s\n' "$word" >>"$WT_WORDS"; done
if [ "${WT_FAIL:-0}" = 1 ]; then
  printf '✗ No branch named %s\n' "$1" >&2
  exit 1
fi
printf '{"action":"switched","path":"%s"}\n' "$WT_PATH"
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

chmod +x "$bin/wt" "$bin/agent" "$bin/agent-killed" "$bin/agent-trapping" "$tmp/shell"

# The wrapper is run by the machine's own `sh`, resolved here so a run can take
# every tool but `wt` off the PATH (that is how a missing jq is tested). Every
# sh the machine has is kept too: the wrapper has to survive a ^C on all of
# them, and dash is the one whose wait dies first.
sh_bin=$(command -v sh)
shells=$sh_bin
if command -v dash >/dev/null 2>&1; then
  shells="$shells $(command -v dash)"
fi

# Run the wrapper the way Rex runs the tab: as an argv with no shell in between,
# the tab's own directory as cwd, and the answer under test as its parameters.
# WRAPPER_PATH narrows the PATH for the run, RUN_SHELL picks the sh, TEST_SHELL
# replaces the stand-in shell, TEST_WT_PATH the path worktrunk reports, and
# STDIN_FROM what the pane's stdin is (a file of commands, for a fallback sh that
# is not a stub). Sets $status and leaves stdout in $tmp/out, stderr in $tmp/err.
run_wrapper() {
  local create=$1 branch=$2 base=$3
  shift 3
  (
    cd "$start" || exit 1
    PATH=${WRAPPER_PATH:-$bin:$PATH}
    SHELL=${TEST_SHELL:-$tmp/shell}
    WT_WORDS=$tmp/wt-words WT_PATH=${TEST_WT_PATH:-$worktree} WT_FAIL=${WT_FAIL:-0}
    export PATH SHELL WT_WORDS WT_PATH WT_FAIL
    "${RUN_SHELL:-$sh_bin}" -c "$script" sh "$create" "$branch" "$base" "$@"
  ) >"$tmp/out" 2>"$tmp/err" <"${STDIN_FROM:-/dev/null}"
  status=$?
}

# A create run: worktrunk is asked to create the branch from the base, the agent
# runs in the worktree it made, and a login shell is left there.
ran=$((ran + 1))
run_wrapper 1 feat/x1 @ agent "/brainstorming for bead p-1"
if [ "$status" -ne 0 ]; then
  fail "a create run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf 'switch\n--create\nfeat/x1\n--base\n@\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "a create run asks worktrunk to create the branch from the base"
fi

ran=$((ran + 1))
if ! grep -qx "agent pwd: $worktree" "$tmp/out"; then
  fail "the agent runs in the worktree" "output: $(cat "$tmp/out")"
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

# An existing worktree: the same run with no --create, so no second worktree
# appears, and no --base either -- the base says what a *new* branch starts from.
ran=$((ran + 1))
run_wrapper 0 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "an existing-worktree run finishes" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
printf 'switch\nfeat/x1\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "an existing worktree is switched to, not created"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
  fail "an existing worktree ends in a shell there too" "output: $(cat "$tmp/out")"
fi

# Creating with no base named: worktrunk's own default, so the parameter is
# empty and --base is not sent.
ran=$((ran + 1))
run_wrapper 1 feat/x1 "" agent "p"
printf 'switch\n--create\nfeat/x1\n--no-cd\n--format=json\n' >"$tmp/want"
if ! diff -u "$tmp/want" "$tmp/wt-words"; then
  fail "a create run with no base sends no --base"
fi

# A switch that fails: worktrunk has said why on stderr, the agent is not
# started at all -- never in the wrong directory -- and the shell still opens,
# in the tab's directory, so the pane is usable rather than dead.
ran=$((ran + 1))
WT_FAIL=1 run_wrapper 1 nope/nothing @ agent "/brainstorming"
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
if ! grep -q "nope/nothing" "$tmp/err" || ! grep -q "not starting" "$tmp/err"; then
  fail "a failed switch says which branch it could not switch to" \
    "stderr: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if ! grep -q 'wt switch nope/nothing failed (exit' "$tmp/err"; then
  fail "a failed switch names the switch and its status" "stderr: $(cat "$tmp/err")"
fi

# The path cannot be read -- jq is missing here, which is the same empty path a
# reply without one gives: nothing tells the wrapper where the worktree is, so
# the agent is not started.
ran=$((ran + 1))
WRAPPER_PATH=$bin run_wrapper 1 feat/x1 @ agent "/brainstorming"
if [ "$status" -ne 0 ]; then
  fail "a run with no jq still leaves a shell" "exit $status: $(cat "$tmp/err")"
fi

ran=$((ran + 1))
if grep -q "agent pwd" "$tmp/out"; then
  fail "a worktree path that cannot be read never starts the agent" \
    "output: $(cat "$tmp/out")"
fi

ran=$((ran + 1))
if ! grep -qx "shell pwd: $start" "$tmp/out" || ! grep -q jq "$tmp/err"; then
  fail "a missing jq is named and the shell stays put" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The switch itself worked, so the failing step is reading the path out of its
# reply: the message names that step rather than reporting a bare "exit 0", which
# would send a reader looking for a switch that never failed.
ran=$((ran + 1))
if ! grep -q 'could not read the worktree path' "$tmp/err"; then
  fail "a reply with no readable path names the failing step" "stderr: $(cat "$tmp/err")"
fi

# A worktree path that starts with a dash: `cd -dash` is a bad option to every
# shell, so the wrapper has to end the options before handing the path over.
ran=$((ran + 1))
mkdir -p "$start/-dash"
TEST_WT_PATH=-dash run_wrapper 0 feat/x1 "" agent "/brainstorming"
if ! grep -qx "agent pwd: $start/-dash" "$tmp/out"; then
  fail "a worktree path starting with a dash is entered" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# A path worktrunk reported but the shell cannot enter -- the worktree going away
# between the switch and the cd. The agent must not run there either, and the
# pane still gets its shell, in the tab's directory.
ran=$((ran + 1))
TEST_WT_PATH=/nonexistent/nope run_wrapper 1 feat/x1 @ agent "/brainstorming"
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
if ! grep -q "could not enter" "$tmp/err" || ! grep -qx "shell pwd: $start" "$tmp/out"; then
  fail "a worktree that cannot be entered is named, and the shell stays put" \
    "output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# A caller that sends too few parameters: `shift 3` on a short list is fatal in a
# non-interactive shell (dash exits outright), which would kill the pane with no
# shell at all. The wrapper says what is missing and opens the shell anyway.
for run_shell in $shells; do
  shell_name=${run_shell##*/}
  ran=$((ran + 1))
  (
    cd "$start" || exit 1
    SHELL=$tmp/shell PATH=$bin:$PATH
    export SHELL PATH
    "$run_shell" -c "$script" sh 1 feat/x1
  ) >"$tmp/out" 2>"$tmp/err" </dev/null
  status=$?
  if [ "$status" -ne 0 ] || ! grep -qx "shell pwd: $start" "$tmp/out"; then
    fail "too few parameters still leave a shell ($shell_name)" \
      "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
  fi

  ran=$((ran + 1))
  if ! grep -q "create, branch and base" "$tmp/err"; then
    fail "too few parameters say which ones are missing ($shell_name)" \
      "stderr: $(cat "$tmp/err")"
  fi
done

# $SHELL naming a program that is not installed: exec'ing it would leave the pane
# dead with exit 127, so the plain sh is the fallback. That sh is not a stub, so
# it is given a command on stdin: it reads it once it has started.
ran=$((ran + 1))
cat >"$tmp/fallback" <<'EOF'
printf 'fallback shell pwd: %s\n' "$PWD"
EOF
TEST_SHELL=/nonexistent/shell STDIN_FROM=$tmp/fallback run_wrapper 0 feat/x1 "" agent "/brainstorming"
if [ "$status" -ne 0 ] || ! grep -qx "fallback shell pwd: $worktree" "$tmp/out"; then
  fail "a missing \$SHELL falls back to /bin/sh in the worktree" \
    "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
fi

# The answer is data: a branch and a prompt full of shell syntax reach worktrunk
# and the agent as themselves, and none of it is executed.
ran=$((ran + 1))
run_wrapper 0 'feat/x$(id);echo pwned' "" agent 'p "quotes" $(id) `id`;echo pwned'
if grep -qx "agent arg: p \"quotes\" \$(id) \`id\`;echo pwned" "$tmp/out" \
  && [ "$(sed -n 2p "$tmp/wt-words")" = 'feat/x$(id);echo pwned' ] \
  && ! grep -q '^pwned$' "$tmp/out" "$tmp/err"; then
  :
else
  fail "the branch and the prompt are arguments, not program text" \
    "words: $(cat "$tmp/wt-words") output: $(cat "$tmp/out")"
fi

# A ^C in the pane: it goes to the whole process group, so the agent AND this
# wrapper get it, and a wrapper killed by it leaves no shell behind at all --
# the pane dies. Both shapes have to end in a shell: an agent killed by the
# signal, and an agent that catches it and exits cleanly.
#
# Bash's job control puts the run in its own process group, exactly as a
# terminal does, so the INT can be sent to the group; the agent touches $tmp/ready
# once it is running, so the signal arrives while it is.
interrupt_run() {
  local agent_name=$1
  shift
  rm -f "$tmp/ready" "$tmp/got-int" "$tmp/no-group"
  (
    cd "$start" || exit 1
    set -m
    PATH=${WRAPPER_PATH:-$bin:$PATH}
    SHELL=$tmp/shell
    WT_WORDS=$tmp/wt-words WT_PATH=$worktree WT_FAIL=0
    READY=$tmp/ready GOT_INT=$tmp/got-int
    export PATH SHELL WT_WORDS WT_PATH WT_FAIL READY GOT_INT
    "${RUN_SHELL:-$sh_bin}" -c "$script" sh 0 feat/x1 "" "$agent_name" "$@" &
    local child=$! waited=0
    while [ ! -e "$tmp/ready" ] && [ "$waited" -lt 100 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    # The signal has to reach the whole group, the way a terminal's ^C does.
    # Signalling only the process is no longer a workable fallback -- the
    # wrapper ignores INT, so the run would sit here until the agent's sleep
    # ran out, and then pass for the wrong reason. A group that cannot be
    # signalled means `set -m` did not take, and the run says so by name.
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
    fail "the ^C reaches the whole process group ($agent_name, ${RUN_SHELL:-$sh_bin})" \
      "$(cat "$tmp/no-group")"
  fi
}

for run_shell in $shells; do
  shell_name=${run_shell##*/}

  ran=$((ran + 1))
  RUN_SHELL=$run_shell interrupt agent-killed "/brainstorming"
  if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
    fail "a ^C that kills the agent still leaves the shell ($shell_name)" \
      "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
  fi

  ran=$((ran + 1))
  RUN_SHELL=$run_shell interrupt agent-trapping "/brainstorming"
  if [ ! -e "$tmp/got-int" ]; then
    fail "the ^C reaches the agent itself ($shell_name)" \
      "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
  fi

  ran=$((ran + 1))
  if ! grep -qx "shell pwd: $worktree" "$tmp/out"; then
    fail "a ^C the agent catches still leaves the shell ($shell_name)" \
      "exit $status: output: $(cat "$tmp/out") stderr: $(cat "$tmp/err")"
  fi
done

if [ "$fails" -ne 0 ]; then
  printf '%d of %d assertions failed\n' "$fails" "$ran"
  exit 1
fi

printf 'ok %d assertions\n' "$ran"
