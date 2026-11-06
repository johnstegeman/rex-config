# rex-config: one screen for `ctrl+space>n`

**Date:** 2026-10-29
**Status:** design, approved in conversation. **Historical:** the tooling this
document names has moved twice since — worktrunk (`wt`) gave way to jj workspaces
(`2026-11-03-rex-jj-workspaces-design.md`) and then to `jws`/dojjo
(`2026-11-06-dojjo-workspace-cut-design.md`). Every `wt` here is what the flow
used *then*; read the later two for what it does now.
**Owner:** John Stegeman

## Intent

`ctrl+space>n` already does the right thing — a bead becomes a branch, a
worktree and an agent — but it asks three questions in a row: the bead-or-prompt
question, then the agent, then the branch. The prompt wanted one screen instead.
fzf's query is already the prompt (text matching no bead *is* the prompt), the
list is already the bead list with a preview nothing else offers, and the ✎ row
already covers the awkward multiline case. The only thing making it feel
sequential is that agent and branch are two further questions.

This design collapses all of it into one fzf invocation whose header carries the
live state and whose keys collect the other answers, then hands back the same
payload `pick` produces today, so `work_new_go` and everything downstream of it
do not change shape.

Two real defects found while reviewing `nicosuave/rex-launch` ride along, because
they live in the same argv contract this work touches: the tab wrapper can hang
on an invisible credential prompt, and a prompt starting with `-` is read as an
agent flag.

One behaviour is genuinely new rather than rearranged: the **blank** answer — a
worktree and an agent with nothing to say. Today it is unexpressible; Esc is the
only no-bead exit and it always supplies `no_bead_prompt`.

Success is: from a project session, `ctrl+space>n`, Enter on a bead, and an agent
starts brainstorming it — one screen, one keystroke, and the state you cared
about visible on it the whole time.

## Goals

- One fzf invocation replaces the bead, agent and branch questions.
- The header shows project, agent, branch and base, plus the key hints, and is
  repainted in place when an answer changes (no `reload` for a one-line change).
- Five answers are expressible: a bead, the ✎ field, typed prompt text, **blank**,
  and no bead at all (Esc).
- A new branch starts from a real, named base ref: the remote default branch by
  default, fetched first, with the same screen offering a short cycle of other
  bases.
- `GIT_TERMINAL_PROMPT=0` and a `-`-leading prompt are fixed, each pinned by a
  test.
- The repeat launch is one Enter: the agent you used last is the header's agent.
- Still Lua + POSIX sh + bash tests. No new runtime dependency beyond fzf and gum,
  which the picker already needs.

## Non-goals (this cut)

- **Moving `bd update --claim` into the tab.** The claim stays in `work_new_go`
  before the tab exists, and the README keeps its `bd unclaim` paragraph. This
  is bead `rex-config-dan`'s open question #3; it is a separate, deliberate
  decision.
- **A full base-ref picker.** The cycle is short and fixed; searching every local
  and remote branch is not part of this.
- **`install` subcommand and CI.** Both stay out until this leaves this machine.
- **Cross-implementation parity test** between `candidate_rows` and
  `new_tab_argv`.
- **Probing agents for their models**, kitty-graphics chrome, always-unique
  branches, scratch/"no project" mode, multi-host scans, project discovery.
- **Remembering the base or the branch.** Only the agent is remembered; a
  remembered base would fight the new default, and the branch already tracks the
  bead or the query.

## Anti-goals

- A second question after the screen. The point is one screen; a fallback
  sequence would double the paths and the tests.
- Network work inside the picker. A fetch behind fzf can block the list behind an
  invisible credential prompt — the exact failure the wrapper fix exists to
  prevent.
- Losing an answer because a key repainted. ctrl-a and ctrl-r change exactly
  one field and touch nothing else — no reload, no cursor reset, the query and
  the other fields untouched. ctrl-b is the one key allowed to repaint (gum
  suspends fzf; the owner accepted the tear-down), and even it must keep the
  query and the other fields intact — only the cursor row may reset.
- A blank prompt quietly becoming `no_bead_prompt`. "Nothing to say" and "the
  picker was never asked" stay different answers.
- A fetch failure that stops work from starting.

## Constraints

