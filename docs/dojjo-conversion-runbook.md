# Converting a repo to dojjo

The runbook for the repos this flow drives, one repo at a time, after the
worktrunk cut ([the design](superpowers/specs/2026-11-06-dojjo-workspace-cut-design.md)).
It is the last step of that cut and the only part of it that happens outside
`rex-config`: each repo has its own hook file, its own history, and its own
commit.

Read the repo's file before you edit it. The inventory below is what the design
found; a repo that has been converted since will not match it, and the file on
disk is the truth.

**Nothing here has been run against a real repo yet.** Every `djo` and `jj` claim
below was checked against scratch wrappers built to the wrapper shape (`djo`
0.2.2, `jj` 0.47.1), and the recipe is written so that a wrong result shows up as
a wrong result rather than as a silent pass — with one exception, the copy hook's
own summary line, which counts what it attempted rather than what arrived
([step 5](#step-5-verify-in-the-repo) names the log line that gives the difference
away) — but the eight repos in the inventory are all still in their pre-cut
state, so the first real run is the first test.
**`pi-rex` goes first**, and it is the one to watch.

## What changes, and why

`jws` makes the workspace with `jj workspace add` and then runs
`djo hook post-start` inside it. dojjo is therefore what runs a repo's setup
steps — and dojjo reads **one** shape of hook config: a `[hooks]` table, at
`<workspace>/.config/wt.toml`. worktrunk's *top-level* `[post-start]` and
`[post-remove]` are parsed by dojjo and run **nowhere**, silently.

So, per repo, exactly three things change, all of them in
`<wrapper>/main/.config/wt.toml`:

1. the top-level `[post-start]` table becomes `[hooks.post-start]`, and each
   command inside it is translated (the table below) — or, where one command has
   to finish before another starts, becomes the pipeline form
   `post-start = [{ … }, { … }]` ([step 1](#step-1-rewrite-the-hook-table));
2. the `[post-remove] jj = "jj workspace forget …"` hook is **deleted** — not
   moved, not carried across: `djo remove` forgets the workspace and deletes its
   directory itself (verified: a `djo remove <name> -y` from `main` leaves no
   row, no directory and no bookmark);
3. nothing else in the file, and nothing about that repo's layout, has to change
   for the hooks to run. Everything else is about the git layer, and that is
   [a separate decision](#step-4-pick-a-route). One file nearby does matter,
   though, and it is not in `.config/`: a `.worktreeinclude` that worktrunk
   wrote turns the copy hook **off** under dojjo —
   [same step](#worktreeinclude--delete-it-or-make-its-lines-literal).

The file keeps its name — `.config/wt.toml`, worktrunk's — on purpose: no repo
can then be left holding a stale hook file that dojjo half-reads.

### What a wrapper is, in one paragraph

`<wrapper>` is the nearest ancestor holding `.jj/repo` **as a directory**;
`<wrapper>/main` is the base workspace, the only workspace with the full sparse
patterns, and the one `jws` creates from. That `main` beside it is also what
makes it a wrapper rather than a plain colocated repo.

```bash
cd ~/Projects/_ai/pi-rex            # the wrapper
test -d .jj/repo && echo "wrapper ok"
test -d main && echo "main ok"
jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'
```

If those two tests fail, this runbook is not the procedure you want — see
[What this runbook is not](#what-this-runbook-is-not).

## The inventory

`main/.config/wt.toml` as the design found it, with the current state of each
wrapper checked alongside it (2026-11-06, `djo` 0.2.2, `jj` 0.47.1):

| repo | wrapper | the hook file today | route |
|---|---|---|---|
| pi-rex | `~/Projects/_ai/pi-rex` | `[post-start] copy = "wt step copy-ignored --require-include"`; `[post-remove] jj = "jj workspace forget {{ branch }} 2>/dev/null \|\| true"` | in place |
| pi-carte | `~/Projects/_ai/pi-carte` | same as pi-rex | in place |
| pi-garnish | `~/Projects/_ai/pi-garnish` | same as pi-rex | in place |
| pi-whetstone | `~/Projects/_ai/pi-whetstone` | same as pi-rex | in place |
| rex-config | `~/Projects/_ai/rex-config` | `[post-remove]` forget only — no `[post-start]` at all | in place |
| pmm-iris | `~/Projects/_pmm/pmm-iris` | `[post-start] copy = …`, `dev = "bun install"`; `[post-remove]` forget | in place |
| ci-platform | `~/Projects/_pmm/ci-platform` | `[post-start] beads-redirect = "mkdir -p .beads && echo '{{ repo_path }}/.beads' > .beads/redirect"` — no copy hook, no forget hook | rebuild |
| pi-packages | `~/Projects/_ai/pi-packages` | no `.config/wt.toml` at all | nothing to translate |

Two rows need a word more:

- **ci-platform has no `.jj` at all.** It is a bare-rooted git wrapper (a bare
  `.git` at the wrapper, `main/` as its only worktree), so there is no `.jj/repo`
  directory for `jws` to walk up to and no `default` workspace to leave inert.
  Converting it means giving it a jj repo, which is
  [the rebuild route](#step-4-pick-a-route); the hook file is translated on the
  other side of that.
- **`pmm-iris_bak` is a backup directory and is left alone.** So is anything
  else under `backups/`.

Every one of the `_ai` wrappers still carries `.git` at the wrapper with
`main` registered as a worktree in it. That is the git layer, and stripping it
is [a step of its own](#the-git-layer--the-owners-step).

## The six steps, per repo

The commands below name `pi-rex` at `~/Projects/_ai/pi-rex` as the worked
example. Substitute the repo you are converting and its own path.

### Step 1: rewrite the hook table

Open `<wrapper>/main/.config/wt.toml` and put the hooks under `[hooks.post-start]`,
translating each command — or, where one has to finish before another starts,
under `[hooks]` as a pipeline (below). On
[the rebuild route](#step-4-pick-a-route) this is the **old** wrapper's file, which
that route deletes, so write the translated file in the **new** wrapper after the
clone — or commit and push the translation first, so the clone brings it across.

| worktrunk | dojjo | why |
|---|---|---|
| `copy = "wt step copy-ignored --require-include"` | `copy = "djo copy-ignored --from main"` | `wt step` is gone; `--require-include` is a worktrunk flag dojjo does not have; the source workspace is named explicitly |
| `dev = "bun install"` | `dev = "bun install"` | unchanged — it never mentioned worktrunk |
| `beads-redirect = "… {{ repo_path }}/.beads …"` | `… {{ primary_workspace_path }}/.beads …` | under dojjo `repo_path` is the **new workspace**, so the old form points at `<new workspace>/.beads`; `primary_workspace_path` is the wrapper |
| `[post-remove] jj = "jj workspace forget {{ branch }}"` | *(deleted)* | `djo remove` forgets the workspace itself |
| a second hook that has to run **after** the first | both keys in one `[post-start]` table | `post-start = [{ copy = "…" }, { dev = "…" }]` **under `[hooks]`** — one entry per step | steps run in order; one table is one step and its entries run **parallel**, so a key cannot wait for another key in its own table |

What each repo's file becomes:

```toml
# pi-rex, pi-carte, pi-garnish, pi-whetstone
[hooks.post-start]
copy = "djo copy-ignored --from main"
```

```toml
# pmm-iris — one entry per step, so the copy lands before the install
[hooks]
post-start = [
  { copy = "djo copy-ignored --from main" },
  { dev = "bun install" },
]
```

```toml
# ci-platform
[hooks.post-start]
beads-redirect = "mkdir -p .beads && echo '{{ primary_workspace_path }}/.beads' > .beads/redirect"
```

**One table is one step, and a step's entries run in parallel.** `[hooks.post-start]`
with two keys starts both commands in the same second — verified: two `sleep 2`
keys finished in 2.2 s, while the same two as pipeline *steps* took 4 s and their
timestamps were 2 s apart. So anything that has to happen **after** something else
belongs in the pipeline form, `post-start = [{ … }, { … }]`, whose steps run in
order — `pmm-iris` above is the one repo here that needs it. And the pipeline form
is read **only under `[hooks]`**: a top-level `post-start = [...]` is silently
ignored exactly like a top-level table (verified: `No hooks configured for
"post-start".`, exit 0, no log, no workspace changes at all).

The keys on the left of the `=` (`copy`, `dev`, `beads-redirect`) are what dojjo
names the log files after — `post-start-copy.log` and so on. Keep them, because
[step 5](#step-5-verify-in-the-repo) reads them.

A repo whose file ends up holding nothing — `rex-config` is the one, since all it
had was the forget hook — should have the file **deleted**. `pi-packages` has
never had one and works: a workspace with no hooks is fine, a workspace with
hooks dojjo ignores is not.

On `rex-config` (and `pi-packages`) `No hooks configured for "post-start".` is
consequently the **pass**, and not the failure the same message means on a repo
whose file still holds a top-level table
([step 3](#step-3-verify-the-table-is-the-only-one)): nothing ran because nothing
is configured, which is exactly right, and no log is written.

### Step 2: delete the forget hook

`djo remove` forgets the workspace and deletes the directory in one command, so
the `[post-remove]` hook has nothing left to do. Delete it with the rest of the
old top-level table. Do **not** carry it across as `[hooks.post-remove]`: dojjo
runs those two hook types, and `jj workspace forget` for a workspace dojjo is in
the middle of removing is a no-op at best.

### Step 3: verify the table is the only one

This is the step the whole runbook exists for. A top-level `[post-start]` /
`[post-remove]` left anywhere in the file is **silently ignored**: no error, no
log, no hook. Verified, in a scratch wrapper whose file held only
`[post-start]`:

```
$ djo hook post-start
No hooks configured for "post-start".
$ echo $?
0
```

Two static checks:

```bash
cd ~/Projects/_ai/pi-rex/main
# must print NOTHING (a missing file is also a pass — that is rex-config):
grep -n '^\[\(post-start\|post-remove\)\]' .config/wt.toml 2>/dev/null || true
grep -n '^\[hooks' .config/wt.toml 2>/dev/null || true   # what dojjo will read
```

and one live check, **after** [step 5](#step-5-verify-in-the-repo) has made its
throwaway workspace — go forward to that step, then come back here — and inside
that workspace rather than in `main`. `main` is the worst place for it, since a
copy hook there copies `main` onto itself, skips every entry and proves nothing:

```bash
cd <the throwaway workspace>
djo hook post-start
# prints nothing at all when the table is read and the hooks ran, and writes
# its log beside the wrapper
# prints `No hooks configured for "post-start".` when it is not — except on a
# repo whose file was deleted on purpose (rex-config, pi-packages), where that
# same line is the pass
```

### Step 4: pick a route

Two routes reach a jj-only wrapper, and the owner does not mind which a repo
takes. Both start from the hook file above.

**Rebuild the working copy.** `jclone <remote-uri> <directory>` into a fresh
directory (`jj git clone --no-colocate`, a `main` workspace, an inert `default`,
beads recovered from `refs/dolt/data`), move any uncommitted work across, and
delete the old wrapper. This is the route for a repo that is not a wrapper yet —
`ci-platform` today — and for one whose git layer is tangled enough that
starting again is cheaper than unpicking it. Move the work across by hand: an
existing worktree is removed rather than adopted, because `jj workspace add`
refuses a directory that has anything in it, and a worktree left behind is a
hazard of its own — a `jj` command run inside it resolves the *wrapper* as the
workspace and snapshots the whole directory into the inert `default` one.

**Clean up in place.** The wrapper keeps its directory. Its `default` workspace
is already inert — `ginit` and `jinit` sparse-clear it and park it on `root()`, so
a stray jj command run from the wrapper snapshots nothing — and the hook file is
therefore the only thing that has to change. The git layer, if it is going, goes
separately below.

#### `.worktreeinclude` — delete it, or make its lines literal

`djo copy-ignored` has **no globs**. It reads `.worktreeinclude` from the source
workspace when there is one, and treats each line as a literal path or path
prefix; if the file exists and nothing matches, **nothing is copied at all**.
Verified on `djo` 0.2.2:

```bash
# main/.worktreeinclude holding the worktrunk glob
$ printf '%s\n' '.env*' > .worktreeinclude
$ djo copy-ignored --from main --dry-run
Would copy 0 entries from main.

# the same file with a literal name
$ printf '%s\n' '.env' > .worktreeinclude
$ djo copy-ignored --from main --dry-run
  [copy] .env
Would copy 1 entries from main.

# no file at all
$ djo copy-ignored --from main --dry-run
  [copy] node_modules
  [copy] .env
Would copy 2 entries from main.
```

Every repo here that carries a copy hook also carries a `.worktreeinclude`
holding `.env*` — the glob worktrunk expanded. Under dojjo that line matches
nothing, so the file turns the copy hook off. **Delete
`<wrapper>/main/.worktreeinclude`** — it is worktrunk's file and means nothing to
this flow, and deleting it is what gives the accepted behaviour in
[the next section](#behaviour-change-1-the-copy-hook-no-longer-filters) — or, if
you want to keep it, replace every line with a literal path.

Three things about that deletion:

- **the file is committed** in all five repos that have one (the four `_ai` ones
  got it in the `jinit`/`ginit` seed commit, `pmm-iris` in a `chore:` commit of its
  own), so the deletion is a tracked change that goes in with
  [step 6](#step-6-commit-the-change-in-that-repo)'s commit. Deleting it on disk
  alone leaves it in `HEAD`, and the next workspace created from `main` brings it
  back;
- **a `jclone` rebuild restores it from the remote**, so re-check it after
  [step 4](#step-4-pick-a-route)'s clone — that is the one way this file comes
  back with no error anywhere;
- the design says dojjo "does not read `.worktreeinclude`". That is **wrong for
  0.2.2** — verified in the dry runs above, and from `djo` 0.2.2 itself, whose
  copy-ignored loads and applies the file as a literal include list. If you find
  yourself reconciling the two, this document is the one that was run.

`jinit` seeds that same `.env*` line into a fresh wrapper, so a wrapper made by
`jinit` today copies nothing on its post-start hook either. That is a known
defect in the seed, not intended behaviour; the workaround is the one above —
delete the file, or use literal names — until the seed is fixed.

#### The git layer — the owner's step

Stripping git from a wrapper is the owner's own work, `pi-rex` first: no bare
`.git` at the wrapper, no `git worktree list` registrations, and nothing in the
flow asks for it afterwards — `jws`, the picker and the done flow are jj's and
dojjo's, and the flow's only remaining git question is `origin/HEAD`, which it
falls through when there is no `.git` to ask. Converting the hook file first and
stripping git later is fine and is the order here, because the hook file is the
part that silently breaks.

### Step 5: verify in the repo

One throwaway workspace, made and removed the way the flow makes and removes
them. From `main`:

```bash
cd ~/Projects/_ai/pi-rex/main
ls -l ~/Projects/_ai/pi-rex/../.jj/djo/logs          # note what is there NOW
                                                    # (it may not exist yet: the
                                                    #  first hook run makes it)
touch .env                                          # see the note under this box
jws hooks-check --path-file /tmp/jws-path.txt        # a create, from main
cat /tmp/jws-path.txt                                # the workspace path
ls -a "$(cat /tmp/jws-path.txt)"                     # .env came across
```

`pi-rex`, `pi-carte`, `pi-garnish` and `pi-whetstone` have **nothing untracked in
`main`** today — no `.env`, no `node_modules`, nothing ignored at all — so on
those four a correct copy hook copies nothing, and an `ls` with no `.env` in it
proves nothing either way. The `touch .env` is what gives such a repo something
to prove the hook with: delete it again afterwards, and do not commit it.
`pmm-iris` needs no such help — its `main` carries `.env` and a top-level
`node_modules`, so its copy has something to bring across on the first run (once
its `.worktreeinclude` is gone — [step 4](#step-4-pick-a-route)).

Then the log, which is the only evidence there is:

```bash
ls -l ~/Projects/_ai/pi-rex/../.jj/djo/logs
cat ~/Projects/_ai/pi-rex/../.jj/djo/logs/post-start-copy.log | tail -5
# and, because the summary counts what it tried rather than what arrived:
# must print NOTHING:
grep -n 'Failed to copy' ~/Projects/_ai/pi-rex/../.jj/djo/logs/post-start-copy.log \
  2>/dev/null || true
```

The path is `<wrapper>/../.jj/djo/logs` — **beside** the wrapper, not inside it,
and not `<wrapper>/.jj/djo/logs`. dojjo resolves the shared `.jj` from the text
in `<workspace>/.jj/repo` (`../../.jj/repo`) without resolving it against the
workspace, so its logs land one directory above the wrapper; dojjo prints that
path relative to the workspace it is in, which is where the `../..` comes from.
The log set is shared by every wrapper whose parent is the same directory
(`~/Projects/_ai/.jj/djo/logs` serves pi-rex, rex-config, pi-carte and the
rest), and the files are appended to, so compare with what you noted before
rather than trusting that a file exists.

One consequence of the same defect, worth knowing before it bites: the first hook
run in a `_ai` wrapper creates `~/Projects/_ai/.jj`, a `.jj` directory with no
`repo/` inside it. **Do not run any `jj` command in `~/Projects/_ai` itself**
afterwards — jj finds that `.jj` on its way up and stops there, answering
`The repository appears broken or inaccessible` for the directories around it.

Three signatures, and only two of them are a pass:

```
post-start(copy): djo copy-ignored --from main          the hook ran
  node_modules
  .env
Copied 2 entries from main.                             a pass

post-start(copy): djo copy-ignored --from main
No untracked files found in main.                       a pass on a repo whose main
                                                        has nothing untracked — which
                                                        is pi-rex, pi-carte,
                                                        pi-garnish and pi-whetstone
                                                        today, though only while the
                                                        `touch .env` above is absent
                                                        — or whose only untracked
                                                        paths are dojjo's own fixed
                                                        exclusions (`.pi/`, `.jj/`
                                                        and their kin — Behaviour
                                                        change 1), which it skips
                                                        as it walks, so they never
                                                        count as untracked at all

post-start(copy): djo copy-ignored --from main
Copied 0 entries from main.                             NOT a pass on a first run:
                                                        untracked paths were there
                                                        and nothing came across.
                                                        Either something filtered
                                                        every one out (a
                                                        .worktreeinclude, almost
                                                        certainly — step 4), or the
                                                        only untracked paths sit
                                                        under a directory the new
                                                        workspace already has (the
                                                        nested case, below).
                                                        On a re-run in a workspace
                                                        that already has the entries,
                                                        0 copied is expected and fine
```

`Copied N entries` counts the entries the copy **attempted**, not the ones that
arrived: a **`Failed to copy …` line anywhere in that log** means that entry did
not come across even though the summary counts it, so read the whole file, not
just its last line. A permission error does it; so does a disk that fills up
part-way through 981 MB, which is the realistic case here. Verified: with an
unreadable file inside `main/node_modules` the log read `Failed to copy
…/main/node_modules: cp: … Permission denied`, then `Copied 2 entries from main.`,
exit 0 — and the workspace's `node_modules` was left empty. Fix the cause, `rm -rf`
the entry that did not arrive — the copy only takes a top-level entry that is
absent — then re-run `djo hook post-start` in that workspace. Verified: deleting a
half-copied `node_modules` and running the copy again brought that one entry and
skipped `.env`, which was already there.

A file that says `post-start(copy) failed (exit 64)` is the old command still in
place; `No hooks configured for "post-start".` on the pane (and no fresh log at
all) is a top-level table, [step 3](#step-3-verify-the-table-is-the-only-one) —
and on `rex-config` and `pi-packages`, whose files have no hooks at all on
purpose, that last line is the pass. A **`Failed to copy`** line under an entry
the summary counted is neither: the copy ran and lost part of what it took, and
the paragraph under the box is the repair.

Then, where the repo has a redirect hook (`ci-platform`):

```bash
cat "$(cat /tmp/jws-path.txt)/.beads/redirect"       # must be <wrapper>/.beads
```

and the removal, from `main`:

```bash
cd ~/Projects/_ai/pi-rex/main
djo remove hooks-check -y
jj workspace list -T 'name ++ "\t" ++ root ++ "\n"'  # no hooks-check row
test ! -d ~/Projects/_ai/pi-rex/hooks-check && echo "directory gone"
# prints nothing at all when the bookmark is gone:
jj log -r 'bookmarks(exact:"hooks-check")' --no-graph -T 'commit_id.short()'
echo
```

That last read is the flow's own: `djo remove` deletes the bookmark with the
workspace, and `jj bookmark list` is the wrong reader for the result — a bookmark
that was tracking a remote is only tombstoned by the deletion, so the listing
still renders `<name>@origin` and cannot tell you the local one is gone. (A
bookmark created here and never pushed has no `@origin` and simply disappears
from the listing, so the listing proves nothing in that case either.) The revset
can — it is what `new-work.sh` and `init.lua` read.

### Step 6: commit the change in that repo

The hook file is that repo's file, and this runbook's repo does not commit for
it:

```bash
cd ~/Projects/_ai/pi-rex/main
jj commit -m "hooks: dojjo runs the post-start hooks"
```

(Or `jj describe` and the repo's own push/PR, whichever that repo does. The
nesting is `main/.config/wt.toml` — one `jj commit` in `main` covers it, and
because the hook file lives in what every new workspace is created from, a
workspace made from `main` afterwards has it too. **This is also the commit that
carries the `.worktreeinclude` deletion** on the five repos that have one, plus
the hook file's own removal on `rex-config`: one commit, "dojjo runs the hooks,"
covering everything the conversion changed in that repo's tree.)

## Behaviour change 1: the copy hook no longer filters

worktrunk could be told which ignored paths to bring across
(`--require-include`, `.worktreeinclude`'s globs). `djo copy-ignored` cannot take
a pattern: it takes every **top-level** entry `jj file list` does not track, so
**`node_modules` comes across with `.env`** where each sits at the top of the
repo. The owner accepted this — a workspace's first minute is worth more than
the disk — and it is the behaviour the copy hook above is written for.
`pmm-iris` is where it is biggest and where the limit shows: once its
`.worktreeinclude` is gone, its copy brings its **top-level** `node_modules`
along with `.env`, `.env.docs`, `.env.integration`, `.env.prod` and their kin —
while its nested `apps/*/node_modules` stay behind, because each sits under
`apps`, and `apps` already exists in the new workspace. That top-level
`node_modules` is 981 MB of stale modules, and that repo's other hook is
`dev = "bun install"` — so the first post-start in a `pmm-iris` workspace copies
the gigabyte and then reinstalls over it, and that is the price of the accepted
behaviour. It is only a *then* because that repo's file is the **pipeline** form
from [step 1](#step-1-rewrite-the-hook-table), `post-start = [{ copy = … },
{ dev = … }]`, whose steps run in order: two keys in one `[hooks.post-start]`
table would run **in parallel**, and `bun install` and a 981 MB copy would then
race over the same `node_modules`, which can leave it half copied and half
installed. A workspace already left in that state is repaired in place —
`rm -rf node_modules && bun install` there — and so is one where the copy itself
failed part-way ([step 5](#step-5-verify-in-the-repo)). Two limits of it are
worth knowing:

- dojjo's own fixed exclusion list always skips `.git`, `.jj`, `.worktrees`,
  `.pi` and their kin, whatever the ignore file says (verified: a `.pi/` and a
  `.worktrees/` in `main` are not copied, a top-level `node_modules/` is);
- **the copy is by top-level entry, so anything not at the top of the tree is at
  the mercy of its top directory.** An entry whose name the new workspace already
  has — which is every directory the repo commits, `apps` in `pmm-iris` included
  — is skipped unless `--force`, which **deletes that top-level entry in the
  workspace and copies it again** from `main`: tracked files and `main`'s
  uncommitted edits included (verified: `--force` replaced a workspace's `apps`
  with `main`'s uncommitted version and removed a file that only the workspace
  had). So a nested cache (`apps/*/node_modules`, `infra/*/.terraform`) is
  **never** copied on its own account, first run or re-run — only the `--force`
  re-copy of its top directory brings it, and that replaces the directory; a
  top-level one is copied once and skipped on the hook's next run, because by
  then it is there.

## Behaviour change 2: a failed hook leaves no exit code

`djo hook` exits **0** whether or not a hook worked. The pane gets one line and
the log path; nothing else carries the failure. This is the one class of failure
no exit status anywhere in this flow reports, and the reason step 5 reads the log
rather than the status:

```
post-start(copy) failed (exit 64), see ../../.jj/djo/logs/post-start-copy.log
```

A hook that fails mid-run still leaves the workspace made — the person has their
tab — so the repair is in the workspace, not a rebuild: fix the table in `main`,
then run `djo hook post-start` again in that workspace (it re-runs the hooks, and
an entry already in place is skipped).

## The translation table, in one piece

| what | worktrunk (before) | dojjo (after) |
|---|---|---|
| the table | `[post-start]` / `[post-remove]` | `[hooks.post-start]` (and `[hooks.post-remove]`, which this flow has no use for) |
| a hook that must run **after** another | both keys in one table — no ordering to express | `post-start = [{ copy = … }, { dev = … }]` **under `[hooks]`**: one entry per step, steps run in order. Keys in a single table run **parallel**; a top-level `post-start = [...]` is silently ignored |
| copying ignored paths | `wt step copy-ignored --require-include` | `djo copy-ignored --from main` |
| a hook that installs | `dev = "bun install"` | `dev = "bun install"` |
| a redirect to the wrapper's beads | `{{ repo_path }}/.beads` | `{{ primary_workspace_path }}/.beads` |
| forgetting the workspace | `[post-remove] jj = "jj workspace forget {{ branch }}"` | deleted — `djo remove` does it |
| which ignored paths come across | `.worktreeinclude`'s globs, and only those | every **top-level** untracked entry — and a nested one only where its top directory does not already exist in the new workspace; `.worktreeinclude` read as literals, so delete it |
| where a hook's output goes | worktrunk's own logs | `<wrapper>/../.jj/djo/logs/post-start-<hook>.log` |

Variables that stay available inside a hook, checked in a scratch workspace:
`{{ branch }}` (e.g. `feat/v`), `{{ repo_path }}` (the new workspace),
`{{ primary_workspace_path }}` (the wrapper). The hook runs with the new
workspace as its working directory.

## What this runbook is not

- **Not the way to make a new repo.** `jinit` (an empty remote) and `jclone` (an
  existing one) are for fresh wrappers; they build the shape from nothing and
  `jclone` is one of the two routes above.
- **Not the way to convert a plain colocated repo.** Turning the roughly 40 repos
  under `~/Projects` that are a normal `jj git init`-in-place clone into wrapper
  shape is a different procedure — their `.jj/repo` is inside the worktree, there
  is no `main` beside it, and `jj workspace add` refuses a directory that has
  anything in it — and it is deliberately out of scope for this cut. The picker
  refuses such a repo by name rather than half-driving it.
- **Not a hook-writer.** A repo whose post-start hook does something the table
  above does not mention keeps its own command; only the table's shape (a table,
  or a pipeline where one command has to follow another) and the translations in
  that table are this cut's business.
