# rex-config: new work lands in a jj colocated workspace

**Date:** 2026-11-03
**Status:** design, approved in conversation
**Owner:** John Stegeman
**Bead:** `rex-config-pxp`

## Intent

The owner is moving off a git/worktrunk-only workflow onto colocated jj
workspaces. `ctrl+space>n` still has to be the way work starts, so the worktree
it creates has to be a jj colocated workspace — a git worktree *and* a jj
workspace of the same directory repo, set up in the one order that works.

`gws` (a fish function in `~/.config/fish/functions/gws.fish`) is the only thing
that knows how to do that correctly today: it runs `jj workspace add --colocate`
**from `main`'s workspace** so the new workspace inherits the full sparse
pattern, attaches a git branch at the workspace's HEAD so worktrunk can see it
the way it always could, and then runs the project's post-start hooks by hand
(`wt -C <path> -y hook post-start`) because jj, not wt, created the worktree.
Project-specific setup therefore stays where it belongs — in each repo's
`.config/wt.toml` hooks — and rex learns none of it.

So this change is not "a different command": it is *delete rex's half-knowledge
of how a worktree is made and hand the whole job to `gws`*, while keeping
everything the tab does around it (agent, prompt, login shell, the failure lines
that keep an agent out of the wrong directory).

## Goals

- A create through the picker produces a jj colocated workspace plus a git
  worktree with the branch attached, with the project's post-start hooks run.
  A branch that already exists but has no worktree gets one the same way, jj's
  way, instead of an ordinary git worktree.
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
- **`candidates`'s sources.** Branch names still come from `wt list --format=json`
  plus `git for-each-ref`, and `branch-default` still names branches. What
  changes is that the picker now reads that list for a *decision* (is this a
  worktree, an existing branch, or neither?) and not only for a suggestion.
- **Worktree removal.** Still `wt remove <name>` by hand; the ginit seed hook
  forgets the jj workspace.
- **PR/MR shortcuts.** `wt switch pr:12` *creates* a worktree, and rex no
  longer creates with wt, so those shortcuts leave `candidates`. A PR head is
  still reachable the manual way: fetch the branch, then pick its name (attach)
  or `gws` it by hand.

## Anti-goals

- A second copy of `gws`'s knowledge inside rex — the `<wrapper>/<name>` layout,
  the sparse inheritance, the branch attach, the manual hook run.
- Capturing `gws`'s stdout to find the new path. That output is the pane's, and
  it carries the post-start hooks' own chatter; swallowing it to parse a path
  would hide the project's setup from the person watching.
- An agent starting in a directory nobody verified.
- A silent fallback that turns "this repo isn't ginit'd yet" into a plain
  worktree that quietly recreates the problem jj is there to solve.

## Constraints

- **`gws` lives outside this repo** (`~/.config/fish/functions/`, unversioned,
  no tests here). Its contract is pinned in this document and stood in for in
  `test/wrapper_test.sh`; it is not otherwise testable from rex-config.
- **Rex runs actions with its own PATH** (`/usr/bin:/bin:…`), while `fish`,
  `wt`, `jj`, `jq`, `bd` and `fzf` live on the login shell's PATH. The tab's
  pane is a login shell, so the wrapper may rely on that PATH — but the wrapper
  is now a fish program, so `fish` must be on it.
- **`fish -c SCRIPT <words…>` puts those words in `$argv`**, element by element:
  no `$0` slot (`sh -c` needed the spare `sh`). A branch with a slash and a
  prompt with spaces still arrive as single values.
- **`jj workspace add` refuses a non-empty destination directory**, so existing
  worktrees cannot be adopted in place (verified — see Migration). It also does
  not create parent directories: a branch like `feat/pxp` cannot become a
  directory path on its own.
- **In a colocated wrapper, `<wrapper>/main/.jj/repo` is a file**, not a
  directory; only `<wrapper>/.jj/repo` is a directory. That is how `gws` finds
  the wrapper, and how the refusal check can tell a ginit'd wrapper from a bare
  worktrunk one.
