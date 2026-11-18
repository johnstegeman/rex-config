# rex-config

A Rex plugin for starting new work from a bead with one keystroke.

`ctrl+space>n` asks six questions in the command palette — the bead, the branch,
the worktree, the base, the agent and the prompt — and then opens a tab for that
branch in the project's own session, claims the bead, creates the worktree with
[worktrunk](https://worktrunk.dev), and starts your agent inside it already
working on the bead.

```
ctrl+space>n  →  bead · branch · worktree · base · agent · prompt
              →  a tab, a worktree, a claimed bead, and an agent on it
```

## What it does

1. `ctrl+space>n` runs the action `work_new`. It reads the focused terminal's
   directory, works out which project that is, and refuses (naming the reason)
   if the directory is not in a git repository or the repository has no beads
   database.
2. Otherwise it asks, in order:

   | # | Question | How | Opens on |
   |---|---|---|---|
   | a | **Bead** | `rex.ui.pick` over the ready beads, plus a last row *No bead: a branch and an agent only* | the whole list |
   | b | **Branch** | `rex.ui.input` | the bead's name — `bug/a4l` for `pmm-iris-a4l` — or `feat/<adjective>-<noun>` with no bead |
   | c | **Worktree** | `rex.ui.input`, a name and never a path | the branch's directory name, `bug-a4l` |
   | d | **Base** | `rex.ui.pick` over the base chain, the clone's own answer first | that first row |
   | e | **Agent** | `rex.ui.pick` over `agents`, plus a *(none)* row | filtered to the agent the last launch used |
   | f | **Prompt** | `rex.ui.input` | `bead_prompt` for a bead, `no_bead_prompt` (empty) for none |

   Each one is answered with `enter`, and leaving a field as it opened is the
   usual answer. Cancelling any of them starts nothing and says nothing; a
   question that could not be put to you at all — the app went away, the prompt
   timed out, another one is already up — is refused with the reason named.

   A bead's row carries its title, its id and type underneath, its priority as
   `P<n>`, and an icon for the kind of work: a package for an epic, a star for a
   feature, a branch for a bug, a gear for a chore, code for a spike, a tag for
   a decision, a document for anything else. With nothing ready the pick holds
   that one *No bead* row and the title says `no ready beads in <project>`.

   A branch name is checked with `git check-ref-format --branch` before anything
   is made, and a name git refuses stops the flow with git's own reason: there
   is no way to re-ask inside a `rex.ui` prompt, and starting over is cheap.

   The worktree is a name, so blank means worktrunk's own worktree-path template
   names the directory. A name travels to the tab as `--path ../<name>` — a
   sibling of the main worktree, which is what the template builds anyway — and
   a name holding a `/` is refused, because that is a path.

   The agent row *(none)* starts no agent at all: the tab is still made, the
   worktree still created and the bead still claimed, and the pane is a login
   shell in that worktree. The prompt you answered is printed above it, so
   nothing you wrote disappears.

   A cleared prompt field is an answer, not an empty question: the agent starts
   and is told nothing, and no word is appended to its command line.
3. Then, in the project's own session:
   - it finds the session by label, creating it with a `main` tab in the main
     worktree when it is not there yet;
   - selects the tab if one is already labelled with that branch — no new tab,
     no second claim, no second worktree;
   - otherwise claims the bead (`bd update <id> --claim`, run in the main
     worktree) and creates the tab, labelled with the branch, in the main
     worktree, running a small shell wrapper:

     ```
     GIT_TERMINAL_PROMPT=0                                     # before anything else
     git fetch --quiet <remote>                                # when the base lives on a remote
     wt switch --create <branch> --base <base> --path <path>   # --base and --path only when given
     cd <the worktree that switch reported> && <agent> <prompt>
     exec "$SHELL" -l                                          # the shell the agent exits to
     ```

     Every value reaches that wrapper as a positional parameter, so no branch,
     base, path, prompt or agent name is ever parsed as shell text. A blank
     answer sends no prompt parameter at all, and a prompt whose first character
     is `-` travels with one leading space, so the agent reads a value rather
     than a flag. With no agent the `cd` goes straight to `exec "$SHELL" -l`,
     after printing the prompt above it.

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

### Running one without the questions

Every answer is also an optional argument, so the action asks only for what it
was not given. From a terminal inside the project:

```bash
rex do work_new bead=pmm-iris-608            # asks the other five
rex do work_new bead= branch=feat/x worktree= base=@ agent=pi prompt=
```

`bead=` with nothing after it is the *No bead* row, `agent=` starts none,
`worktree=` lets worktrunk name the directory, and `prompt=` says nothing to the
agent that was started.

## The base

By default a new branch starts from a named ref, not from whatever this clone
last checked out. The base question opens on the first of these that exists —
the same order orca uses:

1. the branch `refs/remotes/origin/HEAD` points at, as `origin/main`;
2. `origin/main`;
3. `origin/master`;
4. `main`;
5. `master`;

and on `@` — HEAD, the plugin's old behaviour — when the clone has none of them.
The rows after that opening answer are `@`, then `main` and `master` where this
clone has them, deduplicated. The opening answer is never dropped, even when the
ref does not resolve: a base you name in configuration is the row that opens the
question, and the tab then starts from it exactly as it is.

The tab is what fetches, and only when a branch is created from a ref that lives
on a remote: that ref's own remote is fetched first (`upstream`, not `origin`,
if that is where it lives), with a 30-second cap when `timeout` or `gtimeout` is
installed. `@`, a local branch and worktrunk's default carry no remote and cost
no fetch, and it is the ref record — not a slash in the name — that says where a
ref lives, so a local `feat/x` is never fetched. Nothing in the questions
touches the network: a fetch behind a prompt could hang on a credential prompt
nobody can see. `GIT_TERMINAL_PROMPT=0` makes the tab's fetch fail instead of
asking.

