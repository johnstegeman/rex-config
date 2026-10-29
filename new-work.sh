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
      print the bases the branch question opens on and cycles through, one
      "ref<TAB>remote" row each, the opening answer first; an empty ref means
      no --base at all, which leaves it to worktrunk
  fzf-answer STATUS
      read fzf's --print-query --expect reply on stdin and print what it means
      as one "bead<TAB>prompt<TAB>blank" row, empty where there is no answer;
      STATUS is the status fzf exited with
  pick --main DIR --root PATH --project NAME [--base REF | --no-base]
       [--base-refs FILE] [--bead ID | --prompt TEXT | --blank]
       [--agents NAME]... [--agent NAME] [--branch NAME] [--dry-run]
      ask which bead (or prompt), which agent, and which branch, and hand the
      answer to Rex as one JSON object, with the base a new branch is created
      from and the remote that base lives on; exit 3 when no branch or agent was
      chosen, exit 2 when the name typed for a new branch is not a valid ref

--bd-json, --wt-json, --refs and --base-refs read saved tool output instead of
asking the tools, which is how the tests and dry runs work: --bd-json stands in
for bd, --wt-json with --refs for both of the lookups --main would be read for,
and --base-refs for the one bases reads, so a run given all four never touches
--main at all.

The first question is one screen: the ready beads, with "✎  write a prompt
instead" pinned on top. Text typed at the fzf prompt that matches no row is the
prompt itself (--print-query with --expect: the query is line 1, the key that
was pressed line 2 -- empty when none was -- and the selected row line 3 when
there is one), and picking the prompt row opens a prompt field for text that
would be awkward to type there. esc means no bead, so the configured no-bead
prompt says what the flow is; ctrl-n means blank, an agent started with
nothing said to it at all.

The second question is the agent: the --agents names, with "none" last. none
starts nothing, so the tab is the new worktree and a login shell, and the prompt
it could not deliver is printed above that shell rather than dropped. The third
is the branch, typed with the bead's name already in the field, so a bare Enter
accepts it.

The branch question carries the base it opens on: the one --base names, or the
one this clone would be created from (origin/HEAD's target, then origin/main,
origin/master, main, master), or none at all with --no-base. The base travels to
the tab with the remote it lives on so the tab can fetch that one; a base on no
remote carries no remote, and nothing is fetched for it. --base-refs reads a
saved for-each-ref instead of the repository, as bases does.

pick's --bead, --prompt, --blank, --agent and --branch answer a question
instead of asking it, and an empty value means none. --blank is the answer
ctrl-n gives -- no bead and nothing said to the agent, which the tab reads as
no prompt word at all -- and, like the others, it cannot be combined with an
answer to the same question. With no terminal on stdin nothing is asked: the
bead question is skipped, the agent falls back to the first --agents name, and
the branch reads an empty answer, rather than waiting for any of them.
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

# The last row of the agent question: the answer that starts no agent at all.
# Its label is prose, so what was chosen is read back against the configured
# names rather than by matching this text.
none_agent_row='none — no agent, just the tab'

