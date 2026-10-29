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
  pick --main DIR --root PATH --project NAME [--base B]
       [--bead ID] [--branch NAME] [--dry-run]
      ask for a bead, then a branch, and hand the answer to Rex as one JSON
      object; exit 3 when no branch was chosen, exit 2 when the name typed for
      a new branch is not a valid ref

--bd-json, --wt-json and --refs read saved tool output instead of asking the
tools, which is how the tests and dry runs work: --bd-json stands in for bd, and
--wt-json with --refs for both of the lookups --main would be read for, so a run
given all three never touches --main at all.

pick's --bead and --branch answer a question instead of asking it, and an
empty value means none. The branch question is typed, with the bead's name
offered in the prompt: an empty answer accepts that name, or cancels when
there is none. With no terminal on stdin the bead question is skipped and the
branch question reads an empty answer, rather than waiting for either.
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
# the float closes on it the way esc always did. Named once, because the picker
# exits with it and hold_pick has to recognise it.
cancelled=3

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
    | "\(.id)\t\((.title // "") | gsub("[\\t\\n\\r]+"; " "))"
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
  # a place that does not exist.
  if [ -n "$main" ]; then
    [ -d "$main" ] || die "candidates: no such directory: $main"
  fi
  command -v jq >/dev/null 2>&1 || die 'jq is required but was not found on PATH'

  candidate_rows "$main" "$wt_json" "$refs"
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

# The bead question: the ready list in fzf, with `preview` in the pane so a
# long description never crowds the rows. Aborting (esc, ctrl-c) is a real
# answer -- it means no bead -- so it prints nothing and succeeds. The chosen
# row comes back whole, as "id<TAB>title".
pick_bead() {
  local main=$1 rows=$2
  local script main_q
  script=$(printf '%q' "$0")
  main_q=$(printf '%q' "$main")

  printf '%s\n' "$rows" |
    fzf --delimiter='\t' \
      --with-nth=1,2 \
      --reverse \
      --header 'pick a bead · esc = no bead' \
      --preview "$script preview {1} --main $main_q" || return 0
}

# The branch question: a typed answer, not a picker. Creating a branch is the
# usual case and a list of names that already exist offers nothing for a name
# that does not exist yet, so the answer is typed -- with the name derived from
# the bead shown in the prompt, where a bare Enter accepts it. Whatever is
# typed is the branch, exactly as typed; the candidate list decides afterwards
# whether that name is an existing worktree to switch to or one to create.
#
# The prompt goes to stderr because stdout carries the hand-back, and only to a
# terminal: a pipe is answered, never asked. EOF -- a pipe that has ended, or a
# terminal closed with ctrl-d -- is an empty answer, which pick turns into
# exit 3 the way esc used to.
pick_branch() {
  local suggestion=$1 prompt='branch> ' answer=''

  if [ -n "$suggestion" ]; then
    prompt="branch [$suggestion]> "
  fi
  if [ -t 0 ]; then
    printf '%s' "$prompt" >&2
  fi
  # read fails at EOF; that is an empty answer rather than a reason to stop, so
  # it must not end the run here under `set -e`.
  IFS= read -r answer || true
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

# `new-work.sh pick --main DIR --root PATH --project NAME [--base B]`
#       `[--bead ID] [--branch NAME] [--dry-run]`
#
# The two questions behind ctrl+space>n: which bead, then which branch. The
# answer goes back to Rex as one JSON object, built by jq so no value is ever
# interpolated into a command line. --bead and --branch answer a question
# without asking it, which is how the tests and scripts drive the picker.
cmd_pick() {
  local main='' root='' project='' base='' bead='' branch=''
  local bead_set=0 branch_set=0 dry_run=0
  local bd_json='' wt_json='' refs=''

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
      --bead)
        [ $# -ge 2 ] || usage_error 'pick: --bead needs an id'
        bead=$2
        bead_set=1
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

  # The hand-back's paths are read by the Rex server, whose working directory is
  # not this one, so they have to say where they are. The Lua side derives both
  # from git and they are always absolute; this is the guard for a hand-run.
  need_absolute 'pick: --main' "$main"
  need_absolute 'pick: --root' "$root"

  # --main is where bd, wt and git are read, so a directory that is not there is
  # refused here, by name: left to the pipelines below it reaches `cd` inside a
  # subshell, whose failure reads as a line number in this script rather than as a
  # place that does not exist. Only when one of those lookups will really be made:
  # a run given all three fixtures never touches --main.
  if [ -z "$bd_json" ] || [ -z "$wt_json" ] || [ -z "$refs" ]; then
    [ -d "$main" ] || die "pick: no such directory: $main"
  fi

  # The picker's own requirements, before any work. fzf is asked for only where
  # the bead question will really be asked -- in the float, where stdin is a
  # terminal -- so a scripted run is not stopped by a tool it would never call:
  # the branch question is typed and needs nothing but stdin. Saved tool output
  # stands in for the tools it replaces.
  if [ -t 0 ] && [ "$bead_set" -eq 0 ]; then
    need fzf
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
  if [ "$bead_set" -eq 0 ]; then
    if [ -z "$rows" ]; then
      # Nothing to offer: say so, and let the branch question carry the note,
      # because an empty picker asks for a choice that does not exist.
      note='no ready beads'
    elif [ ! -t 0 ]; then
      # A pipe or a script, never the Rex float: asking would wait forever, so
      # take no bead and move on with the branch instead.
      printf '%s: skipping the bead question: stdin is not a terminal\n' \
        "$PROG" >&2
    else
      local picked
      picked=$(pick_bead "$main" "$rows")
      if [ -n "$picked" ]; then
        bead=${picked%%$'\t'*}
      fi
    fi
  fi

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
    # be lost to field splitting.
    {
      read -r issue_type
      read -r title
    } < <(printf '%s\n' "$ready" | jq -r --arg id "$bead" '
          ([.[] | select(.id == $id)][0]) as $b
          | ($b.issue_type // ""),
            (($b.title // "") | gsub("[\\t\\n\\r]+"; " "))')
  fi

  local candidates
  if ! candidates=$(candidate_rows "$main" "$wt_json" "$refs"); then
    die "pick: could not list the branches of $main"
  fi

  if [ "$branch_set" -eq 0 ]; then
    local suggestion=''
    if [ -n "$bead" ]; then
      # A bead the list did not describe still gets a name: types outside the
      # map fall back to feat, like the map itself does.
      suggestion=$(cmd_branch_default --type "${issue_type:-other}" --id "$bead")
    fi
    # Told before the prompt rather than packed into it, so the prompt stays one
    # short line whatever the reason for asking.
    if [ -n "$base" ]; then
      printf '%s: new branches start from %s\n' "$PROG" "$base" >&2
    fi
    if [ -n "$note" ]; then
      printf '%s: %s\n' "$PROG" "$note" >&2
    fi
    branch=$(pick_branch "$suggestion")
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

  local payload
  payload=$(jq -cn \
    --arg project "$project" \
    --arg root "$root" \
    --arg main "$main" \
    --arg branch "$branch" \
    --arg bead "$bead" \
    --arg title "$title" \
    --argjson create "$create" \
    '{project: $project, root: $root, main: $main, branch: $branch,
      bead: $bead, title: $title, create: $create}')

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
  preview)
    shift
    cmd_preview "$@"
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