- Branch names are sanitised into directory names **the way worktrunk does it**
  (`feat/pxp` → `feat-pxp`, the layout `wt` already produces), so a rex-created
  worktree sits exactly where a `wt`-created one would. The jj workspace is
  named after the branch, slashes and all, so the ginit post-remove hook
  (`jj workspace forget {{ branch }}`) still cleans up after `wt remove`
  (verified: `--name 'feat/pxp'` then `forget 'feat/pxp'`).

## Decisions made by the owner

- Creation goes through `gws`; wt keeps owning the hooks. No fallbacks anywhere.
- The tab wrapper becomes `fish -c` instead of `sh -c`.
- The base answer is in jj land: one revision string, and the fetch moves to jj.
- The default base stays the current state of `main@origin`, because the local
  working copy of `main` may not have been updated.
- `gws` may be edited; it gains `--path-file` so the caller learns the path
  without touching the pane's output.
- `gws` sanitises the branch name into a directory the way worktrunk does, and
  names the jj workspace after the branch.
  An existing branch with no worktree is handled by `gws` too, not by making an
  ordinary git worktree: the picker says which of switch / attach / create it
  means.
  `gws.fish` is updated in place in the dotfiles.
- The `rex-config` conversion is a runbook the owner runs, not something the
  plan executes.

## How it works

### The units, and where the change lands

