# rex-config: `ctrl+space>n` — start new work from a bead

**Date:** 2026-10-28
**Status:** design, approved in conversation. **Historical:** the tooling this
document names has moved twice since — worktrunk (`wt`) gave way to jj workspaces
(`2026-11-03-rex-jj-workspaces-design.md`) and then to `jws`/dojjo
(`2026-11-06-dojjo-workspace-cut-design.md`). Every `wt` here is what the flow
used *then*; read the later two for what it does now.
**Owner:** John Stegeman

## Intent

Starting a new piece of work used to be a herdr/orca gesture: find the repo,
click **+**, type a branch name, and an agent starts in the new checkout. The
"which thing am I working on" half was done by hand first — `bd list`, `bd show`,
carry a bead id in your head — and then typed into the agent as
`/brainstorming for bead <id>`.

This plugin collapses that into one keystroke inside Rex: pick a bead, get a
branch name derived from it, and land in a new tab, in a new worktree, with the
agent already brainstorming that bead.

Success is: from a shell anywhere in a project, `ctrl+space>n` → two picks →
an agent working on the right bead, on the right branch, in the right
directory, as a tab in the project's own session.

## Goals

- One keystroke replaces "(+) + branch name + manual `bd list`/`bd show` +
  typed agent prompt".
- The bead drives the branch name and the prompt; the branch name stays
  editable.
- The resulting tab lives in the **project's** session, beside the user's
  `main` tab — not in a session of its own.
- The agent is a configuration value, not a hard-coded `pi`.
- Implementation is Lua + shell only.

## Non-goals (this cut)

- **GitHub issues.** Bead-first and bead-only. Beads is a hard requirement, so
  there is no degraded mode for a repo without it.
- **Worktree removal / cleanup.** No "close finished work" flow. The user closes
  the tab and runs `wt remove`. Tracked separately as bead `rex-config-6c4`.
- **Switching to existing worktrees as a first-class flow.** The old trial
  plugin `rex-worktrunk` is being removed; this plugin only offers an existing
  worktree when the typed branch matches one.
- **Picking a project other than the one the current pane is in.**
- **Adopting `rex-sessionizer`'s or `rex-worktrunk`'s session-per-worktree
  convention.**

## Anti-goals

- A second, competing session convention. Two shapes for "the session for this
  repo" would make every other Rex tool guess wrong.
- Silent duplicate tabs: pressing the key twice for the same branch must not
  produce two tabs, two worktrees, or a second claim.
- A picker that shows anything another session is already working on.

## Constraints

- **Rex key-bound actions cannot wait for input** — the app stops taking input
  while one runs. The pickers therefore run in a floating terminal, exactly as
  `rex-worktrunk` does: `rex.session.new_layer` with a shell flavor
  running the picker script, which hands its answer back with `rex do <action>`.
- **Switching the app to a session from the CLI needs Remote Control on**
  (Rex → Settings → Rex Server). Action run from a key already in the active
  session can queue the selection directly.
- **Login-shell `PATH`.** `wt`, `fzf`, `jq`, `bd`, and the agent must all be on
  the login shell's `PATH`.
- **Tooling present on this machine:** worktrunk (`wt`), `fzf`, `jq`, `bd`
  (beads 1.3.2), `pi`.
- **Worktrunk owns worktree creation.** Branches, paths, and hooks
  (`copy-ignored`, `bun install`, `.beads/redirect`) stay worktrunk's job. This
  plugin never runs `git worktree add`.

## Decisions made by the owner

- **Paradigm: project session, tab per worktree.** A "project" is a repository.
  Rex has one session per project (`pmm-iris`); inside it, one tab for `main`
  (the user creates it and treats it as home) and one tab per worktree in
  flight.
- **`ctrl+space>n`** is the key (`n` for new).
- **Tab first, then `wt switch`.** The tab is created before the worktree
  exists, and the switch happens inside it, so the pane ends up in the right
  directory.
- **Bead-driven branch names.** A picked bead defaults the branch name to
  `<prefix>/<short-id>` — `bug/58h`, `feat/58h`. With no bead, the name is typed
  freely.
