# rex-config

A Rex plugin for starting new work from a bead with one keystroke.

`ctrl+space>n` opens one screen: the ready beads, with a row pinned on top for
writing the prompt yourself, and a header that shows the project, the agent, the
branch and the base the branch is created from. Accept what the header shows and
Rex opens a tab for that branch in the project's own session, claims the bead,
creates the worktree with [worktrunk](https://worktrunk.dev), and starts your
agent inside it already working on the bead.

```
ctrl+space>n  →  one screen: a bead, or a prompt you write, with the agent,
                 the branch and the base in the header
              →  a tab, a worktree, a claimed bead, and an agent on it
```

## What it does

1. `ctrl+space>n` runs the action `work_new`. It reads the focused terminal's
   directory, works out which project that is, and refuses (naming the reason)
   if the directory is not in a git repository or the repository has no beads
   database.
2. Otherwise a floating picker opens, running `new-work.sh`, and everything is
   answered on one screen:

   ```
   ✎  write a prompt instead
   pmm-iris-a4l  Flaky hook test started failing
   pmm-iris-58h  Add a --dry-run flag

    pmm-iris · agent: pi · branch: bug/58h · base: origin/main
   ctrl-a agent  ctrl-b branch  ctrl-r base  ctrl-n blank  enter start  esc no bead
   ```

   The header is the state the tab will start from — the project, the agent, the
   branch and the base a new branch is created from — and a key repaints it in
   place. The list, the text typed at the prompt and every answer a key did not
   touch stay as they were; the cursor starts on the bead the list leads with —
   the prompt row when there is no bead — so a bare `enter` takes it.

   | Key | What it does |
   |---|---|
   | `ctrl-a` | the next agent, then `none`, then round again |
   | `ctrl-b` | type the branch, in a field opened on the one the header shows |
   | `ctrl-r` | the next base in the short cycle |
   | `ctrl-n` | **blank**: an agent, and nothing said to it |
   | `enter` | start with what the screen shows |
   | `esc` | no bead: the configured `no_bead_prompt` says what the flow is |

   Five answers are expressible: a bead, the `✎` row's field, text typed at the
   prompt that matches no row, `ctrl-n`'s blank, and `esc`'s no bead at all.
   Picking a bead sends `/brainstorming for bead <id>`; the `✎` row opens a field
   for text that would be awkward to type on one line; `ctrl-n` sends no prompt
   word at all, so the agent starts bare. A preview of the highlighted bead is
   below the list.

   The branch the header shows is the name the leading bead derives —
   `<prefix>/<short-id>`, e.g. `bug/58h` for `pmm-iris-58h` — so a bare `enter`
   creates exactly that; a bead picked further down the list derives its own name
   at the hand-back, and `ctrl-b` types one by hand. A bead-less answer — typed
   text, or the `✎` row — has no bead to take a name from, so the screen asks for
   one after it closes, in a field opened on whatever the header held; `enter`
   there keeps that name, and `esc` cancels the pick. Typing the name of an
   existing branch or worktree switches to it instead of creating anything;
   worktrunk's own shortcuts — `^` the default branch, `-` the previous worktree,
   `@` the current one, `pr:<n>` / `mr:<n>` a pull or merge request's branch —
   switch too, with no branch created, and the new tab is labelled with what you
   typed.

   `ctrl-a`'s `none` starts no agent at all: the tab is still made, the worktree
   still created and the bead still claimed, and the pane is a login shell in
   that worktree — with the prompt printed above it, so nothing you typed
   disappears.
3. The picker hands its answer back to the action `work_new_go`, which:
   - finds the project's session by label, creating it with a `main` tab in the
     main worktree when it is not there yet;
   - selects the tab if one is already labelled with that branch — no new tab,
     no second claim, no second worktree;
   - otherwise claims the bead (`bd update <id> --claim`, run in the main
     worktree) and creates the tab, labelled with the branch, in the main
     worktree, running a small shell wrapper:

     ```
     GIT_TERMINAL_PROMPT=0                                              # before anything else
     git fetch --quiet <remote>                                         # creating from a remote base
     wt switch --create <branch> --base <base> --no-cd --format=json    # or
     wt switch <branch> --no-cd --format=json                           # existing
     cd <the worktree that switch reported> && <agent> <prompt>
     exec "$SHELL" -l                                                   # the shell the agent exits to
     ```

     Every value reaches that wrapper as a positional parameter, so no branch,
     prompt or agent name is ever parsed as shell text. A blank answer sends no
     prompt parameter at all, and a prompt whose first character is `-` travels
     with one leading space, so the agent reads a value rather than a flag. With
     no agent the `cd` goes straight to `exec "$SHELL" -l`, after printing the
     prompt above it.

   - and shows that session and tab in the app.

Rex answers a session's methods only on a connection attached to that session,
and the app is attached to the session it is showing, which is not necessarily
the project's. So the flow attaches to the project's session before it reads its
tabs or creates the new one, and stays attached — nothing detaches afterwards,
and attaching takes nothing away from the session you are looking at.

worktrunk owns the worktree: it creates it and runs its hooks in the tab, so the
tab ends up in the right directory without the plugin changing directory
itself. The plugin never runs `git worktree add`.

When the agent exits — quit, crash, or a brainstorming that finished — the tab
drops into your login shell in that worktree: worktrunk's hook output and the
agent's last lines stay readable above the prompt, and the tests the agent just
wrote can be run there. Exiting that shell closes the tab.

## The base

By default a new branch starts from a named ref, not from whatever this clone
last checked out. The screen opens its base field on the first of these that
exists — the same order orca uses:

1. the branch `refs/remotes/origin/HEAD` points at, as `origin/main`;
2. `origin/main`; 3. `origin/master`; 4. `main`; 5. `master`;

and on `@` — HEAD, the plugin's old behaviour — when the clone has none of them.
`ctrl-r` cycles a short list from there: that opening answer, then `@`, then
`main` and `master` where this clone has them, deduplicated and with anything
that does not resolve dropped.

The tab is what fetches, and only when a branch is being created from a ref that
lives on a remote: that ref's own remote is fetched first (`upstream`, not
`origin`, if that is where it lives), with a 30-second cap when `timeout` or
`gtimeout` is installed. `@`, a local branch and worktrunk's default carry no
remote and cost no fetch, and it is the ref record — not a slash in the name —
that says where a ref lives, so a local `feat/x` is never fetched. Nothing in the
picker touches the network: a fetch behind the float could hang on a credential
prompt nobody can see. `GIT_TERMINAL_PROMPT=0` makes the tab's fetch fail
instead of asking.

