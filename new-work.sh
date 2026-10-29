#!/usr/bin/env bash
# new-work.sh -- the pickers behind rex's new-work flow (ctrl+space>n).
#
# Called by the Lua module; every subcommand is a plain function so the tests
# and dry runs can exercise it without fzf or a terminal.
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<'EOF'
usage: new-work.sh <command> [options]

commands:
  beads --main DIR [--bd-json FILE]
      list pickable ready beads, one "id<TAB>title" row each, sorted by
      priority then id
  preview ID --main DIR
      print one bead's full text, for the picker's preview pane
  branch-default --type TYPE --id ID
      print the branch name to offer for a bead, e.g. bug/pmm-iris-a4l
  candidates --main DIR [--wt-json FILE] [--refs FILE]
      print the branch names that already exist, one per line, worktree
      branches first
  bases --main DIR [--base-refs FILE] [--base REF | --no-base]
      print the bases the screen opens on and cycles through, one
      "ref<TAB>remote" row each, the opening answer first; an empty ref means
      no --base at all, which leaves it to worktrunk
  fzf-answer STATUS
      read fzf's --print-query --expect reply on stdin and print what it means
      as one "bead<TAB>prompt<TAB>blank" row, empty where there is no answer;
      STATUS is the status fzf exited with
  pick --main DIR --root PATH --project NAME [--base REF | --no-base]
       [--base-refs FILE] [--bead ID | --prompt TEXT | --blank]
       [--agents NAME]... [--agent NAME] [--branch NAME] [--dry-run]
      open the one screen and hand its answers to Rex as one JSON object: the
      bead (or prompt, or nothing said at all), the agent, the branch, the base
      a new branch is created from and the remote that base lives on; exit 3
      when no branch or agent was chosen, exit 2 when the name typed for a new
      branch is not a valid ref
  composer rows --state DIR
  composer header --state DIR --project NAME [--no-base]
  composer cycle-agent --state DIR --project NAME [--agents NAME]...
  composer cycle-base --state DIR --project NAME --main DIR
           [--base-refs FILE] [--base REF | --no-base]
  composer branch-field --state DIR [--project NAME]
      the one screen's answers, one verb each, kept in DIR so a key can read and
      change them while the screen is up: rows and header print what fzf shows,
      cycle-agent, cycle-base and branch-field are what ctrl-a, ctrl-r and ctrl-b
      run, and branch-field prints nothing

--bd-json, --wt-json, --refs and --base-refs read saved tool output instead of
asking the tools, which is how the tests and dry runs work: --bd-json stands in
for bd, --wt-json with --refs for both of the lookups --main would be read for,
and --base-refs for the one bases reads, so a run given all four never touches
--main at all.

The one screen asks everything at once: the ready beads with "✎  write a prompt
instead" pinned on top, and the agent, the branch and the base in its header, a
key for each. Text typed at the fzf prompt that matches no row is the prompt
itself (--print-query with --expect: the query is line 1, the key that was
pressed line 2 -- empty when none was -- and the selected row line 3 when there
is one), and picking the prompt row opens a prompt field for text that would be
awkward to type there. esc means no bead, so the configured no-bead prompt says
what the flow is; ctrl-n means blank, an agent started with nothing said to it
at all; ctrl-a, ctrl-b and ctrl-r cycle the agent, type the branch and cycle the
base, and each repaints the header alone. The agent cycle is the --agents names
followed by "none", which starts nothing -- the tab is then the new worktree and
a login shell, with the prompt it could not deliver printed above that shell
rather than dropped. The branch starts as the name derived from the bead and a
bare Enter keeps it.

The base field opens on the one --base names, or the one this clone would be
created from (origin/HEAD's target, then origin/main, origin/master, main,
master), or none at all with --no-base -- which reads "wt default", because it
is a real answer rather than a missing one. The base travels to the tab with the
remote it lives on so the tab can fetch that one; a base on no remote carries no
remote, and nothing is fetched for it. --base-refs reads a saved for-each-ref
instead of the repository, as bases does.

pick's --bead, --prompt, --blank, --agent and --branch answer a question
instead of asking it, and an empty value means none -- so a run given one of the
first three opens no screen at all. --blank is the answer
ctrl-n gives -- no bead and nothing said to the agent, which the tab reads as
no prompt word at all -- and, like the others, it cannot be combined with an
answer to the same question. With no terminal on stdin nothing is asked: the
bead question is skipped, the agent falls back to the one this picker used last
and then to the first --agents name, and the branch reads an empty answer,
rather than waiting for any of them. That remembered name lives in
$XDG_STATE_HOME/rex-config/state (~/.local/state/rex-config/state when unset),
is read tolerantly and written before each hand-back, and a name the agent list
no longer offers is ignored.
--main and --root must be absolute: Rex resolves them against its own working
directory, not this one.
EOF
}

# Exit 2: the caller asked for something this script does not do.
usage_error() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  usage >&2
  exit 2
}