- **The picker lists bead id + title**, with a way to read the long description
  without it crowding the list.
- **Only `bd ready` beads appear.**
- **Molecule and gate issues never appear** — another session is already working
  them.
- **Picking a bead claims it** (`bd update <id> --claim`).
- **The agent command is configurable** (`pi`, `claude`, …).
- **Lua and shell only**; no Go/Rust helper.

## How it works

> **Superseded (owner decisions after this design).** Two things below were
> replaced at the product owner's direction once the flow ran for real, and one
> consequence of that is a trade taken deliberately; the shipped code,
> `new-work.sh` and `README.md` carry the behaviour to build against.
>
> - **The branch question is a typed prompt, not a picker.** There is no
>   `fzf --print-query` stage: `new-work.sh` prints `branch [bug/58h]> `, a bare
>   Enter accepts the bead-derived name (so the typed name is the branch, with
>   nothing to reconcile between a query and a selection), and anything typed is
>   the branch exactly as typed, trimmed of surrounding whitespace. The candidate
>   list is still consulted — afterwards — to decide whether the name is a
>   worktree to switch to or one to create.
> - **The tab runs a `sh` wrapper, with no `-x` and no kept-open pane.** It is
>   `wt switch [--create <branch> --base <base>] --no-cd --format=json` → read
>   `.path` with `jq` → `cd` there → the agent with its prompt →
>   `exec "$SHELL" -l`. Worktrunk's hooks still run inside the pane, and every
>   value travels as a positional parameter, never as program text. Exiting that
>   login shell closes the tab, which is why nothing sets `--keep-open`: a pane
>   outliving its program is the dead tab this flow exists to avoid.
> - **Known trade: a ^C during `wt switch` ends the wrapper.** The wrapper
>   ignores INT only while the agent runs, so a hook approval prompt stays
>   interruptible; with no kept-open pane the tab closes rather than hanging.
>   Deliberate, not a bug.

### Flow

1. `ctrl+space>n` runs action `work_new`.
2. `work_new` reads the focused terminal's working directory
   (`rex.block.call("com.superlogical.terminal", "process")`), then resolves the
   project from it:
   - `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` →
     `/…/pmm-iris/.git`; the project root is its parent and the project name its
     basename. This works identically from `main/` and from any worktree.
   - The **main worktree** path comes from `wt list --format=json` (schema 2:
     `items[].worktree.path` with `items[].worktree.main`), and is the tab's
     initial working directory **and** the cwd for every `bd` call.
3. `work_new` stops here if the project has no beads database (probe: `bd where`
   or `bd ready --json` from the main worktree) — an error names the directory and
   says beads is required. Otherwise it opens a floating picker (bounds
   configurable) running `new-work.sh`, passing the project root, project name and
   `--base`.
4. `new-work.sh` asks two questions:
   - **Bead** — `bd ready --json`, filtered (see below), shown as
     `id  title` with `fzf --preview` running `bd show <id>` (through `bat` when
     present) so long text stays out of the list. Esc means "no bead".
   - **Branch** — an `fzf --print-query` prompt prefilled with the bead-derived
     name, listing existing worktrees and local branches too. Enter on an
     existing entry focuses that worktree's existing tab; a new name creates.
     *Superseded: the branch question is a typed prompt — see “Superseded (owner
     decisions after this design)” above.*
5. `new-work.sh` hands back:
   `rex do work_new_go --args '<json>'`, one JSON object with the keys `project`,
   `root`, `main`, `branch`, `bead`, `title` and `create`, so no value is ever
   interpolated into a command line