A failed fetch does not cost the work. One line on the pane says the branch
starts from the base as it is, and the switch runs from that last-known position
anyway.

Two answers are not refs. `base = false` opens the field on `wt default` — no
`--base` word at all, and worktrunk chooses — and `@` is HEAD, which is always in
the cycle.

## Requirements

On the login shell's `PATH` (Rex actions run with a minimal `PATH`, so these are
looked up through your shell):

| Tool | Why |
|---|---|
| `wt` | worktrunk, for switching, creating, and naming the worktree's path |
| `jq` | the picker's JSON hand-back, the tab's worktree path, and bead filtering |
| `fzf` | the one screen: the ready list, the preview, the typed prompt and the keys (tested against 0.74.5) |
| `gum` | every field the screen opens: the `✎` row's, `ctrl-b`'s and the bead-less branch field (tested against 2.0.2) |
| `bd` | beads, for `bd ready` and claiming the picked bead |
| your agent | default `pi`; anything that takes a prompt argument works |
| `bat` | optional, for the bead preview |

`git` and `bash` are the exceptions to that: they run under Rex's own `PATH` —
the picker is started by its `#!/usr/bin/env bash` shebang — so they only need
to be where Rex can find them.

| Tool | Why |
|---|---|
| `git` | project resolution, branch-name checks, the branch candidate list and the base cycle |
| `bash` | `new-work.sh` is a bash script (`pipefail`, process substitution) |

Also needed:

- **beads in the project.** Beads is a hard requirement: a repository with no
  beads database is refused rather than run without one, because the whole flow
  is bead-driven.
- **Rex Remote Control** (Rex → Settings → Rex Server) for the picker's
  hand-back, which switches the app to the project's session from the command
  line. From a key or the palette the plugin queues the switch to the client
  instead and this is not needed.

## Install

Clone the repository into Rex's configuration directory, next to `init.lua`:

```bash
git clone <this repo> ~/.config/rex/rex-config
```

Then, in `~/.config/rex/init.lua`:

```lua
require("rex-config").setup{}
rex.bind("ctrl+space>n", "work_new")
```

Reload the configuration:

```bash
rex config check
rex config reload
```

The plugin finds `new-work.sh` beside its own `init.lua`, so there is nothing
else to point at.

## Options

Every option is optional; these are the defaults.

```lua
require("rex-config").setup{
  agent = "pi",                            -- agent started in the new tab
  agents = nil,                            -- the agent cycle's list; nil = { agent }
  agent_args = {},                         -- extra arguments before the prompt
  bead_prompt = "/brainstorming for bead {id}",  -- {id}, {title}, {branch}, {project}
  no_bead_prompt = "/brainstorming",       -- used when the flow ran without a bead
  base = nil,                              -- the base cycle's first entry: nil =
                                           -- the clone's own default, resolved;
                                           -- a string opens on that ref;
                                           -- false opens on "wt default"
  bounds = { 0.15, 0.1, 0.7, 0.8 },        -- picker float, fractions of the window
  script = "/…/rex-config/new-work.sh",  -- new-work.sh beside init.lua (the default)
}
```

