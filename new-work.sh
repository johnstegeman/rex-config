#!/usr/bin/env bash
# new-work.sh -- the lookups behind rex's new-work flow (ctrl+space>n).
#
# Called by the Lua module, which asks the flow's questions itself with rex.ui;
# this script answers the four lookups that want the login shell's PATH -- the
# ready beads, a bead's derived branch name, a bead's text, and the bases -- and
# nothing else. Every subcommand is a plain function, so the tests and dry runs
# drive it with saved tool output and no terminal.
set -euo pipefail

PROG=${0##*/}

usage() {
  cat <<'EOF'
usage: new-work.sh <command> [options]

commands:
  beads --main DIR [--bd-json FILE]
      list pickable ready beads, one
      "id<TAB>title<TAB>issue_type<TAB>priority" row each, sorted by priority then
      id
  preview ID --main DIR
      print one bead's full text
  branch-default --type TYPE --id ID
      print the branch name to offer for a bead, e.g. bug/pmm-iris-a4l
  bases --main DIR [--base-refs FILE] [--base REF | --no-base]
      print the bases the base question offers, one "ref<TAB>remote" row each,
      the opening answer first; an empty ref means no --base at all, which leaves
      it to worktrunk

--bd-json and --base-refs read saved tool output instead of asking the tools,
which is how the tests and dry runs work: --bd-json stands in for bd and
--base-refs for the one for-each-ref bases reads, so a run given both never
touches --main at all.

The base question opens on the one --base names, or the one this clone would be
created from (origin/HEAD's target, then origin/main, origin/master, main,
master), or none at all with --no-base -- which reads "wt default", because it
is a real answer rather than a missing one. The base travels to the tab with the
remote it lives on so the tab can fetch that one; a base on no remote carries no
remote, and nothing is fetched for it.
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
# all, which nothing could pick. A row is
# "id<TAB>title<TAB>issue_type<TAB>priority", sorted by priority then id: the id
# and the title name the bead, the type picks the row's icon, and the priority is
# its P number. A title is flattened to one line, and a bead bd gave no priority
# to gets an empty last field rather than a made-up rank, so a producer that is
# not bd itself cannot split a row or stop the listing.
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
    | "\(.id)\t\((.title // "") | tostring | gsub("[\\t\\n\\r]+"; " "))\t\((.issue_type // "") | tostring | gsub("[\\t\\n\\r]+"; " "))\t\(if .priority == 999 then "" else (.priority | tostring) end)"
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

# The ref records `git for-each-ref` prints for refs/remotes and refs/heads, one
# per line: the fixture when one is given (tests and dry runs), else the lookup.
# A NUL cannot live in a shell variable, so it becomes the tab separating a
# record's two fields -- no refname and no symref target can contain one.
base_ref_records() {
  local main=$1 fixture=$2
  if [ -n "$fixture" ]; then
    # A fixture that cannot be opened is refused here rather than left to the
    # redirect: the shell's own "line 409: ... No such file or directory" names
    # a line of this script instead of the file, and it arrives beside the
    # message below rather than instead of it.
    [ -r "$fixture" ] || return 1
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
#
# LABEL is the command a failure is reported under, so a person reading the one
# line they get back knows which verb they ran.
base_chain() {
  local main=$1 fixture=$2 base=$3 no_base=$4 label=${5:-bases}
  local records

  if ! records=$(base_ref_records "$main" "$fixture"); then
    die "$label: could not read the refs of ${fixture:-$main}"
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
        # --base can be given as the refname it really is, and every row here
        # speaks the short name. One left whole would match no ref record, so a
        # base on a remote would read as local and the tab would skip the
        # fetch it needs.
        open = base
        sub(/^refs\/remotes\//, "", open)
        sub(/^refs\/heads\//, "", open)
      } else if ("refs/remotes/origin/HEAD" in refs \
                 && symref["refs/remotes/origin/HEAD"] ~ /^refs\/remotes\//) {
        # A symref pointing out of refs/remotes names no base this clone
        # tracks, so it falls through to the fixed names as any miss does.
        target = symref["refs/remotes/origin/HEAD"]
        open = target
        sub(/^refs\/remotes\//, "", open)
        # The target can be gone from the dump while the symref still names
        # it -- a branch deleted upstream. No record then says which remote
        # it lives on, and the first segment of the name is all that is left;
        # without it the tab would skip the fetch that ref needs.
        if (!(target in refs)) {
          cut = index(open, "/")
          if (cut > 1) remote_of[open] = substr(open, 1, cut - 1)
        }
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

  base_chain "$main" "$base_refs" "$base" "$no_base" 'bases'
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

  command -v bd >/dev/null 2>&1 || die 'bd is required but was not found on PATH'

  if command -v bat >/dev/null 2>&1; then
    ( cd "$main" && bd show "$id" ) | bat --plain --language=markdown
  else
    ( cd "$main" && bd show "$id" )
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
  bases)
    shift
    cmd_bases "$@"
    ;;
  preview)
    shift
    cmd_preview "$@"
    ;;
  *)
    usage_error "unknown command ${1:-<none>}"
    ;;
esac
