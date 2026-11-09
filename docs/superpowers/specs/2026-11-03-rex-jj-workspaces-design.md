# rex-config: new work lands in a jj colocated workspace

**Date:** 2026-11-03
**Status:** design, approved in conversation. **Superseded for the workspace
tool** by `docs/superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md`:
the tool that makes a workspace is `jws`, not `gws`, and the tool that runs its
hooks and removes it is `djo` (dojjo), not `wt` (worktrunk). Everything here
that is not about those two tools still stands — the tab, the path file, the
three modes and the refusals. The title's *colocated* is history as well: a
wrapper cut to jj alone has no git worktree in it, and nothing here needs one.
**Owner:** John Stegeman
**Bead:** `rex-config-pxp`

## Intent

The owner is moving off a git/worktrunk-only workflow onto jj workspaces.
`ctrl+space>n` still has to be the way work starts, so the worktree it creates
has to be a jj workspace of the wrapper's directory repo, set up in the one order
that works. (It was a git worktree as well when this was written; a wrapper cut
to jj alone has no git to make one with, and the workspace does not need one.)

`jws` (a fish function in `~/.config/fish/functions/jws.fish`) is the only thing
that knows how to do that correctly: it runs `jj workspace add --name <branch>`
**from `main`'s workspace** so the new workspace inherits the full sparse
pattern, creates the branch's bookmark, and then runs the project's post-start
hooks with `djo hook post-start`, inside the new workspace, because jj and not
dojjo made it. Project-specific setup therefore stays where it belongs — in each
repo's `.config/wt.toml` hooks — and rex learns none of it.

So this change is not "a different command": it is *delete rex's half-knowledge
of how a worktree is made and hand the whole job to `jws`*, while keeping
everything the tab does around it (agent, prompt, login shell, the failure lines
that keep an agent out of the wrong directory).

## Goals

- A create through the picker produces a jj workspace with a bookmark for the
  branch, with the project's post-start hooks run. A branch that already exists
  but has no workspace gets one the same way, jj's way, instead of an ordinary
  git worktree.
- The base a new branch starts from is the **remote's current state** of the
  default branch (`main@origin`), not a possibly stale local `main` — the
  behaviour the flow has today, expressed in jj's vocabulary.
- The tab keeps every property it has now: it survives the agent, it lands in
  the new worktree and nowhere else, an unreadable path starts no agent, a
  failure is one readable line above a login shell.
- `rex-config` itself ends up ginit'd, so the flow works in the repo that
  implements it.

## Non-goals (this cut)

- **A fallback for repos that are not ginit'd.** The flow refuses, early and
  readably; it does not quietly create a plain git worktree.
- **Any other repo's migration.** Only `rex-config` is converted here.
- **The bead, agent, prompt and base *picking* flows.** The composer, its keys,
  its state file and the remembered agent are untouched.
- **`candidates`'s sources.** Branch names came from `wt list --format=json`
  plus `git for-each-ref` when this was written; they come from
  `jj workspace list` and `jj bookmark list` now (the 2026-11-06 design), and
  `branch-default` still names branches. What this cut changes is that the
  picker reads that list for a *decision* (is this a worktree, an existing
  branch, or neither?) and not only for a suggestion.
- **Workspace removal.** Still by hand — `djo remove <name> -y` — because the
  key that does it is the 2026-11-05 design. No seed hook forgets the workspace
  any more: `djo remove` forgets it itself, which is why that hook was deleted.
- **PR/MR shortcuts.** `wt switch pr:12` *created* a worktree — history: the
  flow runs no worktrunk at all now — so those shortcuts left `candidates`. A PR
  head is still reachable the manual way: fetch the branch, then pick its name
  (attach) or `jws` it by hand.

## Anti-goals

- A second copy of `jws`'s knowledge inside rex — the `<wrapper>/<name>` layout,
  the sparse inheritance, the bookmark, the manual hook run.
- Capturing `jws`'s stdout to find the new path. That output is the pane's, and
  it carries the post-start hooks' own chatter; swallowing it to parse a path
  would hide the project's setup from the person watching.
- An agent starting in a directory nobody verified.
- A silent fallback that turns "this repo isn't ginit'd yet" into a plain
  worktree that quietly recreates the problem jj is there to solve.

## Constraints

- **`jws` lives outside this repo** (`~/.config/fish/functions/`, unversioned,
  like `gws`). Its contract is pinned in this document and driven for real by
  `test/jws_test.sh`, which reads the developer's own file and **fails** rather
  than skips when it is not there: a real `jj workspace add` makes the workspace
  and a stand-in `djo` is what stands in for dojjo's hooks.