`script` is derived from where the module itself lives, so a clone beside Rex's
`init.lua` needs nothing here; set it only to run some other copy.

`agent`, `agent_args` and the prompts are what the new tab's command line is
built from, so `agent = "claude"` starts Claude instead of `pi` without any
other change. An unknown option is ignored with a warning rather than silently
kept.

`agents` is the list `ctrl-a` cycles, in order, and the picker ends the cycle
with `none` — the answer that starts no agent. That answer is not something to
configure, so `agents` has no way to say it and an empty `agent` is refused.
Leave it unset to cycle between the one agent you configured and `none`, or set
it to offer a choice; `agent_args` travel to whichever agent is started.

The agent the screen opens on is the one you used last. The picker remembers it
in `$XDG_STATE_HOME/rex-config/state` (`~/.local/state/rex-config/state` when
`XDG_STATE_HOME` is unset), a `key=value` file holding one `agent=<name>` line,
so the second launch of the same kind of work is a bare `enter`. The file is
read tolerantly: missing, unreadable, corrupt, and a name `agents` no longer
offers all fall back to the first name on the list, and a write that fails is
never a reason to fail a launch. It is written before the hand-back, so a
launch Rex refuses still counts as the agent you chose. Nothing else is
remembered — not the base, not the branch.

`base` is the cycle's first entry and nothing more. A string opens the field on
that ref, so `base = "@"` keeps the old local-HEAD answer within reach; `false`
opens it on `wt default` and sends no `--base` word at all; leaving it unset
follows the chain in [The base](#the-base). `ctrl-r` still cycles off whatever
the field opens on, so the option sets the starting answer rather than pinning
it. It is consulted again only for a hand-run `rex do work_new_go` that says
nothing about the base.

## The convention

A **project** is a repository. Rex has one session per project, labelled with the
project's name (`pmm-iris`), and inside it one tab per worktree: the user's
`main` tab in the main worktree, and one tab per branch in flight, labelled with
the branch name exactly as typed (`bug/58h` — or `@`, `^`, `-`, `pr:123` when a
worktrunk shortcut was typed).

- The session is found by its **label only**. A session called `pmm-iris-2` is
  not the project's, and nothing scans terminal directories or renames a session
  to guess.
- The main worktree is never a target: every tab is created in the project's
  session with the main worktree as its starting directory, and `bd` is always
  run there, which is where the database is reachable.
- Switching the key twice for the same branch selects the tab that is already
  there. One tab, one worktree, one claim.

## Failure behaviour

- Not a git repository, or no beads database: the picker never opens; the error
  names the directory.
- A tool missing from the login shell's `PATH`: the picker float says which one
  and waits for a keypress instead of vanishing.
- `esc` at the screen means "no bead" rather than "nothing at all": the flow goes
  on with the configured `no_bead_prompt`. Cancelling a field is not cancelling
  the pick either — `ctrl-c` at `ctrl-b` leaves the branch as it was and the
  screen carries on. Only a field holding an answer the pick cannot do without
  cancels it: the `✎` row's prompt field, and the bead-less branch field that
  asks for the one answer still missing after a typed prompt. Cancelling those
  starts nothing, as the branch question always did.
- The bead cannot be claimed: the flow stops before a tab is made, naming what
  `bd` said, so an agent never starts on a bead that is not its own.
- The fetch fails (offline, a remote that is gone, a credential prompt): one line
  says the branch starts from the base as it is, and the work starts anyway. A
  fetch is a freshening, not a precondition.
- `wt switch` fails (bad ref, dirty base, a failing hook): its output stays in
  the tab, the agent is not started — it never starts in the wrong directory —
  and you are left in a login shell in the main worktree. The bead stays
  claimed, since the tab is there too; `bd unclaim <id>` releases it.
- `jq` is missing, or worktrunk reports no worktree path: the same, with a
  one-line error naming the branch on the tab.
- The tab was made but the app could not be switched to it: the error says the
  tab was created and names what failed. The tab is still there.
- The tab could not be made at all: the error names what Rex said, and — since
  the bead was already claimed before the tab — how to hand the claim back
  (`bd unclaim <id>`).

## Layout

```
~/.config/rex/rex-config/
  init.lua        the module: options, the two actions, project and session logic
  new-work.sh     the one screen behind ctrl+space>n; hands back to work_new_go
  test/           lua and bash tests, run with `bash test/run.sh`
  docs/           the design this was built from
```

## Tests

```bash
bash test/run.sh
```

The Lua tests stub the `rex` global, so they need no Rex server, and the shell
tests read saved tool output instead of asking `bd`, `fzf`, `wt` or the
repository, drive the screen's own subcommands (`composer header`, `cycle-agent`,
`cycle-base`, `fzf-answer`) through pipes, and pipe the branch answer instead of
typing it at the prompt.
