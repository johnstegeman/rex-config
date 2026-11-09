# rex-config: dojjo replaces worktrunk for the new-work flow

**Date:** 2026-11-06
**Status:** design, approved in conversation
**Owner:** John Stegeman
**Bead:** `rex-config-2ow`
**Molecule:** `rex-config-mol-rn1`
**Supersedes:** the worktrunk-owned parts of
`docs/superpowers/specs/2026-11-03-rex-jj-workspaces-design.md` and
`docs/superpowers/specs/2026-11-05-rex-done-teardown-design.md`

## Intent

worktrunk is a *git worktree* tool. Every repository this flow is meant for has
been converted to the `ginit` wrapper, where `main` and every feature directory
are **jj colocated workspaces of the directory-level repo** — and jj detaches
`HEAD` on the next jj command it runs. So in exactly the repos the flow exists
for:

- `wt list --format=json` reports `branch: null` for every worktree, and flags a
  feature worktree as `"main": true` (verified today in pi-rex),
- `wt_branch_rows` therefore returns nothing, `candidates` prints only the
  git-heads half, and `branch_mode` classifies a branch that *has* a workspace
  as `attach` — which then refuses, because the directory is already there,
- `gws`'s `git checkout -b` is undone by the next jj command, so the
  branch-attached view worktrunk needs never survives,
- the seeded `[post-remove]` hook cannot even expand `{{ branch }}` for a
  detached worktree, so the "keep jj in sync" hook never ran.

Put plainly: the worktrunk half of the flow is dead weight in the repos the flow
was built for, and the done flow's "was the branch kept?" reporting cannot be
computed from it at all.

dojjo (`djo`, v0.2.2) speaks jj natively: `djo switch` creates a jj workspace,
`djo remove` forgets one. This cut makes dojjo the workspace tool, makes **jj the
only source of truth** for which workspaces and bookmarks exist, and wraps every
`djo` call in one fish shim (`jws`) so that a future swap — dojjo is 72 commits
old with a single maintainer — stays a one-file change.

## Goals

- `ctrl+space>n` creates, attaches and switches using dojjo, and nothing in the
  flow asks worktrunk anything.
- Existence and paths come from `jj workspace list`; branch names from
  `jj bookmark list`. Neither answer is parsed out of a tool's chatty stdout.
- The tab's contract is unchanged: `--path-file FILE` with the absolute path on
  one line, non-zero exit on failure, one readable line naming the step that
  failed, a login shell and no agent after it.
- **No `djo` invocation can block on stdin.** dojjo prompts `Create it? [y/N]`
  for a name it does not know, and in a pane that is an invisible hang.
- The whole flow works in a wrapper with **no `.git` anywhere** — the state the
  owner is taking pi-rex to.
- `gclone`, `ginit` and `gws` are untouched, so git-flavoured repos keep
  working exactly as they do today.
- Every wrapper-layout project on disk ends up with hook config dojjo actually
  reads, and no `wt step` command left in it.

## Non-goals (this cut)

- **Hook approval parity.** dojjo has no equivalent of worktrunk's
  `approvals.toml`. The owner accepted this.
- **Other repos' commits.** The conversion of pi-rex, pi-packages, pi-carte,
  pi-garnish, pi-whetstone, ci-platform and pmm-iris is a **runbook the owner
  runs**, not work the plan executes. The owner does not yet know whether a
  conversion means rebuilding a working copy or cleaning one up in place; the
  runbook covers both routes.
- **Converting an existing plain colocated repo** (files at the root, no
  wrapper, no `main/`) into the wrapper shape. `jinit`/`jclone` are for a fresh
  or empty remote. Roughly 40 repos under `~/Projects` are in that shape and
  nothing here touches them.
- **The bead, agent, prompt and base *picking* flows**, the composer, its keys
  and its state file. Untouched.
- **Pruning, merging and remote-branch creation.** `djo prune` / `djo merge`
  are not adopted; nothing calls them.

## Anti-goals

- A `djo` call that can prompt. Any name that might not exist is either guarded
  by an existence check or created with `-c`.
- Parsing a path out of `djo`'s stdout. That stream carries hook chatter, and
  the one thing the tab must never do is `cd` somewhere it guessed.
- A second copy of the wrapper layout inside rex — the `<wrapper>/<sanitised>`
  placement, the sparse inheritance, the hook run. `jws` owns all of it.
- A stale top-level `[post-start]` left behind. dojjo parses it and runs
  nothing, silently: hooks that vanish without a message are worse than hooks
  that fail.
- A git-shaped fallback for a repo that is not converted.

## Constraints (verified against djo 0.2.2 / jj 0.47.1)

These were established in scratch wrappers (`/tmp/djotest` with git,
`/tmp/pj2` with no git) and in the real pi-rex repo. They are the ground the
design stands on.

