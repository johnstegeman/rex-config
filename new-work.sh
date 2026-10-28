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
      object; exit 3 when no branch was chosen

--bd-json, --wt-json and --refs read saved tool output instead of asking the
tools, which is how the tests and dry runs work.

pick's --bead and --branch answer a question instead of asking it, and an
empty value means none; with no terminal on stdin both questions are skipped
rather than waited on.
EOF
}

# Exit 2: the caller asked for something this script does not do.
usage_error() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  usage >&2
  exit 2
}

# Exit 1: the environment cannot run the command at all.
die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

# Exit 1 after a pause: the picker runs in a floating terminal, so exiting at
# once would make the pane vanish before anyone could read why it did. The
# keypress goes to that terminal; with stdin closed (a script, or the tests) it
# returns immediately.
need() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s not found on PATH — press any key\n' "$1" >&2
  read -r -s -n 1 _ || true
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
# molecule and gate container beads, and step:* labels. Rows are
# "id<TAB>title", sorted by priority then id.
pickable_rows() {
  jq -r '
    [ .[]
      | select(.id | contains(".") | not)
      | select(.issue_type != "molecule" and .issue_type != "gate")
      | select([.labels[]? | startswith("step:")] | any | not)
    ]
    | sort_by(.priority, .id)
    | .[]
    | "\(.id)\t\(.title)"
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

  ready_json "$main" "$fixture" | pickable_rows
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

  local prefix
  case $type in
    bug) prefix=bug ;;
    chore) prefix=chore ;;
    spike) prefix=spike ;;
    feature | task) prefix=feat ;;
    *) prefix=feat ;;
  esac

  printf '%s/%s\n' "$prefix" "${id##*-}"
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

  {
    if [ -n "$wt_json" ]; then
      wt_branches <"$wt_json"
    elif [ -n "$main" ]; then
      # A repository worktrunk cannot read still has branches git can name,
      # so a broken `wt` costs the picker its worktree rows, not the command.
      ( cd "$main" && wt list --format=json ) 2>/dev/null | wt_branches || true
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

# The branch question: the existing branches as suggestions, prefilled with
# the bead-derived name and editable. `--print-query` puts the typed text on
# the first line, and `enter:replace-query` swaps the query for the
# highlighted entry first -- so one keystroke means "switch to this branch"
# when a branch is highlighted and "create this name" when nothing matches.
# Aborting prints nothing, which pick turns into exit 3.
pick_branch() {
  local candidates=$1 query=$2 header=$3 out

  out=$(
    { [ -z "$candidates" ] || printf '%s\n' "$candidates"; } |
      fzf --print-query --reverse --query "$query" --header "$header" \
        --bind 'enter:replace-query+accept'
  ) || return 0
  printf '%s\n' "$out" | head -n 1
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

  # The picker's own requirements, before any work: fzf first, because a run
  # that may stop to ask something is a run that needs it. Saved tool output
  # stands in for the tools it replaces.
  if [ "$bead_set" -eq 0 ] || [ "$branch_set" -eq 0 ]; then
    need fzf
  fi
  [ -n "$wt_json" ] || need wt
  need jq
  [ -n "$bd_json" ] || need bd

  local ready rows
  if ! ready=$(ready_json "$main" "$bd_json"); then
    die "pick: could not read the ready beads from ${bd_json:-$main}"
  fi
  rows=$(printf '%s\n' "$ready" | pickable_rows)

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
      printf '%s: %s is not on the ready list; starting it without a title\n' \
        "$PROG" "$bead" >&2
    fi
    issue_type=$(printf '%s\n' "$ready" | jq -r --arg id "$bead" \
      '[.[] | select(.id == $id)][0].issue_type // ""')
    title=$(printf '%s\n' "$ready" | jq -r --arg id "$bead" \
      '([.[] | select(.id == $id)][0].title // "") | gsub("[\\t\\n\\r]+"; " ")')
  fi

  local candidates
  if ! candidates=$(candidate_rows "$main" "$wt_json" "$refs"); then
    die "pick: could not list the branches of $main"
  fi

  if [ "$branch_set" -eq 0 ]; then
    if [ ! -t 0 ]; then
      # Same rule as the bead question: with no terminal there is nobody to
      # ask, and the empty branch below ends the run the way esc does.
      if [ -n "$note" ]; then
        printf '%s\n' "$note" >&2
      fi
      printf '%s: skipping the branch question: stdin is not a terminal\n' \
        "$PROG" >&2
    else
      local query=''
      if [ -n "$bead" ]; then
        # A bead the list did not describe still gets a name: types outside the
        # map fall back to feat, like the map itself does.
        query=$(cmd_branch_default --type "${issue_type:-other}" --id "$bead")
      fi
      local header='pick an existing branch, or type a new name to create it'
      if [ -n "$base" ]; then
        header="$header (new branches start from $base)"
      fi
      if [ -n "$note" ]; then
        header="$note — $header"
      fi
      branch=$(pick_branch "$candidates" "$query" "$header")
    fi
  elif [ -n "$note" ]; then
    printf '%s\n' "$note" >&2
  fi

  if [ -z "$branch" ]; then
    printf '%s: no branch given, nothing to start\n' "$PROG" >&2
    exit 3
  fi

  # An exact match is a worktree that already exists: switch to it. Anything
  # else is a name to create, even when it looks like something on the list.
  local create=true
  if printf '%s\n' "$candidates" | grep -Fxq -- "$branch"; then
    create=false
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

  rex do work_new_go --args "$payload"
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
    cmd_pick "$@"
    ;;
  *)
    usage_error "unknown command ${1:-<none>}"
    ;;
esac
