# rex-config: "I'm done" — one key removes the tab, the worktree, the branch and the jj workspace

**Date:** 2026-11-05
**Status:** design, approved in conversation
**Owner:** John Stegeman
**Bead:** `rex-config-6c4`

## Intent

Today, finishing work means typing several different things: `wt remove` for the
worktree and branch, `jj workspace forget` for the workspace row (which is not
run today at all — `main` has no `.config/wt.toml`), and closing the Rex tab by
hand. The ask is one action that does all three, and nothing typed.

This is the counterpart to `ctrl+space>n` (`2026-10-28-rex-new-work-design.md`,
`2026-11-03-rex-jj-workspaces-design.md`): new work is created by one key, so
work is torn down by one key. The same three units are involved in reverse —
the jj workspace, the git worktree and branch, and the Rex tab inside the
project's session.

The second half of the ask is that the key leaves the repository ready for the
next piece of work rather than merely tidy. Finishing the *last* thing and
starting the *next* thing are one motion, and the state that breaks that motion
is a `main` that is behind the remote it was just merged into: the next
`ctrl+space>n` would open on a stale base. So the flow fetches, and it moves the
`main` workspace forward onto `main@origin` — forward only, and only when doing
so cannot lose anything.

The boundary matters, because this flow could easily grow into a second copy of
somebody else's job. `pi-rex`'s `finishing-a-development-branch` skill owns
everything *inside* jj and git — its Step 7 deletes nothing precisely so the
directory's life belongs to whoever created it, which is this repo, and its Step
8 proves the merge before abandoning anything and is the step that defines how
`main` moves. So this flow reuses Step 8's rules for `main` verbatim rather than
inventing its own, and it does not clean up jj or git state.

The bead was written on 2026-10-28, before the move to jj. Its detection steps
are git-shaped, and its comment of 2026-11-05 recorded what changed. This
document is written against the jj world: the unit is the **bead**, the workspace
is found by **name and path** (after a merge, `@` carries no bookmark at all),
and "unmerged" means content rather than ancestry.

## Goals

- One action, bound to a key and present in the "New work" category, that tears
  down the workspace the focused pane is in: the tab, the git worktree, the
  branch, the jj workspace row.
- The safety is the feature: when anything would be lost or is still running,
  the flow **refuses**, on a screen that names what is blocking. It removes
  nothing in that case.
- The three refusals the bead asks for: changes not merged into `main@origin`,
  a working copy with changes of its own, and a program still running in the tab.
  Plus the structural one: never tear down `main`, and never the wrapper root.
- The bead is read and reported — its state is on the refusal screen — but never
  mutated.
- **The comparison is honest**: the flow fetches before it compares, so "merged"
  is judged against what the remote actually has, not against a stale
  `main@origin`.
- **`main` is left ready for the next branch**: when — and only when — `main`'s
  working copy is provably empty and `main` is behind `main@origin`, the flow
  moves the `main` workspace forward onto `main@origin`, by Step 8's method.
- `main` gets the `post-remove` hook it is missing, so `wt remove` forgets the
  jj workspace by itself, in this repo as it already does in a `ginit`'d one.
- The clean path is quiet: no confirmation, no choices. The tab disappearing is
  the confirmation.
- Everything above is testable from `bash test/run.sh`, no pty.

## Non-goals (this cut)