| # | Fact |
|---|---|
| 1 | **`djo switch` is unusable in a wrapper — see 15 — so this design never calls it.** A workspace is made with `jj workspace add --name <branch> <wrapper>/<sanitised branch> [-r <rev>]` run from `<wrapper>/main`, which is what `gws` does today minus its git half: the new workspace inherits `main`'s sparse patterns, and no bookmark is created |
| 2 | Hooks are run by **`djo hook post-start`**, in the new workspace, with the workspace as cwd. It **exits 0 even when a hook fails**: the failure is printed on stderr and written to the log, and no exit status carries it |
| 3 | attach is a new commit on top of the existing bookmark (`jj workspace add -r <branch>`), with the bookmark left where it is — exactly what `gws` + `git checkout <branch>` left behind. (`djo switch -c --no-bookmark` with no base lands the workspace on `root()` — verified — which is one more reason not to use it.) |
| 4 | `djo remove <name> -y` forgets the workspace, deletes the directory **and deletes the bookmark** (`--keep-bookmark` keeps it, `--keep-revision` keeps the revision). There is **no merged check** and no `branch_outcome` equivalent |
| 5 | dojjo never fetches — there is no `jj git fetch` in its source. The bounded fetch must stay in the shim |
| 6 | dojjo has no `-C`/`--cwd`. The shim must `builtin cd` first, which also keeps the new workspace inside the wrapper |
| 7 | Directory placement is computed from the cwd's **workspace root**: from `main` it is right, from the wrapper (sparse-cleared `default`) it lands *outside* at `<wrapper>/..` |
| 8 | `djo list --json` reports `path: ""` for every workspace. `djo list -f` is correct, and `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'` is the source both `new-work.sh` and `init.lua` already read |
| 9 | `djo switch` has **no** `--format`, `--porcelain` or JSON output (`-c/--create`, `--bookmark`, `-b/--base` defaulting to `trunk()`, `-x/--execute`, `--skip-hooks`), and `djo list --json` reports `path: ""` for every workspace |
| 10 | dojjo reads hooks from a `[hooks]` table only (simple, pipeline, or named `[hooks.post-start]`), in `<workspace>/.config/wt.toml`, `~/.config/dojjo/config.toml`, `dojjo.toml`, `dojjo.local.toml`. worktrunk's **top-level** `[post-start]` / `[post-remove]` are parsed and silently ignored |
| 11 | dojjo **does** run `[hooks.pre-remove]` and `[hooks.post-remove]` (`remove_command.dart:52,75`) — but this design deletes the forget hook rather than moving it, because `djo remove` forgets the workspace itself |
| 12 | Inside a hook, worktrunk's `wt step copy-ignored` is rewritten to `djo run copy-ignored`, an alias lookup that fails (`post-start(copy) failed (exit 64)`). A failed hook never fails the run — so a broken hook is invisible unless somebody reads the log |
| 13 | Template variables differ: under dojjo `repo_path` = the **new workspace**, `primary_workspace_path`/`base_workspace_path` = the `default` workspace = `<wrapper>`; `{{ branch }}` **is** defined (worktrunk could not expand it for a detached worktree) |
| 14 | A wrapper with **no git at all** works: `jj git init --no-colocate`, `printf '*' > .gitignore`, `jj workspace add --name main main`, `jj sparse set --clear`, `jj new 'root()'`, then a workspace created with `jj workspace add` and its hooks run by `djo hook post-start` (re-verified for this design; this is the path that is used) |
| 15 | **Every dojjo path that resolves the shared `.jj` is broken in the wrapper layout.** `<workspace>/.jj/repo` holds the *relative* text `../../.jj/repo`; `state.dart:8-23` takes its dirname and joins `djo-state` / `djo/logs` onto it **without resolving it against the workspace**, so from `<wrapper>/main` the answer is `<wrapper>/../.jj`. Consequence: `djo switch` dies `PathNotFoundException: Cannot open file, path = '../../.jj/djo-state'` with exit 1 — *after* it has created the workspace and run the hooks — and `djo hook` writes its logs to `<wrapper>/../.jj/djo/logs`. A wrapper whose parent happens to hold a `.jj` works, which is why the earlier `/tmp` findings looked green: `/tmp/.jj` exists, dated from those very probes |

## Decisions made by the owner

- **The runbook is the deliverable for the other repos**; the owner runs it. He
  does not mind whether a repo is converted by rebuilding its working copy or by
  cleaning it up in place — the runbook covers both.
- **The `[post-remove]` forget hook is deleted outright**, not carried forward
  as `[hooks.post-remove]`.
- **`djo switch` is not used**; `jws` creates workspaces with jj and runs `djo hook post-start` as a separate step, keeping dojjo for what it does correctly (hooks and `remove`).
- **Hook logs at `<wrapper>/../.jj/djo/logs` are acceptable** — one shared, last-writer-wins log set per parent directory — rather than carrying a patched dojjo build.
- **Every git-ignored path comes across** on a workspace create: `djo copy-ignored` has no include filter and does not read `.worktreeinclude`, so `node_modules` is copied along with `.env`. Accepted. **Correction, measured on 0.2.2 after this was written: it *does* read `.worktreeinclude`**, applying each line as a literal include and turning the copy off when a line matches nothing — so a wrapper carrying worktrunk's `.env*` glob copies nothing, `jinit` seeds the file empty for that reason, and [the runbook](../../dojjo-conversion-runbook.md) carries the procedure for the repos that still hold one.
- `gclone` / `ginit` / `gws` stay exactly as they are.
- No hook approval gate is acceptable.
- The owner is stripping git from pi-rex himself; the flow must work without it.
- The fish functions live in `~/.config/fish/functions/` (unversioned, like
  `gws`) and are part of this bead's deliverable.

## Calls made in this design (mine, not the owner's)