| Unit | File | Change |
|---|---|---|
| `gws` | `~/.config/fish/functions/gws.fish` | gains `--path-file`, `--attach`, and the directory/workspace naming split; fetches with `jj git fetch` when given a base revision |
| tab wrapper | `init.lua` (`M.new_tab_script`) | rewritten as fish; three modes — switch via `wt`, attach and create via `gws` |
| argv builder | `init.lua` (`M.new_tab_argv`) | `fish -c`; three positional words instead of four; `<mode>` replaces `<create>`; no remote |
| base cycle | `new-work.sh` (`base_chain`, `cmd_bases`, `pick`) | jj revisions from `jj bookmark list --all-remotes`; no remote column |
| mode decision | `new-work.sh` (`pick`) | a picked name is said to be an existing worktree, an existing branch, or a new one |
| refusal | `new-work.sh` (`pick`'s preflight) | no `.jj/repo`, no `jj`, or no `gws` function is refused before the screen |
| the repo | `rex-config` | a runbook the owner follows after this lands — the plan does not convert it |

Nothing else moves. The composer, `branch-default`, `beads`, `preview`, the
state file and the payload's other keys are untouched.

### `gws`: the path file, the three modes, and the fetch

```
gws [--path-file FILE] [--attach] <branch> [base-revision]
```

- **`<branch>` is the branch name, slashes and all** — the thing the picker
  chose. The directory is that name sanitised the way worktrunk sanitises its
  `worktree-path` template (`feat/pxp` → `<wrapper>/feat-pxp`), and the jj
  workspace is created with `--name <branch>`, so a worktree made by rex sits
  where a `wt`-made one would and `jj workspace forget {{ branch }}` still
  matches it.
- **`--attach`** — the branch already exists but has no worktree: run
  `jj workspace add --colocate <path> -r <branch>` and check the branch out
  (`git -C <path> checkout <branch>`) instead of `checkout -b`. Everything
  else — hooks, path file, closing lines — is the same as a create. Without the
  flag the branch is made, exactly as today.
- **`--path-file FILE`** — on success, write the absolute path of the new
  workspace and a newline to `FILE`, immediately before the final `cd`. Nothing
  `gws` prints changes: stdout and stderr remain the pane's, which is the whole
  point of a file rather than a parseable line.
- **The fetch** — when a base revision is given, run `jj git fetch` before
  `jj workspace add -r`, bounded by `timeout`/`gtimeout` at 30 seconds when one
  of them is installed and unbounded otherwise (today's wrapper behaviour, moved
  intact). A failed fetch prints one line naming the revision and **carries
  on**: the workspace is created from the revision as it currently resolves.
  With no base revision nothing is fetched, so a bare `gws name` stays fast and
  works offline.
- **Unchanged** — the ancestor walk for `<wrapper>/.jj/repo`, the refusal when
  `<wrapper>/main` is missing, `jj workspace add --colocate` run from `main`,
  `wt -C <path> -y hook post-start`, the closing `cd`, and both printed lines.

The `timeout` bound and the failed-fetch line exist because the pane is a
terminal nobody can type into: a credential prompt or a dead network must not
hang there invisibly. `jj` fails rather than prompting, and the wrapper still
exports `GIT_TERMINAL_PROMPT=0` for the `git` that post-start hooks run.

### Switching, attaching, creating

The picker already holds both lists it needs — `wt list` says which branches
have a worktree, and `git for-each-ref refs/heads` says which branches exist —
so it answers the question the create flag was never able to: **which of three
things did you just pick?**

| The name is… | mode | What runs |
|---|---|---|
| on an existing worktree | `switch` | `wt switch <branch> --no-cd --format=json` |
| an existing branch, no worktree | `attach` | `gws --attach <branch> --path-file <f>` |
| neither | `create` | `gws <branch> [<base-revision>] --path-file <f>` |

`switch` is the only mode that still goes through worktrunk, and it is the only
one where a worktree already exists — so it can never create one. That is the
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
3. **`switch`**: `wt switch <branch> --no-cd --format=json`, then `.path` out of
   the reply with `jq`. This is the one place JSON survives.
4. **`create` and `attach`**: `mktemp` a path file, then
   `gws [--attach] <branch> [<base-revision>] --path-file <file>`, and read the
   path from the file. The base word is omitted entirely when it is empty, and
   it is never sent for `attach`.
5. No path, one line naming **which** step failed (gws's exit status, or a zero
   exit whose path file says nothing), then a login shell and no agent.
6. `cd -- <path>`; the same line and shell if it fails.
7. No agent: any prompt the picker really typed is printed above the login
   shell — never silently dropped.
8. An agent: `^C` must reach the agent and not the wrapper, so the wrapper
   installs a no-op handler (`function … --on-signal INT`) for the length of
   the agent's run. Unlike `sh`'s `trap '' INT`, a fish handler is not inherited
   across `exec`, so the agent child gets the default disposition without a
   nested reset — **the builder verifies this with a real `^C` in the float**,
   because a pane that dies with the agent is the failure this guard exists for.
9. Every exit path ends in `exec $SHELL -l`, falling back to `/bin/sh -l`.

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
  branch"**: `<branch>@origin`, where `<branch>` is resolved exactly as today —
  `refs/remotes/origin/HEAD`'s symref target first, then `main`, then `master`.
  The git refs still exist in a colocated wrapper, so this resolution is reused
  unchanged and only the rendering differs. The fetch that makes it *current*
  now happens in `gws`, in the tab, after the answer was given.
- **The cycle** stays `[default, "@", "main", "master"]` — all three of the
  others are valid jj revisions (`@` is the working copy, `main` and `master`
  local bookmarks) — deduplicated, with entries jj cannot resolve dropped and
  the configured first entry kept even when it does not resolve, exactly as
  today.
- **`base = false`** is unchanged as a configuration answer: the field opens on
  "no revision at all" and ctrl-r still cycles away from it. Its header label
  changes from `base: wt default` to `base: none`, because there is no worktrunk
  default to hand it to any more.
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

> the directory holding `--main` must contain `.jj/repo` as a **directory**,
> `jj` must be on the login shell's PATH (the base cycle runs it), and
> `gws` must be a fish function (`fish -c 'functions -q gws'`), because the tab
> cannot create anything without it and a bead claimed for nothing is worse than
> a refusal.

Without the first, `pick` prints one line saying this repo is not ginit'd yet and
names `ginit`; without either of the other two it names the missing piece the way
`need` does. All three exit before any screen opens, so the first thing the
person sees is the refusal rather than a claimed bead and a dead pane. The tab's
own failure path stays as a second line of defence: `gws` refusing is a line on
the pane and no agent.

| `bounds`, `script` | unchanged | unchanged |

No new options. `M.options.base`'s documented default of `"@"` still works: `@`
is a revision in both vocabularies.

## Edge cases and failure behaviour

- **`gws` fails** — path exists, `main` missing, jj refuses: the pane prints one
  line naming `gws` and its exit status, then leaves a login shell. No agent.
- **`gws` exits 0 but the path file is missing or empty** — the same "could not
  read the worktree path" line jq's absence produces today, then a shell. The
  bead is still in progress, as it is today when a switch fails after the claim.
- **The fetch fails** — one line naming the revision; the workspace is created
  from it as it stands. Deliberately not fatal: a dead network should not cost
  the person their new tab.
- **`@` or a local bookmark as the base** — still one `jj git fetch`, see the
  rule above. `base = false` is the only answer that fetches nothing, because it
  hands `gws` no revision at all.
- **`--path-file` is not supplied** (someone runs `gws` by hand, or a future
  caller) — `gws` behaves exactly as it does today; the flag is additive.
- **A repo whose wrapper has `.jj/repo` but no `main` workspace** — the pick
  preflight passes (it only proves jj is there) and `gws` refuses on the pane.
  Documented rather than pre-checked: `gws` already says the useful thing.
- **The picked name is an existing branch with no worktree** — `attach`, not a
  create and not a `wt` switch: the branch is what the person is going back to,
  and `gws --attach` puts a jj workspace on it. A branch that exists only on a
  remote is not in `candidates` at all — it has to be fetched first, and then
  picked.
- **The directory `gws` would use already exists on disk** (a stale folder where
  a worktree used to be): `gws` refuses, the pane says so, no agent starts. The
  flow does not delete anything it did not create.
- **A leftover plain git worktree in a converted wrapper** — hazardous: a jj
  command run inside it resolves the *wrapper* as the workspace and snapshots
  everything there into the inert default workspace. This is why the migration
  removes them, and why the flow never creates one again.
- **The agent is `""`** — untouched: nothing is started, the prompt (if any) is
  printed, the pane is the worktree and a login shell.

## Testing

Everything below runs from `bash test/run.sh`, no pty:

- `test/wrapper_test.sh` — now drives the wrapper through `fish`. A stand-in
  `gws` is supplied by pointing `fish_function_path` at a temporary functions
  directory, so the create and attach paths are asserted without jj: `gws`
  receives the branch and, for a create, the base revision; `--attach` is there
  for an attach and absent for a create; `--path-file` names a file the stand-in
  writes; and the agent starts in the directory that file named. A stand-in that
  writes no file, or exits non-zero, leaves a login shell and starts nothing,
  with the right line on stderr. The `switch` path still runs `wt switch
  --format=json` and reads `.path`, and never calls `gws`. `GIT_TERMINAL_PROMPT=0`
  is in the child's environment. A prompt starting with `-`, a prompt containing
  `fix "it"` and `{{ now }}`, and a blank prompt each still arrive as one
  argument — or none.
- `test/pure_test.lua` — `new_tab_argv`'s new shape: `fish -c` with the script,
  three positional words, the mode in `$argv[1]` for each of `switch`/`create`/
  `attach`, no remote word, `agent_args` only with an agent, `base: false` as an
  empty third word, a hand-run payload with no `base` falling back to the
  configured one, an old hand-run payload saying `create: true` still arriving as
  `create`, and the dash-prefixed prompt's leading space.
- `test/branch_test.sh` — the base chain from a saved bookmark listing: the
  default renders `main@origin` from `origin/HEAD`'s target, falls back through
  `main` and `master`, drops `@git`, dedupes the cycle, and keeps an
  unresolvable configured first entry.
- `test/pick_test.sh` — the payload carries a revision string or `false` and
  never `base_remote`; `worktree` says `switch`, `attach` or `create` for a name
  with a worktree, a bare branch, and a name that is neither; a wrapper directory
  with no `.jj/repo` is refused with the ginit line and opens no screen; a
  missing `jj`, or a machine whose fish has no `gws`, is refused the same way and
  names the missing piece; a saved-bookmarks run still works off a terminal.
- **By hand, once, in the float**: a real `gws` create into a real ginit'd repo,
  the agent running in it, and `^C` killing the agent but not the pane. A pipe
  cannot prove any of that, and pretending otherwise would be the test lying.

## Migration: making `rex-config` ginit'd

**A runbook for the owner, not a task for the plan.** It runs after this change
has merged, from outside this worktree, and the plan's job is to write it down
and check it against a scratch repo — not to execute it.

`ginit` assumes an empty remote and a directory it creates from nothing, so it
cannot be re-run over `rex-config`. What is needed is ginit's step 3, applied to
the layout `rex-config` already has (bare `.git` at the wrapper, `main` and
`feat-pxp` as worktrees, `.beads` at the wrapper root).

Verified against a scratch repo built in that shape:

1. **The seed files first.** `rex-config/main` has no `.config/wt.toml` and no
   `.worktreeinclude`, and its `.gitignore` lacks `.env` and `.worktrees/`, so
   the ginit seed (the post-start `copy-ignored` hook, the post-remove
   `jj workspace forget` hook, the ignore lines) has to be committed to `main`
   **before** `main` is re-created — the hooks must be in the tree the new
   workspace gets.
2. **Existing worktrees are removed, not adopted.** `jj workspace add` refuses a
   non-empty directory, so `feat-pxp` is removed with `git worktree remove
   --force` and re-created later with `gws`; leaving it behind is the hazard
   above.
3. **`main` is re-created in ginit's order.** From the wrapper:
   `jj git init --git-repo .git .`, then — *before* any `jj sparse set --clear`,
   because a new workspace inherits the current workspace's sparse patterns and
   `main` must inherit the full set — `git worktree remove --force main`,
   `jj workspace add --colocate main`, `git -C main checkout main`,
   `jj bookmark track main@origin`. The default workspace is then made inert
   exactly as ginit does it: `jj sparse set --clear`, `jj new "root()" -m
   'default workspace: intentionally empty (see ginit)'`, and the post-start
   hooks are run by hand (`wt -C main -y hook post-start`).
4. **The beads database is left out of jj's object store.** `.beads` lives at the
   wrapper root and nothing in the conversion reads or moves it — but the first
   `jj git init` at the wrapper snapshots that directory, so the whole embedded
   Dolt db and `.beads.gate.lock` land in `.git` as objects before the inert
   workspace is abandoned. One line before the init keeps them out: `.beads/` and
   `.beads.gate.lock` appended to `.git/info/exclude` (verified on a clone of
   `rex-config`). This is my call rather than a requirement: the abandoned
   snapshot is harmless, just tens of megabytes nobody asked for.
5. **The check at the end** is the flow itself: `cd` into `main`, run
   `new-work.sh` once by hand, and confirm the tab lands in a jj workspace with
   the branch attached and the hooks run.

This is the one part of the design with fingers crossed: it ran against a
scratch repo, not against `rex-config`, and `jj`'s workspace and git-worktree
layers are known to disagree in the corners (which is why `gws` exists at all).

## What's left to the builder

- The exact `jj bookmark list --all-remotes` invocation and template that renders
  one `<name>@<remote>` per line, and the saved fixture that stands in for it —
  including whether `@git` is filtered in the template or in the shell.
- The default-branch resolution keeps reading `refs/remotes/origin/HEAD`
  through git: the check already exists and the colocated wrapper still has the
  ref. If the builder finds jj's own remote-bookmark view cleaner, only the
  rendering has to stay the same.
- Where the temp path file lives and when it is removed: `mktemp` under
  `TMPDIR`, read, then deleted, or left for the pane's owner to see.
- Whether `cmd_bases` and its subcommand keep their names once the rows are
  revisions, and how the composer's header label reads for the `false` answer.
- The `^C` check in the float (see Testing) — the one behaviour no pipe proves.
- The README's rewritten flow section, its base-field paragraph, and a new
  failure-mode paragraph for a repo that is not ginit'd yet.
- How `pick` learns the mode cheaply: `candidates` already separates worktree
  branches from bare ones, so the builder decides whether that ordering becomes a
  second field on the row or a second saved listing — either way it is one read,
  not a `wt list` per keystroke.
- The sanitising rule, checked against worktrunk itself for a name with a slash,
  a dot and a character `wt` rewrites (`feat/pxp`, `v1.2`, `fix:it`), so a
  rex-made directory and a `wt`-made one always agree.
- `gws`'s own argument parsing for `--path-file` and `--attach` around a branch
  name that could look like a flag.