6. `work_new_go` (Lua):
   - resolves the project session by label = project name, creating it (with a
     `main` tab in the main worktree) when absent;
   - if a tab labelled `<branch>` already exists in that session, selects it and
     returns — no claim, no switch, no duplicate;
   - otherwise claims the bead (`bd update <id> --claim`, run with the main
     worktree as cwd — same database via `.beads/redirect`);
   - creates the tab with `rex window new` in the project session, label =
     branch, cwd = main worktree, `--keep-open`, whose command is:

     ```
     wt switch --create <branch> [--base <base>] -x <agent> -- <prompt>
     wt switch <branch> -x <agent> -- <prompt>          # existing branch/worktree
     ```

     *Superseded: no `-x`, no `--keep-open`; the tab runs a `sh` wrapper around
     `wt switch --no-cd --format=json` — see “Superseded (owner decisions after
     this design)” above.*

   - asks the app to show that session and tab.

### Why `wt switch -x`

*Superseded: see “Superseded (owner decisions after this design)” above — the
wrapper replaces `-x`, and there is no kept-open pane.*

`--execute` runs the agent as the worktree's program: worktrunk switches, runs
its hooks in the tab where their output stays visible, and starts the agent in
the worktree. No `cd` of our own, no dependence on the login shell's worktrunk
integration, and the "tab first, then switch" ordering falls out exactly.

`--keep-open` keeps the pane (and the hook output above the agent) after the
agent exits.

### Project → session mapping

| Thing | Derived from | Value for pmm-iris |
|---|---|---|
| Project root | parent of `--git-common-dir` | `~/Projects/_pmm/pmm-iris` |
| Project name / session label | basename of project root | `pmm-iris` |
| Main worktree | `wt list` where `worktree.main` | `~/Projects/_pmm/pmm-iris/main` |
| Tab label | branch name as typed | `bug/58h` |

A project session that doesn't exist is created with one `main` tab, so the
user's "home tab" convention bootstraps itself for a repo never opened in Rex
before.

**The label is the only key.** The plugin never scans sessions' terminal
working directories to guess which one belongs to a project, and never renames
one. A session you made by hand for pmm-iris under some other name will not be
adopted — the convention is that a project's session is named after the
project, and the flow creates it that way.

### Bead filtering

`bd ready --json`, run with the **main worktree** as cwd (the project root is not
enough: in the worktrunk layout the root holds only `.git` and worktrees, and
`bd ready` there fails with "no beads database found" — `main/.beads/redirect`
is what resolves the DB). Fall back to the project root for a repo whose DB sits
at the root with no separate main worktree. Then drop:

- any issue whose id contains `.` — molecule steps have ids like
  `superpowers-workflow.explore` and no repo prefix;
- `issue_type` of `molecule` or `gate`;
- any issue carrying a `step:*` label.

Everything remaining is a real bead. Rows are `id` + title; the description
lives in the preview only.

### Branch-name defaults

`<prefix>/<short-id>` where `<short-id>` is the bead id after the project
prefix (`pmm-iris-58h` → `58h`) and `<prefix>` comes from `issue_type`:

| issue_type | prefix |
|---|---|
| bug | `bug` |
| feature | `feat` |
| task | `feat` |
| chore | `chore` |
| spike | `spike` |
| anything else | `feat` |

The default is a prefilled query the user edits, never a forced choice.

*Superseded: the default is offered in a typed prompt and a bare Enter accepts
it — see “Superseded (owner decisions after this design)” above.*

### Proven patterns to reuse (no longer on disk)

`rex-worktrunk` was retired and deleted before this design was written, so these
four patterns from it are recorded here rather than linked. They are known to
work in this Rex version:

1. **A key-bound action cannot wait for input**, so the action opens a float and
   returns immediately: `rex.session.new_layer{ bounds = …, focus = true,
   layout = { block = { flavor = "com.superlogical.terminal.shell", label = …,
   options = { command = <cmd table>, cwd = … } } } }`. The layer id is kept so
   a second press replaces the first picker.
2. **The picker hands back with `rex do <action> k=v …`** from inside the float;
   that CLI call is where all Rex API work happens.
3. **Selecting a session has two paths.** From a key or palette origin the app
   ran the action, so `rex.client.queue("session.select", { session_id = … })`
   is accepted. From the CLI hand-back it is not: iterate
   `rex.call("client.list", { kinds = { "app" } })` and call
   `rex.call("client.perform", { client_id = …, action = "session.select",
   args = { session_id = … }, origin = … })`. Requires Remote Control.