- `jws` is the **only** place dojjo is named: `djo hook post-start` after a create, and `djo remove` in the teardown. Workspace creation is jj's.
- `jws` reads the new workspace's path from `jj workspace list`, never from a tool's chatty stdout.
- A hook failure is dojjo's to report (it prints the line and the log path on stderr). `jws` does not try to turn it into its own failure — `djo hook` exits 0 either way.
- The hook config keeps its filename `.config/wt.toml`, so no repo can be left
  with a stale file that dojjo half-reads.
- `2026-11-03-rex-jj-workspaces-design.md` and the done-flow spec are **updated
  in place** to match, rather than superseded by a second stack of documents.
- Name validation stops using `git check-ref-format` and becomes a pure-shell
  rule that accepts exactly what git accepted (see *Name validation*).
- `jinit` keeps ginit's beads steps (fresh db at the wrapper, dolt remote,
  initial push), because a wrapper without a beads database is not what the rest
  of the flow expects.
- Verification happens **(a)** end to end in `rex-config` itself — which this
  bead also converts — and **(b)** in a scratch wrapper with no `.git` at all,
  because pi-rex's git strip is the owner's to do.

## How it works

### The units, and where the change lands

| Unit | File | Change |
|---|---|---|
| `jws` | `~/.config/fish/functions/jws.fish` (new) | the whole workspace job: wrapper walk, `builtin cd` to `main`, bounded fetch, `jj workspace add` (+ bookmark for a create, `-r <bookmark>` for an attach, existence guard for a switch), `djo hook post-start`, path from `jj workspace list`, `--path-file` |
| `jinit` | `~/.config/fish/functions/jinit.fish` (new) | a fresh wrapper from an empty remote: `.jj` only, `main` workspace, inert `default`, `[hooks]` seed, beads, first push |
| `jclone` | `~/.config/fish/functions/jclone.fish` (new) | the same end state from an existing remote: `jj git clone --no-colocate`, `main` workspace, beads from `refs/dolt/data` |
| picker | `new-work.sh` (`wt_branch_rows`, `local_branch_rows`, `branch_mode`, fixtures) | workspaces from `jj workspace list`, branches from `jj bookmark list` |
| name rule | `new-work.sh` (`valid_branch_name`) | no `git check-ref-format` |
| base default | `new-work.sh` (`origin_head_ref`) | no git at all: the `--origin-head` fixture or nothing, then bookmark `main`, then `master`, then `@` |
| tab wrapper | `init.lua` (`M.new_tab_script`) | `switch` → `jws --existing`; `create`/`attach` → `jws`; `jq` and `wt` gone |
| project | `init.lua` (`M.project_for`, `M.main_worktree`) | no `git rev-parse`; the wrapper walk; worktrunk's `main` flag fallback deleted |
| done | `new-work.sh` (`done_wt_*`, `cmd_done`), `init.lua` (`M.work_done_go`) | `djo remove -y`; verification stays on `jj workspace list`; kept-bookmark from a `bookmarks(exact:…)` revset, not a `jj bookmark list` (see *The done flow*) |
| requirements | `new-work.sh` (`pick` preflight), `init.lua` (`M.options` docs), `README.md` | `djo` and `jws` instead of `wt` and `gws`; `git` no longer required |
| docs | `README.md`, `docs/superpowers/specs/2026-11-03-…`, `2026-11-05-…` | dojjo/jj vocabulary, no "worktrunk owns the switch" claims |
| hooks | each repo's `main/.config/wt.toml` | out of this repo — the runbook |

### `jws`: the one seam, and the workspace itself

```
jws [--path-file FILE] [--attach | --existing] <branch> [base-revision]
```

The sibling of `gws`, deliberately the same shape, with three modes instead of
two. dojjo creates nothing here — the workspace is jj's, and `jws` runs dojjo
only for the hooks:

| flag | means | what runs |
|---|---|---|
| *(none)* | create the workspace **and a bookmark for it** | `jj workspace add --name <branch> <path> [-r <base>]`, then `jj bookmark create <branch> -r @`, then `jj bookmark track <branch>@origin` where origin names one |
| `--attach` | the bookmark exists, the workspace does not | `jj workspace add --name <branch> <path> -r <branch>` — a new commit on top of the branch; the bookmark is left where it is, as it was before |
| `--existing` | the workspace exists; switch only | nothing but the row read — no creation, no hooks |

and then, for a create or an attach only, **`djo hook post-start`, run inside the
new workspace**.

Steps, in order:

1. Parse with `argparse` exactly as `gws` does, resolve a relative `--path-file`
   against the **caller's** cwd before any `cd`, and refuse `--attach` /
   `--existing` together with a base revision (both start from something that
   already exists).
2. Walk up for the nearest ancestor holding `.jj/repo` **as a directory**. That
   directory is the wrapper. Refuse, in one line, when there is none
   (`no jj repo at or above cwd`), and when `<wrapper>/main` is missing.
3. Refuse when `djo` is not on the `PATH` (`command -q djo`) — for a create or an
   attach, which run the hooks. `--existing` runs jj only and does not need it.
4. `builtin cd <wrapper>/main`, checked. That is where `jj workspace`, the
   workspace's sparse patterns and the fetch all have to run from.
5. **Fetch** — only when a base revision was given: `jj git fetch` bounded by
   `timeout 30` / `gtimeout 30` when present, unbounded otherwise. A failed
   fetch prints one line and **carries on** (dojjo never fetches, constraint 5;
   the pane is a terminal nobody can type into).
