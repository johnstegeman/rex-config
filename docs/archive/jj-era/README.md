# The jj era, archived

rex-config's flow was worktrunk's for most of its life. Between 2026-11-03 and
2026-11-17 it was [jj](https://jj-vcs.github.io/jj/)'s: colocated workspaces,
a workspace row instead of a worktree row, and at the end `djo` (dojjo) in place
of `wt`. Bead `rex-config-v46` returned the flow to worktrunk, and the reverts
that did it delete these documents from the live tree.

They are kept here, verbatim, because they are the record of why the era looked
the way it did — and because a future jj attempt should read the failures
before repeating them. Nothing in the current flow reads this directory.

Relative layout is preserved so the documents' own relative links still
resolve without editing them: the runbook's link to the cut design, and the two
earlier specs' links back to the runbook.

## Contents

| file | origin path | origin commit | blob |
| --- | --- | --- | --- |
| `dojjo-conversion-runbook.md` | `docs/dojjo-conversion-runbook.md` | `8cf9eb3` (PR #11) | `47596f4` |
| `superpowers/specs/2026-11-03-rex-jj-workspaces-design.md` | `docs/superpowers/specs/2026-11-03-rex-jj-workspaces-design.md` | `4d3ded7` (PR #4, `feat/pxp`) | `a9d4591` |
| `superpowers/specs/2026-11-05-rex-done-teardown-design.md` | `docs/superpowers/specs/2026-11-05-rex-done-teardown-design.md` | `54d2878` (PR #5) | `3e586de` |
| `superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md` | `docs/superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md` | `8cf9eb3` (PR #11) | `045a858` |

Each file is byte-identical to the blob at those paths in `b132ddb9`; recover
the full text of any of them with `git show b132ddb9:<origin path>`.

## What the era was

- **2026-11-03** (`a9d4591`) — new work lands in a jj colocated workspace. The
  design that replaced worktrunk's worktree with `jj workspace add`, and gave
  the tab a `gws` call to do it.
- **2026-11-05** (`3e586de`) — "I'm done": one key removes the tab, the
  worktree, the branch and the jj workspace.
- **2026-11-06** (`045a858`) — `djo` (dojjo) replaces worktrunk outright, and
  `gws` becomes `jws`. This is the design the runbook executes.
- **2026-11-17** (`b132ddb9`) — the conversion finishes: `.config/wt.toml` is
  emptied and the repo is djo/jj throughout.

## What replaced it

`worktrunk`, as before the era: `wt switch --create` from the tab wrapper,
`wt list --format=json` for the rows, `wt remove` for teardown. See the root
`README.md` and `docs/superpowers/specs/` for the live designs.

One thing the era added does not come back with the revert: the `done` key
(`cmd_done`). Pre-jj rex-config has no teardown at all, and the jj version was
jj to the bone — it forgot workspaces. If `done` is wanted again it is a new
bead on `wt remove --foreground -y --format=json`, keeping only `cmd_done`'s
non-jj bones: find the worktree row, refuse when the branch is unmerged, close
the tab.