A failed fetch does not cost the work. One line on the pane says the branch
starts from the base as it is, and the switch runs from that last-known position
anyway.

Two answers are not refs. `base = false` opens the question on `worktrunk's
default` — no `--base` word at all, and worktrunk chooses — and `@` is HEAD,
which is always one of the rows.

## Requirements

On the login shell's `PATH` (Rex actions run with a minimal `PATH`, so these are
looked up through your shell):

| Tool | Why |
|---|---|
| `wt` | worktrunk, for creating the worktree and naming its path — **0.82 or later** |
| `jq` | the bead rows, and the path out of the tab's `wt switch` reply |
| `bd` | beads, for `bd ready` and claiming the picked bead |
| your agent | default `pi`; anything that takes a prompt argument works |

`git` and `bash` are the exceptions to that: they run under Rex's own `PATH` —
`git` for project resolution and the branch-name check, `bash` because
`new-work.sh` is a bash script (`pipefail`, process substitution).

**worktrunk 0.82 or later.** The worktree question hands a name to `wt switch
--path`, which worktrunk marks `[experimental]`: it may change or go away, and a
release without it refuses the flow's worktree name with a message rather than
ignoring it. Blank the worktree field and the older behaviour is what you get —
worktrunk's own `worktree-path` template.

Also needed:

- **beads in the project.** Beads is a hard requirement: a repository with no
  beads database is refused rather than run without one, because the whole flow
  is bead-driven.
- **Rex 0.1.0-preview.21 or later** (control API revision 18), for `rex.ui.input`
  and `rex.ui.pick`. An older server refuses the flow with a message instead of
  asking nothing.
- **Rex Remote Control** (Rex → Settings → Rex Server) for a `rex do work_new`
  run, which switches the app to the project's session from the command line.
  From a key or the palette the plugin queues the switch to the client instead
  and this is not needed.

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
else to point at. `ctrl+space>n` has to be bound to the action `work_new`, not
to a function: a prompt only pauses an action's own run.

## Options

Every option is optional; these are the defaults.

```lua
require("rex-config").setup{
  agent = "pi",                            -- agent started in the new tab
  agents = nil,                            -- the agent question's list; nil = { agent }
  agent_args = {},                         -- extra arguments before the prompt
  bead_prompt = "/brainstorming for bead {id}",  -- {id}, {title}, {branch}, {project}
  no_bead_prompt = "",                     -- the prompt question, with no bead
  base = nil,                              -- the base question's first row: nil =
                                           -- the clone's own default, resolved;
                                           -- a string opens on that ref;
                                           -- false opens on worktrunk's default
  script = "/…/rex-config/new-work.sh",  -- new-work.sh beside init.lua (the default)
}
```

`script` is derived from where the module itself lives, so a clone beside Rex's
`init.lua` needs nothing here; set it only to run some other copy.

`agent`, `agent_args` and the prompts are what the new tab's command line is
built from, so `agent = "claude"` starts Claude instead of `pi` without any
other change. An unknown option is ignored with a warning rather than silently
kept — `bounds`, the old float's geometry, is one of those now: there is no
float to place.