4. **Finding a terminal's directory**: `rex.block.call("com.superlogical.terminal",
   "process", { block_id = … })` and read `foreground.cwd`, then `child.cwd`;
   `nil` means refuse rather than guess.

Shell tests: keep the pattern of a script mode that prints candidates and exits
(`new-work.sh --list-beads`, `--dry-run`) so the filter and branch-default
functions are testable without `fzf`.

## Configuration surface

```lua
require("rex-config").setup{
  agent       = "pi",                            -- program run in the new tab
  agent_args  = {},                              -- extra args before the prompt
  bead_prompt = "/brainstorming for bead {id}",  -- {id}, {title}, {branch}, {project}
  no_bead_prompt = "/brainstorming",             -- used when no bead was picked
  base        = "@",                             -- what --create branches from, resolved in the main worktree; false = worktrunk default
  bounds      = { 0.15, 0.1, 0.7, 0.8 },         -- picker float, fractions of the window
  script      = nil,                             -- override new-work.sh's path
}
rex.bind("ctrl+space>n", "work_new")
```

Actions defined: `work_new` (enter the flow) and `work_new_go` (the hand-back,
usable from the CLI for tests and for scripting).

## Edge cases and failure behaviour

- **Not a git repository** → picker never opens; an error names the directory.
- **No beads database** → the flow refuses. The picker never opens; an error
  names the directory and says beads is required. Brainstorming does not work
  without beads, so a branch-with-agent run that skipped the bead would produce
  an agent with nothing to work on.
- **`wt`, `fzf`, or `jq` missing** → the float says which one and waits for a
  keypress, rather than vanishing.
- **Branch already has a worktree and a tab** → select that tab; change nothing.
- **Branch has a worktree but no tab** → create the tab and switch without
  `--create`. No second worktree.
- **`wt switch` fails** (invalid ref name, dirty base, hook failure) → its output
  stays in the tab, the pane is kept open, and the bead is left claimed only if
  the tab was created (the user can unclaim).
- **The `rex do` hand-back fails after the tab is made** → the tab still works; the
  error names what failed.
- **Two presses in quick succession** → the second finds the tab by label and
  just selects it.

## Repo layout and install

The repository is cloned into Rex's configuration directory, the way
`rex-worktrunk` is:

```
~/.config/rex/rex-config/      # git clone of this repo
  init.lua                     # module: actions, config, project/session logic
  new-work.sh                  # the bead picker and the branch prompt; hands back
                               # with `rex do work_new_go --args <json>`
  test/                        # shell tests
  docs/superpowers/specs/      # this design
  README.md
```

Rex's own `~/.config/rex/init.lua` is edited by hand:

```lua
require("rex-config").setup{ agent = "pi" }
rex.bind("ctrl+space>n", "work_new")
```

The repo's `.beads/` directory travels with the clone and is inert there.

## What's left to the builder

- Exact `fzf` bindings, header text, and the look of the two prompts — including
  whether the bead and branch questions read as two steps or one screen.
  *Superseded: the bead question is the picker and the branch question a typed
  prompt — see “Superseded (owner decisions after this design)”.*
- How the Lua module quotes and assembles the `wt switch … -x … -- <prompt>`
  command for `rex window new` (argument boundaries matter; the prompt contains
  spaces and slashes). *Superseded: the tab's command is the `sh` wrapper above,
  with every value a positional parameter — see “Superseded (owner decisions
  after this design)”.*
- Whether the bead claim happens before or after the worktree exists, and how a
  failed switch is undone.
- Session-selection mechanics for the CLI hand-back (queue vs. `client.perform`),
  mirroring the two paths `rex-worktrunk` already proves out.
- Shell tests for the bead filter and branch-default functions, in the style of
  `rex-worktrunk/test/list_test.sh`, using `--list-beads` / `--dry-run` modes so
  no `fzf` is needed.
- The README.