- **Rex runs actions with its own PATH** (`/usr/bin:/bin:…`), while `fish`,
  `jj`, `djo`, `jq`, `bd` and `fzf` live on the login shell's PATH. The tab's
  pane is a login shell, so the wrapper may rely on that PATH — but the wrapper
  is now a fish program, so `fish` must be on it.
- **`fish -c SCRIPT <words…>` puts those words in `$argv`**, element by element:
  no `$0` slot (`sh -c` needed the spare `sh`). A branch with a slash and a
  prompt with spaces still arrive as single values.
- **`jj workspace add` refuses a non-empty destination directory**, so existing
  worktrees cannot be adopted in place (verified — see the runbook). It also does
  not create parent directories: a branch like `feat/pxp` cannot become a
  directory path on its own.
- **In a wrapper, `<wrapper>/main/.jj/repo` is a file**, not a directory; only
  `<wrapper>/.jj/repo` is a directory. That is how `jws` finds the wrapper, and
  how the refusal check can tell a ginit'd wrapper from a plain colocated repo.
- Branch names are sanitised into directory names **the way `gws` does it**
  (`feat/pxp` → `feat-pxp`, the layout worktrunk's `worktree-path` template
  already produced), so a rex-created workspace sits exactly where a `gws`-created
  one does. The workspace is named after the branch, slashes and all, which is
  what makes `jj workspace list` the list every part of the flow reads and
  `djo remove <branch> -y` the removal (verified: `--name 'feat/pxp'`, then
  `djo remove 'feat/pxp' -y`).

## Decisions made by the owner

- Creation goes through `jws`; dojjo keeps owning the hooks. No fallbacks
  anywhere.
- The tab wrapper becomes `fish -c` instead of `sh -c`.
- The base answer is in jj land: one revision string, and the fetch moves to jj.
- The default base stays the current state of `main@origin`, because the local
  working copy of `main` may not have been updated.
- `jws` carries `--path-file`, so the caller learns the path without touching
  the pane's output.
- `jws` sanitises the branch name into a directory the way `gws` does, and
  names the jj workspace after the branch.
  An existing branch with no worktree is handled by `jws` too, not by making an
  ordinary git worktree: the picker says which of switch / attach / create it
  means.
  `jws.fish` is its own file in `~/.config/fish/functions/`, beside `gws`.
- The `rex-config` conversion is a runbook the owner runs, not something the
  plan executes.

## How it works

### The units, and where the change lands