- **fzf's reply order is a contract.** With `--print-query` and `--expect`, fzf
  prints the query first, the key **second** ("or as the second line if
  `--print-query` is also used"), then the selected row. Reading the key off line
  1 reads an empty query as "no key pressed" and slides the selected row up into
  the query slot — measured, in the prototype.
- **Keys fzf already owns.** fzf binds ctrl-n/ctrl-p/ctrl-j/ctrl-k by default. The
  prototype measured ctrl-n working as an `--expect` key with fzf 0.74.5, and the
  answer function tolerates a missing key line, so an older fzf degrades to
  "no key" rather than to a wrong answer.
- **The picker runs in a Rex float**, where stdin is a terminal; tests drive it
  through pipes and subcommands, never a pty.
- **Rex key-bound actions cannot wait for input**, so the picker hands back with
  `rex do work_new_go --args <payload>` exactly as today.
- **The tab's program is POSIX sh**, handed over through `sh -c` with positional
  parameters; nothing about the flow may be written into the program text.
- **`wt -x` expands `{{ }}` in the prompt**, which is why every value travels as
  its own parameter — the new base argument does not change that.

## Decisions made by the owner

- The one-screen composer is the shape wanted, on the existing fzf picker, not a
  new UI.
- `ctrl-b` may hand the terminal to `gum input`: the tear-down-and-repaint is
  acceptable because ~90% of launches pick a bead and accept the proposed branch,
  and the rest is a typed branch with a blank prompt.
- The base should be a picker option, **defaulting to what orca does** (fetch,
  then branch from the remote's default branch), not to today's local-`@`
  behaviour.
- That cycle should be **short**, not a search over every ref.
- The two wrapper defects and the base/fetch question are in scope with the
  composer.

## How it works

### The screen

One `fzf` invocation replaces `pick_bead`, `pick_agent` and `pick_branch`:

```
✎  write a prompt instead        <- row 1, always
bead-1a2<TAB>the first bead's title
bead-3c4<TAB>the second bead's title
```

Rows are `id<TAB>title` and nothing else — `--with-nth=1,2` draws both fields of
a row that has exactly two, so no priority column is shown.

```
 `rex-config · agent: pi · branch: bug/58h · base: origin/main`
 `ctrl-a agent  ctrl-b branch  ctrl-r base  ctrl-n blank  enter start  esc no bead`
```

When `base = false` there is no base to name and the field reads `base: wt
default`, so the field is never blank and never lies about what will happen.

- `--print-query --expect=ctrl-n --reverse`, delimiter tab, `--with-nth=1,2`, the
  bead preview below (`preview {1}`), `load:pos(2)` so a bare Enter takes the
  bead the list leads with — the same choice the real picker makes today.
- `ctrl-a` → `transform-header(composer cycle-agent)` + `refresh-preview`. No
  reload: the rows did not change, and a reload clears and repaints the list and
  resets the cursor.
- `ctrl-b` → `execute(composer branch-field)` (gum input, prefilled) then
  `transform-header` + `refresh-preview`. **No reload**: nothing in the row set
  depends on the branch — the rows are beads, and the branch only decides
  `create` at hand-back — so a reload here would be a bare cursor reset and would
  break the anti-goal above for no reason.
- `ctrl-r` → `transform-header(composer cycle-base)`. Nothing else changes.
- All state (`agent`, `branch`, `branch_edited`, `base`, index counters) lives in
  one `mktemp -d` directory per picker run, removed by a `trap` on exit, so a
  killed float leaves nothing behind and two picker runs cannot collide.

### The answers, and how a reply becomes a decision

`fzf-answer` grows from two lines to three and stays a subcommand, so the pipe
tests keep pinning the bytes fzf really produces:

| What you do | status | lines | answer |
|---|---|---|---|
| Enter on a bead | 0 | query, ``, row | that bead |
| Enter on the ✎ row | 0 | query, ``, row | the text from the field (gum input) |
| typed text matching no bead, Enter | 1 | query, then whatever else fzf printed | that text is the prompt |
| `ctrl-n` anywhere | 0 | query, `ctrl-n`, row | **blank**: no bead, no prompt |
| Esc / ctrl-c | 130 | — | no bead: the configured `no_bead_prompt` |

The key line wins over the row: ctrl-n is blank even with the cursor on a bead,
which is the whole reason `--expect` is used rather than `--print-query` alone.

The reader takes up to three lines and decides on what it finds rather than on how
many lines arrived: no key line means no key pressed, and no selected row under a
status-0 or status-1 reply means the query is the answer. How many lines fzf
actually emits per case is settled by the fixtures — they pin the real bytes, so
this table describes meaning, not line counts. An unexpected fzf exit status is a
failure of the picker, not a decision.

### Blank, end to end

Blank is a third state for the prompt, and it has to survive the whole way to the
agent:

- the picker sets `blank=1` and sends **no** `prompt` field, with `blank: true`
  in the payload;
- `new_tab_argv` treats `blank` as "append no prompt parameter at all", so the
  argv ends after the agent (and its `agent_args`);
- the wrapper's `exec "$@"` then starts the agent bare — no argument, so no
  prompt. The existing no-agent path (which prints a prompt the user really
  typed, above the login shell) is untouched.

`blank` and `prompt_set == 0` must stay distinct: the first says "an agent, and
nothing to say"; the second says "the picker was not asked, use the configured
template".

### The base ref

**Resolution, in the picker, with no network.** A new `base-default` subcommand
resolves, in order, the first ref that exists:

1. the target of `refs/remotes/origin/HEAD` (as `origin/main`),
2. `origin/main`, 3. `origin/master`, 4. `main`, 5. `master`.

*(History, from the 2026-11-06 dojjo cut: this is no longer how the base is
chosen. The chain is now `main@origin`, then `master@origin`, then `@`, decided
from `jj bookmark list --all-remotes` — no `origin/HEAD` read and no git at all;
`--origin-head` is the fixture that names a remote default outright. See
[The base](../../../README.md#the-base).)*

The check is one `for-each-ref --format='%(refname)%00%(symref)'` over exactly
those refs (the same trick orca uses: a character class, so `main/topic` cannot
impersonate `main`), not `rev-parse` per candidate.

**The cycle** is `[default, "@", "main", "master"]`, deduplicated and with
unresolvable entries dropped — the opening answer excepted, because a `base` you
name is the answer the field starts on even when the ref does not resolve —
`default` first. `@` is today's behaviour and stays reachable two ways: as a
cycle entry, and as `base = "@"` in configuration.
**`base = false` is a cycle entry, not a lock.** Its first entry is a `wt
default` sentinel meaning "pass no `--base` and let worktrunk decide", followed by
the same `@`, `main`, `master`; the auto-detected chain is not computed at all
(no refs are read). ctrl-r still cycles, so the opt-out sets the answer the screen
opens on rather than pinning the field — the header shows `base: wt default` while
it is there.

**The picker also resolves whether a fetch is warranted**, so the wrapper never
has to guess. When the chosen base names a remote-tracking ref (`for-each-ref`
says `refs/remotes/<remote>/<branch>`), the payload carries that `<remote>`;
`@`, `^`, a local branch and the `wt default` sentinel carry none. A textual
"contains a slash" test is wrong: `feat/x` is a local branch and would produce a
failing `git fetch feat` on every launch.

**Configuration moves the first entry, not the chain.** `base` (a string) becomes
the cycle's first entry instead of a notification; unset means auto-detect. The
existing `new branches start from X` stderr line goes away with the branch
question it introduced.

**The fetch happens in the tab, not the picker.** Only when creating, only when
the picker said the base lives on a remote: `git fetch --quiet <remote>` before
`wt switch`, with `GIT_TERMINAL_PROMPT=0` exported, bounded by
`timeout`/`gtimeout` **when one is installed** and unbounded otherwise (documented; the credential prompt is the
hang this really fixes). A failed fetch prints one line on the pane and **the
switch still runs** from the ref's last-known position — orca's own instinct in
`compare-base-ref-fetch.ts`.

### The payload

`pick`'s hand-back gains exactly three things and keeps everything else:

```json
{ "project": …, "root": …, "main": …, "branch": …, "bead": …, "title": …,
  "create": true,
  "base": "origin/main" | false,    // absent = the picker never answered
  "base_remote": "origin",          // only when the base is remote-tracking
  "prompt": "…" | absent,           // as today, when the picker was answered
  "blank": true,                    // when ctrl-n was pressed
  "agent": "pi" | "" }              // as today
```

This object is what `pick` emits — the JSON printed after `rex do work_new_go
--args`. It is not what the action is handed: `work_new_go` receives it **key by
key**, filtered against the pairs its registered `args.properties` declares, so
a key the declaration does not name never arrives.

`base` is deliberately three-valued: a string is the ref to create from, `false`
is the `wt default` sentinel (pass no `--base`), and **absent** means the picker
never answered — a hand-run `rex do work_new_go --args '…'`, which keeps today's
behaviour by falling back to `M.options.base` when that is a string. So the
payload is authoritative when it speaks, and `base = false` survives end to end
instead of being swallowed by a configuration fallback.

`work_new_go` needs no logic change — it validates `project`/`root`/`main`/
`branch`, claims the bead, makes the tab — but it **must declare every payload
key it forwards**: `base` as `string|boolean`, `base_remote`, and `blank`,
alongside the fields the picker already sent. An undeclared key is filtered out
before the action or `new_tab_argv` ever sees it, and the flow then degrades
silently: the picker's `base = false` becomes the configured base again, and the
blank answer becomes the configured `no_bead_prompt`. `new_tab_argv` is the only
consumer whose logic changes.

One thing no real Rex has confirmed: `base = { type = { "string", "boolean" } }`
(`init.lua:1006`) is the workspace's only array-typed JSON-schema declaration,
and `test/action_test.lua`'s `as_rex_passes` filters by declared key rather than
by declared type. A validator that rejected a type union would fail every
hand-back whose base is the `wt default` sentinel — and the tests would not
notice, because they filter the way the declaration is documented to work, not
the way Rex might enforce it.

### The wrapper

Two fixes, both in the argv contract:

1. `export GIT_TERMINAL_PROMPT=0` early in `new_tab_script`, so `wt` (and any
   `git` the hooks run) cannot stop on an invisible credential prompt.
2. A prompt beginning with `-` travels with one leading space, added in
   `new_tab_argv` — the argv builder owns the argument contract, and the wrapper
   stays the dumb `exec "$@"` it is. The agent therefore never sees a leading
   dash it could read as a flag. (The no-agent path, which prints the prompt for
   the user, prints that same string; the space is invisible there.)

Plus the base, which widens the positional contract by one word:

```
sh -c SCRIPT sh <create> <branch> <base> <remote> <agent> [agent_args] <prompt>
```

`<base>` empty means no `--base` at all (`wt default`), and `<remote>` empty means
no fetch. The wrapper's `shift` moves from 3 to 4 and its "not enough parameters"
guard moves with it, so a caller that sends three still gets a clear message and a
login shell rather than a `dash` exit. The wrapper then runs `git fetch --quiet
<remote>` (when set, and only when creating) before `wt switch --create --base
<base>`, prints one line if the fetch failed, and carries on.

## Configuration surface

| Option | Now | After |
|---|---|---|
| `agent` | string | unchanged |
| `agent_args` | table | unchanged |
| `agents` | list or nil | unchanged (the cycle's order and labels) |
| `bead_prompt`, `no_bead_prompt` | strings | unchanged (`no_bead_prompt` is the Esc answer) |
| `base` | string, default `"@"`, printed as a note | string = the cycle's first entry; `false` = the cycle opens on `wt default`; **unset = auto-detect (the orca chain)** |
| `bounds`, `script` | unchanged | unchanged |

**The agent cycle** is `agents` (or the one configured agent) in order, with the
no-agent row last, exactly as the question offers it today: the header reads
`agent: none` there, the payload sends `"agent": ""`, and an empty value is
written to the state file. A one-name list still cycles: that name, then none.

New state, outside the configuration: `$XDG_STATE_HOME/rex-config/state`
(`~/.local/state/rex-config/state` when unset), a `key=value` file the picker
reads tolerantly (missing file, missing key, corrupt line → the configured
default; a write failure is not worth failing a launch). It holds `agent=<name>`,
and `agent=` with no name is the remembered answer *none* — a line for the key
with nothing after it, which is a different answer from no line at all — so the
cycle's last answer is kept too. It is used to choose the header's initial agent
(a name no longer in `agents` is ignored). **The picker writes it**, immediately
before `rex do work_new_go`, so a refused hand-back still remembers what was
chosen, the write lives in the script whose subcommands pipe tests can reach,
and Lua gains no filesystem code.

## Edge cases and failure behaviour

- **fzf 130** — no bead: the configured `no_bead_prompt` speaks for the work, and
  the pick carries on to the branch field. 130 ends the pick only after that
  field, when nothing has named a branch by then (see *No bead and no branch*).
- **ctrl-n on the ✎ row** — blank: the key wins, the row is ignored.
- **gum cancelled at ctrl-b** — the branch keeps its previous value and the pick
  continues; a cancelled branch question no longer cancels the pick, because the
  screen is not a sequence of questions any more. A cancelled **fallback** field
  (below) is a cancelled pick, as a cancelled question always was.
- **A branch edited by hand** — the branch stops tracking (`branch_edited=1`);
  before that it is recomputed from the bead at each repaint and at hand-back. It
  is **not** recomputed per keystroke: there is no `change` binding, so a typed
  query does not repaint the header on every character.
- **No bead and no branch** — Enter on a typed prompt, on the ✎ field, or esc,
  with no branch yet: the screen asks for the branch in a `gum` field, and only
  that path pays for the extra field. The field opens **empty**: the header's
  branch is the leading bead's name, and handing that back would create a
  worktree on a branch named after a bead nobody picked. ctrl-b's answer is the
  exception in the other direction — a branch typed by hand is an answer
  already, so the field is not opened at all. A cancelled field, or an empty
  one, is a cancelled pick (exit 3), as it is today.
- **`base = false`** — the header opens on `base: wt default`, no refs are read,
  and ctrl-r can still move off it.
- **No base ref resolvable** (no origin, no main) — the cycle is just `@`, the
  header says `base: @`, no fetch is attempted, and `wt switch --base @` behaves
  exactly as today.
- **Fetch fails / offline** — one line on the pane, work starts from the ref as it
  is.
- **Blank with agent `none`** — the wrapper prints nothing (there is no prompt to
  print) and hands over a login shell.
- **Two picker presses** — unchanged: the second replaces the first's float, and
  the branch lookup in `work_new_go` still finds the existing tab.
- **A piped run (no terminal)** — unchanged: the bead question is skipped, the
  agent takes the first offered name, the branch reads stdin; the base resolves
  the same way, without the cycle.
- **A fixture run in the tests** — the existing `--bd-json` / `--wt-json` /
  `--refs` flags mean "no tool is consulted for this", and a base lookup against
  `--main` would break that for the tests whose `--main` does not exist. So a
  fourth fixture, `--base-refs FILE`, stands in for the `for-each-ref` output —
  the same shape as the other three — and `--base REF` short-circuits resolution
  entirely.

## Testing

Everything below runs from `bash test/run.sh` with no pty:

- `test/pick_test.sh` — the reply reading, pinned as bytes: query/key/row line
  order, ctrl-n over a row, ctrl-n over the ✎ row, status 1 with a query, status
  130, a missing key line, a three-line reply whose row is empty. Plus the
  payload: `base` travels as a string, `false` for `wt default`, and is absent
  only when the picker never answered; `base_remote` appears only for a
  remote-tracking base; `blank` travels as a flag and no `prompt` field; an
  existing-worktree branch still sets `create: false`.
- `test/pick_test.sh` also pins the bead-less fallback: a typed-prompt answer with
  no `--branch` asks for one, takes the typed line, and an empty or cancelled
  answer exits 3 the way the branch question always did. `--branch` still
  short-circuits the ask, so every other fixture stays ask-free.
- `test/branch_test.sh` — the base chain: today `main@origin`, then
  `master@origin`, then `@`, from a saved bookmark listing (it was
  `base-default`'s origin/HEAD-then-origin/main chain from git before the
  2026-11-06 dojjo cut); nothing resolvable leaves `@`; the cycle dedupes and
  drops unresolvable entries.
- `test/wrapper_test.sh` — the stand-in `wt` sees `GIT_TERMINAL_PROMPT=0` in its
  environment; a fetch failure still lets the switch run and start the agent; the
  `--base` word reaches `wt switch` verbatim; a prompt starting with `-` and a
  prompt containing `fix "it"` and `{{ now }}` each reach the agent as one
  argument, verbatim; a blank prompt starts the agent with no prompt argument.
- `test/pure_test.lua` — `new_tab_argv`: the dash-prefixed prompt gains its
  leading space, `blank` appends no prompt parameter, `agent_args` still travel
  only with an agent, the four positional words keep their places, `base: false`
  sends an empty third word and a hand-run payload with no `base` still falls back
  to the configured one.

The composer's repaint behaviour (a key changing one field without losing the
query) is the one thing a pipe cannot prove; it is checked by hand once, in the
float, and listed in the plan as a manual step rather than pretended at in a
test.

## What's left to the builder

- How the composer's subcommands are split so each is pipe-testable
  (`header`, `rows`, `cycle-agent`, `cycle-base`, `branch-field`, `answer`) and
  the exact fzf bindings that call them.
- The state file's exact syntax and read/write helpers.
- Whether `cmd_branch_default` is reused as-is for the bead's suggestion or
  wrapped. It stays the only naming scheme: nothing derives a branch from typed
  text.
- Whether the existing three question functions (`pick_bead`, `pick_agent`,
  `pick_branch`) are deleted or kept for piped runs, where the composer is not
  used at all.
- The README's rewritten flow section, and its new failure-mode paragraphs for
  the fetch.
- How the base cycle's existence check is cached within a picker run (one
  `for-each-ref` per run, not per keystroke).
