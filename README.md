# rex-config

A Rex plugin for starting new work from a bead with one keystroke.

`ctrl+space>n` opens a picker: choose one of the project's ready beads, accept or
edit the branch name it suggests, and Rex opens a tab for that branch in the
project's own session, claims the bead, creates the worktree with
[worktrunk](https://worktrunk.dev), and starts your agent inside it already
brainstorming the bead.

```
ctrl+space>n  →  pick a bead  →  edit the branch name  →  a tab, a worktree,
                                                          a claimed bead,
                                                          and an agent on it
```

## What it does

1. `ctrl+space>n` runs the action `work_new`. It reads the focused terminal's
   directory, works out which project that is, and refuses (naming the reason)
   if the directory is not in a git repository or the repository has no beads
   database.
2. Otherwise a floating picker opens, running `new-work.sh`. It asks two
   questions: which ready bead (with a preview of its long description), then
   which branch — typed at a prompt that offers `<prefix>/<short-id>`, e.g.
   `bug/58h` for `pmm-iris-58h`, so a bare Enter accepts it. Typing the name of
   an existing branch or worktree switches to it instead of creating anything.
3. The picker hands its answer back to the action `work_new_go`, which:
   - finds the project's session by label, creating it with a `main` tab in the
     main worktree when it is not there yet;
   - selects the tab if one is already labelled with that branch — no new tab,
     no second claim, no second worktree;
   - otherwise claims the bead (`bd update <id> --claim`, run in the main
     worktree) and creates the tab, labelled with the branch, in the main
     worktree, running a small shell wrapper:

     ```
     wt switch --create <branch> --base <base> --no-cd --format=json   # or
     wt switch <branch> --no-cd --format=json                          # existing
     cd <the worktree that switch reported> && <agent> <prompt>
     exec "$SHELL" -l                  # the shell the agent exits to
     ```

     Every value reaches that wrapper as a positional parameter, so no branch,
     prompt or agent name is ever parsed as shell text.

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

## Requirements

On the login shell's `PATH` (Rex actions run with a minimal `PATH`, so these are
looked up through your shell):

| Tool | Why |
|---|---|
| `wt` | worktrunk, for switching, creating, and naming the worktree's path |
| `jq` | the picker's JSON hand-back, the tab's worktree path, and bead filtering |
| `fzf` | the bead picker and its preview pane |
| `bd` | beads, for `bd ready` and claiming the picked bead |
| your agent | default `pi`; anything that takes a prompt argument works |
| `bat` | optional, for the bead preview |

`git` and `bash` are the exceptions to that: they run under Rex's own `PATH` —
the picker is started by its `#!/usr/bin/env bash` shebang — so they only need
to be where Rex can find them.

| Tool | Why |
|---|---|
| `git` | project resolution, branch-name checks and the branch candidate list |
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
  agent = "pi",                            -- program started in the new tab
  agent_args = {},                         -- extra arguments before the prompt
  bead_prompt = "/brainstorming for bead {id}",  -- {id}, {title}, {branch}, {project}
  no_bead_prompt = "/brainstorming",       -- used when the flow ran without a bead
  base = "@",                              -- what --create branches from ("@" = the
                                           -- main worktree); false lets worktrunk choose
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

## The convention

A **project** is a repository. Rex has one session per project, labelled with the
project's name (`pmm-iris`), and inside it one tab per worktree: the user's
`main` tab in the main worktree, and one tab per branch in flight, labelled with
the branch name exactly as typed (`bug/58h`).

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
- The bead cannot be claimed: the flow stops before a tab is made, naming what
  `bd` said, so an agent never starts on a bead that is not its own.
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
  new-work.sh     the bead picker and the branch prompt; hands back to work_new_go
  test/           lua and bash tests, run with `bash test/run.sh`
  docs/           the design this was built from
```

## Tests

```bash
bash test/run.sh
```

The Lua tests stub the `rex` global, so they need no Rex server, and the shell
tests read saved tool output instead of asking `bd` or `fzf`, and pipe the
branch answer instead of typing it at the prompt.
