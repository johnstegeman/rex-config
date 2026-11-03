# rex-config

A Rex plugin for starting new work from a bead with one keystroke.

`ctrl+space>n` opens one screen: the ready beads, with a row pinned on top for
writing the prompt yourself, and a header that shows the project, the agent, the
branch and the base the branch is created from. Accept what the header shows and
Rex opens a tab for that branch in the project's own session, claims the bead,
makes the worktree, and starts your agent inside it already working on the bead.

The worktree is a **jj colocated workspace**, made by `gws`: the git worktree and
the jj workspace of the same directory repo, with a branch attached and the
project's post-start hooks run. rex-config knows none of that — it hands `gws` a
branch, and for a new one the revision to make it from, and reads the new
workspace's path back out of a file.

```
ctrl+space>n  →  one screen: a bead, or a prompt you write, with the agent,
                 the branch and the base in the header
              →  a tab, a jj workspace, a claimed bead, and an agent on it
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

   pmm-iris · agent: pi · branch: bug/a4l · base: main@origin
   ctrl-a agent  ctrl-b branch  ctrl-r base  ctrl-n blank  enter start  esc no bead
   ```

   The header is the state the tab will start from — the project, the agent, the
   branch and the base a new branch is created from — and a key repaints it in
   place. The list, the text typed at the prompt and every answer a key did not
   touch stay as they were; the cursor starts on the bead the list leads with —
   the prompt row when there is no bead — so a bare `enter` takes it. One field
   is only ever seeded: the branch is the leading bead's name and moving the
   cursor does not recompute it, so a bead picked lower down hands back the name
   that bead derives instead (below).

   The base is the create answer's, and while the screen is up the mode is not
   knowable, so it is resolved for every pick that opens one: it shows, and
   `ctrl-r` cycles it, even when the branch turns out to have a worktree
   already — and then it is not sent, because a switch and an attach start
   nothing from a revision. A pick that opens no screen — a scripted one, or
   `--dry-run` — resolves the cycle only for a create.

   | Key | What it does |
   |---|---|
   | `ctrl-a` | the next agent, then `none`, then round again |
   | `ctrl-b` | type the branch, in a field opened on the one the header shows |
   | `ctrl-r` | the next base in the short cycle |
   | `ctrl-n` | **blank**: the header's branch, and an agent with nothing said to it |
   | `enter` | start with what the screen shows |
   | `esc` | no bead: the configured `no_bead_prompt` says what the flow is |

   Five answers are expressible: a bead, the `✎` row's field, text typed at the
   prompt that matches no row, `ctrl-n`'s blank, and `esc`'s no bead at all.
   Picking a bead sends `/brainstorming for bead <id>`; the `✎` row opens a field
   for text that would be awkward to type on one line; `ctrl-n` sends no prompt
   word at all, so the agent starts bare in the branch the header was showing,
   and no field is opened to ask for one. A preview of the highlighted bead is
   below the list.

   The branch the header shows is the name the leading bead derives —
   `<prefix>/<short-id>`, e.g. `bug/a4l` for `pmm-iris-a4l` — so a bare `enter`
   creates exactly that. A bead picked further down the list derives its own name
   at the hand-back, and a branch typed at `ctrl-b` wins over both: the name you
   typed is the one the tab is given, and it is not asked for again. A bead-less
   answer — typed text, the `✎` row, or `esc`'s no bead — has no bead to take a
   name from, so the screen asks for one after it closes, in a field that opens
   empty: the header's branch belongs to the bead the list leads with, which is
   not the bead you picked, so it is not offered. A name typed there is the
   branch; an empty answer cancels the pick. What that name means is decided
   from the two lists the screen has already read — the branches with a
   worktree, and the branches git knows — and it is one of three things: a
   branch with a worktree, **switch**, and worktrunk moves you there without
   anything being created; a local branch with no worktree, **attach**, and
   `gws` puts a jj workspace on the branch as it is, with no revision to start
   it from; neither, **create**, and `gws` makes the branch and the workspace,
   from the base. The new tab is labelled with what you typed.

   A name is checked before any tab is made — only a create can be refused for
   it — and `not a valid branch name` is said on the float, not in a tab.
   That takes worktrunk's old shortcuts with it: `^`, `-` and `pr:<n>` /
   `mr:<n>` are not branch names, and `@` is refused because it is the working
   copy, a jj revision. A pull or merge request's head is still reachable the
   manual way: fetch the branch, then pick its name, which makes it an attach.

   With no ready beads the list is the `✎` row alone and `no ready beads` is said
   on stderr. Nothing seeds the header's branch either, so a typed prompt is
   asked for one — and `ctrl-n`, which takes the branch the header shows, has
   nothing to create and ends the pick with `no branch given, nothing to start`.

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
     worktree, running a small fish wrapper:

     ```
     GIT_TERMINAL_PROMPT=0                               # before anything else
     wt switch <branch> --no-cd --format=json            # switch: the path is .path
     gws <branch> <base> --path-file <f>                 # create: the path is in <f>
     gws --attach <branch> --path-file <f>               # attach: the path is in <f>
     cd <the path that reply or that file named> && <agent> <prompt>
     exec "$SHELL" -l                                    # the shell the agent exits to
     ```

     Exactly one of the three middle lines runs: the mode is one word the
     picker decided, and the tab neither works it out again nor asks the
     repository a second time. Only a create is given a base; a switch and an
     attach name a branch that already exists.

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

