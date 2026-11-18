#!/usr/bin/env bash
# The module under Rex's own Lua, which stock Lua cannot stand in for: see
# test/host.lua. The pass is skipped, not failed, when there is nothing to run
# it against -- a checkout with no `rex` on PATH or no server running is not a
# broken parser, and starting a server from a test would reach outside it.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v rex >/dev/null 2>&1; then
  printf 'skipping the Rex-host pass; rex is not on PATH\n'
  exit 0
fi

# --autostart=false: a test must not start the server it is testing against.
if ! rex --autostart=false whoami >/dev/null 2>&1; then
  printf 'skipping the Rex-host pass; no Rex server is running\n'
  exit 0
fi

if ! rex do --autostart=false test/host.lua; then
  printf 'FAIL the module answers wrong inside Rex'"'"'s Lua, or panics there\n'
  exit 1
fi