6. **`--existing` guard.** Read the workspace rows (`jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'`) and refuse — one line, non-zero, before anything is created — when the branch is not one of them. Switch mode creates nothing and runs no tool that could prompt, so a name that might not exist cannot reach `djo` at all.
7. The destination is the branch with `/` → `-` (`feat/x` → `<wrapper>/feat-x`),
   computed here rather than by a worktrunk template, so a directory `rex` makes
   sits exactly where `gws` used to put it. A destination that already exists is
   refused: nothing is adopted, deleted or overwritten.
8. `jj workspace add --name <branch> <path>` from `main` — with `-r <base>` for a
   create that was given one, with no `-r` at all when the picker said "no
   revision" (the workspace then sits on `main`'s working copy, exactly as the
   old `create = false` path meant), and with `-r <branch>` for an attach.
   jj creates no bookmark, so:
9. Create only: `jj bookmark create <branch> -r @` in the new workspace, then
   `jj bookmark track <branch>@origin` when origin names that bookmark (its
   absence is not an error — most branches are new).
10. Create and attach: `djo hook post-start` inside the new workspace. Its output
    is the pane's, and a hook failure is **not** a create failure: dojjo prints
    the failing hook and the log path and exits 0 (constraint 2). The log lives
    in `<wrapper>/../.jj/djo/logs` (constraint 15), and dojjo's own line names
    it — `jws` does not repeat it.
11. **Read the path from jj**: the row whose name is exactly `<branch>` in
    `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'`. No row after a create
    or an attach is a failure, one line, and nothing is written: a path the tab
    guessed is the failure this shim exists to prevent.
12. Write the path and a newline to `--path-file`, through `tee` for the reason
    `gws` does it (fish prints its own warning for a failed redirect and cannot
    be quieted), then `builtin cd` into it, then print the two closing lines —
    with `djo remove <branch> -y`, or `ctrl+space>d`, as the removal hint.

Everything `gws` borrows through `command` stays borrowed through `command`, `cd`
stays `builtin cd` (on this machine `cd` is a `ze` jumper and `rm` is a `trash`
wrapper), and the branch reaches jj as one quoted value after a `--` terminator.
The programs `jws` needs are `jj`, `djo` and fish itself — no `wt`, no `git`, no
`jq`.

### `jinit`: a fresh wrapper, no git layer

`jinit <directory> <git-remote-uri>` — `ginit`'s counterpart for repos whose
remote is plain and empty.

1. `take <directory>`, then the **same nesting guard as `ginit`**: walk the
   parents for a real beads workspace (`embeddeddolt` or `metadata.json`) and
   refuse rather than let `bd init` adopt the parent's database.
2. The wrapper: `jj git init --no-colocate .` — a `.jj` and **no `.git`
   anywhere** — and `printf '*' > .gitignore`, so the `default` workspace's
   snapshot cannot absorb anything before it is sparse-cleared.
3. `main` as a workspace of that repo (`jj workspace add --name main main`),
   **before** the sparse-clear, because a new workspace inherits the current
   workspace's sparse patterns and `main` must inherit the full set.
4. Make `default` inert exactly as `ginit` does: `jj sparse set --clear` then
   `jj new 'root()' -m 'default workspace: intentionally empty (see jinit)'`.
   Never `jj workspace forget` it — a forgotten default is resurrected by any
   stray jj command run from a non-workspace directory, and junk-snapshots the
   wrapper.