`gws` owns the create and [worktrunk](https://worktrunk.dev) owns the switch.
`gws` runs `jj workspace add --colocate` from `main` — so the new workspace
inherits the full sparse pattern — attaches a git branch at its head, and then
runs the project's post-start hooks by hand, because jj and not wt made the
worktree.

When the agent exits — quit, crash, or a brainstorming that finished — the tab
drops into your login shell in that worktree: the hooks' output and the
agent's last lines stay readable above the prompt, and the tests the agent just
wrote can be run there. Exiting that shell closes the tab.

## The base

A new branch starts from one **jj revision**, not from whatever this clone last
checked out. Here that revision is `main@origin` — the remote's current state of
the default branch, rather than this machine's copy of it. `origin/main` was the
git spelling of the same thing; the `@remote` suffix says where a revision comes
from now, so there is no second field that could disagree with it.

The screen opens on `<default-branch>@origin`, with the default branch found the
way git finds it. When this clone names no `origin/HEAD`, it falls through to a
fixed name — and to the working copy when the bookmarks do not have either:

1. the branch `refs/remotes/origin/HEAD` points at, as `<that branch>@origin`;
2. `main@origin`, when the bookmarks render it;
3. `master@origin`, when the bookmarks render that one;
4. `@`, the working copy, which is always there.

The bookmarks are asked about those two fixed names and about nothing else, so
the opening answer survives even where no bookmark renders it: a clone whose
`origin/HEAD` is `develop` opens on `develop@origin` either way, and so does a
base you name in configuration. The revision is made in the tab, where `jj`
answers for it and a fetch has already had its chance.

`ctrl-r` cycles a short list from there: that opening answer, then `@`, then
`main` and `master`, offered only where the bookmarks say they exist.

The base travels with a create and nothing else. A switch and an attach name a
branch that already exists, so there is no revision to start one from.

The tab is what fetches, and `gws` is what does it: given a revision, it runs
`jj git fetch` before it makes the workspace, with a 30-second cap when `timeout`
or `gtimeout` is installed and unbounded otherwise. Nothing in the picker touches
the network: a fetch behind the float could hang on a prompt nobody can see.
`GIT_TERMINAL_PROMPT=0` is exported in the tab for the other program that
reaches a remote there — the `git` a project's post-start hooks run — so a hook
fails rather than waiting on a prompt nobody can answer.

A failed fetch does not cost the work: one line on the pane — `gws: could not
fetch; <branch> starts from <revision> as it is` — and the workspace is made from
the revision as it resolves locally.

One answer is not a revision at all: `base = false` opens the field on nothing
(the header reads `base: none`), and `gws` is given no revision, so the new
workspace sits on `main`'s working copy.

## Requirements

Creating a workspace is `gws`'s job, and `gws` is not a program on your `PATH`: it
is a fish function in `~/.config/fish/functions/gws.fish`, and it is the one
thing that knows how to make a jj colocated workspace. The tab's wrapper is a
fish script for that reason. Before the screen opens, the picker refuses a repo
that is not yet [ginit'd](#converting-a-repo-to-jj-workspaces), a machine without
`jj`, and a fish without `gws`: a claimed bead in a pane that could not create
anything is worse than a refusal.

On the login shell's `PATH` (Rex actions run with a minimal `PATH`, so these are
looked up through your shell):

| Tool | Why |
|---|---|
| `wt` | [worktrunk](https://worktrunk.dev), for switching to a worktree that already exists, and for the hooks a jj-made workspace needs |
| `jj` | the base cycle, and the workspace itself |
| `fish` | `gws` is a fish function, and the tab's wrapper is fish |
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
- **a ginit'd repo.** `gws` needs the layout `ginit` makes: a wrapper with
  `.jj/repo` as a directory **beside** its `main` worktree, because `gws` runs
  `jj workspace add` from `main` so the new workspace inherits its sparse
  patterns. A repo without one — including a clone `jj git init`ed where it
  stands, whose `.jj/repo` is inside the worktree rather than beside a `main` —
  is refused rather than given an ordinary git worktree. [Converting a repo to
  jj workspaces](#converting-a-repo-to-jj-workspaces) is how it gets one.
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
                                           -- a string opens on that revision;
                                           -- false opens on no revision at all
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
so the second launch of the same kind of work is a bare `enter`. `ctrl-a`'s
`none` is remembered too, as an empty value (`agent=`), so a pick that started
no agent is not followed by a screen that offers the first name again. The file
is read tolerantly: missing or unreadable, no `agent=` line at all, a corrupt
line, and a name `agents` no longer offers all fall back to the first name on
the list, and a write that fails is never a reason to fail a launch. It is
written before the hand-back, so a launch Rex refuses still counts as the agent
you chose. Nothing else is remembered — not the base, not the branch.

`base` is the cycle's first entry and nothing more. A string opens the field on
that revision, so `base = "@"` starts a create from the working copy; `false`
opens it on no revision at all and `gws` is given none; leaving it unset follows
the chain in [The base](#the-base). `ctrl-r` still cycles off whatever the field
opens on, so the option sets the starting answer rather than pinning it. It is
consulted again only for a hand-run `rex do work_new_go` that says nothing about
the base.

A hand-run now says the mode as a word — `rex do work_new_go project=… branch=…
worktree=create …` — because `create` is no longer a declared argument and this
Rex build rejects a named pair it does not know: `create=true` written as a
named pair is refused outright, while the same field inside an `--args` object
reaches the action whole and still means create.

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
- A created or attached workspace sits beside `main`, in the repo's wrapper
  directory — the one holding `.git` — named from the branch with its slashes
  flattened: `feat/pxp` → `feat-pxp`.

## Failure behaviour

Before the screen opens:

- Not a git repository, or no beads database: the picker never opens; the error
  names the directory.
- The repo is not ginit'd — no `.jj/repo` as a directory in the directory above
  the main worktree: the picker refuses in one line and names `ginit`, and no
  bead is claimed: `pick: /… is not ginit'd — gws needs a wrapper with .jj/repo
  as a directory beside the main worktree; run ginit first`.
- A tool the run cannot do without is missing — `fzf`, `gum`, `bd`, `wt`, `jq`,
  `jj`, or a fish with no `gws`: the float names the missing piece and waits for
  a keypress instead of vanishing (`jj not found on PATH — press any key`,
  `gws is not a fish function — add it to ~/.config/fish/functions — press any
  key`).

At the screen:

- `esc` at the screen means "no bead" rather than "nothing at all": the flow goes
  on with the configured `no_bead_prompt`. Cancelling a field is not cancelling
  the pick either — `ctrl-c` at `ctrl-b` leaves the branch as it was and the
  screen carries on. Only a field holding an answer the pick cannot do without
  cancels it: the `✎` row's prompt field, and the bead-less branch field that
  asks for the one answer still missing after a typed prompt. Cancelling those
  starts nothing.
- A name that is not a valid ref, for a create, is refused before any tab is
  made: `new-work.sh: not a valid branch name: <name>` on the float.
- The bead cannot be claimed: the flow stops before a tab is made, naming what
  `bd` said, so an agent never starts on a bead that is not its own.

In the tab:

- The fetch fails (offline, a remote that is gone, a credential prompt): `gws`
  says in one line that the branch starts from the base as it is, and the work
  starts anyway. A fetch is a freshening, not a precondition.
- `gws` fails — a revision jj cannot resolve, a directory that is already there,
  no `main` workspace: its own output stays in the tab, then
  `rex-config: gws <branch> failed (exit <status>); not starting <agent>`, and
  you are left in a login shell in the main worktree. The bead stays claimed,
  since the tab is there too; `bd unclaim <id>` releases it.
- `gws` succeeds but the path file holds no path, or cannot be read:
  `rex-config: could not read the worktree path of <branch> from the gws path
  file; not starting <agent>`, and the same login shell.
- `wt switch` fails (a bad ref, a dirty worktree, a failing hook):
  `rex-config: wt switch <branch> failed (exit <status>); not starting <agent>`,
  with its output above it, and the same login shell.
- `jq` is missing, or worktrunk's reply has no path in it:
  `rex-config: could not read the worktree path of <branch> from the switch
  reply (jq missing, or no path in it); not starting <agent>`.
- The tab was made but the app could not be switched to it: the error says the
  tab was created and names what failed. The tab is still there.
- The tab could not be made at all: the error names what Rex said, and — since
  the bead was already claimed before the tab — how to hand the claim back
  (`bd unclaim <id>`).

## Converting a repo to jj workspaces

Creating work needs a repo that is ginit'd: a jj directory repo at the wrapper,
`main` as a full-sparse workspace beside it, and `ginit`'s seed files in the
tree. `ginit` builds that from nothing — an empty remote, and a directory it
makes itself — so it cannot be re-run over a repo that already has a `.git` at
its wrapper and worktrees beside it. What is needed instead is ginit's own step,
by hand, in the order that works.

Run all of this from the wrapper — the directory holding `.git`, `main` and the
worktrees — with nothing uncommitted in any of them.

1. **Commit the seed files first.** `main` needs what `ginit` would have written
   there: the post-start `copy-ignored` hook and the post-remove
   `jj workspace forget {{ branch }}` hook in `.config/wt.toml`, the
   `.worktreeinclude`, and the ignore lines `.env` and `.worktrees/`. `ginit`
   writes both files in its second step, so copy them from there. They have to be
   committed to `main` **before** `main` is re-created, because the hooks have to
   be in the tree the new workspace gets.
2. **Remove the existing worktrees; do not adopt them.** `jj workspace add`
   refuses a directory that has anything in it, and an ordinary git worktree
   left behind in a converted repo is a hazard: a `jj` command run inside one
   resolves the *wrapper* as the workspace and snapshots that whole directory
   into the empty default one. The branch stays; only the working copy goes.

   ```bash
   git worktree list                     # what is there
   git worktree remove --force feat-pxp  # one line per worktree
   ```

3. **Keep the beads database out of jj's object store.** `.beads/` sits at the
   wrapper root, and the first `jj git init` snapshots whatever is there, so the
   embedded Dolt database and `.beads.gate.lock` would land in `.git` as objects
   before the inert workspace is abandoned. One line, **before** the `jj git
   init` in step 4, keeps them out:

   ```bash
   printf '.beads/\n.beads.gate.lock\n' >> .git/info/exclude
   ```

4. **Re-create `main` in ginit's order.**

   ```bash
   jj git init --git-repo .git .
   git worktree remove --force main
   jj workspace add --colocate main
   git -C main checkout main
   jj bookmark track main@origin || true
   jj sparse set --clear
   jj new "root()" -m 'default workspace: intentionally empty (see ginit)'
   wt -C main -y hook post-start
   ```

   The order is the point. `jj workspace add` copies the sparse patterns of the
   workspace it runs from, so `main` has to be added before
   `jj sparse set --clear` empties the default workspace — otherwise the new
   `main` is as empty as the workspace at the wrapper. The `jj sparse set
   --clear` and the `jj new "root()"` are what make that wrapper workspace
   inert once its worktree is gone, and the last line runs the post-start hooks
   by hand, because jj and not wt made this worktree.
5. **Check it with the flow itself**, which are the two checks no script here
   can make. In `main`:
   - **a create.** Press `ctrl+space>n` and pick a branch name that does not
     exist yet, so the pick is a create: the tab lands in a jj workspace with
     the branch attached and the hooks run — `jj workspace list` from `main`
     names the new one — and the agent starts in it. `^C` kills the agent and
     the pane stays a shell in that workspace.
   - **a switch to what that made.** Pick the same branch a second time and the
     tab must *switch* to the worktree that is already there rather than make
     anything: it is worktrunk's switch, and this is the exercise that proves it
     accepts a workspace jj created (on a scratch wrapper it answers
     `{"action":"existing","branch":"feat/zz","path":"…/feat-zz"}`, exit 0, to
     `wt -C <main> switch feat/zz --no-cd --format=json`). Through the flow the
     tab lands in that directory and `jj workspace list` names no second one.
     Close the tab the create left open first — exit the shell it left, or close
     the window: with a tab already open on the branch the pick finds it and
     shows it again, so the wrapper never runs and `wt switch` is never made.
     The check has passed only if a switch really happened.

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
typing it at the prompt. The screen's own paths — the ones that exist only where
stdin is a terminal — are run with `PICK_SCREEN=1`, the script's answer for a run
with no terminal to hand, so they are the script itself rather than a patched
copy of it, with `fzf` and `gum` stand-ins answering for the person.