- **A sweep for stale workspaces.** The flow acts strictly on the pane it was
  invoked from (owner's call). A clean, merged, idle workspace such as
  `feat/init` is never collected by it; an "audit what I could remove" listing is
  a separate idea, deliberately not built here.
- **A partial path.** When changes are unmerged the flow does not offer
  "remove the worktree, keep the branch" — it refuses. There is no second
  question on the refusal screen (owner's call).
- **Any jj or git cleanup of its own.** No `jj abandon`, no `jj workspace
  forget` typed by rex, no bookmark deletion, no `jj-finish-audit` invocation.
  The skill's Steps 7 and 8 stay theirs. The one jj *write* this flow makes is
  moving `main` forward, which is the exception named below and nothing more.
- **Moving any workspace other than `main`.** Every other workspace is a report,
  not a target — Step 8's rule, kept.
- **Forcing.** No `-f`, no `-D`, no `--reap`. The audit already refused the
  situations those flags exist for. No `--no-hooks` either, but for the opposite
  reason: the hook is the step that forgets the jj workspace, so skipping it
  would leave half the teardown undone.
- **Reaping processes.** Killing dev servers is `wt --reap`'s experimental job,
  and it kills things rex did not start.
- **Merging, pushing, rebasing, or opening a PR.** The merge is the person's, on
  the forge. This flow never pushes.
- **Feeding the rest of the repository's ginit seed.** `main` also lacks
  `.worktreeinclude` and the `post-start` `copy-ignored` hook. Noticed while
  looking, deliberately left out of this change (see *Edge cases*).
- **Unclaiming or commenting the bead.** See *The bead*.
- **Other repos.** Nothing is ginit'd or converted here.

## Anti-goals

- A screen that offers choices when something is at risk. The answer to "what
  should I do about these unmerged changes?" is not rex's to give.
- Re-deriving what the finishing skill already decided — the discard flow, the
  merge proof, the rebase onto `main@origin`.
- **Moving `main` in any direction but forward**, or moving it at all when its
  working copy is not provably empty. A backward or speculative move of the
  shared checkout is the one mistake here that costs somebody else's work.
- Tearing down `main` or the wrapper root, in any state, for any reason.
- A failure that is swallowed or reported only to a log. If anything does not
  finish, the person sees why, in the float, before it closes.
- Depending on a path that moves between installs. `jj-finish-audit` lives in
  the installed `pi-superpowers-plus` package, under a path that differs per
  install; `pi-rex-b9y` records a case where it was not on disk. This flow reads
  jj directly instead (see *Why not `jj-finish-audit`*).
- Anything that ends with the person typing a command to finish the job —
  including `jj git fetch`.

## Constraints

- **Rex runs actions with its own PATH** (`/usr/bin:/bin:…`), while `wt`, `jj`,
  `bd` and `fish` live on the login shell's PATH. Everything this flow runs goes
  through the login shell, as the new-work flow already does.
- **The pane's shell lives in the directory being removed.** Its cwd is the
  workspace root; `wt remove` unlinks it out from under that shell.
- **Closing a window kills every block in it**, including the block that asked
  for the close. Nothing may follow a close, and the close must be the last act
  of the process that issues it — or it must be issued by somebody who outlives
  the window. Rex's control API has `session.close_window`, and no client action
  for closing a window, so the second option means the CLI.
- **A fetch needs the network and a credential-free path.** The pane is a
  terminal nobody can type into, so a credential prompt must not hang there:
  `GIT_TERMINAL_PROMPT=0`, and the fetch bounded by `timeout`/`gtimeout` at 30
  seconds when either is installed — the discipline `gws` already uses.
- **`wt` post-* hooks run in the background** with output logged, so a removal
  that succeeds at the git level can still leave the jj workspace row behind,
  invisibly. `wt remove --foreground` blocks the *removal*, not the hook — only
  `wt hook <type> --foreground` runs a hook inline — so the row is something the
  verification *waits for* rather than something it can trust.
- **`wt remove` deletes the branch only when `wt` itself judges it merged**, and
  reports what it did as `branch_outcome` in its `--format=json` reply
  (`deleted`, `retained_unmerged`, `retained_checked_out`, …).
- **`wt` reads the project hooks from `main`** — `wt hook show` names
  `main/.config/wt.toml`. A hook seeded anywhere else does nothing.
- **Merged means content, not ancestry.** After a squash or rebase merge — the
  normal forge flow, and the one this repo uses — a branch's changes are not
  ancestors of `main@origin` even though the work is fully merged. Only a
  content comparison answers "is this merged?" after a squash.
- **Worktree names and branch names differ in shape.** The branch and the jj
  workspace are both named after the plan (`feat/6c4`); the directory is
  worktrunk's sanitised form (`feat-6c4`). The tab is labelled with the branch.
- **jj workspaces share one repository.** The workspace's commits are already in
  the shared object store; removing the workspace loses the *row*, the
  *directory*, and the *finding*, not the commits.
- **The action cannot take a hand-back with an undeclared key.** This Rex build
  filters undeclared arguments before the action runs, so every field
  `done` hands back has to be declared in `work_done_go`'s `args`.
- **No pty in the suite.** Every tool read needs a fixture seam, and every
  Rex effect needs a stub, as `pick_test.sh`, `action_test.lua` and
  `wrapper_test.sh` already do it.

## Decisions made by the owner

- The screen **refuses and says what is blocking**; it does not offer a choice.
- The flow **stays strictly on the pane it was invoked from**; no stale sweep.
- The `post-remove` hook is **seeded by this change**.
- The flow **fetches automatically**, and **keeps `main` up to date** if it can.
- **A retained branch is a failure, not silence** (from the builder check): the
  flow's whole promise is one complete teardown, so a branch worktrunk declines
  to delete is reported with the one command that finishes it.

## How it works

### The units, and where the change lands

| Unit | File | Change |
|---|---|---|
| action `work_done` | `init.lua` (`M.setup`) | new action, `category = "New work"`, no args: finds the pane's project and opens the flow's float |
| action `work_done_go` | `init.lua` (`M.setup`) | new action with declared args: the hand-back target that removes and verifies |
| the flow's guts | `init.lua` | `M.work_done`, `M.work_done_go`, `M.tab_processes` — beside `M.work_new`/`work_new_go` |
| the audit, the refresh and the screen | `new-work.sh` | a `done` subcommand with fixture seams and a `--dry-run` hand-back |
| project hooks | `main/.config/wt.toml` | **new file**: the `post-remove` hook, committed on `main` |
| keybinding | `README.md` | one `rex.bind` line beside `ctrl+space>n`, and a flow section |
| tests | `test/done_test.sh`, `test/action_test.lua`, `test/setup_test.lua` | the refusal cases, the clean hand-back, the removal sequence |

Nothing else moves. `pick`, the composer, `bases`, `branch-default`, the payload
of the new-work flow, `gws`, and the finishing skill are untouched.

### The shape: picker-shaped, like `work_new`

The flow reuses the two-action pattern the picker already established, because it
is the pattern this repo tests well:

```
key  →  work_done                 (no args; finds the pane, opens a float)
          new-work.sh done        (process check, fetch, audit, refresh, decide)
            →  rex do work_done_go --args '{"project":…,"root":…,"main":…,"workspace":…,"path":…}'
                 work_done_go     (wt remove, verify, report)
            →  rex window close -s <session> <window>   (the script's last act)
```

`work_done` does four things and nothing else: it reads the pane's cwd
(`block_cwd`, already used by `work_new`), resolves the project (`M.project_for`,
already used by `work_new` — wrapper root, name, and `main`), reads which
programs the tab is still running (`M.tab_processes`), and opens a float running
`M.options.script done --main <main> --root <root> --project <name> --cwd <pane
cwd> --session <id> --window <id>` plus one `--running <name>` per program. The
float is a layer in the current window, `bounds` as the picker uses them.

The window and session ids come from the pane, not from a label lookup: `ctx`
already carries `session_id` and `block_id` (that is how `block_cwd` works), so
the tab being torn down is the tab the person is looking at. This is the one
place where the flow is *simpler* than `work_new_go`, which has to find its tab
by label because the tab it wants does not exist yet.

Rex facts stay in Rex, jj and git facts stay in bash. The one crossover is
"what is still running", which only Rex can answer, so `work_done` reads it and
passes it in as data.

### Finding the workspace, and the refusals that come before any question

The script is handed `--cwd`, `--main` and `--root`, so it can refuse without
asking anything of the repository:

1. **`--cwd` is `--main` or inside it, or is the wrapper root** → refuse: this
   is the main worktree, or `default`, the empty workspace at the wrapper root,
   and the flow never tears down either. Structural, by path — not by name, so a
   repo whose main worktree is called something else is still protected.
2. Otherwise, one read: `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'`,
   run in `--cwd`. **The longest listed root that is a prefix of, or equal to,
   `--cwd` is this workspace** — its **name** (the tab label and the branch) and
   its **root** (the directory to remove). Longest wins because roots nest:
   measured on the live wrapper, `default` is `/…/rex-config`, `main` is
   `/…/rex-config/main` and `feat/6c4` is `/…/rex-config/feat-6c4`, so a
   subdirectory of a workspace matches two rows and only the deepest is the
   answer. `default` matching at all therefore means the cwd is at or under the
   wrapper with no deeper workspace owning it — which is rule 1's refusal, from
   the other direction.
3. **No row matches** → refuse: this pane is not inside a jj workspace the
   wrapper knows about (a stale directory, or a plain git worktree left over from
   before the conversion). Nothing is guessed.
4. `wt list --format=json` must show a worktree at that root. If it does not,
   the directories have drifted apart — the jj row exists and the git worktree
   does not, or the reverse — and the screen says so instead of removing one
   half.

The workspace **name** is what the tab is called; the workspace **root path** is
what `wt remove` is given, because a path cannot be a branch name and cannot
collide with one.

### The audit: the hook, the fetch, then four facts and a bead

The audit's reference base is resolved the way `bases` already resolves it —
`refs/remotes/origin/HEAD`'s target, then `main`, then `master` — and rendered as
one jj revision, `<branch>@origin`. It is not hard-coded, because the wrapper
root's default branch is a property of the remote, and a project whose default is
not `main` would otherwise refuse forever.

**Before the fetch, one question decides whether the teardown can finish at
all**: will worktrunk actually run the hook that forgets the jj workspace?
`wt hook show post-remove --format=json`, read from `main`, answers it. worktrunk
gates a project hook on approval, and `wt remove -y` **skips the prompt rather
than granting it**, so an unapproved hook does not run: the worktree goes, the
jj row stays, and the flow would learn that only after the directory was gone —
the one outcome this design forbids (*a teardown is complete or it is not*). So
the audit refuses, before anything is fetched or moved, when no project hook's
template mentions `jj workspace forget` (a repo that was never seeded — the
refusal names `main/.config/wt.toml` and `ginit`), when that hook reports
`needs_approval: true` (the one-time approval, `wt config approvals add` run in
`main`, is the remedy), or when the listing cannot be read or parsed at all: a
prerequisite that cannot be checked is not a prerequisite that holds.

**Then the fetch**, because every comparison below is a comparison against
`main@origin` and a stale `main@origin` makes the answer wrong in the direction
that matters: it reports merged work as unmerged. One `jj git fetch`, bounded by
`timeout`/`gtimeout` at 30 seconds when installed (the `gws` discipline, moved
intact), with `GIT_TERMINAL_PROMPT=0` exported so a credential prompt cannot hang
the float. A failed fetch is a **refusal**, naming that the fetch failed and that
the comparison could not be made — never a silently stale comparison.

Then, all read-only, all from inside the workspace:

- **Changes not merged into the base** — *content*, not ancestry:
  `jj diff --summary -r '<base>..@'` is non-empty. Reachability would refuse
  forever after a squash or rebase merge, which is this repo's normal flow; the
  content diff is the same rule worktrunk applies when it decides whether a
  branch is merged. The refusal lists the affected **paths** and the number of
  changes in the range, because "3 changes touching new-work.sh, init.lua" is
  what the person can act on.
- **A working copy with changes of its own** — `jj diff --summary -r @` is
  non-empty. This is what `dirty=yes` means in `jj-finish-audit state`'s
  vocabulary, and it is the workspace's own commit; the refusal says how many
  paths, not what they are.
- **A program still running in the tab** — `--running`, given by Rex. Any block
  in the tab whose foreground process is not a known shell is named. The shells
  are a short list (`fish`, `zsh`, `bash`, `sh`, `nu`); an unknown name is a
  refusal, not a pass, because the cost of a wrong pass is a killed agent — and
  so is a name Rex could not read at all.
- **The bead** — reported, never touched. The workspace name carries the bead's
  hash (`feat/6c4` ↔ `rex-config-6c4`), so the script matches the last
  dash-separated segment of any `in_progress` bead id from
  `bd list --status in_progress --json` and prints what it found. A bead still
  `in_progress` is **a warning line on the refusal screen and nothing more**: the
  doctrine is that one bead is one workspace and one session, so a finished
  workspace normally has a closed bead, and a bead still in progress is
  information the person wants, not something the flow fixes. No `bd unclaim`,
  no comment, no status change. Absent `bd`, or no match, is silence rather than
  a failure.

**Why not `jj-finish-audit`.** It answers the same questions — its `state`
output is `divergent:`, `bookmark:` and `workspace: … base=… dirty=` per
workspace, and it exits 0 always. But it lives inside the installed
`pi-superpowers-plus` package, at a path that differs per install and which
`pi-rex-b9y` records as having gone missing once. A handful of jj reads is
cheaper than a dependency on a moving path, and they are the same reads the
skill's own script makes. The screen therefore has no "the audit tool is
missing" state to handle — one refusal fewer and one failure mode fewer. Step 8's
*rules* are reused, verbatim and by citation; its *script* is not.

### Moving `main` forward, and only forward

This is the flow's one jj write, so it reuses Step 8's rule without inventing a
variant of it:

> **Verify the base, and only the base:** `jj log -r 'main | main@origin'`. A
> tracked `main` fast-forwards on fetch; if it lagged, `jj bookmark set main -r
> main@origin`, and never move `main` back. Move the primary `main` workspace
> onto `main@origin` only when it is provably empty — `jj diff --from @- --to @
> --name-only` prints nothing and `@` has no description — and move it by
> running `jj new main@origin` in that workspace. Every other workspace is a
> report, not a target.

Two guarded steps, after the fetch:

1. **The bookmark.** `main` may lag `main@origin` after a fetch. It is moved with
   `jj bookmark set main -r main@origin` **only when `main` is contained in
   `main@origin`** — never when `main` has commits of its own, because that move
   would be backwards. (Measured on the live wrapper, both bookmarks currently
   sit on the same commit, so this is a no-op on a healthy repo.)
2. **The `main` workspace's working copy.** Moved by `jj new main@origin` run in
   `main`, and only when the provable-emptiness test passes. (Measured on the
   live `main`: `jj diff --from @- --to @ --name-only` prints nothing and `@`
   has no description — so this is a real fast-forward for this repo, not a
   hypothetical.)

Either step that cannot be taken is a **blocker**, not a footnote: the screen says
`main` was not moved, why, and the command that would move it, and the teardown
stops. The reason is the clean path's silence — a warning printed on a float that
closes itself a second later is a warning nobody reads — and because an unmoved
`main` means the next branch starts from a stale base, which is the thing this
step exists to prevent. An untidy `main` is one command away from being tidy; a
`main` moved when it should not have been is a loss, and the asymmetry decides
which way to guess when the test cannot be made.

This runs in the script, before the hand-back and therefore before anything is
removed, so a failure is on the float the person is already reading. It runs
whether the teardown is refused or not: keeping `main` current is desirable on
its own, and it removes nothing.

### The verdict, and what the float looks like

The script prints, and exits:

| Exit | Meaning | What is printed |
|---|---|---|
| 0 | clean | nothing; it hands back instead |
| 4 | refused | the refusal block, then it waits for a key |
| 1 | the environment cannot run it | one line via `die` |
| 2 | bad arguments | `usage_error` |

The refusal block, on a held float (the `hold_pick` pattern, a `hold_done`
twin — the float closes when the script exits, so the wait is what keeps the
message readable):

```
can't tear down feat/6c4

  changes not merged into main@origin: 3 changes, 4 paths
    init.lua
    new-work.sh
  working copy has changes: 2 paths
  still running in this tab: pi, node

  bead rex-config-6c4 is still in_progress

nothing was removed; press any key
```

Blockers in that order, the bead last and marked as information. The word
"nothing was removed" is load-bearing: the screen is the whole answer, and it
has to say that the flow stopped rather than partially acted. The two `main`
blockers join the list after `still running in this tab`, each naming
`jj new main@origin` as the command that would clear it.

On the clean path the screen never appears — `done` prints nothing, hands back,
and the float closes on its own. That is the decision this cut makes about
confirmation: with nothing at risk, the tab going away is the feedback.

### The clean path: remove, verify, then close from the script

`work_done_go` removes and reports; it does not close anything.

1. **`wt remove <path> --foreground -y --format=json`**, run through the login
   shell with `cwd = main`. `--foreground` so the removal itself blocks and its
   `branch_outcome` is final — it does not wait for the `post-remove` hook, which
   worktrunk runs in the background; `-y` because nobody is there to approve a
   prompt; `--format=json` so the reply can be read rather than guessed. No `-f`,
   `-D`, no `--reap`, no `--no-hooks`: if worktrunk refuses on its own terms,
   that refusal is the report.
2. **The branch really went.** The reply is an array — one entry per removal,
   and this flow removes one path — so the entry's `branch_outcome` is what is
   read. `deleted` is complete. `not_attempted` with no `branch` is complete
   too, and it is the *normal* answer here: a jj wrapper's workspaces are
   detached (`gws` adds them with `jj workspace add`, and nothing attaches a
   branch), so worktrunk has nothing to delete and leaves nothing behind.
   Anything else — `retained_unmerged`, `retained_checked_out`,
   `retained_raced`, `retained_failed`, a field that is not there, or a value
   this flow does not know — is a **failure**, reported with the branch's name
   and `wt remove -D <branch>` as the command that would finish it: the
   worktree's path is gone by then, so the branch is the only thing left to
   name. `-D` is not run by the flow: if worktrunk and the audit disagree about
   merged, the person decides. A bookmark or a branch ref that survives the
   removal is not this case at all: Step 8 owns bookmarks, and the flow neither
   deletes nor reports one.
3. **Verify the store, rather than trust the hook.** `jj workspace list` must no
   longer list the name — read with `--ignore-working-copy`, because the
   background hook is forgetting the workspace in this same repository and a
   plain read would wait on the working-copy lock that hook holds — and
   `wt list --format=json` must no longer show the path. This is the check the
   bead's comment asked for, because the seeded hook ends in `|| true` and a
   background hook can fail silently — and because it runs after the removal has
   returned, the row is given a bounded moment (up to ten reads over about two
   seconds) before it counts as left behind, so a row a healthy hook clears a
   moment later is not a failure. A surviving jj row is reported with the one
   command that would clear it.
4. **Return.** Success returns nothing; every failure returns its line, which
   Rex prints on the float's terminal and which makes `rex do` exit non-zero.

Then the **script** finishes: it prints any line the hand-back produced and holds
it (`hold_done`), or — on success — it does two last things and nothing else:

```bash
cd "$main"                        # the workspace directory is gone by now
rex window close -s "$session" "$window"
```

The close is the script's last act, deliberately. The block that closes a window
is a block in that window, so the process that asks for the close dies with it;
the script is that process here, and it has nothing left to do. This is why
`work_done_go` must not close: it runs under `rex do`, a child of that block, and
closing there would kill the caller in the middle of the removal. The `cd` first
is not cosmetic — the script's own cwd is the directory `wt remove` just deleted,
and a process with a deleted cwd may fail to exec.

This also removes the need for a second float: every failure happens while the
first one is still on screen.

### Seeding the `post-remove` hook

`main` has no `.config/wt.toml` today, so `wt remove` in this repo leaves the
workspace row behind — which is the `jj workspace forget` the person types by
hand now. The file is created in `main` and committed on `main`, matching
`ginit`'s seed exactly:

```toml
[post-remove]
jj = "jj workspace forget {{ branch }} 2>/dev/null || true"
```

Identical to `ginit.fish` on purpose: a repo seeded two ways is a repo where the
next surprise is a difference nobody remembers choosing. `{{ branch }}` is
worktrunk's template variable and resolves to the branch the tab and workspace
are named after — the shape `ginit` already relies on, and the shape this repo's
workspace names (`feat/6c4`, slashes and all) are built for. The trailing
`|| true` is kept from the seed, and is exactly why step 3 of the clean path
verifies the row is gone instead of assuming it.

This is a commit on `main`, separate from the feature commit, and it is the one
part of this change that is not code in a worktree.

## Edge cases and failure behaviour

- **The pane is in `main` or at the wrapper root** — refused before anything is
  read (`--cwd` is a path comparison). The screen is the same refusal, with one
  line: the main worktree is not a workspace to tear down.
- **The pane is in a directory jj does not list** — refused, naming the cwd. A
  stale directory from a half-done removal is the usual cause, and the message
  says which paths exist and which do not.
- **jj lists the row, worktrunk does not** (or the reverse) — refused, naming
  both halves, because removing one of them is the state that is hard to unpick
  by hand.
- **worktrunk will not run the `post-remove` hook** — no project hook that
  forgets the jj workspace, or one that reports `needs_approval: true`, or a
  listing that cannot be read. Refused **before the fetch**, naming the remedy
  (`ginit`, or `wt config approvals add` in `main`), because the removal would
  otherwise go through and leave the row behind: a teardown that cannot finish
  must not start.
- **The fetch fails** (no network, no credentials, timeout) — refused, naming
  the fetch and that no comparison was possible. Nothing is removed, and
  `main@origin` is not silently believed.
- **Changes exist but are already merged by squash** — the content diff is
  empty and the flow proceeds. This is the case a reachability test gets wrong,
  and the normal path through this repo.
- **The base revision does not resolve** (`<branch>@origin` absent, no remote) —
  refused by name rather than assuming "merged".
- **`main` has work in progress** — a blocker: not moved, reported with the
  command that would move it, and nothing removed. An unmoved `main` is
  recoverable in one command; a discarded working copy is not.
- **The `main` bookmark is ahead of `main@origin`** — a blocker (the move would
  be backwards), reported the same way.
- **A dev server or watcher is still running in another block** — a refusal, by
  name, from `--running`. The person stops it and runs the key again; rex does
  not kill it, and `--reap` is not used.
- **Rex cannot read a block's process** — a refusal, treated like an unknown
  program name.
- **The workflow was run from a second tab of the same workspace** — the tab that
  closes is the one the pane is in, which is the one the person meant. (Unlike
  `work_new_go`, nothing here is found by label.)
- **`bd` is absent, or the id does not match a bead** — silence. The bead line is
  information, and its absence is not a failure.
- **Ignored files in the worktree** (`.env`, `node_modules`) — deleted with the
  directory, and **not** a blocker. This is my call: they are the thing
  `post-start` hooks recreate, and refusing on `node_modules` would make the flow
  useless in every repo that has one. The screen does not count them.
- **The removal succeeds, the jj row survives** — the hook failed, or never
  finished, and the row is still there at the end of the wait. Reported with
  the exact command to finish by hand, on the float that stays.
- **The removal succeeds, the branch is retained** — reported with
  `wt remove -D <branch>` — the branch, not the path, because the worktree is
  gone by the time the line is read — and the tab does **not** close (nothing is
  closed on any failure), so the person can finish from where they are.
- **The workspace is detached** — the jj wrapper's normal case, since `gws`
  adds workspaces with `jj workspace add` and nothing attaches a branch. There
  is no branch for worktrunk to delete, it says `not_attempted`, and that is a
  completed teardown: nothing was left behind to report.
- **The window will not close** — the last act failed and nothing is left running
  to say so. Accepted and documented: the directories and the workspace row are
  already gone by then, so the residue is a tab whose shell is in a deleted
  directory; `ctrl+w` closes it.
- **A local bookmark survives the removal** — Step 8 owns bookmarks (it deletes
  the merged one after proving the trees identical), so this flow neither deletes
  nor reports it. A bookmark left pointing at an abandoned change is harmless; a
  bookmark left pointing at unmerged work is exactly what the unmerged-changes
  refusal already caught.
- **`main` has no `.worktreeinclude` and no `post-start` hook** — noticed while
  reading, out of scope here, and worth its own bead: new workspaces in this repo
  do not get their ignored files copied, which is the seed `ginit` writes and
  `rex-config` never received.

## Testing

Everything runs from `bash test/run.sh`, no pty.

- **`test/done_test.sh`** (new) — the audit, the refresh and the screen, with
  every tool read replaced by a fixture: `--workspaces` (a saved
  `jj workspace list -T …`), `--wt-json` (a saved `wt list --format=json`),
  `--hooks-json` (a saved `wt hook show post-remove --format=json`: approved,
  `needs_approval: true`, empty, and a reply that is not a listing),
  `--diff` (a saved `jj diff --summary` for the base range), `--own-status` (a
  saved `jj diff --summary -r @`), `--main-state` (a saved rendering of the two
  `main` checks), `--bd-json` and `--running`. `--no-fetch` is passed by every
  scripted run, so the suite never touches the network. Asserted: exit 4 and the
  exact refusal block for each blocker alone and in combination; the paths listed
  for a non-empty content diff, and **exit 0 for the squash case** where the base
  range has changes but an empty diff; the bead line printed for a matching id,
  absent for no match and for no `bd`; exit 4 for a `--cwd` equal to `--main`, to
  the wrapper, and for a `--cwd` under a workspace **inside another workspace**
  (the longest-prefix rule, with a `default`-plus-`feat/6c4` fixture); exit 4 when
  the jj row and the worktree disagree; exit 4 naming the fetch when a stand-in
  `jj` on `PATH` fails it (every other scripted run passes `--no-fetch`, so the
  suite never reaches the network); the `main` refresh running `jj new main@origin` for a
  provably empty `main` and **not** running it for a `main` with a description or
  a non-empty diff; the bookmark move skipped when `main` is not contained in
  `main@origin`; exit 2 for a relative `--cwd`; and — for a clean workspace — exit
  0 with exactly one line, the `rex do work_done_go --args '<json>'` hand-back
  (`payload_of`, as `pick_test.sh` compares it), the json carrying `path` for the
  removal and `workspace` for the tab.
- **`test/action_test.lua`** — `M.work_done` opens one layer with the expected
  argv (`--session`/`--window` from ctx, one `--running` per non-shell foreground
  process, including a tab whose second block runs `node`, and none for a tab of
  bare shells); `block.process` failing to answer produces a `--running` entry
  rather than silence. `M.work_done_go` runs `wt remove <path> --foreground -y
  --format=json` with `cwd = main`, and **never** closes a window: the removal's
  reply is read from `test/fixtures` as worktrunk writes it — an array, one entry
  per removal — so a `deleted` entry returns success and so does the detached
  `not_attempted` one, `retained_unmerged` returns the branch line naming
  `wt remove -D <branch>`, and an entry with no `branch_outcome` fails; a
  surviving `jj workspace list` row returns the leftover-row
  line only after the list has been read again within the wait, and a row the
  next read loses is a success; a `wt` that exits non-zero returns its stderr.
- **`test/setup_test.lua`** — both actions are registered, `work_done` has
  `category = "New work"` and no `args`, and `work_done_go` declares exactly
  `project`, `root`, `main`, `workspace`, `path`.
- **`test/wrapper_test.sh`**-style stand-in — a `jj` and a `rex` on `PATH` record
  their argv, proving the fetch, the two `main` moves, and the closing `rex
  window close -s … …` happen in that order and only in that order, with the
  close last, and nothing at all after it.
- **By hand, once, in the float** — one real teardown: the fetch, the refusal
  screen readable for as long as it takes to read, then a clean run where the tab,
  the directory, the branch and the `jj workspace list` row all go, `main`'s `@`
  lands on `main@origin`, and the tab closes itself. A pipe cannot prove the hold,
  the window close, the fetch, or the unlink-under-a-live-shell, and pretending
  otherwise would be the test lying.

## What's left to the builder

- The saved-fixture format for `--main-state` (one rendering of the emptiness
  test and the containment test), and the exact `jj log`/`jj diff` invocations
  behind them.
- Whether the base resolution shares `bases`'s code or repeats its three-step
  fallback, and whether a repo with no remote refuses at the fetch instead.
- Whether the `--running` shell list lives in `init.lua` or in the script's
  contract documentation, and the list itself (`nu`? a python REPL? — an unknown
  name refuses).
- The bead-id ↔ workspace-name match: whether the last dash segment is enough
  for every project's naming.
- The refusal float's bounds, and whether the held-terminal `wait_for_key` is
  enough for a message this long (a `gum`-less pager is my preference — one
  screenful, no scrolling).
- Whether the refusal block's `main` line is printed above or below the
  `nothing was removed` line.
- The exact `rex window close` argv (`-s` before or after the id), and whether
  the script needs to re-`cd` before it (`cd "$main"` is the guess).
- The README section: the keybind line, a flow paragraph beside the new-work
  one, its own paragraph for the fetch and the `main` fast-forward, and a
  failure-modes paragraph for the refusals.
- Whether `done` names a `refused=4` constant beside the existing `cancelled=3`.