# Exit 2: an argument whose value cannot mean what it says. Rex resolves the
# hand-back's paths against its own working directory rather than the float's,
# so a relative one would build a tab somewhere else entirely -- and fail there
# with nothing on screen to explain it.
need_absolute() {
  case $2 in
    /*) return 0 ;;
  esac
  usage_error "$1 must be an absolute path, not $2"
}

# Exit 1: the environment cannot run the command at all.
die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

# Whether this run has already paused, so a failure that has been read is not
# waited on twice: need pauses for its own message, and hold_pick covers every
# other way the picker can stop.
held=0

# The directory this run keeps the one screen's answers in, empty until pick
# makes one. Declared out here rather than inside pick because hold_pick removes
# it, and every way out of pick passes through hold_pick.
composer_state=''

# Wait for one keypress before the message just printed disappears with the
# terminal: the picker runs in a floating terminal, which closes the moment this
# script exits. The keypress goes to that terminal; with no terminal on stdin (a
# script, a pipe, or the tests) there is nobody to wait for, so it returns.
wait_for_key() {
  held=1
  [ -t 0 ] || return 0
  read -r -s -n 1 _ || true
}

# The status a cancelled pick leaves with: an answer rather than a failure, so
# the float closes on it the way esc always did. The usage text above says the
# same number in prose, because a quoted heredoc cannot interpolate this one.
cancelled=3

# The first row of the bead question: not a bead, but the way to write a prompt
# when the text would match a bead or needs more than fzf's one line. It carries
# no id -- a marker no bead id can be -- so field 1 alone tells it from every
# bead row. A tab separates the fields, as in every other row.
prompt_row_marker='✎'
prompt_row=$prompt_row_marker$'\t''write a prompt instead'

# On the way out of pick -- usage_error's 2, die's 1, a missing tool's 1, rex's
# own status -- hold the float with the failure still on screen. A cancelled
# pick is an answer rather than a failure, so it is left alone. The one screen's
# state directory, when this run made one, is removed here too: every way out of
# pick comes through here, so a killed float leaves nothing behind.
hold_pick() {
  local status=$?
  if [ -n "$composer_state" ]; then
    rm -rf "$composer_state"
  fi
  if [ "$status" -ne 0 ] && [ "$status" -ne "$cancelled" ] && [ "$held" -eq 0 ]; then
    wait_for_key
  fi
  exit "$status"
}

# Exit 1: a tool the command cannot work without is not installed, so the pane
# is held open on the name of it.
need() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s not found on PATH — press any key\n' "$1" >&2
  wait_for_key
  exit 1
}

# Ready beads as JSON: the fixture when one is given (tests and dry runs), else
# `bd ready` run from the main worktree, which is the worktree every bd call
# uses.
ready_json() {
  local main=$1 fixture=$2
  if [ -n "$fixture" ]; then
    cat "$fixture"
  else
    ( cd "$main" && bd ready --json )
  fi
}

# Rows for the beads a person can actually start work on, from `bd ready --json`
# on stdin. Out go the things that are not work: molecule steps (dotted ids),
# molecule and gate container beads, step:* labels, and a record with no id at
# all, which nothing could pick. Rows are "id<TAB>title", sorted by priority
# then id. A title is flattened to one line and a missing priority gets a value,
# so a producer that is not bd itself cannot split a row or stop the listing;
# what the picker hands back is read from the JSON again, so this is for reading
# only.
pickable_rows() {
  jq -r '
    [ .[]
      | .id //= ""
      | .priority //= 999
      | select(.id != "")
      | select(.id | contains(".") | not)
      | select(.issue_type != "molecule" and .issue_type != "gate")
      | select([.labels[]? | startswith("step:")] | any | not)
    ]
    | sort_by(.priority, .id)
    | .[]
    | "\(.id)\t\((.title // "") | tostring | gsub("[\\t\\n\\r]+"; " "))"
  '
}

# `new-work.sh beads --main DIR [--bd-json FILE]`
#
# The ready beads as picker rows. --bd-json reads a saved `bd ready --json`
# instead of asking the database.
cmd_beads() {
  local main='' fixture=''
  while [ $# -gt 0 ]; do
    case $1 in
      --main)
        [ $# -ge 2 ] || usage_error "beads: --main needs a directory"
        main=$2
        shift 2
        ;;
      --bd-json)
        [ $# -ge 2 ] || usage_error "beads: --bd-json needs a file"
        fixture=$2
        shift 2
        ;;
      *) usage_error "beads: unknown option $1" ;;
    esac
  done

  if [ -z "$main" ] && [ -z "$fixture" ]; then
    usage_error 'beads: need --main DIR (or --bd-json FILE)'
  fi
  command -v jq >/dev/null 2>&1 || die 'jq is required but was not found on PATH'

  # bd's own error above says what went wrong; this line says where, since the
  # directory is the half of it that a person can act on.
  local ready
  if ! ready=$(ready_json "$main" "$fixture"); then
    die "beads: could not read the ready beads from ${fixture:-$main}"
  fi

  printf '%s\n' "$ready" | pickable_rows
}

# `new-work.sh branch-default --type TYPE --id ID`
#
# The branch name the picker offers for a bead: the issue type picks the
# prefix and only the last dash-separated segment of the id is kept, so a bead
# reads as `bug/a4l` rather than `bug/pmm-iris-a4l`. Types outside the map get
# `feat`.
cmd_branch_default() {
  local type='' id=''

  while [ $# -gt 0 ]; do
    case $1 in
      --type)
        [ $# -ge 2 ] || usage_error 'branch-default: --type needs a value'
        type=$2
        shift 2
        ;;
      --id)
        [ $# -ge 2 ] || usage_error 'branch-default: --id needs a value'
        id=$2
        shift 2
        ;;
      *) usage_error "branch-default: unknown option $1" ;;
    esac
  done

  [ -n "$type" ] || usage_error 'branch-default: need --type TYPE'
  [ -n "$id" ] || usage_error 'branch-default: need --id ID'

  local prefix short
  case $type in
    bug) prefix=bug ;;
    chore) prefix=chore ;;
    spike) prefix=spike ;;
    feature | task) prefix=feat ;;
    *) prefix=feat ;;
  esac

  # Only the last dash-separated segment is kept, and an id that ends in a dash,
  # or is nothing but dashes, leaves no segment at all: "feat/" is not a ref, so
  # it is refused here rather than handed to worktrunk.
  short=${id##*-}
  [ -n "$short" ] || usage_error "branch-default: --id $id leaves no name to use"

  printf '%s/%s\n' "$prefix" "$short"
}

# Branch names out of `wt list --format=json`. Schema 2 puts the branch on the
# item (`items[].branch`) and some versions also repeat it inside the worktree
# object, so prefer the worktree copy and fall back to the item. A detached
# worktree reports no branch at all and is skipped.
wt_branches() {
  jq -r '
    ( if type == "array" then . else (.items // []) end )[]
    | (.worktree.branch? // .branch? // empty)
    | strings
  '
}

# The candidate branch names for --main, or for the given saved tool output.
# Worktree branches come first -- wt lists the main worktree at the top --
# then the local branches git knows about. One branch can be both, so the
# first sighting wins.
candidate_rows() {
  local main=$1 wt_json=$2 refs=$3
  local listing

  {
    if [ -n "$wt_json" ]; then
      wt_branches <"$wt_json"
    elif [ -n "$main" ]; then
      # A repository worktrunk cannot read still has branches git can name, so a
      # broken `wt` costs the picker its worktree rows, not the command. The loss
      # is said out loud, naming the directory: a branch left out of the list is
      # one the picker would offer to create rather than switch to.
      if listing=$( cd "$main" && wt list --format=json ); then
        printf '%s\n' "$listing" | wt_branches
      else
        printf '%s: could not read the worktrees of %s; only its git branches are listed\n' \
          "$PROG" "$main" >&2
      fi
    fi

    if [ -n "$refs" ]; then
      cat "$refs"
    elif [ -n "$main" ]; then
      ( cd "$main" && git for-each-ref refs/heads --format='%(refname:short)' )
    fi
  } | awk 'NF && !/\/HEAD$/ && !seen[$0]++'
}

# `new-work.sh candidates --main DIR [--wt-json FILE] [--refs FILE]`
#
# Every branch name that already exists, one per line, so the picker can
# offer "switch to this one" alongside "create that one". --wt-json and
# --refs swap the two sources for saved output, which is how the tests and
# dry runs work.
cmd_candidates() {
  local main='' wt_json='' refs=''

  while [ $# -gt 0 ]; do
    case $1 in
      --main)
        [ $# -ge 2 ] || usage_error 'candidates: --main needs a directory'
        main=$2
        shift 2
        ;;
      --wt-json)
        [ $# -ge 2 ] || usage_error 'candidates: --wt-json needs a file'
        wt_json=$2
        shift 2
        ;;
      --refs)
        [ $# -ge 2 ] || usage_error 'candidates: --refs needs a file'
        refs=$2
        shift 2
        ;;
      *) usage_error "candidates: unknown option $1" ;;
    esac
  done

  if [ -z "$main" ] && { [ -z "$wt_json" ] || [ -z "$refs" ]; }; then
    usage_error 'candidates: need --main DIR (or --wt-json FILE and --refs FILE)'
  fi
  # --main is where git and wt are read, so a directory that is not there is
  # refused here, by name: left to candidate_rows it reaches `cd` inside a
  # subshell, whose failure reads as a line number in this script rather than as
  # a place that does not exist. Only when one of those lookups will really be
  # made: with both fixtures the directory is never read.
  if [ -z "$wt_json" ] || [ -z "$refs" ]; then
    [ -d "$main" ] || die "candidates: no such directory: $main"
  fi
  command -v jq >/dev/null 2>&1 || die 'jq is required but was not found on PATH'

  candidate_rows "$main" "$wt_json" "$refs"
}

# The ref records `git for-each-ref` prints for refs/remotes and refs/heads, one
# per line: the fixture when one is given (tests and dry runs), else the lookup.
# A NUL cannot live in a shell variable, so it becomes the tab separating a
# record's two fields -- no refname and no symref target can contain one.
base_ref_records() {
  local main=$1 fixture=$2
  if [ -n "$fixture" ]; then
    tr '\0' '\t' <"$fixture"
  else
    ( cd "$main" && git for-each-ref --format='%(refname)%00%(symref)' \
        refs/remotes refs/heads ) | tr '\0' '\t'
  fi
}

# The base cycle for --main: one "ref<TAB>remote" row each, the answer the
# screen opens on first. One for-each-ref call settles every "does this ref
# exist" question, and it is answered by whole refnames, so refs/heads/main/topic
# cannot stand in for refs/heads/main. remote is the remote a ref lives on and
# is empty for everything else, and it is the ref record that says so rather
# than a slash in the name: feat/x is a local branch and nothing to fetch.
base_chain() {
  local main=$1 fixture=$2 base=$3 no_base=$4
  local records

  if ! records=$(base_ref_records "$main" "$fixture"); then
    die "bases: could not read the refs of ${fixture:-$main}"
  fi

  printf '%s\n' "$records" | awk -F'\t' -v base="$base" -v no_base="$no_base" '
    {
      # An empty line is what an empty record list prints, not a ref.
      if ($1 == "") next
      refs[$1] = 1
      symref[$1] = $2
      if ($1 ~ /^refs\/remotes\//) {
        short = $1
        sub(/^refs\/remotes\//, "", short)
        slash = index(short, "/")
        if (slash > 1) remote_of[short] = substr(short, 1, slash - 1)
      }
    }

    END {
      # The answer the screen opens on. --no-base is the worktrunk default and
      # --base names it outright, so neither asks the refs for one; otherwise
      # origin/HEAD -- the branch this clone says it is a clone of -- is asked
      # before any fixed name. Exact refname equality throughout, so a branch
      # named main/something is not main.
      if (no_base == "1") {
        open = ""
      } else if (base != "") {
        open = base
      } else if ("refs/remotes/origin/HEAD" in refs \
                 && symref["refs/remotes/origin/HEAD"] != "") {
        open = symref["refs/remotes/origin/HEAD"]
        sub(/^refs\/remotes\//, "", open)
      } else if ("refs/remotes/origin/main" in refs) {
        open = "origin/main"
      } else if ("refs/remotes/origin/master" in refs) {
        open = "origin/master"
      } else if ("refs/heads/main" in refs) {
        open = "main"
      } else if ("refs/heads/master" in refs) {
        open = "master"
      } else {
        open = "@"
      }

      # The cycle: the opening answer first, then @, then main and master once
      # this clone has them. @ is always offered -- it is what the branch
      # question did before there was a cycle -- and first sighting wins.
      n = 0
      cand[++n] = open
      cand[++n] = "@"
      if ("refs/heads/main" in refs) cand[++n] = "main"
      if ("refs/heads/master" in refs) cand[++n] = "master"

      for (i = 1; i <= n; i++) {
        if (cand[i] in seen) continue
        seen[cand[i]] = 1
        printf "%s\t%s\n", cand[i], ((cand[i] in remote_of) ? remote_of[cand[i]] : "")
      }
    }
  '
}

# `new-work.sh bases --main DIR [--base-refs FILE] [--base REF | --no-base]`
#
# The bases the branch question cycles through, the one it opens on first, as
# "ref<TAB>remote" rows. --base-refs reads a saved for-each-ref instead of
# asking the repository, which is how the tests and dry runs work.
cmd_bases() {
  local main='' base_refs='' base='' no_base=''

  while [ $# -gt 0 ]; do
    case $1 in
      --main)
        [ $# -ge 2 ] || usage_error 'bases: --main needs a directory'
        main=$2
        shift 2
        ;;
      --base-refs)
        [ $# -ge 2 ] || usage_error 'bases: --base-refs needs a file'
        base_refs=$2
        shift 2
        ;;
      --base)
        [ $# -ge 2 ] || usage_error 'bases: --base needs a value'
        base=$2
        shift 2
        ;;
      --no-base)
        no_base=1
        shift
        ;;
      *) usage_error "bases: unknown option $1" ;;
    esac
  done

  if [ -z "$main" ] && [ -z "$base_refs" ]; then
    usage_error 'bases: need --main DIR (or --base-refs FILE)'
  fi
  [ -z "$base" ] || [ -z "$no_base" ] ||
    usage_error 'bases: --base and --no-base answer the same question'
  # The refs are read from --main, so a directory that is not there is refused
  # here, by name: left to base_chain it reaches `cd` inside a subshell, whose
  # failure reads as a line number in this script rather than as a place that
  # does not exist. With --base-refs the directory is never read.
  if [ -z "$base_refs" ]; then
    [ -d "$main" ] || die "bases: no such directory: $main"
  fi

  base_chain "$main" "$base_refs" "$base" "$no_base"
}

# `new-work.sh preview ID --main DIR`
#
# One bead's full text, for the preview pane beside the bead list. `bd show`
# reads much better through bat, so use it when it is installed; the preview
# still works without it.
cmd_preview() {
  local id='' main=''

  while [ $# -gt 0 ]; do
    case $1 in
      --main)
        [ $# -ge 2 ] || usage_error 'preview: --main needs a directory'
        main=$2
        shift 2
        ;;
      -*)
        usage_error "preview: unknown option $1"
        ;;
      *)
        [ -z "$id" ] || usage_error "preview: unexpected argument $1"
        id=$1
        shift
        ;;
    esac
  done

  [ -n "$id" ] || usage_error 'preview: need ID'
  [ -n "$main" ] || usage_error 'preview: need --main DIR'

  # The prompt row is not a bead: picking it opens a prompt field, so its preview
  # says so rather than asking bd about an id that cannot exist.
  if [ "$id" = "$prompt_row_marker" ]; then
    printf 'Picking this row writes the prompt in a field of its own.\n\nText typed at the "%s" line that matches no bead is the prompt as well. esc starts the no-bead flow; ctrl-n starts the agent with nothing to say.\n' '> '
    return 0
  fi

  need bd

  if command -v bat >/dev/null 2>&1; then
    ( cd "$main" && bd show "$id" ) | bat --plain --language=markdown
  else
    ( cd "$main" && bd show "$id" )
  fi
}

# One shell word holding $1, quoted for a POSIX shell, so a printed dry run
# can be pasted back into a terminal unchanged.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The composer: the one screen's answers, kept in a directory of their own so a
# key can read and change one of them while fzf is up. fzf needs a terminal, so
# the screen itself is out of a pipe's reach; every verb below is a subcommand
# with one job, which is what lets the tests pin what each key does.
#
#   agent         the agent's name, empty for none
#   branch        the branch, empty until a bead or a key gives it one
#   branch_edited 1 once it was typed by hand, which stops it tracking the bead
#   bases         the base cycle, one "ref<TAB>remote" row each, the opening
#                 answer first, an empty ref for the worktrunk-default sentinel
#   base_index    which of those rows the screen is showing, 1-based
#   rows          the fzf rows: the prompt row, then the beads

# The second header line: every key that changes an answer, and the two ways out
# of the screen. Fixed, with two spaces between the pairs, so it reads as a
# legend rather than as prose.
composer_hints='ctrl-a agent  ctrl-b branch  ctrl-r base  ctrl-n blank  enter start  esc no bead'

# One answer from the state directory, and one answer into it. A file that is not
# there reads as an empty answer rather than as a failure: a key can fire before
# the picker has written every file, and a header missing a field is still a
# header.
state_get() {
  local file=$1/$2
  if [ -r "$file" ]; then
    cat "$file"
  fi
}

state_put() {
  printf '%s\n' "$3" >"$1/$2"
}

# How many entries a state file has, 0 when it is not there at all. awk's NR, not
# wc -l: a last line without a trailing newline is a whole entry, and counting it
# short would shorten the base cycle by one for a state written by hand.
state_lines() {
  local file=$1/$2
  if [ -r "$file" ]; then
    awk 'END { print NR }' "$file"
  else
    printf '0\n'
  fi
}

# What the last pick chose, remembered for the next one: one key=value file
# outside the configuration, because it is what happened rather than what was
# asked for. XDG's location, so a run can be pointed at a directory of its own
# and no test ever reads or writes the developer's real one.
state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-${HOME:-}/.local/state}/rex-config"
}

# The agent the screen opens on: the name the last pick wrote, when the list
# still offers it. A name the list no longer offers is ignored rather than
# shown -- ctrl-a could not step to it, so the header would be a field nothing
# can change -- and the caller falls back to the first name, the configured
# default. Every way the file can be wrong is silence: not there, not
# readable, no line for the key, a line with no value. None of them is worth a
# word on stderr, let alone a failed launch.
remembered_agent() { # NAMES: one offered name per line
  local names=$1 file name=''
  file=$(state_dir)/state
  [ -f "$file" ] && [ -r "$file" ] || return 0
  name=$(sed -n 's/^agent=//p' "$file" 2>/dev/null | sed -n 1p) || name=''
  [ -n "$name" ] || return 0
  printf '%s\n' "$names" | grep -Fxq -- "$name" || return 0
  printf '%s\n' "$name"
}

# And the answer back into it, tried before the hand-back so a hand-back Rex
# refuses still remembers the agent that was chosen. The file holds this one
# key, so it is written whole; a directory that cannot be made and a file that
# cannot be written are both discarded, because a launch is worth more than the
# memory of it.
remember_agent() { # NAME
  local dir file
  dir=$(state_dir) || return 0
  file=$dir/state
  mkdir -p "$dir" 2>/dev/null || return 0
  printf 'agent=%s\n' "$1" >"$file" 2>/dev/null || return 0
}

# The cycle entry the screen is showing, as the "ref<TAB>remote" line base_chain
# prints: field 1 the ref, field 2 the remote it lives on. Field 1 is empty for
# the worktrunk-default sentinel, which is a real answer and not a missing one.
# NO_BASE only matters when the state holds no cycle at all -- a screen opened by
# hand -- and is then what says which of the two the empty ref means. Nothing
# named and nothing said about it falls back to @, which is what base_chain
# itself settles on when no ref resolves.
composer_base_row() {
  local state=$1 no_base=${2:-0}
  local index row=''
  index=$(state_get "$state" base_index)
  case $index in
    '' | *[!0-9]*) index=1 ;;
  esac
  [ "$index" -ge 1 ] || index=1
  row=$(state_get "$state" bases | sed -n "${index}p")
  if [ -z "$row" ]; then
    if [ "$no_base" -eq 1 ]; then
      row=$'\t'
    else
      row="@"$'\t'
    fi
  fi
  printf '%s\n' "$row"
}

# The header, exactly two lines: the project with the three fields the keys
# change, then the legend. The leading space is part of both lines -- fzf indents
# the header anyway, and without a field of its own a blank one would swallow it.
# An empty agent reads "none" -- the cycle's no-agent answer -- and an empty base
# ref reads "wt default", so neither field is ever blank and neither lies about
# what the tab will do. A branch that nothing has given a name to yet -- no bead
# to derive one from, no ctrl-b -- reads "(none yet)" for the same reason: a blank
# field would print as a doubled space and read as a bug.
composer_header_lines() {
  local state=$1 project=$2 no_base=${3:-0}
  local agent branch base_row base_ref
  agent=$(state_get "$state" agent)
  branch=$(state_get "$state" branch)
  base_row=$(composer_base_row "$state" "$no_base")
  base_ref=${base_row%%$'\t'*}
  printf ' %s · agent: %s · branch: %s · base: %s\n' \
    "$project" "${agent:-none}" "${branch:-(none yet)}" "${base_ref:-wt default}"
  printf ' %s\n' "$composer_hints"
}

# ctrl-a: the next name on the agent list, then none, then round again, one name
# per line in NAMES. Only the header is repainted: the rows are beads and nothing
# about them depends on the agent, so a reload would clear the list and drop the
# cursor back to the top for a one-word change. The answer is written before the
# header is printed, because the header is all this prints.
composer_cycle_agent() {
  local state=$1 project=$2 names=$3
  local current='' next=''
  current=$(state_get "$state" agent)
  if [ -n "$names" ]; then
    next=$(printf '%s\n' "$names" | awk -v cur="$current" '
      { slot[NR] = $0 }
      END {
        n = NR
        at = n + 1              # none, when the agent is no name on the list
        for (i = 1; i <= n; i++) if (slot[i] == cur) at = i
        print slot[at % (n + 1) + 1]   # the next slot, wrapping to the first
      }')
  fi
  state_put "$state" agent "$next"
  composer_header_lines "$state" "$project"
}

# ctrl-r: the next base in the cycle, wrapping. The cycle was resolved once,
# before the screen opened -- one for-each-ref per picker run, not one per
# keystroke -- so this only moves an index. --main and the rest are here for a
# state that holds no cycle, which is a screen opened by hand: then the cycle is
# resolved the way bases resolves it, and only then.
composer_cycle_base() {
  local state=$1 project=$2 main=$3 base_refs=$4 base=$5 no_base=$6
  local total index next=1
  total=$(state_lines "$state" bases)
  if [ "$total" -eq 0 ] && { [ -n "$main" ] || [ -n "$base_refs" ]; }; then
    base_chain "$main" "$base_refs" "$base" "$no_base" >"$state/bases"
    total=$(state_lines "$state" bases)
  fi
  index=$(state_get "$state" base_index)
  case $index in
    '' | *[!0-9]*) index=1 ;;
  esac
  if [ "$total" -ge 1 ] && [ "$index" -lt "$total" ]; then
    next=$((index + 1))
  fi
  state_put "$state" base_index "$next"
  composer_header_lines "$state" "$project" "$no_base"
}

# The branch answer, trimmed. gum asks it in the float with PREFILL already in
# the field, so a bare Enter keeps it; off a terminal -- a pipe, a script, the
# tests -- the answer is read from stdin instead, because there is nobody to ask.
# A cancelled ask (ctrl-c, which gum exits non-zero on) and a pipe with nothing
# on it are both no answer at all: nothing is printed, and the caller decides
# what an empty answer means.
#
# Trimming is not cosmetic. A pasted name usually arrives with whitespace around
# it, whitespace is part of no branch name, and a trimmed space-then-Enter is
# Enter -- accepting the name already in the field rather than failing
# `git check-ref-format` on one that looks perfectly valid on screen.
ask_branch() {
  local prefill=$1 project=${2:-} answer=''
  if [ -t 0 ]; then
    local header='branch: Enter accepts the name shown'
    [ -z "$project" ] || header="$project · $header"
    if [ -n "$prefill" ]; then
      answer=$(gum input --value "$prefill" --header "$header") || answer=''
    else
      answer=$(gum input --header "$header") || answer=''
    fi
  else
    # Nothing is printed for a pipe: nobody is reading a prompt there, and it
    # would land in the middle of a script's output. read fails at EOF, which is
    # an empty answer rather than a reason to stop, so it must not end the run
    # here under `set -e`.
    IFS= read -r answer || true
  fi
  printf '%s' "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ctrl-b: the branch, typed by hand. The field opens on the branch the header is
# showing, and a cancelled field -- or an empty one -- leaves the branch exactly
# as it was and the pick carries on: the screen is not a sequence of questions
# any more, so backing out of one field does not cancel it. Nothing is printed;
# the header the binding repaints next is where the answer shows.
composer_branch_field() {
  local state=$1 project=${2:-}
  local answer=''
  answer=$(ask_branch "$(state_get "$state" branch)" "$project")
  [ -n "$answer" ] || return 0
  state_put "$state" branch "$answer"
  state_put "$state" branch_edited 1
}

# The one screen. fzf reads the rows from the state directory and every key runs
# a verb against that same directory, so a key changes one answer and the header
# that shows it.
#
# --print-query with --expect=ctrl-n is what makes every answer expressible: the
# query is the prompt, and ctrl-n is blank. The reply is fzf's own, in the order
# fzf prints it (query, key, row), and fzf_answer reads it -- reading the key off
# the wrong line is the bug --expect exists to prevent.
#
# No binding reloads the list. The rows are beads, and nothing a key changes adds
# or removes one, so a reload would clear and repaint the list and reset the
# cursor: a change of one field costing the gesture the screen exists for. ctrl-b
# is the exception the terminal forces -- gum suspends fzf to take it -- and even
# there only the header is repainted: the query and every other answer stay as
# they were.
#
# The cursor starts on row 2, the bead the list leads with, so a bare Enter takes
# it; row 1 is the prompt row, and with no beads it is the only row and fzf keeps
# the cursor there. That is the load event's pos(1-based number), not --cursor:
# this fzf has no such flag, and the start event fires before the list exists.
# The preview is refreshed in the same breath because it renders against the row
# the cursor started on, and would otherwise describe the prompt row until the
# first keypress. The pane is a bottom one rather than a right-hand split: at the
# real float size (80x24) a side split leaves about 36 columns for the list, which
# truncates every bead title, and about 42 for the preview, which cuts prose
# mid-word. A bottom pane is full width for both, and the preview wraps.
#
# Every path is quoted for a shell, because a shell is what fzf runs a binding
# through, and the script's own path is absolute because fzf runs them in the
# project's directory rather than this one.
composer_screen() {
  local state=$1 main=$2 project=$3 base=$4 base_refs=$5 no_base=$6 names=$7
  local self script main_q state_q project_q
  local base_q='' base_refs_q='' no_base_q='' agents_q='' name
  self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  script=$(printf '%q' "$self")
  main_q=$(printf '%q' "$main")
  state_q=$(printf '%q' "$state")
  project_q=$(printf '%q' "$project")
  [ -z "$base" ] || base_q=" --base $(printf '%q' "$base")"
  [ -z "$base_refs" ] || base_refs_q=" --base-refs $(printf '%q' "$base_refs")"
  [ "$no_base" -eq 0 ] || no_base_q=' --no-base'
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    agents_q=$agents_q" --agents $(printf '%q' "$name")"
  done < <(printf '%s\n' "$names")

  "$self" composer rows --state "$state" |
    fzf --delimiter='\t' \
      --with-nth=1,2 \
      --print-query \
      --expect=ctrl-n \
      --reverse \
      --prompt ' ❯ prompt or bead> ' \
      --pointer '▌' \
      --marker '✓' \
      --header "$(composer_header_lines "$state" "$project" "$no_base")" \
      --preview-window 'down,55%' \
      --preview "$script preview {1} --main $main_q" \
      --bind 'load:pos(2)+refresh-preview' \
      --bind "ctrl-a:transform-header($script composer cycle-agent --state $state_q --project $project_q$agents_q)" \
      --bind "ctrl-b:execute($script composer branch-field --state $state_q --project $project_q)+transform-header($script composer header --state $state_q --project $project_q$no_base_q)+refresh-preview" \
      --bind "ctrl-r:transform-header($script composer cycle-base --state $state_q --project $project_q --main $main_q$base_refs_q$base_q$no_base_q)"
}

# `new-work.sh composer <verb> --state DIR [...]`
#
# The screen's own subcommands, dispatched here the way the script's are at the
# bottom: the state directory is the only thing all five share.
cmd_composer() {
  case ${1:-} in
    rows)
      shift
      cmd_composer_rows "$@"
      ;;
    header)
      shift
      cmd_composer_header "$@"
      ;;
    cycle-agent)
      shift
      cmd_composer_cycle_agent "$@"
      ;;
    cycle-base)
      shift
      cmd_composer_cycle_base "$@"
      ;;
    branch-field)
      shift
      cmd_composer_branch_field "$@"
      ;;
    *) usage_error "composer: unknown command ${1:-<none>}" ;;
  esac
}

# The rows fzf is given, as they are.
cmd_composer_rows() {
  local state=''
  while [ $# -gt 0 ]; do
    case $1 in
      --state)
        [ $# -ge 2 ] || usage_error 'composer rows: --state needs a directory'
        state=$2
        shift 2
        ;;
      *) usage_error "composer rows: unknown option $1" ;;
    esac
  done
  [ -n "$state" ] || usage_error 'composer rows: need --state DIR'
  # A screen whose rows were never written is an empty list rather than a
  # failure: the list is the one thing there is nothing to do about from here.
  if [ -r "$state/rows" ]; then
    cat "$state/rows"
  fi
}

# The two header lines, as the screen shows them.
cmd_composer_header() {
  local state='' project='' no_base=0
  while [ $# -gt 0 ]; do
    case $1 in
      --state)
        [ $# -ge 2 ] || usage_error 'composer header: --state needs a directory'
        state=$2
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] || usage_error 'composer header: --project needs a name'
        project=$2
        shift 2
        ;;
      --no-base)
        no_base=1
        shift
        ;;
      *) usage_error "composer header: unknown option $1" ;;
    esac
  done
  [ -n "$state" ] || usage_error 'composer header: need --state DIR'
  [ -n "$project" ] || usage_error 'composer header: need --project NAME'
  composer_header_lines "$state" "$project" "$no_base"
}

# The header again, after the agent moved on.
cmd_composer_cycle_agent() {
  local state='' project='' names=''
  while [ $# -gt 0 ]; do
    case $1 in
      --state)
        [ $# -ge 2 ] ||
          usage_error 'composer cycle-agent: --state needs a directory'
        state=$2
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] ||
          usage_error 'composer cycle-agent: --project needs a name'
        project=$2
        shift 2
        ;;
      --agents)
        [ $# -ge 2 ] && [ -n "$2" ] ||
          usage_error 'composer cycle-agent: --agents needs a name'
        names=${names:+$names$'\n'}$2
        shift 2
        ;;
      *) usage_error "composer cycle-agent: unknown option $1" ;;
    esac
  done
  [ -n "$state" ] || usage_error 'composer cycle-agent: need --state DIR'
  [ -n "$project" ] || usage_error 'composer cycle-agent: need --project NAME'
  composer_cycle_agent "$state" "$project" "$names"
}

# The header again, after the base moved on.
cmd_composer_cycle_base() {
  local state='' project='' main='' base_refs='' base='' no_base=0
  while [ $# -gt 0 ]; do
    case $1 in
      --state)
        [ $# -ge 2 ] ||
          usage_error 'composer cycle-base: --state needs a directory'
        state=$2
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] ||
          usage_error 'composer cycle-base: --project needs a name'
        project=$2
        shift 2
        ;;
      --main)
        [ $# -ge 2 ] || usage_error 'composer cycle-base: --main needs a directory'
        main=$2
        shift 2
        ;;
      --base-refs)
        [ $# -ge 2 ] || usage_error 'composer cycle-base: --base-refs needs a file'
        base_refs=$2
        shift 2
        ;;
      --base)
        [ $# -ge 2 ] || usage_error 'composer cycle-base: --base needs a value'
        base=$2
        shift 2
        ;;
      --no-base)
        no_base=1
        shift
        ;;
      *) usage_error "composer cycle-base: unknown option $1" ;;
    esac
  done
  [ -n "$state" ] || usage_error 'composer cycle-base: need --state DIR'
  [ -n "$project" ] || usage_error 'composer cycle-base: need --project NAME'
  [ -n "$main" ] || usage_error 'composer cycle-base: need --main DIR'
  [ -z "$base" ] || [ "$no_base" -eq 0 ] ||
    usage_error 'composer cycle-base: --base and --no-base answer the same question'
  composer_cycle_base "$state" "$project" "$main" "$base_refs" "$base" "$no_base"
}

# The branch field: it writes an answer and prints none.
cmd_composer_branch_field() {
  local state='' project=''
  while [ $# -gt 0 ]; do
    case $1 in
      --state)
        [ $# -ge 2 ] ||
          usage_error 'composer branch-field: --state needs a directory'
        state=$2
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] ||
          usage_error 'composer branch-field: --project needs a name'
        project=$2
        shift 2
        ;;
      *) usage_error "composer branch-field: unknown option $1" ;;
    esac
  done
  [ -n "$state" ] || usage_error 'composer branch-field: need --state DIR'
  composer_branch_field "$state" "$project"
}

# What fzf's reply to the bead question means, as one "id<TAB>prompt<TAB>blank"
# row. fzf prints the query first and then -- with --expect, which is how ctrl-n
# is heard at all -- the key that was pressed on a line of its own, whether or
# not a row was selected, that line empty when no key was pressed. So:
#
#   0, query, <key>, row   a row was selected; the key line wins over it
#   1, query, <key>       nothing matched, so the text typed is the prompt
#   130                    esc or ctrl-c: no bead, no prompt -- the no-bead flow
#
# ctrl-n is the blank answer -- an agent, and nothing to say -- so it is no bead
# and no prompt whatever the row under the cursor said. A reply with no key line
# at all, or one whose key line is empty, is "no key pressed": the reader takes
# up to three lines and decides on what it finds rather than on how many lines
# arrived, so a shorter reply is an answer, never an error.
#
# The selected row's id is field 1 of the row, and the prompt row's marker is
# what tells a prompt from a bead. All three fields are printed with the tab
# between them, empty where there is no answer, so the caller never counts
# lines. Any other status is fzf failing rather than answering, and is reported
# as such: a picker that could not run is not a decision to start no work.
fzf_answer() {
  local status=$1 query='' key='' row=''
  case $status in
    0)
      IFS= read -r query || true
      IFS= read -r key || true
      IFS= read -r row || true
      if [ "$key" = ctrl-n ]; then
        printf '\t\t1\n'
      elif [ -z "$row" ]; then
        # A query with no row under it is the same answer status 1 gives: fzf's
        # own options can make it exit 0 on a query that matched nothing
        # (--exit-0 is the common one), and the text typed then is still the
        # prompt rather than something to throw away.
        printf '\t%s\t\n' "$query"
      else
        printf '%s\t\t\n' "${row%%$'\t'*}"
      fi
      ;;
    1)
      # Nothing matched, so there is no row to read: the query and the key line
      # are what fzf printed, and either of them can be the last line there is.
      IFS= read -r query || true
      IFS= read -r key || true
      if [ "$key" = ctrl-n ]; then
        printf '\t\t1\n'
      else
        printf '\t%s\t\n' "$query"
      fi
      ;;
    130)
      printf '\t\t\n'
      ;;
    *)
      printf '%s: the bead picker failed (fzf exit %s)\n' "$PROG" "$status" >&2
      return 1
      ;;
  esac
}

# `new-work.sh fzf-answer STATUS` (fzf's reply on stdin)
#
# That reading, as a subcommand of its own: fzf needs a terminal and cannot be
# driven from a pipe, so this is the one part of the bead question a test can
# drive -- the four answers are pinned against the bytes fzf really produces.
cmd_fzf_answer() {
  [ $# -eq 1 ] || usage_error 'fzf-answer: need the status fzf exited with'
  case $1 in
    '' | *[!0-9]*) usage_error "fzf-answer: $1 is not an exit status" ;;
  esac
  fzf_answer "$1"
}

# The shortcuts `wt switch` resolves itself -- ^ the default branch, - the previous
# worktree, @ the current one, pr:N and mr:N the branch of a pull or merge
# request -- are answers rather than names to create: they are neither refs that
# could be made nor names `git check-ref-format` accepts, and worktrunk is the one
# that knows what they mean.
is_wt_shortcut() {
  case $1 in
    '^' | '-' | '@') return 0 ;;
    pr:* | mr:*)
      case ${1#*:} in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Whether worktrunk could create a branch with this name.
# `git check-ref-format --branch` is the test, with one twist: it *expands* a
# name like @{-1} and prints what that resolved to, so only an answer equal to
# the input means the input itself is a branch name. Without the comparison the
# literal @{-1} would pass the check and be created as a branch so named.
valid_branch_name() {
  local resolved
  resolved=$(git check-ref-format --branch "$1" 2>/dev/null) || return 1
  [ "$resolved" = "$1" ]
}

# The branch name READY's bead ID derives, or nothing: a bead the list did not
# describe still gets a name (types outside the map fall back to feat, as the map
# itself does), and an id no name can be built from -- one ending in a dash -- is
# no reason to stop the pick with a usage dump. The issue type is read from the
# ready list rather than from a row, so a row is never parsed for it.
branch_for_bead() {
  local ready=$1 id=$2 type=''
  [ -n "$id" ] || return 0
  type=$(printf '%s\n' "$ready" | jq -r --arg id "$id" \
    '([.[] | select(.id == $id)][0].issue_type) // ""') || type=''
  # In a subshell of its own: cmd_branch_default answers a name it cannot build
  # with a usage error, and that error is a status to ignore here -- the bead
  # simply offers nothing -- not one that ends the pick.
  (cmd_branch_default --type "${type:-other}" --id "$id" 2>/dev/null) || true
}

# `new-work.sh pick --main DIR --root PATH --project NAME`
#       `[--base REF | --no-base] [--base-refs FILE]`
#       `[--bead ID | --prompt TEXT | --blank] [--agents NAME]...`
#       `[--agent NAME] [--branch NAME] [--dry-run]`
#
# The three questions behind ctrl+space>n: which bead (or prompt), which agent,
# then which branch. The answer goes back to Rex as one JSON object, built by jq
# so no value is ever interpolated into a command line. --bead, --prompt,
# --blank, --agent and --branch answer a question without asking it, which is how
# the tests and scripts drive the picker: --blank is ctrl-n's blank answer -- an
# agent, and nothing to say -- which a pipe cannot press for itself. --base,
# --no-base and --base-refs answer the base the branch question opens on, which
# the payload carries to the tab.
cmd_pick() {
  local main='' root='' project='' base='' bead='' branch=''
  local prompt='' agent='' agent_choices=''
  local bead_set=0 prompt_set=0 agent_set=0 branch_set=0 dry_run=0 no_base=0
  local blank_set=0
  local bd_json='' wt_json='' refs='' base_refs=''

  while [ $# -gt 0 ]; do
    case $1 in
      --main)
        [ $# -ge 2 ] || usage_error 'pick: --main needs a directory'
        main=$2
        shift 2
        ;;
      --root)
        [ $# -ge 2 ] || usage_error 'pick: --root needs a path'
        root=$2
        shift 2
        ;;
      --project)
        [ $# -ge 2 ] || usage_error 'pick: --project needs a name'
        project=$2
        shift 2
        ;;
      --base)
        [ $# -ge 2 ] || usage_error 'pick: --base needs a value'
        base=$2
        shift 2
        ;;
      --no-base)
        no_base=1
        shift
        ;;
      --bead)
        [ $# -ge 2 ] || usage_error 'pick: --bead needs an id'
        bead=$2
        bead_set=1
        shift 2
        ;;
      --prompt)
        [ $# -ge 2 ] || usage_error 'pick: --prompt needs a value'
        prompt=$2
        prompt_set=1
        shift 2
        ;;
      # ctrl-n, as a word: the blank answer is the one fzf can only be given by
      # a keystroke, so a script -- and the test that pins the payload -- needs a
      # way to say it. It answers the bead question, so it takes no value.
      --blank)
        blank_set=1
        shift
        ;;
      # One --agents per name, in the order the agent question should offer
      # them: the first is the one an unasked question takes.
      --agents)
        [ $# -ge 2 ] && [ -n "$2" ] || usage_error 'pick: --agents needs a name'
        agent_choices=${agent_choices:+$agent_choices$'\n'}$2
        shift 2
        ;;
      --agent)
        [ $# -ge 2 ] || usage_error 'pick: --agent needs a name'
        agent=$2
        agent_set=1
        shift 2
        ;;
      --branch)
        [ $# -ge 2 ] || usage_error 'pick: --branch needs a name'
        branch=$2
        branch_set=1
        shift 2
        ;;
      --bd-json)
        [ $# -ge 2 ] || usage_error 'pick: --bd-json needs a file'
        bd_json=$2
        shift 2
        ;;
      --wt-json)
        [ $# -ge 2 ] || usage_error 'pick: --wt-json needs a file'
        wt_json=$2
        shift 2
        ;;
      --refs)
        [ $# -ge 2 ] || usage_error 'pick: --refs needs a file'
        refs=$2
        shift 2
        ;;
      --base-refs)
        [ $# -ge 2 ] || usage_error 'pick: --base-refs needs a file'
        base_refs=$2
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *) usage_error "pick: unknown option $1" ;;
    esac
  done

  [ -n "$main" ] || usage_error 'pick: need --main DIR'
  [ -n "$root" ] || usage_error 'pick: need --root PATH'
  [ -n "$project" ] || usage_error 'pick: need --project NAME'

  # A bead and a prompt are two answers to the same question, so both at once is
  # a script that cannot mean what it says: the tab would carry a bead's prompt
  # and a prompt of its own.
  if [ "$bead_set" -eq 1 ] && [ "$prompt_set" -eq 1 ]; then
    usage_error 'pick: --bead and --prompt answer the same question'
  fi

  # Blank answers that same question -- "which work, and what is said to the
  # agent" -- so any two of the three at once is a script that cannot mean what
  # it says: blank is the answer "no bead, and nothing to say", which a bead or
  # a prompt contradicts.
  if [ "$blank_set" -eq 1 ] &&
    { [ "$bead_set" -eq 1 ] || [ "$prompt_set" -eq 1 ]; }; then
    usage_error 'pick: --blank and --bead/--prompt answer the same question'
  fi

  # A base and no base answer one question too, as they do for bases.
  [ -z "$base" ] || [ "$no_base" -eq 0 ] ||
    usage_error 'pick: --base and --no-base answer the same question'

  # The hand-back's paths are read by the Rex server, whose working directory is
  # not this one, so they have to say where they are. The Lua side derives both
  # from git and they are always absolute; this is the guard for a hand-run.
  need_absolute 'pick: --main' "$main"
  need_absolute 'pick: --root' "$root"

  # --main is where bd, wt and git are read, so a directory that is not there is
  # refused here, by name: left to the pipelines below it reaches `cd` inside a
  # subshell, whose failure reads as a line number in this script rather than as a
  # place that does not exist. Only when one of those lookups will really be made:
  # a run given all four fixtures never touches --main.
  if [ -z "$bd_json" ] || [ -z "$wt_json" ] || [ -z "$refs" ] ||
    { [ -z "$base_refs" ] && [ "$no_base" -eq 0 ]; }; then
    [ -d "$main" ] || die "pick: no such directory: $main"
  fi

  # The screen's own requirements, before any work, and only where the screen
  # will really open -- in the float, where stdin is a terminal -- so a scripted
  # run is not stopped by a tool it would never call: off a terminal nothing is
  # asked, the bead question is skipped, the agent falls back to the first name
  # and the branch reads stdin. Saved tool output stands in for the tools it
  # replaces.
  if [ -t 0 ] && [ "$bead_set" -eq 0 ] && [ "$prompt_set" -eq 0 ] &&
    [ "$blank_set" -eq 0 ]; then
    # fzf is the screen and gum is every field it opens: the prompt row's and
    # ctrl-b's.
    need fzf
    need gum
  fi
  [ -n "$wt_json" ] || need wt
  need jq
  [ -n "$bd_json" ] || need bd
  # check-ref-format keeps an uncreatable name out of the new tab and
  # for-each-ref is the branch list, so git is not optional either: without it
  # every name would come back "not a valid branch name".
  need git

  local ready rows
  if ! ready=$(ready_json "$main" "$bd_json"); then
    die "pick: could not read the ready beads from ${bd_json:-$main}"
  fi
  if ! rows=$(printf '%s\n' "$ready" | pickable_rows); then
    die "pick: could not read the bead list from ${bd_json:-$main}"
  fi

  # The agent the screen opens on: the one this picker chose last, when the
  # list still offers it, and the list's first name -- the configured default --
  # otherwise. Read once, here, because both ways into the screen use it: the
  # header's field in the float and the answer an unasked question takes off a
  # terminal, which have to agree or the tab would start an agent the header
  # never showed.
  local agent_seed=''
  if [ -n "$agent_choices" ]; then
    agent_seed=$(remembered_agent "$agent_choices")
    [ -n "$agent_seed" ] ||
      agent_seed=$(printf '%s\n' "$agent_choices" | sed -n 1p)
  fi

  local note=''
  # The screen's state, made here so its keys have somewhere to write while it is
  # up: one directory per run, removed by hold_pick on the way out, so a killed
  # float leaves nothing behind and two picker runs cannot collide. Only the float
  # gets one -- off a terminal nothing is asked, and a scripted run keeps the
  # tools it was promised and no temporary directory of its own.
  if [ -t 0 ]; then
    composer_state=$(mktemp -d) || die 'pick: could not make a state directory'
    # The agent list leads with its default, or with the name the last pick
    # chose, which is what the header opens on; no list at all is no agent
    # answer, and the payload then says nothing about the agent.
    state_put "$composer_state" agent "$agent_seed"
    # The branch the screen opens on. --branch is an answer already, and one
    # given by hand, so the header shows it and nothing derives it again.
    # Otherwise it is the first pickable row's name: load:pos(2) lands the cursor
    # on that bead, so a bare Enter creates exactly the branch the header is
    # showing, and the header never reads as a blank field on the way in. A bead
    # picked lower down derives its own name at hand-back, which wins.
    if [ "$branch_set" -eq 1 ]; then
      state_put "$composer_state" branch "$branch"
      state_put "$composer_state" branch_edited 1
    else
      state_put "$composer_state" branch \
        "$(branch_for_bead "$ready" \
          "$(printf '%s\n' "$rows" | sed -n 1p | cut -f1)")"
    fi
    # The base cycle, resolved once for the whole run: one for-each-ref here, and
    # ctrl-r only ever moves the index into it.
    base_chain "$main" "$base_refs" "$base" "$no_base" >"$composer_state/bases"
    state_put "$composer_state" base_index 1
    {
      printf '%s\n' "$prompt_row"
      [ -z "$rows" ] || printf '%s\n' "$rows"
    } >"$composer_state/rows"
  fi

  # The bead question is asked only when it was not answered already: a bead, a
  # prompt and a blank answer are all answers to it.
  if [ "$bead_set" -eq 0 ] && [ "$prompt_set" -eq 0 ] &&
    [ "$blank_set" -eq 0 ]; then
    if [ -z "$rows" ]; then
      # Nothing to offer: say so, and let the branch question carry the note --
      # the prompt row is still worth asking, but a list with no beads in it is
      # not the reason to keep quiet about.
      note='no ready beads'
    fi
    if [ ! -t 0 ]; then
      # A pipe or a script, never the Rex float: asking would wait forever, so
      # take no bead and move on with the branch instead.
      printf '%s: skipping the bead question: stdin is not a terminal\n' \
        "$PROG" >&2
    else
      local reply='' asked=0 answer=''
      reply=$(composer_screen "$composer_state" "$main" "$project" "$base" \
        "$base_refs" "$no_base" "$agent_choices") || asked=$?
      if ! answer=$(printf '%s\n' "$reply" | fzf_answer "$asked"); then
        exit 1
      fi
      # Field 1 is the row's id -- the prompt row's marker when that row was
      # picked -- field 2 the text typed when nothing matched, and field 3 the
      # blank flag. Only one of the first two can be non-empty, and the fields
      # are read from the answer's end so a prompt holding a tab of its own
      # keeps it: the flag is what follows the last tab, and what is left holds
      # the other two.
      if [ "${answer##*$'\t'}" = 1 ]; then
        blank_set=1
      fi
      answer=${answer%$'\t'*}
      bead=${answer%%$'\t'*}
      prompt=${answer#*$'\t'}
      if [ "$blank_set" -eq 1 ]; then
        # ctrl-n is the answer "an agent, and nothing to say": no bead -- the
        # row under the cursor is not it, whatever the key line printed above
        # -- and no prompt, so the field the prompt row would open is never
        # opened at all.
        bead=''
        prompt=''
      elif [ "$bead" = "$prompt_row_marker" ]; then
        # The prompt row hands over to a field of its own: fzf's query line is
        # one line long, with no room to see what is being typed into it.
        bead=''
        if ! prompt=$(gum input --header 'prompt for the agent'); then
          printf '%s: no prompt given, nothing to start\n' "$PROG" >&2
          exit "$cancelled"
        fi
      fi
      # Only text that was really typed is an answer: an empty one leaves the
      # configured no-bead prompt to speak, which is what a blank first question
      # has always meant.
      if [ -n "$prompt" ]; then
        prompt_set=1
      fi
    fi
  fi

  # A prompt with nothing in it but spaces is no prompt at all: a stray space
  # before Enter produces one, and sending it would replace the configured
  # no-bead prompt with whitespace. It is read as the empty answer it is -- and
  # one that was given with --prompt stays an answered question, the way
  # --agent '' is an answered agent question, because "no prompt" and "the picker
  # was never asked" are different answers.
  case $prompt in
    '') ;;
    *[![:space:]]*) prompt_set=1 ;;
    *) prompt='' ;;
  esac

  # The title is read from the ready list rather than from the row, so quotes
  # and whitespace arrive as the database has them. Only whitespace is
  # touched: it would break the one-line JSON this has to fit in.
  local title=''
  if [ -n "$bead" ]; then
    if ! printf '%s\n' "$rows" | cut -f1 | grep -Fxq -- "$bead"; then
      # It can still have a title: a gate, a molecule or a step is filtered out
      # of the picker but present in the database.
      printf '%s: %s is not on the pickable list\n' "$PROG" "$bead" >&2
    fi
    # A title that is not a string is stringified first, as in pickable_rows:
    # gsub cannot match a number.
    title=$(printf '%s\n' "$ready" | jq -r --arg id "$bead" '
          (([.[] | select(.id == $id)][0].title) // "")
          | tostring | gsub("[\\t\\n\\r]+"; " ")')
  fi

  # The agent is the header's: ctrl-a cycles it through the list and then none, so
  # there is no second question after the screen to ask. Off a terminal nobody can
  # press a key, and the answer is the seed the header would have opened on --
  # the remembered name, or the list's first -- which is what an unasked question
  # has always taken.
  if [ "$agent_set" -eq 0 ] && [ -n "$agent_choices" ]; then
    if [ -n "$composer_state" ]; then
      agent=$(state_get "$composer_state" agent)
    else
      agent=$agent_seed
    fi
    agent_set=1
  fi

  local candidates
  if ! candidates=$(candidate_rows "$main" "$wt_json" "$refs"); then
    die "pick: could not list the branches of $main"
  fi

  # The screen's branch wins over --branch when it was edited: what the header
  # showed while the pick was being made is what gets handed back, or the float
  # would promise one branch and the tab create another.
  if [ -n "$composer_state" ] &&
    [ "$(state_get "$composer_state" branch_edited)" = 1 ]; then
    branch=$(state_get "$composer_state" branch)
    branch_set=1
  fi

  if [ "$branch_set" -eq 0 ]; then
    local suggestion=''
    if [ -n "$bead" ]; then
      suggestion=$(branch_for_bead "$ready" "$bead")
    fi
    # Told before the prompt rather than packed into it, so the prompt stays one
    # short line whatever the reason for asking.
    if [ -n "$note" ]; then
      printf '%s: %s\n' "$PROG" "$note" >&2
    fi
    if [ -n "$composer_state" ]; then
      # The screen had its chance and the branch was not edited, so it is the one
      # this bead derives -- the name the field would have opened on.
      branch=$suggestion
      # A bead-less answer -- text that matched no bead, or the prompt row --
      # has no bead to derive a name from, so it is asked the branch question in
      # the field that question has always been asked in, opened on whatever the
      # header holds: Enter accepts that name, and anything typed replaces it.
      # Only this path pays for the field. A bead carries its own name, --branch
      # and ctrl-b are answers given before the pick is handed back, and a run
      # off a terminal reads its line of stdin as it always has.
      #
      # Blank is the exception, and stays the cancelled pick it is today: it is
      # the answer "an agent, and nothing to say", and a run with nothing to say
      # has never been asked for a branch. An empty or cancelled field is no
      # answer either, and falls through to the exit below rather than quietly
      # taking the seed the field was opened on.
      if [ -z "$bead" ] && [ "$blank_set" -eq 0 ]; then
        branch=$(ask_branch "$(state_get "$composer_state" branch)" \
          "$project")
      fi
    else
      # Nobody to ask: the answer is a line of stdin, and an empty one is the
      # suggestion accepted -- which is what a bare Enter means in the float.
      branch=$(ask_branch "$suggestion" '')
      [ -n "$branch" ] || branch=$suggestion
    fi
  elif [ -n "$note" ]; then
    printf '%s\n' "$note" >&2
  fi

  if [ -z "$branch" ]; then
    printf '%s: no branch given, nothing to start\n' "$PROG" >&2
    exit "$cancelled"
  fi

  # An exact match is a worktree that already exists: switch to it. So is a
  # worktrunk shortcut -- worktrunk resolves what ^, -, @, pr:N and mr:N mean --
  # and neither is a name to check or a ref to create. Anything else is a name to
  # create, even when it looks like something on the list.
  local create=true
  if is_wt_shortcut "$branch" ||
    printf '%s\n' "$candidates" | grep -Fxq -- "$branch"; then
    create=false
  fi

  # A name to create has to be one worktrunk can actually create: better to say
  # so here, where the float is still on screen, than in the new tab's output.
  if [ "$create" = true ] && ! valid_branch_name "$branch"; then
    printf '%s: not a valid branch name: %s\n' "$PROG" "$branch" >&2
    exit 2
  fi

  # The base the tab creates from: it travels in the payload with the remote it
  # lives on so the tab can fetch that one, and nothing is said about it on stderr,
  # where the announcement used to be. On the screen it is ctrl-r's answer, the
  # cycle entry the base_index points at; off a terminal it is the cycle's first
  # row, which is what `bases` prints first -- --base names it outright, whatever
  # this clone would have opened on, and --no-base is the worktrunk default, no
  # ref at all. The remote comes from the row rather than from a slash in the name,
  # because feat/x is a local branch and nothing to fetch.
  local base_ref='' base_remote='' base_default=0 base_row=''
  if [ -n "$composer_state" ]; then
    base_row=$(composer_base_row "$composer_state" "$no_base")
    base_ref=${base_row%%$'\t'*}
    base_remote=${base_row#*$'\t'}
    [ -n "$base_ref" ] || base_default=1
  elif [ "$no_base" -eq 1 ]; then
    base_default=1
  else
    base_row=$(base_chain "$main" "$base_refs" "$base" '' | sed -n 1p)
    base_ref=${base:-${base_row%%$'\t'*}}
    base_remote=${base_row#*$'\t'}
  fi

  # prompt and agent travel only when they were answered: an absent prompt leaves
  # the plugin's own template to say what the flow is, and an absent agent is one
  # the plugin still knows better than the picker does. A blank answer is neither
  # of those: it says "an agent, and nothing to say", so it carries the blank
  # flag and no prompt at all -- which is how the tab knows to send the agent no
  # prompt word rather than the configured template.
  local payload
  payload=$(jq -cn \
    --arg project "$project" \
    --arg root "$root" \
    --arg main "$main" \
    --arg branch "$branch" \
    --arg bead "$bead" \
    --arg title "$title" \
    --argjson create "$create" \
    --arg base "$base_ref" \
    --arg base_remote "$base_remote" \
    --argjson base_default "$base_default" \
    --arg prompt "$prompt" \
    --argjson prompt_set "$prompt_set" \
    --argjson blank_set "$blank_set" \
    --arg agent "$agent" \
    --argjson agent_set "$agent_set" \
    '{project: $project, root: $root, main: $main, branch: $branch,
      bead: $bead, title: $title, create: $create,
      base: (if $base_default == 1 then false else $base end)}
     + (if $base_remote == "" then {} else {base_remote: $base_remote} end)
     + (if $prompt_set == 1 then {prompt: $prompt} else {} end)
     + (if $blank_set == 1 then {blank: true} else {} end)
     + (if $agent_set == 1 then {agent: $agent} else {} end)')

  if [ "$dry_run" -eq 1 ]; then
    printf 'rex do work_new_go --args %s\n' "$(shell_quote "$payload")"
    return 0
  fi

  # What this pick chose is remembered here, before the hand-back rather than
  # after it: a hand-back Rex refuses still chose an agent, and the next screen
  # should open on it. Only an agent the picker has an answer for is written --
  # a run with no agent list answered nothing -- and the write cannot fail the
  # launch.
  if [ "$agent_set" -eq 1 ]; then
    remember_agent "$agent"
  fi

  # The hand-back is the last thing that can fail here, and the one failure that
  # used to leave nothing on screen: rex prints why it refused on this terminal,
  # and a line of ours says the hand-back did not finish even when rex says
  # nothing at all. hold_pick keeps it there while the float still exists.
  local handed=0
  rex do work_new_go --args "$payload" || handed=$?
  if [ "$handed" -ne 0 ]; then
    die "Rex could not finish the hand-back: rex exited $handed"
  fi
}

case ${1:-} in
  beads)
    shift
    cmd_beads "$@"
    ;;
  branch-default)
    shift
    cmd_branch_default "$@"
    ;;
  candidates)
    shift
    cmd_candidates "$@"
    ;;
  bases)
    shift
    cmd_bases "$@"
    ;;
  preview)
    shift
    cmd_preview "$@"
    ;;
  fzf-answer)
    shift
    cmd_fzf_answer "$@"
    ;;
  composer)
    shift
    cmd_composer "$@"
    ;;
  pick)
    shift
    # Every way the picker can stop passes through here on its way out, so the
    # pause that keeps its message on screen is taken in one place.
    trap hold_pick EXIT
    cmd_pick "$@"
    ;;
  *)
    usage_error "unknown command ${1:-<none>}"
    ;;
esac