# On the way out of pick -- usage_error's 2, die's 1, a missing tool's 1, rex's
# own status -- hold the float with the failure still on screen. A cancelled
# pick is an answer rather than a failure, so it is left alone.
hold_pick() {
  local status=$?
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

# The bead question, in one screen: the ready list with the prompt row pinned on
# top, and `preview` in the pane below so a long description never crowds the
# rows. --print-query is what makes bead-or-text-or-blank expressible at all --
# the query is line 1, the key that was pressed line 2 (--expect=ctrl-n, and an
# empty line when none was), the selected row line 3 when there is one -- so
# what comes back here is fzf's own reply and status, and fzf_answer reads it.
# Reading the key off the wrong line is the bug --expect exists to prevent: the
# blank answer arrives as a key, and a reader that took line 2 for the row would
# see ctrl-n as a bead.
#
# The pane is a bottom one rather than a right-hand split: at the real float
# size (80x24) a side split leaves about 36 columns for the list, which truncates
# every bead title, and about 42 for the preview, which cuts prose mid-word. A
# bottom pane is full width for both, and the preview wraps.
#
# The cursor starts on the first bead rather than on the prompt row, so a bare
# Enter still takes the bead the list leads with; with no beads to lead with it
# stays on the prompt row, which is then the only answer worth offering. That is
# the load event's pos(1-based number), not --cursor: this fzf has no such flag,
# and the start event fires before the list exists. The preview is refreshed in
# the same breath, because it renders against the row the cursor started on and
# would otherwise describe the prompt row until the first keypress.
pick_bead() {
  local main=$1 rows=$2 pos=1
  local script main_q
  script=$(printf '%q' "$0")
  main_q=$(printf '%q' "$main")
  if [ -n "$rows" ]; then
    pos=2
  fi

  {
    printf '%s\n' "$prompt_row"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
    fi
  } |
    fzf --delimiter='\t' \
      --with-nth=1,2 \
      --print-query \
      --expect=ctrl-n \
      --bind "load:pos($pos)+refresh-preview" \
      --reverse \
      --header 'pick a bead · type to write a prompt · esc = no bead' \
      --preview-window 'down,60%' \
      --preview "$script preview {1} --main $main_q"
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

# The agent question: the names the configuration offers, with the no-agent row
# last. gum choose prints the row it landed on, prose and all, so the caller
# reads the answer back against the configured names. ctrl-c -- all gum listens
# to, as it ignores esc -- ends it non-zero, which the caller turns into the same
# cancelled exit as everywhere else.
pick_agent() {
  local choices=$1
  {
    printf '%s\n' "$choices"
    printf '%s\n' "$none_agent_row"
  } | gum choose --header 'start which agent?'
}

# The branch question: a typed answer, not a picker. Creating a branch is the
# usual case and a list of names that already exist offers nothing for a name
# that does not exist yet, so the answer is typed -- with the name derived from
# the bead already in the field, where a bare Enter accepts it. Whatever is
# typed is the branch, exactly as typed; the candidate list decides afterwards
# whether that name is an existing worktree to switch to or one to create.
#
# gum input asks it in the float. Off a terminal -- a pipe, a script, the tests
# -- there is nobody to ask, so the answer is read from stdin instead, which is
# what keeps this path reachable without a pty. A failed ask (ctrl-c) and EOF
# are both an empty answer, which pick turns into exit 3 the way esc used to.
pick_branch() {
  local suggestion=$1 answer=''

  if [ -t 0 ]; then
    if [ -n "$suggestion" ]; then
      answer=$(gum input --value "$suggestion" \
        --header 'branch: Enter accepts the name shown') || return 1
    else
      answer=$(gum input --header 'branch') || return 1
    fi
  else
    # Nothing is printed for a pipe: nobody is reading a prompt there, and it
    # would land in the middle of a script's output. read fails at EOF, which is
    # an empty answer rather than a reason to stop, so it must not end the run
    # here under `set -e`.
    IFS= read -r answer || true
  fi
  # A pasted name usually arrives with whitespace around it, and whitespace is
  # part of no branch: trimmed, so space-then-Enter is Enter -- accepting the
  # suggestion -- rather than a `git check-ref-format` refusal naming a branch
  # that looks perfectly valid on screen.
  answer=$(printf '%s' "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "$answer" ]; then
    answer=$suggestion
  fi
  printf '%s\n' "$answer"
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

  # The picker's own requirements, before any work, and only for the questions
  # that will really be asked -- in the float, where stdin is a terminal -- so a
  # scripted run is not stopped by a tool it would never call: off a terminal the
  # bead question is skipped, the agent question takes the first name and the
  # branch question reads stdin. Saved tool output stands in for the tools it
  # replaces.
  if [ -t 0 ]; then
    if [ "$bead_set" -eq 0 ] && [ "$prompt_set" -eq 0 ] &&
      [ "$blank_set" -eq 0 ]; then
      need fzf
    fi
    # gum asks the agent question and the branch question, and it writes the
    # prompt in the field the bead question's prompt row opens -- a path of that
    # same question -- so it is needed wherever one of the three is really asked.
    # No agent list means no agent question.
    if [ "$branch_set" -eq 0 ] ||
      { [ "$agent_set" -eq 0 ] && [ -n "$agent_choices" ]; } ||
      { [ "$bead_set" -eq 0 ] && [ "$prompt_set" -eq 0 ] &&
        [ "$blank_set" -eq 0 ]; }; then
      need gum
    fi
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

  local note=''
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
      reply=$(pick_bead "$main" "$rows") || asked=$?
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
  local title='' issue_type=''
  if [ -n "$bead" ]; then
    if ! printf '%s\n' "$rows" | cut -f1 | grep -Fxq -- "$bead"; then
      # It can still have a title: a gate, a molecule or a step is filtered out
      # of the picker but present in the database.
      printf '%s: %s is not on the pickable list\n' "$PROG" "$bead" >&2
    fi
    # One lookup for both fields, one per line, so the empty issue_type cannot
    # be lost to field splitting. A title that is not a string is stringified
    # first, as in pickable_rows: gsub cannot match a number.
    {
      read -r issue_type
      read -r title
    } < <(printf '%s\n' "$ready" | jq -r --arg id "$bead" '
          ([.[] | select(.id == $id)][0]) as $b
          | ($b.issue_type // ""),
            (($b.title // "") | tostring | gsub("[\\t\\n\\r]+"; " "))')
  fi

  # The agent question, asked before the branch and after everything derived from
  # the bead: nothing about it is derived from anything.
  if [ "$agent_set" -eq 0 ] && [ -n "$agent_choices" ]; then
    if [ -t 0 ]; then
      local chosen='' chosen_status=0
      chosen=$(pick_agent "$agent_choices") || chosen_status=$?
      if [ "$chosen_status" -ne 0 ]; then
        printf '%s: no agent chosen, nothing to start\n' "$PROG" >&2
        exit "$cancelled"
      fi
      # The no-agent row's label is prose, so the answer is read back against
      # the names that were offered: anything else is none.
      agent=''
      if printf '%s\n' "$agent_choices" | grep -Fxq -- "$chosen"; then
        agent=$chosen
      fi
      agent_set=1
    else
      # Nobody to ask: the list leads with the default, which is the answer an
      # unasked question takes -- the same agent the configuration names.
      agent=$(printf '%s\n' "$agent_choices" | sed -n 1p)
      agent_set=1
    fi
  fi

  local candidates
  if ! candidates=$(candidate_rows "$main" "$wt_json" "$refs"); then
    die "pick: could not list the branches of $main"
  fi

  if [ "$branch_set" -eq 0 ]; then
    local suggestion=''
    if [ -n "$bead" ]; then
      # A bead the list did not describe still gets a name: types outside the
      # map fall back to feat, like the map itself does. An id no name can be
      # built from -- one ending in a dash -- is no reason to stop the pick with
      # a usage dump: the prompt simply offers nothing.
      suggestion=$(cmd_branch_default --type "${issue_type:-other}" --id "$bead" 2>/dev/null) ||
        suggestion=''
    fi
    # Told before the prompt rather than packed into it, so the prompt stays one
    # short line whatever the reason for asking.
    if [ -n "$note" ]; then
      printf '%s: %s\n' "$PROG" "$note" >&2
    fi
    # A failed ask -- gum's ctrl-c -- is no branch, which is the same cancelled
    # pick an EOF on the typed answer has always been.
    branch=$(pick_branch "$suggestion") || branch=''
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

  # The base the tab creates from, resolved once, here, where the answer the
  # branch question opens on is known: it travels in the payload with the remote
  # it lives on so the tab can fetch that one, and nothing is said about it on
  # stderr, where the announcement used to be. --base is the answer whatever
  # this clone would have opened on; --no-base is the worktrunk default, no ref
  # at all; otherwise the base cycle's first row is it, the answer `bases`
  # prints first. The remote comes from that row rather than from a slash in the
  # name, because feat/x is a local branch and nothing to fetch.
  local base_ref='' base_remote='' base_default=0
  if [ "$no_base" -eq 1 ]; then
    base_default=1
  else
    local base_row=''
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