| Unit | File | Change |
|---|---|---|
| `jws` | `~/.config/fish/functions/jws.fish` | the whole workspace job: the wrapper walk, the fetch, `jj workspace add` plus the bookmark (or `-r <bookmark>` for an attach), `djo hook post-start`, the path from `jj workspace list`, `--path-file` |
| tab wrapper | `init.lua` (`M.new_tab_script`) | rewritten as fish; three modes — switch via `jws --existing`, attach and create via `jws` |
| argv builder | `init.lua` (`M.new_tab_argv`) | `fish -c`; three positional words instead of four; `<mode>` replaces `<create>`; no remote |
| base cycle | `new-work.sh` (`base_chain`, `cmd_bases`, `pick`) | jj revisions from `jj bookmark list --all-remotes`; no remote column |
| mode decision | `new-work.sh` (`pick`) | a picked name is said to be an existing worktree, an existing branch, or a new one |
| refusal | `new-work.sh` (`pick`'s preflight) | no `.jj/repo`, no `jj`, no `djo`, or no `jws` function is refused before the screen |
| the repo | `rex-config` | a runbook the owner follows after this lands — the plan does not convert it |

Nothing else moves. The composer, `branch-default`, `beads`, `preview`, the
state file and the payload's other keys are untouched.

### `jws`: the path file, the three modes, and the fetch

```
jws [--path-file FILE] [--attach | --existing] <branch> [base-revision]
```

- **`<branch>` is the branch name, slashes and all** — the thing the picker
  chose. The directory is that name with every `/` replaced by `-`
  (`feat/pxp` → `<wrapper>/feat-pxp`), and the workspace is created with
  `--name <branch>`, so a workspace made by rex sits where a `gws`-made one does
  and `djo remove <branch> -y` names it exactly.
- **`--attach`** — the branch already exists but has no workspace: run
  `jj workspace add --name <branch> <path> -r <branch>`, which is a new commit on
  top of the bookmark with the bookmark left where it is (the state `gws` +
  `git checkout <branch>` left behind). Everything else — hooks, path file,
  closing lines — is the same as a create, and the bookmark work below is
  skipped, because the bookmark is what the add borrowed. Without the flag the
  branch and its bookmark are made.
- **`--existing`** — the workspace already exists: read `jj workspace list`, and
  refuse a name it does not list. Nothing is created and no hooks run, which is
  also why a name that might not exist cannot reach `djo`, whose prompt in a pane
  nobody can type into is an invisible hang.
- **`--path-file FILE`** — on success, write the absolute path of the new
  workspace and a newline to `FILE`, immediately before the final `cd`. Nothing
  `jws` prints changes: stdout and stderr remain the pane's, which is the whole
  point of a file rather than a parseable line.
- **The fetch** — when a base revision is given, run `jj git fetch` before
  `jj workspace add -r`, bounded by `timeout`/`gtimeout` at 30 seconds when one
  of them is installed and unbounded otherwise (today's wrapper behaviour, moved
  intact). A failed fetch prints one line naming the revision and **carries
  on**: the workspace is created from the revision as it currently resolves.
  With no base revision nothing is fetched, so a bare `jws name` stays fast and
  works offline. dojjo never fetches, so this is the only fetch there is.
- **Unchanged** — the ancestor walk for `<wrapper>/.jj/repo`, the refusal when
  `<wrapper>/main` is missing, `jj workspace add --name <branch>` run from
  `main`, `djo hook post-start` inside the new workspace (a hook failure is
  dojjo's to report and does not fail the create), the closing `cd`, and both
  printed lines.

The `timeout` bound and the failed-fetch line exist because the pane is a
terminal nobody can type into: a credential prompt or a dead network must not
hang there invisibly. `jj` fails rather than prompting, and the wrapper still
exports `GIT_TERMINAL_PROMPT=0` for the `git` that post-start hooks run.

### Switching, attaching, creating

The picker already holds both lists it needs — `jj workspace list` says which
branches have a workspace, and `jj bookmark list` says which branches exist —
so it answers the question the create flag was never able to: **which of three
things did you just pick?**

| The name is… | mode | What runs |
|---|---|---|
| on an existing workspace | `switch` | `jws --existing <branch> --path-file <f>` |
| an existing branch, no workspace | `attach` | `jws --attach <branch> --path-file <f>` |
| neither | `create` | `jws <branch> [<base-revision>] --path-file <f>` |

`switch` is the only mode that creates nothing, and the only one where a
workspace already exists — so it can never make a second one: `jws --existing`
refuses a name jj does not list, before anything runs. That is the
hole this closes: `create = false` used to mean both "switch to that worktree"
and "that branch has no worktree, let wt make one", and the second meaning
quietly produced an ordinary git worktree inside a jj wrapper. `pr:N`/`mr:N`
shortcuts are gone with it, because they are creates too.

`base` is sent for `create` only: `attach` starts from the branch itself and
`switch` from nothing.

### The tab wrapper: fish instead of sh

`new_tab_argv` builds:

```
fish -c SCRIPT <mode> <branch> <base> <agent> [agent_args … ] <prompt>
```

Three positional words before the agent, instead of four — the remote is gone
with the git fetch. `fish` has no `$0` slot, so `$argv[1]` is the mode, one of
`switch`, `create`, `attach`.

The wrapper's shape, in order, keeping today's meanings:

1. `set -gx GIT_TERMINAL_PROMPT=0`, first.
2. A broken caller — fewer than three words, or a mode it does not know — says
   which words it needs and leaves a login shell, rather than dying inside
   `$argv[1]`.
3. **All three modes**: `mktemp` a path file, then
   `jws [--attach | --existing] <branch> [<base-revision>] --path-file <file>`,
   and read the path from that file's first line. The base word is omitted
   entirely when it is empty, and it is never sent for `attach` or `--existing`.
   One shape for the three modes means one temp file and one failure vocabulary,
   and the wrapper needs neither `jq` nor `wt`.
4. No path, one line naming **which** step failed (jws's exit status, or a zero
   exit whose path file says nothing), then a login shell and no agent.
5. `cd -- <path>`; the same line and shell if it fails.
6. No agent: any prompt the picker really typed is printed above the login
   shell — never silently dropped.
7. An agent: `^C` must reach the agent and not the wrapper, so the wrapper
   installs a no-op handler (`function … --on-signal INT`) for the length of
   the agent's run. Unlike `sh`'s `trap '' INT`, a fish handler is not inherited
   across `exec`, so the agent child gets the default disposition without a
   nested reset — **the builder verifies this with a real `^C` in the float**,
   because a pane that dies with the agent is the failure this guard exists for.
8. Every exit path ends in `exec $SHELL -l`, falling back to `/bin/sh -l`.

There is no `sh` fallback. A machine without `fish` on the pane's PATH fails
loudly rather than half-working; `fish` is the login shell here.

### The payload

`pick`'s hand-back keeps every key it has and changes one:

```json
{ "project": …, "root": …, "main": …, "branch": …, "bead": …, "title": …,
  "worktree": "switch" | "create" | "attach",
  "base": "main@origin" | false,   // absent = the picker never answered
  "prompt": "…" | absent,
  "blank": true,
  "agent": "pi" | "" }
```

- `base` is a **jj revision**, still three-valued: a string is the revision to
  create from, `false` is "no revision at all" (no `-r`, so the new workspace
  sits on `main`'s working copy), and absent means the picker never answered and
  the configured `base` applies. It is only meaningful for `create`.
- `base_remote` **disappears**. There is one carrier for "where the base comes
  from" — the `@remote` suffix inside the revision — and a second field that can
  disagree with it is how a fetch lands on the wrong remote.
- `worktree` **replaces `create`**, because the boolean could not say the third
  thing. For the hand-run payloads the old key still works: when `worktree` is
  absent, a `create` of `true` is `create` and anything else is `switch`, which
  is exactly what `new_tab_argv` did with it before. The builder sets that
  fallback in one place, in the argv builder, where the argument contract
  lives.
- `work_new_go`'s declared `args.properties` must swap `create` for `worktree`,
  keep `base`, and drop `base_remote`: an undeclared key is filtered before the
  action, so a stale declaration silently loses the answer.

### The base cycle: jj revisions

`base_chain` stops reading git refs and reads jj's bookmarks instead: one
`jj bookmark list --all-remotes` per picker run, rendered as one
`<name>@<remote>` per line, with the `@git` mirror dropped (it is jj's own local
mirror of the remote-tracking refs, not an answer anyone wants to start from).

- **The opening answer stays "the remote's current state of the default
  branch"**: `<branch>@origin`, where `<branch>` is a **conventional** name and
  not a resolved one — `main`, then `master`, decided from the bookmarks. The
  `refs/remotes/origin/HEAD` read this used to name is gone entirely (the
  2026-11-06 design): it was a git fact, and a wrapper cut to jj alone has no
  git to ask, so asking git only where a `.git` happened to survive would have
  made the opening revision depend on the layer being deleted. `--origin-head`
  is the fixture that stands in for a resolved answer. The fetch that makes it
  *current* happens in `jws`, in the tab, after the answer was given.
- **The cycle** stays `[default, "@", "main", "master"]` — all three of the
  others are valid jj revisions (`@` is the working copy, `main` and `master`
  local bookmarks) — deduplicated, with entries jj cannot resolve dropped and
  the configured first entry kept even when it does not resolve, exactly as
  today.
- **`base = false`** is unchanged as a configuration answer: the field opens on
  "no revision at all" and ctrl-r still cycles away from it. Its header label
  changes from `base: wt default` — worktrunk's default, and history now — to
  `base: none`, because there is no tool's default to hand it to any more.
- **Rows lose the remote column**: `bases` prints one revision per line, and an
  empty line still means "nothing".
- **The fixture seam is renamed and re-rendered**: `--base-refs` (a saved
  `for-each-ref`) becomes `--base-bookmarks` (a saved
  `jj bookmark list --all-remotes` rendering), so tests and dry runs keep
  standing in for jj without one installed.

### Outside a ginit'd repo: refuse, don't fall back

`pick`'s preflight gains three checks, next to its `need fzf` / `need bd` lines
and under the same rule — they only run where the screen will really open, and a
saved fixture stands in for the tool it replaces:

> the directory holding `--main` must contain `.jj/repo` as a **directory** — the
> wrapper `jinit` makes, with `main` beside it — `jj` must be on the login
> shell's PATH (the base cycle runs it), `djo` must be there too (a new
> workspace's post-start hooks are dojjo's), and `jws` must be a fish function
> (`fish -c 'functions -q jws'`), because the tab cannot create anything without
> it and a bead claimed for nothing is worse than a refusal.

The first check is the wrapper and only the wrapper. A clone `jj git init`ed
where it stands — `.jj/repo` inside the main worktree rather than beside it —
fails it deliberately, even though `jws`'s own ancestor walk would find that
repo, for a different reason: `jws` runs `jj workspace add` from
`<wrapper>/main` to inherit its sparse patterns, so it refuses a wrapper with no
`main`, and it does so *after* the bead is claimed. That is exactly the outcome
the preflight exists to prevent, so the shape is refused here, where nothing has
been asked yet, and the line says what is missing: the wrapper, with `.jj/repo`
beside its `main` worktree.

Without the first, `pick` prints one line saying this repo is not in the wrapper
shape yet and names the tools that make one (`jinit` for an empty remote,
`jclone` for an existing one — the line used to name `ginit` alone); without any
of the others it names the missing piece the way `need` does. All of them exit
before any screen opens, so the first thing the person sees is the refusal rather
than a claimed bead and a dead pane.
The tab's own failure path stays as a second line of defence: `jws` refusing is a
line on the pane and no agent.

| `bounds`, `script` | unchanged | unchanged |

No new options. `M.options.base`'s documented default of `"@"` still works: `@`
is a revision in both vocabularies.

## Edge cases and failure behaviour

- **`jws` fails** — path exists, `main` missing, jj refuses: the pane prints
  `rex-config: jws <branch> failed (exit <status>); not starting <agent>` after
  its own output, then leaves a login shell. No agent.
- **`jws` exits 0 but the path file is missing or empty** — `rex-config: could
  not read the workspace path of <branch> from the jws path file; not starting
  <agent>`, then a shell. The bead is still in progress, as it is when a jj read
  fails after the claim.
- **The fetch fails** — one line naming the revision; the workspace is created
  from it as it stands. Deliberately not fatal: a dead network should not cost
  the person their new tab.
- **A hook fails** — dojjo prints the failing hook and the log path and exits 0,
  so the create still succeeds and the person still gets their tab. Its log lives
  in `<wrapper>/../.jj/djo/logs`, because dojjo resolves the shared `.jj` through
  a relative path without resolving it against the workspace. This is the one
  class of failure no exit status carries, and it is why the runbook's per-repo
  check exists.
- **`@` or a local bookmark as the base** — still one `jj git fetch`, see the
  rule above. `base = false` is the only answer that fetches nothing, because it
  hands `jws` no revision at all.
- **`--path-file` is not supplied** (someone runs `jws` by hand, or a future
  caller) — `jws` behaves exactly as it does today; the flag is additive.
- **A repo whose wrapper has `.jj/repo` but no `main` workspace** — the pick
  preflight passes (it only proves jj is there) and `jws` refuses on the pane.
  Documented rather than pre-checked: `jws` already says the useful thing.
- **The picked name is an existing branch with no workspace** — `attach`, not a
  create and not a switch: the branch is what the person is going back to, and
  `jws --attach` puts a jj workspace on it. A branch that exists only on a remote
  is not in `candidates` at all — it has to be fetched first, and then picked.
- **The directory `jws` would use already exists on disk** (a stale folder where
  a workspace used to be): `jws` refuses, the pane says so, no agent starts. The
  flow does not delete anything it did not create.
- **A leftover plain git worktree in a converted wrapper** — hazardous: a jj
  command run inside it resolves the *wrapper* as the workspace and snapshots
  everything there into the inert default workspace. This is why the runbook
  removes them, and why the flow never creates one again.
- **The agent is `""`** — untouched: nothing is started, the prompt (if any) is
  printed, the pane is the workspace and a login shell.

## Testing

Everything below runs from `bash test/run.sh`, no pty:

- `test/wrapper_test.sh` — drives the tab's wrapper through `fish`. A stand-in
  `jws` is supplied by pointing `fish_function_path` at a temporary functions
  directory, so the three modes are asserted without jj: `jws` receives the mode's
  flag (`--attach` or `--existing`, none for a create), the branch and, for a
  create, the base revision; `--path-file` names a file the stand-in writes; and
  the agent starts in the directory that file named. A stand-in that writes no
  file, or exits non-zero, leaves a login shell and starts nothing, with the right
  line on stderr. **No `wt`, no `jq`** anywhere in a run.
  `GIT_TERMINAL_PROMPT=0` is in the child's environment. A prompt starting with
  `-`, a prompt containing `fix "it"` and `{{ now }}`, and a blank prompt each
  still arrive as one argument — or none.
- `test/jws_test.sh` — the shim itself: a stand-in `djo` records its argv and its
  cwd, and a real `jj workspace add` makes the workspace, so what is asserted is
  dojjo creating nothing, `djo hook post-start` running *inside* the new
  workspace, the path file's one line, the exact-path refusal, and the
  `--existing` refusal — with **no `djo` invocation** — for a name jj does not
  list.
- `test/pure_test.lua` — `new_tab_argv`'s new shape: `fish -c` with the script,
  three positional words, the mode in `$argv[1]` for each of `switch`/`create`/
  `attach`, no remote word, `agent_args` only with an agent, `base: false` as an
  empty third word, a hand-run payload with no `base` falling back to the
  configured one, an old hand-run payload saying `create: true` still arriving as
  `create`, and the dash-prefixed prompt's leading space.
- `test/branch_test.sh` — the base chain from a saved bookmark listing: the
  default renders `main@origin` from the fixed names (`--origin-head` names it,
  and git is never asked — a liar on `PATH` proves it), falls back through
  `master@origin` and `@`, drops `@git`, dedupes the cycle, and keeps an
  unresolvable configured first entry.
- `test/pick_test.sh` — the payload carries a revision string or `false` and
  never `base_remote`; `worktree` says `switch`, `attach` or `create` for a name
  with a worktree, a bare branch, and a name that is neither; a wrapper directory
  with no `.jj/repo` is refused with the not-a-wrapper line and opens no screen,
  and so is a `.jj/repo` inside the worktree itself with no wrapper beside it; a
  missing `jj`, `djo`, or a fish with no `jws`, is refused the same way and
  names the missing piece; a saved-bookmarks run still works off a terminal.
- **By hand, once, in the float**: a real `jws` create into a real wrapper, the
  agent running in it, and `^C` killing the agent but not the pane. A pipe
  cannot prove any of that, and pretending otherwise would be the test lying.

## Migration: converting a repo to the wrapper shape

**A runbook the owner runs, not a task for the plan.** This section used to spell
out, step by step, how `rex-config` itself was converted — seed files first, old
worktrees removed rather than adopted, `main` re-created in the right order, the
beads database kept out of the object store. That procedure now lives in
[`docs/dojjo-conversion-runbook.md`](../../dojjo-conversion-runbook.md), which
covers every repo this flow is meant for rather than only this one: both routes
(rebuild the working copy, or clean it up in place), the `[hooks.post-start]`
rewrite a worktrunk-shaped `.config/wt.toml` needs, and the per-repo check at
the end. Nothing about the conversion belongs in this document any more.

What survives here is the one fact the flow depends on: `jj workspace add`
refuses a non-empty destination directory, so an existing worktree is removed
rather than adopted.

## What's left to the builder

- The exact `jj bookmark list --all-remotes` invocation and template that renders
  one `<name>@<remote>` per line, and the saved fixture that stands in for it —
  including whether `@git` is filtered in the template or in the shell.
- The default-branch resolution used to read `refs/remotes/origin/HEAD`
  through git on the strength of the colocated wrapper having the ref. The
  builder gated that read on a `.git` being there and let the fixed names answer
  otherwise; the 2026-11-06 design then deleted the read outright, so the fixed
  names are the whole rule and nothing asks git.
- Where the temp path file lives and when it is removed: `mktemp` under
  `TMPDIR`, read, then deleted, or left for the pane's owner to see.
- Whether `cmd_bases` and its subcommand keep their names once the rows are
  revisions, and how the composer's header label reads for the `false` answer.
- The `^C` check in the float (see Testing) — the one behaviour no pipe proves.
- The README's rewritten flow section, its base-field paragraph, and a new
  failure-mode paragraph for a repo that is not ginit'd yet.
- How `pick` learns the mode cheaply: `candidates` separates workspace names
  from bare bookmarks, so the builder decides whether that ordering becomes a
  second field on the row or a second saved listing — either way it is one read,
  not a `wt list` per keystroke (history: worktrunk's list; the two reads are
  `jj workspace list` and `jj bookmark list` now).
- The sanitising rule, checked against worktrunk itself for a name with a slash,
  a dot and a character `wt` rewrote (`feat/pxp`, `v1.2`, `fix:it`), so a
  rex-made directory and a `wt`-made one always agreed. It is `/` → `-` and
  nothing else, so a dot or a colon now stays as it is — history again: the tool
  to compare with is `jws`, which is what the flow creates from.
- `jws`'s own argument parsing for `--path-file`, `--attach` and `--existing`
  around a branch name that could look like a flag.