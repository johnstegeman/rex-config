# rex-config: "I'm done" — one key removes the tab, the worktree, the branch and the jj workspace

**Date:** 2026-11-05
**Status:** design, approved in conversation. **Superseded for the workspace
tool** by `docs/superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md`:
the removal is `djo remove <workspace> -y` (not `wt remove`), and the
kept-branch report comes from jj (not worktrunk's `branch_outcome`). Everything
here that is not about those two answers still stands.
**Owner:** John Stegeman
**Bead:** `rex-config-6c4`

## Intent

Finishing work used to mean typing several different things: `wt remove` for the
worktree and branch — `djo remove <branch> -y` since the 2026-11-06 cut —
`jj workspace forget` for the workspace row (which was not run at all — `main`
had no `.config/wt.toml`), and closing the Rex tab by hand. The ask is one action
that does all three, and nothing typed.

This is the counterpart to `ctrl+space>n` (`2026-10-28-rex-new-work-design.md`,
`2026-11-03-rex-jj-workspaces-design.md`): new work is created by one key, so
work is torn down by one key. The same three units are involved in reverse —
the jj workspace row, its directory and bookmark, and the Rex tab inside the
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
  down the workspace the focused pane is in: the tab, the workspace's directory,
  its bookmark, the jj workspace row.
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
- `main` gets the hook config it is missing, so a new workspace starts the way
  every other repo's does. **The seeding is the runbook's job since the
  2026-11-06 cut**, which rewrote every worktrunk-shaped hook table as a
  `[hooks.post-start]` one and deleted the forget hook — `djo remove` forgets
  the workspace itself, so there is nothing left for a hook to do.
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
- **Forcing.** No `-f`, no `-D`, no `--reap` — worktrunk's flags, and the flow
  runs no worktrunk now (history). The audit already refused the situations they
  exist for. `djo remove` is given `-y` and nothing else: no `--keep-bookmark`,
  because the branch goes with the workspace it was named for, and no
  `--keep-revision` either.
- **Reaping processes.** Killing dev servers was `wt --reap`'s experimental job
  (history: nothing in the flow reaps now), and it kills things rex did not
  start.
- **Merging, pushing, rebasing, or opening a PR.** The merge is the person's, on
  the forge. This flow never pushes.
- **Feeding the rest of the repository's seed.** `main` also lacks
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

- **Rex runs actions with its own PATH** (`/usr/bin:/bin:…`), while `djo`, `jj`,
  `bd` and `fish` live on the login shell's PATH. Everything this flow runs goes
  through the login shell, as the new-work flow already does.
- **The pane's shell lives in the directory being removed.** Its cwd is the
  workspace root; `djo remove` deletes it out from under that shell.
- **Closing a window kills every block in it**, including the block that asked
  for the close. Nothing may follow a close, and the close must be the last act
  of the process that issues it — or it must be issued by somebody who outlives
  the window. Rex's control API has `session.close_window`, and no client action
  for closing a window, so the second option means the CLI.
- **A fetch needs the network and a credential-free path.** The pane is a
  terminal nobody can type into, so a credential prompt must not hang there:
  `GIT_TERMINAL_PROMPT=0`, and the fetch bounded by `timeout`/`gtimeout` at 30
  seconds when either is installed — the discipline `jws` already uses.
- **dojjo's remove is synchronous and forgets the workspace itself.** `djo
  remove <name> -y` deletes the directory, forgets the row and deletes the
  bookmark in one command, and it has no merged check to second-guess. The row is
  still *verified* rather than believed, because an exit code only says dojjo
  thought it had finished; a row left behind is forgotten by the flow itself,
  once, before it is reported.
- **`djo remove` deletes the bookmark unconditionally.** (History: worktrunk
  deleted a branch only when it judged it merged, and reported `branch_outcome`
  in its `--format=json` reply.) So a bookmark that still resolves after the
  removal is the only "kept" case this flow has, and the audit's unmerged-changes
  refusal is the single thing between unmerged work and `djo remove`.
- **dojjo reads the project hooks from the workspace** —
  `<workspace>/.config/wt.toml`, which is the file `main` carries into every new
  workspace. A hook seeded anywhere else does nothing.
- **Merged means content, not ancestry.** After a squash or rebase merge — the
  normal forge flow, and the one this repo uses — a branch's changes are not
  ancestors of `main@origin` even though the work is fully merged. Only a
  content comparison answers "is this merged?" after a squash — and nothing else
  answers it for you: dojjo has no merged check to defer to.
- **Worktree names and branch names differ in shape.** The branch and the jj
  workspace are both named after the plan (`feat/6c4`); the directory is that
  name with every `/` replaced by `-` (`feat-6c4`) — the form worktrunk's
  template produced and `jws` still produces. The tab is labelled with the
  branch.
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
- The `post-remove` hook was to be **seeded by this change**; the 2026-11-06 cut
  deleted it instead — `djo remove` forgets the workspace itself — and what the
  seeding step leaves behind is the `[hooks.post-start]` seed. See *The
  `[hooks.post-start]` seed, and no forget hook at all*.
- The flow **fetches automatically**, and **keeps `main` up to date** if it can.
- **A kept bookmark is a failure, not silence** (from the builder check): the
  flow's whole promise is one complete teardown, so a bookmark that survives the
  removal is reported with the one command that finishes it —
  `jj bookmark delete <name>`. (History: the branch worktrunk declined to delete
  was reported with `wt remove -D`.)

## How it works

### The units, and where the change lands

| Unit | File | Change |
|---|---|---|
| action `work_done` | `init.lua` (`M.setup`) | new action, `category = "New work"`, no args: finds the pane's project and opens the flow's float |
| action `work_done_go` | `init.lua` (`M.setup`) | new action with declared args: the hand-back target that removes and verifies |
| the flow's guts | `init.lua` | `M.work_done`, `M.work_done_go`, `M.tab_processes` — beside `M.work_new`/`work_new_go` |
| the audit, the refresh and the screen | `new-work.sh` | a `done` subcommand with fixture seams and a `--dry-run` hand-back |
| project hooks | `main/.config/wt.toml` | the `[hooks.post-start]` seed when `main` has none — by the 2026-11-06 cut this is the runbook's file, not this plan's |
| keybinding | `README.md` | one `rex.bind` line beside `ctrl+space>n`, and a flow section |
| tests | `test/done_test.sh`, `test/action_test.lua`, `test/setup_test.lua` | the refusal cases, the clean hand-back, the removal sequence |

Nothing else moves. `pick`, the composer, `bases`, `branch-default`, the payload
of the new-work flow, `jws`, and the finishing skill are untouched.

### The shape: picker-shaped, like `work_new`

The flow reuses the two-action pattern the picker already established, because it
is the pattern this repo tests well:

```
key  →  work_done                 (no args; finds the pane, opens a float)
          new-work.sh done        (process check, fetch, audit, refresh, decide)
            →  rex do work_done_go --args '{"project":…,"root":…,"main":…,"workspace":…,"path":…}'
                 work_done_go     (djo remove, verify, report)
            →  rex window close -s <session> <window>   (the script's last act)
```

`work_done` does four things and nothing else: it reads the pane's cwd
(`block_cwd`, already used by `work_new`), resolves the project (`M.project_for`,
already used by `work_new` — wrapper root, name, and `main`), reads which
programs the tab is still running (`M.tab_processes`), and opens a float running
`M.options.script done --main <main> --root <root> --project <name> --cwd <pane
cwd> --session <id> --window <id>` plus one `--running <name>` per program. The
float is a layer in the current window, `bounds` as the picker uses them.

The `main` in that hand-back is resolved by jj, and by nothing else: `M.project_for`
takes the wrapper root from the nearest ancestor holding `.jj/repo` **as a
directory** (history: it used to be git's common directory), the project name
from that directory's basename, and the main worktree from **jj's own workspace
named `main`** — `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'`, read
through the login shell, because jj lives on the login PATH and Rex's PATH does
not have it. There is no fallback any more: a wrapper with no `main` row is
refused by name, which is kinder than the flag that used to answer instead and
could answer wrongly — in a bare-rooted wrapper whose worktrees are all detached
(`pi-rex`) worktrunk flagged a *branch* workspace as main, which put the picker's
float, `bd` and the teardown's two `main` moves in the wrong directory. jj's
workspace name is what the rest of this flow already means by "main": `jinit`
and `jclone` create it, `jws` adds workspaces beside it, and the refusals below
compare against it. (History: worktrunk's `main` flag in `wt list --format=json`
was the fallback, and a wrapper with no jj at all was answered from it.)

The window and session ids come from the pane, not from a label lookup: `ctx`
already carries `session_id` and `block_id` (that is how `block_cwd` works), so
the tab being torn down is the tab the person is looking at. This is the one
place where the flow is *simpler* than `work_new_go`, which has to find its tab
by label because the tab it wants does not exist yet.

Rex facts stay in Rex, jj facts stay in bash. The one crossover is
"what is still running", which only Rex can answer, so `work_done` reads it and
passes it in as data.

### Finding the workspace, and the refusals that come before any question

The script is handed `--cwd`, `--main` and `--root`. `--main` is Rex's own answer
to "which directory is this project's main worktree" — `M.project_for`'s read of
jj's `main` row — and it is not trusted on its own: the two readings of the same
fact are compared, and a disagreement is refused rather than resolved. jj names
its own main row, and that is the answer the protection is built from — with
`--main` kept as well, so the refusal below can never be the thing that lets a
teardown through by being wrong on its own.

1. **Two answers to compare, before any refusal, from one read**:
   `jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'`, run in `--cwd`. The
   row named `main` is **jj's main worktree** (`jj_main`). Put in the same
   one-slash form `--main` is put in, a trailing slash is not a disagreement.
2. **`jj_main` and `--main` disagree** → refuse, naming both paths and saying
   the two answers disagree about which worktree is main. Nothing is fetched,
   moved or removed: this is precisely the repo the flow cannot tell how to act
   in, and refusing is the only safe answer to it. A repo with no row named
   `main` — a main workspace under another name — has one answer only, and
   `--main` is it.
3. **`--cwd` is `--main` or inside it, is `jj_main` or inside it, or is the
   wrapper root** → refuse: this is the main worktree, or `default`, the empty
   workspace at the wrapper root, and the flow never tears down either.
   Structural, by path — not by name, so a repo whose main worktree is called
   something else is still protected. The three are a union rather than a
   choice: with the two answers agreeing, either one protects the same
   directory, and with them disagreeing rule 2 has already refused.
4. Otherwise the same one read answers the second question: **the longest listed
   root that is a prefix of, or equal to, `--cwd` is this workspace** — its
   **name** (the tab label and the branch) and its **root** (the directory to
   remove). Longest wins because roots nest:
   measured on the live wrapper, `default` is `/…/rex-config`, `main` is
   `/…/rex-config/main` and `feat/6c4` is `/…/rex-config/feat-6c4`, so a
   subdirectory of a workspace matches two rows and only the deepest is the
   answer. `default` matching at all therefore means the cwd is at or under the
   wrapper with no deeper workspace owning it — which is rule 3's refusal, from
   the other direction.
5. **No row matches** → refuse: this pane is not inside a jj workspace the
   wrapper knows about (a stale directory, or a plain git worktree left over from
   before the conversion). Nothing is guessed.

Rule 6 of this design — `wt list --format=json` had to show a worktree at that
root, and the two listings disagreeing was a refusal — is **deleted**: `jj
workspace list` is now the only listing, dojjo's remove takes the directory with
the row, and nothing can drift. (History: the rule existed because two tools each
held half of the truth.)

The workspace **name** is what the tab is called and what `djo remove` is given,
because dojjo takes the workspace and not a path; the workspace **root path** is
what the flow checks is gone afterwards — the directory, and the bookmark by
name.

### The audit: the fetch, then four facts and a bead

The audit's reference base is resolved the way `bases` already resolves it —
`refs/remotes/origin/HEAD`'s target, then `main`, then `master` — and rendered as
one jj revision, `<branch>@origin`. It is not hard-coded, because the wrapper
root's default branch is a property of the remote, and a project whose default is
not `main` would otherwise refuse forever.

**The fetch comes first**, because every comparison below is a comparison
against `main@origin` and a stale `main@origin` makes the answer wrong in the
direction that matters: it reports merged work as unmerged. One `jj git fetch`,
bounded by `timeout`/`gtimeout` at 30 seconds when installed (the `jws`
discipline, moved intact), with `GIT_TERMINAL_PROMPT=0` exported so a credential
prompt cannot hang the float. A failed fetch is a **refusal**, naming that the
fetch failed and that the comparison could not be made — never a silently stale
comparison.

Then, all read-only, all from inside the workspace:

- **Changes not merged into the base** — *content*, not ancestry:
  `jj diff --summary -r '<base>..@'` is non-empty. Reachability would refuse
  forever after a squash or rebase merge, which is this repo's normal flow; the
  content diff is the rule this flow applies, and it no longer defers to a tool's
  own merged check — dojjo has none. The refusal lists the affected **paths** and
  the number of changes in the range, because "3 changes touching new-work.sh,
  init.lua" is what the person can act on.
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

1. **`djo remove <workspace> -y`**, run through the login shell with `cwd =
   main`. `-y` because nobody is there to approve a prompt, and no
   `--keep-bookmark` because the branch is merged and goes with the workspace it
   was named for. No `-f`, `-D` or `--reap` — those were worktrunk's and none of
   them has a counterpart here — and no `--no-hooks` either: dojjo runs its own
   remove hooks, and a refusal of its own is the report. In one command dojjo
   deletes the directory, forgets the workspace and deletes the bookmark, and it
   has no merged check to second-guess, so the reads below are the only audit
   this teardown gets.
2. **The bookmark really went.** dojjo deletes the bookmark with the workspace,
   so one that still resolves is the **only** "kept" case this flow has, and it
   is a failure: reported with `jj bookmark delete '<name>'` as the command that
   finishes the job. The read is a jj revset that names the bookmark exactly —
   `jj --ignore-working-copy log --no-graph -r 'bookmarks(exact:"<name>")' -T
   'commit_id ++ "\n"'` — and not a `jj bookmark list`, because deleting a
   bookmark a remote tracks only tombstones it: the listing goes on printing the
   name, so it cannot tell a deleted bookmark from a kept one. A revset can,
   because it resolves to a commit only while the bookmark is really there. The
   delete is not run by the flow: the one command that would finish the job is
   named, and the person decides.
3. **Verify the store, rather than trust the exit code.** `jj workspace list`
   must no longer list the name — read with `--ignore-working-copy`, because a
   post-start hook dojjo started may still hold the working-copy lock. A row
   still there is given a bounded moment (up to ten reads over about two
   seconds), and a row that survives that is forgotten by the flow itself —
   `jj workspace forget '<workspace>'`, run through the login shell with
   `cwd = main` — after which the listing is read once more. A row left behind
   for a directory the flow has just removed is the teardown it started,
   finished; only a row that survives the flow's own forget is reported, with
   `jj workspace forget '<name>'` as the command that would clear it, and a
   forget that fails is judged by the row that follows it rather than by its own
   exit status. This is history's check, kept: the seeded forget hook ended in
   `|| true`, so the row was never something to take on trust.
4. **The directory itself.** `test ! -d <path>` — one argv, so a path with a
   space or a quote in it is never shell text — and a directory still there is
   reported with `djo list -f` as the command that says what dojjo thinks it
   removed. There is no `wt list` to read any more; the directory is the second
   half of "the workspace is gone".
5. **Return.** Success returns nothing; every failure returns its line, which
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
is not cosmetic — the script's own cwd is the directory `djo remove` just deleted,
and a process with a deleted cwd may fail to exec.

This also removes the need for a second float: every failure happens while the
first one is still on screen.

### The `[hooks.post-start]` seed, and no forget hook at all

dojjo reads hooks from a `[hooks]` table only — a `[hooks.post-start]` table,
never a top-level `[post-start]`, which dojjo parses and silently ignores. That
matters here because this repo's `main` had no `.config/wt.toml` at all, and a
file seeded in the wrong shape is worse than no file: hooks that vanish without a
message are worse than hooks that fail. The file keeps its name —
`main/.config/wt.toml`, committed on `main` — so no repo is left with a second
file that dojjo half-reads.

What the seed is now:

```toml
[hooks.post-start]
copy = "djo copy-ignored --from main"
```

`djo copy-ignored` copies every ignored path — `node_modules` as well as `.env` —
because dojjo has no include filter and does not read `.worktreeinclude`; the
owner accepted that trade. A repo that wants a worktree-local `.beads/redirect`
adds its own hook, pointing at `{{ primary_workspace_path }}` (under dojjo
`repo_path` is the *new* workspace). Most wrapper-layout repos need no redirect
hook at all, because beads is found by upward detection.

**There is no forget hook, in any form.** `djo remove` forgets the workspace
itself, so a `[hooks.post-remove]` table would be a no-op and a top-level
`[post-remove]` would be silently ignored. It was deleted rather than carried
across. The row is still verified after the removal, as step 3 of the clean path
says, because the listing rather than a hook is the proof.

The seed is `jinit`'s seed, in `jinit`'s file, so a repo seeded two ways does not
become a repo where the next surprise is a difference nobody remembers choosing.
Seeding `rex-config`'s own `main` is the **runbook's** job since the 2026-11-06
cut, and it is a commit in that repo, not code in this one.

## Edge cases and failure behaviour

- **The pane is in `main` or at the wrapper root** — refused before any question
  is asked (`--cwd` is a path comparison, made against `--main`, the wrapper root
  and jj's own `main` row). The screen is the same refusal, with one line: the
  main worktree is not a workspace to tear down.
- **jj's `main` row and `--main` disagree about which worktree is main** —
  refused, naming both paths, before the fetch: nothing was fetched, moved or
  removed. Both answers are readings of the same jj row now — Rex's and the
  script's — so a disagreement means one of the two reads is wrong, and the flow
  does not choose between them. (History: the second answer was worktrunk's
  `main` flag, seen naming a leftover in a bare-rooted wrapper of detached
  worktrees.)
- **The pane is in a directory jj does not list** — refused, naming the cwd. A
  stale directory from a half-done removal is the usual cause, and the message
  says which paths exist and which do not.
- **jj lists the row and the directory is gone** — the state this design used to
  refuse as the row and the worktree disagreeing. It is the *result* of a
  successful teardown now, so the refusal is deleted; what remains is a row
  dojjo's remove left behind, which the flow forgets itself before reporting it.
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
- **The removal succeeds, the jj row survives** — dojjo's forget did not take, and
  the row is still there at the end of the wait. The flow forgets it itself, once,
  and reads the listing again; only a row that survives *that* is reported, with
  the exact command to finish by hand, on the float that stays.
- **The removal succeeds, the bookmark is kept** — reported with
  `jj bookmark delete <name>`, and the tab does **not** close (nothing is closed
  on any failure), so the person can finish from where they are. dojjo deletes
  the bookmark with the workspace, so a bookmark still resolving is a teardown
  that did not finish.
- **The workspace has no bookmark** — nothing to report. (History: under worktrunk
  this was the normal case — its reply said `not_attempted` for a detached
  worktree and that counted as a complete teardown. Every workspace `jws` makes
  carries its branch's bookmark, so the silent case is now the rare one.)
- **The window will not close** — the last act failed and nothing is left running
  to say so. Accepted and documented: the directories and the workspace row are
  already gone by then, so the residue is a tab whose shell is in a deleted
  directory; `ctrl+w` closes it.
- **A local bookmark survives the removal** — **reported**, with
  `jj bookmark delete '<name>'` as the command that finishes the job. (History:
  this flow once left bookmarks to the finishing skill's Step 8 and reported
  nothing. dojjo deletes the bookmark with the workspace, so one still there is a
  teardown that half happened, and a half teardown is the one thing this flow
  promises never to leave.)
- **`main` has no `.worktreeinclude` and no `post-start` hook** — noticed while
  reading, out of scope here, and worth its own bead: new workspaces in this repo
  do not get their ignored files copied, which is the seed `jinit` writes and
  `rex-config` never received.

## Testing

Everything runs from `bash test/run.sh`, no pty.

- **`test/done_test.sh`** (new) — the audit, the refresh and the screen, with
  every tool read replaced by a fixture: `--workspaces` (a saved
  `jj workspace list -T …`), `--diff` (a saved `jj diff --summary` for the base
  range), `--own-status` (a saved `jj diff --summary -r @`), `--main-state` (a
  saved rendering of the two `main` checks), `--bd-json` and `--running`. Every
  scripted run passes `--no-fetch` except the four that must really reach the fetch — the two
  `main`-disagreement runs, which prove that refusal comes first, and the two
  fetch-failure runs — and each of those reaches jj through the stand-in first on
  `PATH`, so no real jj and no network is touched.
  Asserted: exit 4 and the exact refusal block for each blocker alone and in
  combination; the paths listed for a non-empty content diff, and **exit 0 for
  the squash case** where the base range has changes but an empty diff; the bead
  line printed for a matching id, absent for no match and for no `bd`; exit 4
  for a `--cwd` equal to `--main`, to the wrapper, and for a `--cwd` under a
  workspace **inside another workspace** (the longest-prefix rule, with a
  `default`-plus-`feat/6c4` fixture); exit 2 for `--wt-json`, the option that
  went with worktrunk, so a script still passing it fails loudly; exit 4 naming
  the fetch when a stand-in `jj` on `PATH` fails it; the `main` disagreement
  refusal coming before the fetch — the refusal screen is
  what proves the ordering, and the stand-in `jj` recording **no argv at all** on
  a run given no `--no-fetch` corroborates it (that run's `--main` is not a
  directory, so a fetch moved ahead of the refusal would fail in its own `cd`
  without reaching jj); the `main` refresh running `jj new main@origin` for a
  provably empty `main` and **not** running it for a `main` with a description or
  a non-empty diff; the bookmark move skipped when `main` is not contained in
  `main@origin`; exit 2 for a relative `--cwd`; and — for a clean workspace —
  exit 0 with exactly one line, the `rex do work_done_go --args '<json>'`
  hand-back (`payload_of`, as `pick_test.sh` compares it), the json carrying
  `path` for the removal and `workspace` for the tab.
- **`test/action_test.lua`** — `M.work_done` opens one layer with the expected
  argv (`--session`/`--window` from ctx, one `--running` per non-shell foreground
  process, including a tab whose second block runs `node`, and none for a tab of
  bare shells); `block.process` failing to answer produces a `--running` entry
  rather than silence. `M.work_done_go` runs `djo remove 'feat/6c4' -y` with
  `cwd = main`, and **never** closes a window: the three reads that follow each
  have their answer stubbed — the workspace row, `test ! -d <path>`, and the
  bookmark revset — so a clean teardown returns success, a row that survives both
  the wait and the flow's own `jj workspace forget` returns the leftover-row line,
  a directory still there returns the `djo list -f` line, a bookmark that still
  resolves returns `jj bookmark delete 'feat/6c4'`, a `jj bookmark list` is
  answered by a case that proves it was never asked, and a `djo` that exits
  non-zero returns its stderr.
- **`test/setup_test.lua`** — both actions are registered, `work_done` has
  `category = "New work"` and no `args`, and `work_done_go` declares exactly
  `project`, `root`, `main`, `workspace`, `path`.
- **`test/wrapper_test.sh`**-style stand-in — a `jj` and a `rex` on `PATH` record
  their argv, proving the fetch, the two `main` moves, and the closing `rex
  window close -s … …` happen in that order and only in that order, with the
  close last, and nothing at all after it.
- **By hand, once, in the float** — one real teardown: the fetch, the refusal
  screen readable for as long as it takes to read, then a clean run where the tab,
  the directory, the bookmark and the `jj workspace list` row all go, `main`'s `@`
  lands on `main@origin`, and the tab closes itself. A pipe cannot prove the hold,
  the window close, the fetch, or the delete-under-a-live-shell, and pretending
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
