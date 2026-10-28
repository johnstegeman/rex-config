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

# `new-work.sh beads --main DIR [--bd-json FILE]`
#
# Picker rows for the beads a person can actually start work on. Out go the
# things that are not work: molecule steps (dotted ids), molecule and gate
# container beads, and step:* labels. --bd-json reads a saved `bd ready --json`
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

  ready_json "$main" "$fixture" |
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

case ${1:-} in
  beads)
    shift
    cmd_beads "$@"
    ;;
  *)
    usage_error "unknown command ${1:-<none>}"
    ;;
esac