`agents` is the list the agent question offers, in order. The question always
adds `(none)` after it — the answer that starts no agent — so that answer is not
something to configure, and an empty `agent` is refused. Leave `agents` unset to
be offered the one agent you configured and *none*, or set it to offer a choice;
`agent_args` travel to whichever agent is started.

The agent question opens on the one you used last. The flow remembers it in
`$XDG_STATE_HOME/rex-config/state` (`~/.local/state/rex-config/state` when
`XDG_STATE_HOME` is unset), a `key=value` file holding one `agent=<name>` line.
A single-choice pick cannot preselect a row, so the remembered name arrives as
the list's filter: the list narrows to that one row and `enter` takes it, which
is what makes the second launch of the same kind of work a bare `enter`. The
*(none)* answer is remembered too, as an empty value (`agent=`), so a launch
that started no agent is not followed by a question that offers the first name
again. The file is read tolerantly: missing or unreadable, no `agent=` line at
all, a corrupt line, and a name `agents` no longer offers all fall back to the
whole list, and a write that fails is never a reason to fail a launch. It is
written before the tab is made, so a launch that fails still counts as the agent
you chose. Nothing else is remembered — not the base, not the branch.

`base` is the base question's first row and nothing more. A string opens the
question on that ref, so `base = "@"` keeps the old local-HEAD answer within
reach; `false` opens it on `worktrunk's default` and sends no `--base` word at
all; leaving it unset follows the chain in [The base](#the-base). The other rows
are still there to pick, so the option sets the opening answer rather than
pinning it.

## The convention

A **project** is a repository. Rex has one session per project, labelled with the
project's name (`pmm-iris`), and inside it one tab per worktree: the user's
`main` tab in the main worktree, and one tab per branch in flight, labelled with
the branch name exactly as it was answered (`bug/58h`).

- The session is found by its **label only**. A session called `pmm-iris-2` is
  not the project's, and nothing scans terminal directories or renames a session
  to guess.
- The main worktree is never a target: every tab is created in the project's
  session with the main worktree as its starting directory, and `bd` is always
  run there, which is where the database is reachable.
- Every branch this flow starts is a new one. There is no "switch to a branch
  that already exists" answer, and no worktrunk shortcut typed at a prompt.
- Pressing the key twice for the same branch selects the tab that is already
  there. One tab, one worktree, one claim.

## Failure behaviour

- Not a git repository, or no beads database: no question is asked; the error
  names the directory.
- Cancelling a question (`esc`): nothing is made and nothing is logged. Every
  question cancels the whole flow, because there is no half-answered launch to
  fall back on.
- A question that cannot be asked: the error names the question and the reason
  (`timeout`, `busy`, `no_client`, `unsupported`, `failed`), so a prompt that
  was broadcast to an app that is not there reads differently from one that
  timed out.
- A branch name git refuses: the error carries `git check-ref-format`'s own
  words, and nothing is created. Start the flow again with a name you like.
- A worktree name holding a `/`, or this `wt` without `--path`: refused by name,
  with what to do about it, rather than a worktree somewhere unexpected.
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
  init.lua        the module: options, the action, the six questions, the session
  new-work.sh     the four lookups it runs through your login shell
  test/           lua and bash tests, run with `bash test/run.sh`
  docs/           the designs this was built from
```

`new-work.sh` is not a picker any more: it prints the ready beads' rows, a
bead's derived branch name, a bead's text, and the base chain, and `init.lua`
asks the questions. `beads`, `branch-default`, `bases` and `preview` are the
four verbs, and the listings take saved tool output (`--bd-json`,
`--base-refs`), so they can be run by hand against a fixture.

## Tests

```bash
bash test/run.sh
```

The Lua tests stub the `rex` global — including `rex.ui`, whose answers a test
scripts one question at a time — so they need no Rex server: `action_test.lua`
walks the whole flow, from a cancelled question to a tab that could not be made,
and `pure_test.lua` pins the helpers and the tab's argument contract. The shell
tests read saved tool output instead of asking `bd`, `wt` or the repository, and
`wrapper_test.sh` runs the tab's own wrapper for real under `sh` and `dash`, with
stand-ins for `wt`, `git` and the agent.

The one thing no test can reach is the prompts themselves: they are drawn by the
app, and `rex do -e` cannot drive them (a prompt outside an action's run is
reported as `unsupported`). `rex do work_new` from a project session, answering
the six, is the check that covers it.