5. The seed commit, in `main`, **before any workspace is created from it**:
   `README.md`, `.gitignore` (`.env`, `.worktrees/`, `.beads/`), `.worktreeinclude`
   (created **empty**, so dojjo's literal include filter yields no lines), and
   `.config/wt.toml` in the **[hooks]** form —
   a `[hooks.post-start]` table, never a top-level `[post-start]`. Naming as today:
   `[hooks.post-start] copy = "djo copy-ignored --from main"`, plus a
   `beads-redirect` hook only where a repo wants a worktree-local
   `.beads/redirect` (wrapper-layout repos find the wrapper's `.beads` by upward
   detection, so the default is no redirect hook at all).
6. Remote and history: `jj git remote add origin <uri>`, `jj git fetch`,
   `main@origin` tracking for bookmark `main`, first push.
7. Beads at the wrapper root: `bd init --skip-hooks --skip-agents`, verified to
   have landed at the wrapper (not a parent), `chmod 700 .beads`,
   `bd dolt remote add origin <dolt uri> --allow-git-origin`, `bd dolt push`.
   The ssh short form is normalised to `git+ssh://` exactly as `ginit` does.

The exact command order around steps 4–6 is the builder's, subject to one
verification: `jinit` produces a wrapper where a `jws` create (`feat/x`) lands at
`<wrapper>/feat-x` with its hooks run, and `git` is nowhere in the result.

### `jclone`: an existing remote, no git layer

`jclone <remote> <directory>` — `gclone`'s counterpart.

1. `jj git clone --no-colocate <remote> <wrapper>` (falls back to a clone into a
   scratch directory plus `jj git remote add` + `jj git fetch` if 0.47's clone
   cannot be told not to colocate — builder verifies and pins one).
2. `main` exists **as a workspace named `main`** at `<wrapper>/main`, and the
   `default` workspace at the wrapper is inert (sparse-cleared, `root()`), the
   same shape `jinit` ends in. `jj workspace rename` / `workspace add` both
   reach it; whichever the builder uses, the end state is checked with
   `jj workspace list`.
3. Beads, recovered rather than created — and **all of it after the sparse-clear**,
   because the `default` workspace's snapshot absorbs wrapper files until it is
   cleared and the clear then dematerializes them (the `gclone` caveat, verified
   the hard way). Order inside that step: write `.beads/config.yaml` with
   `sync.remote` **first**, then `bd bootstrap --yes` (which answers `No active
   beads workspace found` without it in a git-less wrapper, so it cannot run
   first), then `.beads/metadata.json` naming the recovered database.
4. Hooks come from the cloned repo — `jclone` seeds nothing. A repo whose config
   is still worktrunk-shaped is what the runbook exists for.
5. `rex window rename main`, as `gclone` does today.

### The picker: workspaces and bookmarks instead of worktrunk and git

`candidates` and `branch_mode` keep their shape — two lists, worktrees first —
and swap both sources:

| today | after |
|---|---|
| `wt_branch_rows` → `wt list --format=json` → `.worktree.branch` | `workspace_rows` → `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'` from `--main`, first field of each row, skipping the row named `default` |
| `local_branch_rows` → `git for-each-ref refs/heads` | `bookmark_rows` → `jj bookmark list -T 'name ++ "\n"'` |
| fixture `--wt-json FILE` (a saved `wt list`) | fixture `--workspaces FILE` — **the flag `done` already takes**, and the same `name<TAB>root` rendering: one saved fixture shape serves both subcommands |
| fixture `--refs FILE` (a saved `for-each-ref`) | fixture `--bookmarks FILE` (a saved `jj bookmark list -T 'name ++ "\n"'`) |

The workspace name **is** the branch name (that is the convention `gws`/`jws`
create and the one `done` already relies on), so the two lists stay comparable
by exact match and `branch_mode`'s rule is unchanged: in the workspace list →
`switch`; else in the bookmark list → `attach`; else → `create`.

`--base-bookmarks` (the base cycle's fixture) is a different seam and keeps its
name; `--bookmarks` is the branch list. Neither may stand in for the other.

Failures keep their asymmetry: a `--workspaces` or `--bookmarks` fixture that
cannot be opened is a caller's mistake and travels up; a live `jj` that cannot
read the repository is a failed read that `candidates` forgives (the other half
of the list is still worth printing) and `branch_mode` refuses, because half a
list cannot tell a switch from an attach.

### The remote default branch without git

`origin_head_ref` is what the base cycle opens on, and it asks git nothing at
all. `git symbolic-ref --short refs/remotes/origin/HEAD` was the flow's last git
read, in a wrapper whose whole point is that there is no `.git` to answer it —
and jj records no remote-HEAD symref to put in its place. So the read is gone
rather than conditional, and the function answers only what it was told: the
`--origin-head` fixture a test or a dry run hands it, and empty otherwise. An
empty answer is a fall-through rather than an error, and `base_chain`'s existing
chain answers for it: bookmark `main@origin`, then `master@origin`, then `@`.
That is the design, not a compromise — whether a clone calls its default branch
`main` or `master` is a convention, jj keeps no answer of its own, and reading a
symref wherever a `.git` happens to survive would make the opening revision
depend on a layer the owner is deleting. Whether the answer is worth *recording*
at clone time so it is exact rather than conventional is in "What's left to the
builder".

### Name validation without git

`valid_branch_name` stops calling `git check-ref-format --branch`. `git` is not
in the flow's requirements any more, and a no-git wrapper has no `git` to call.
The rule becomes pure shell, and **accepts exactly what git accepted** so no
name that worked yesterday starts failing:

- refuse the empty name, `@` on its own (in jj's language `@` is the working
  copy, and a bookmark called `@` would be read as a different question),
  anything starting with `-`, anything containing whitespace, `..`, `~`, `^`,
  `:`, `?`, `*`, `[`, `\`, `//`, and anything ending in `/` or `.`;
- allow letters, digits, `.`, `_`, `-` and `/` elsewhere.

Two names can still sanitise to one directory (`feat/x` and `feat-x` both want
`<wrapper>/feat-x`). That collision predates this cut — worktrunk's
`worktree-path` template had it too — and is already refused by the
destination-exists check, so it is documented rather than solved.

### The tab wrapper: `switch` through `jws`, and `jq` gone

The script keeps every one of its properties (survives the agent, lands in the
new workspace and nowhere else, an unreadable path starts no agent, one readable
line above a login shell). What changes:

- `switch` no longer runs `wt switch --no-cd --format=json` piped into `jq`.
  It runs `jws --existing <branch> --path-file <f>` and reads the first line of
  the file — the same reading the create and attach paths already do. The three
  modes therefore share one shape, one temp file, one failure vocabulary, and
  the wrapper needs neither `jq` nor `wt`.
- The two failure lines that named `jq` collapse into one: `could not read the
  workspace path of <branch> from the jws path file`.
- `--existing`'s guard is the reason a switch can no longer hang or invent a
  workspace: the shim refuses a name jj does not list, before anything runs.
- `GIT_TERMINAL_PROMPT=0` stays exported: post-start hooks may still run git.

Mode is still carried from the picker as `switch` / `attach` / `create` in
`worktree`, with the base revision only for `create`; the payload is unchanged.

### `project_for` without git

`M.project_for` currently reads `git rev-parse --git-common-dir` to find the
project root. A wrapper with no `.git` has no such answer, so the read becomes a
walk: from the cwd, up to the nearest ancestor holding `.jj/repo` **as a
directory** — the wrapper — with the project name taken from that directory's
basename. Anything else is **refused by name**, including a plain colocated repo
(files at the root, `.jj/repo` a directory there, no `main` workspace beside it):
this flow cannot make a workspace in one, and saying so here is kinder than a
picker that opens and then has nothing to offer.

`M.main_worktree` and its worktrunk fallback are deleted: `main_workspace` (jj's
own `main` row, already implemented) is the only answer, and when it is absent
the project is refused by name instead of falling back to a flag that has been
observed naming the wrong worktree.

### The done flow

The audit is unchanged — the fetch, the merged diff, the working-copy check, the
running-program check, main's fast-forward, the bead — because none of it was
worktrunk's. What changes is the two ends of it:

- **Finding the workspace** (`done_workspace`): `done_wt_list` / `done_wt_path` /
  `done_wt_owner` and the "worktrunk and jj disagree" refusals go. `jj workspace
  list` is the only list; the wrapper row and the `main` row are still refused
  by name, and "this directory is not inside a jj workspace this wrapper knows
  about" becomes the single refusal. The `/p/demo` trailing-slash normalisation
  stays.
- **Removing it** (`M.work_done_go`): `djo remove <workspace> -y`, run from
  `main`, with `-y` because nobody is there to answer. dojjo deletes the
  directory, forgets the workspace and deletes the bookmark, so:
  - the `SETTLE_READS` loop and the `jj workspace forget` fallback both stay —
    the row is what is verified, not an exit code — but the fallback now almost
    never fires;
  - the worktree check becomes `test ! -d <path>`, since there is no `wt list`
    to read;
  - `branch_outcome` is gone. **The kept-bookmark line comes from
    `jj bookmark list`**: if `<workspace>` still names a bookmark after the
    removal, the report says `the bookmark <name> was kept: jj bookmark delete
    <name>`; otherwise the teardown deleted it and the branch is gone. dojjo
    has no merged check, so a bookmark left behind is the only "kept" case that
    exists. **Deviated in the implementation, and for a reason the design did
    not have:** a `jj bookmark list` cannot answer it, because `djo remove` only
    tombstones a bookmark a remote tracks and a tombstone goes on printing its
    name in a listing. So the read is `jj --ignore-working-copy log --no-graph
    -r 'bookmarks(exact:"<name>")' -T 'commit_id ++ "\n"'`, a revset that
    resolves only while the bookmark is really there;
  - `-D` disappears from the vocabulary: nothing in this flow runs worktrunk, so
    there is no command to name for a branch worktrunk refused.
- The hand-back payload (`project`, `root`, `main`, `workspace`, `path`) is
  unchanged, and the script's last two acts — the hand-back, then `cd "$main"`
  and `rex window close` — stay in that order.

### Requirements and failure lines

- `pick`'s preflight: `need wt` → **`need djo`**, `need_fish_function gws` →
  **`need_fish_function jws`**, and `need git` **goes away** (nothing in a pick
  needs it once the name rule and `branch-default` are git-free). `need jj`,
  `need jq` and `need bd` keep their places and their conditions. The wrapper
  check (`.jj/repo` a directory beside `main`) stays word for word — it is the
  check that stops a bead being claimed for a pane that cannot be made.
- No `need djo` where nothing will run it: a `--dry-run` creates no workspace,
  so the `djo` requirement sits exactly where the `gws` one sits today.
- The tool still does not own the shim's version: `jws` reports what `djo` says.
- `README.md`'s Requirements section names `djo` and `jws`, and drops `wt`.

### Docs

- `docs/superpowers/specs/2026-11-03-rex-jj-workspaces-design.md`: updated in
  place — the `gws`-owns-creation and worktrunk-owns-switch sentences become
  `jws`/dojjo, and its Migration section points at the runbook below.
- `docs/superpowers/specs/2026-11-05-rex-done-teardown-design.md`: updated in
  place — `wt remove` and `branch_outcome` become `djo remove -y` and
  `jj bookmark list`, and the "Seeding the `post-remove` hook" section becomes
  "the `[hooks.post-start]` seed, and no forget hook at all".
- `README.md`: the flow section, the base-field paragraph, the failure-mode
  paragraphs, and the "Converting a repo to jj workspaces" section becomes the
  runbook.

## Edge cases and failure behaviour

- **`jws` refuses** — no `.jj/repo` above, no `<wrapper>/main`, no `djo`, no
  such workspace for `--existing`: one line naming the missing piece, non-zero
  exit, login shell, no agent.
- **`jj workspace add` fails** — its own message is on the pane, then one line
  naming `jws` and the exit status, then a shell. Nothing is retried with a
  different base: a half-made workspace is reported, not worked around.
- **jj lists no workspace after a create** — a hard failure, one line, and no
  path file: without a row there is no path to hand the tab, and a path the tab
  guessed is the failure this shim exists to prevent.
- **A `--path-file` that cannot be written** — refusal before anything else is
  attempted; a caller with no path cannot find the workspace that was made.
- **The fetch fails** — one line, then the create proceeds from the revision as
  it resolves locally. Offline is not fatal.
- **A base revision that does not resolve** — `jj workspace add -r` fails and
  its message is the report. `jws` does not pre-validate revisions; the base
  cycle already refuses the ones jj cannot resolve.
- **A hook fails** — dojjo prints the failing hook and the log path and exits 0,
  so the create still succeeds and the person still gets their tab. The failure
  is in `<wrapper>/../.jj/djo/logs` (constraint 15), and the runbook's per-repo
  check is what catches a repo whose hook config is still worktrunk-shaped. This
  is the one class of failure no exit code carries.
- **`jws --existing` for a workspace that vanished between the picker and the
  tab** — refused with one line (the row is not there), rather than silently
  recreated onto a bookmark that would then collide.
- **`jws --attach` for a bookmark that is now a workspace** — the destination
  directory exists, so the create is refused before anything is made.
- **`djo remove` fails** — the report is dojjo's own line; the tab stays open,
  the bead stays in progress, and nothing is closed on a failed teardown.
- **A bookmark survives `djo remove`** — reported with the `jj bookmark delete`
  command that finishes the job, exactly as a retained branch was reported
  before.
- **A wrapper whose `main` workspace has another name** — refused by name, as
  today; the flow has no other notion of main.
- **The agent is `""`** — untouched: nothing starts, the prompt (if any) is
  printed, the pane is the workspace and a login shell.

## Testing

Everything below runs from `bash test/run.sh`, no pty:

- `test/wrapper_test.sh` — drives the wrapper through `fish` with stand-ins
  supplied via `fish_function_path`: a stand-in `jws` receives the mode's flag
  (`--attach` or `--existing`, none for a create), the branch and — for a create
  with a base — the revision, and `--path-file` names the file it writes. The
  agent starts in the directory that file named. A stand-in that writes nothing,
  or exits non-zero, leaves a login shell and starts nothing, with the right line
  on stderr. **No `wt`, no `jq`** anywhere in a run. `GIT_TERMINAL_PROMPT=0` is
  in the child's environment; a prompt starting with `-`, one containing
  `fix "it"` and `{{ now }}`, and a blank prompt each still arrive as one
  argument.
- `test/jws_test.sh` — **the shim itself**, not a stand-in: `fish_function_path`
  makes the real `jws.fish` loadable, and a stand-in `djo` (a script on `PATH`
  that records its arguments and its cwd, and can be told to fail) stands in for
  dojjo. A create adds a workspace directory the stand-in creates and a
  `jj`-shaped listing it answers with, so the assertions are: the arguments
  (`--name <branch>`, `-r <base>` only when given, `-r <branch>` for attach,
  none extra for switch), the `djo hook post-start` call and **the directory it
  ran in**, the path file's one line, the exact-path refusal when the destination
  exists, the `--existing` refusal for a name jj does not list (and **no `djo`
  invocation** in that case), and the refusals for no `.jj/repo`, no
  `<wrapper>/main` and no `djo`.
- `test/pure_test.lua` — `new_tab_argv` unchanged in shape (the mode word is
  still `switch`/`attach`/`create`); `project_for`'s wrapper walk and its
  refusal for a plain colocated repo; `main_workspace` as the only main answer.
- `test/branch_test.sh` — the base chain from a saved bookmark listing (already
  jj-shaped), plus the git-free resolution: **git is never asked**, proven with a
  liar on `PATH` that would answer `trunk` and leave a mark if it were run, and
  the cycle answers `main@origin`, then `master@origin`, then `@`.
- `test/pick_test.sh` — `branch_mode` from the new fixtures: a name in the
  workspace list is a `switch`, a name only in the bookmark list is an `attach`,
  neither is a `create`; a `--workspaces` fixture that cannot be opened fails
  loudly; a refused git-shaped name is refused for the same names git refused,
  table-driven; a run with no `djo`, or a fish with no `jws`, is refused naming
  the missing piece; `git` is not required.
- `test/done_test.sh` — `done_workspace` off a saved workspace listing; the two
  protected rows (wrapper, `main`); the removal hand-back payload; and the
  kept-bookmark report from a saved bookmark listing, in both directions.
- `test/action_test.lua` — `work_done_go` with a stand-in `djo`: removes with
  `-y` from `main`, verifies the row is gone, reports the kept bookmark, and
  refuses when the row survives the forget fallback.
- Fixtures: the workspace listings the done flow already uses
  (`workspaces.txt`, `workspaces-main-elsewhere.txt`, `workspaces-no-main.txt`)
  become the picker's seam too, and gain the fixtures its cases need
  (`workspaces-no-feat.txt`, `workspaces-default-only.txt`); `bookmarks.txt`
  keeps serving the base cycle, and `branch-bookmarks.txt` is the picker's local
  bookmark list. `wt-list.json`, `done-wt-list*.json` and `wt-remove-*.json` are
  deleted. Every test that pinned a worktrunk JSON document is rewritten, not
  adapted.
- **By hand, once, in the float**: `ctrl+space>n` create / attach / switch in a
  converted repo, then the done flow; `jws` by hand with `--path-file`, with a
  bad base, with `--attach` on a bookmark, and with `--existing` on a name that
  is not a workspace (must refuse, not prompt). A pipe cannot prove the agent
  and `^C` behaviour, and pretending otherwise would be the test lying.

## The runbook (what it must contain)

A document the owner follows per repo, after this work lands. It is written from
the inventory below, and each repo's file is read before it is edited.

| repo | `main/.config/wt.toml` today |
|---|---|
| pi-rex | `[post-start] copy = "wt step copy-ignored --require-include"`; `[post-remove] jj = "jj workspace forget {{ branch }} 2>/dev/null \|\| true"` |
| pi-carte | same as pi-rex |
| pi-garnish | same as pi-rex |
| pi-whetstone | same as pi-rex |
| rex-config | `[post-remove]` forget only |
| pmm-iris | `[post-start] copy = …`, `dev = "bun install"`; `[post-remove]` forget |
| ci-platform | `[post-start] beads-redirect = "mkdir -p .beads && echo '{{ repo_path }}/.beads' > .beads/redirect"` — no copy hook, no forget hook |
| pi-packages | no `.config/wt.toml` at all |

`pmm-iris_bak` is a backup directory and is left alone.

Per repo:

1. **Rewrite the hook table** as a `[hooks.post-start]` table, translating each
   hook: `wt step copy-ignored --require-include` → `djo copy-ignored --from
   main`; `dev = "bun install"` unchanged; a beads redirect → `{{ repo_path }}`
   becomes `{{ primary_workspace_path }}` (under dojjo `repo_path` is the *new*
   workspace, so the old form would point at `<workspace>/.beads`). ci-platform
   is the one repo with a redirect and no copy hook. **The copy hook no longer
   filters**: `--require-include` and `.worktreeinclude` are worktrunk's, and
   dojjo copies every ignored path — `node_modules` as well as `.env` — which the
   owner accepted; the runbook says so in as many words. Where one command must
   follow another, use a `[hooks]` pipeline (`post-start = [{ copy = … }, { dev =
   … }]`) — one entry per step, and the steps run in order.
2. **Delete the `[post-remove]` forget hook** with the rest of the old table.
   `djo remove` forgets the workspace and deletes the directory; leaving a
   top-level `[post-remove]` behind would be silently ignored, and carrying it
   as `[hooks.post-remove]` would be a no-op.
3. **Verify the table is the only one**: no top-level `[post-start]` /
   `[post-remove]` may remain anywhere in the file, or the hooks run nowhere.
4. **Two routes to the jj-only shape**, both acceptable, one per repo:
   - *Rebuild the working copy*: `jclone <remote> <dir>` into a fresh directory,
     move any uncommitted work across, and delete the old wrapper.
   - *Clean up in place*: the wrapper keeps its directory, the `default`
     workspace is already inert, and only the hook file changes — plus, where
     the repo is going git-free, removing the git layer (no bare `.git` at the
     wrapper, no git worktree registrations) after `pi-rex`'s lead.
5. **Verify in the repo**: `jws <throwaway>` from `main` creates the workspace
   and puts the hooks in **`<wrapper>/../.jj/djo/logs/post-start-*.log`** (not
   `<wrapper>/.jj/…` — constraint 15; the runbook names the real path);
   `copy-ignored` brings `.env` across; a redirect file (where the repo has one)
   points at the wrapper; `djo remove <throwaway> -y` leaves no workspace row and
   no bookmark.
6. **Commit the hook change in that repo** — it is that repo's file and its own
   commit or PR. This bead owns the runbook, not their commits.

A note the runbook must carry: `jinit`/`jclone` are for a fresh or empty remote.
Converting a *plain colocated* repo (roughly 40 of them under `~/Projects`) into
the wrapper shape is a different procedure and is deliberately out of scope.

## What's left to the builder

- Whether `jj git clone --no-colocate` in 0.47 can be told not to colocate at
  all, or whether `jclone` must clone into a scratch directory and point a fresh
  wrapper at it. Pin one, and pin the `main`/`default` ordering with
  `jj workspace list` in the scratch check.
- The exact shell rule behind `valid_branch_name`, table-driven, checked against
  what `git check-ref-format --branch` accepted for a set of awkward names so no
  name that works today starts failing.
- Whether the remote default branch is worth *recording* at clone time (so a
  no-git wrapper answers `branch-default` exactly, rather than falling through
  `main` → `master`), and where that record lives if so.
- Where the temp path file lives and when it is removed (today `mktemp` in
  `TMPDIR`, read, `rm -f`), and whether the switch path should keep its own
  `mktemp` or share the create/attach one.
- Whether the three modes stay `--attach`/`--existing` flags or become a
  positional `<mode>` word that the payload can be forwarded to unchanged.
- How `done` names the "bookmark kept" case when dojjo removed the workspace but
  left the bookmark for a reason of its own — the message names `jj bookmark
  delete`, but the builder decides whether the reason dojjo printed is also
  carried.
- The README's rewritten flow section, its requirements list, and the
  failure-mode paragraphs for a repo with no git at all.
- The `^C` and agent checks in the float, and the "`jws --existing` refuses that
  rather than prompts" check — the two behaviours no pipe proves.
- A **follow-up bead** for the dojjo defect this cut works around (constraint
  15): the one-line fix is to resolve the contents of `.jj/repo` against the
  workspace's own `.jj` directory in `state.dart`, which would put hook logs back
  under `<wrapper>/.jj/djo/logs` and make `djo switch` usable at all. Out of
  scope here, and worth an upstream report rather than a local patch.
