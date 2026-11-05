-- rex-config: start new work from a bead (ctrl+space>n).
--
-- This module is loaded by the stock `lua` interpreter in the tests as well as
-- by Rex, so nothing at load time may touch the `rex` global (or any other
-- global). Pure helpers live at the top; the Rex-facing setup() and actions
-- call rex.* only inside their function bodies.

local M = { version = "0.1.0" }

-- Replace every {key} placeholder with vars[key]; an unknown key renders as the
-- empty string and everything outside a placeholder is left alone.
function M.render_prompt(template, vars)
  vars = vars or {}
  return (template:gsub("{(%w+)}", function(key)
    local value = vars[key]
    if value == nil then
      return ""
    end
    return tostring(value)
  end))
end

-- `<project root>/.git`, as produced by `git rev-parse --path-format=absolute
-- --git-common-dir` (with or without a trailing slash): the project root is its
-- parent and the project name the basename of that root. The plain form of that
-- command prints a path relative to the worktree (".git"), which names no
-- project at all, so a relative input returns nil instead of empty strings --
-- callers must ask git for the absolute form and handle nil.
function M.project_from_common_dir(common_dir)
  if type(common_dir) ~= "string" then
    return nil
  end
  local dir = common_dir:gsub("/+$", "")
  if not dir:match("^/") then
    return nil
  end
  local root = dir:match("^(.*)/[^/]+$")
  if root == nil then
    return nil
  end
  local name = root:match("([^/]+)$")
  if name == nil then
    return nil
  end
  return { root = root, name = name }
end

-- Path of the main worktree from a decoded `wt list --format=json`.
-- Accepts schema 2 (items[].worktree.path + items[].worktree.main) and the
-- legacy flat shape ([].path + [].is_main); nil when neither flags a main.
function M.main_worktree(list_json)
  if type(list_json) ~= "table" then
    return nil
  end
  local items = list_json.items or list_json
  if type(items) ~= "table" then
    return nil
  end
  for _, item in ipairs(items) do
    if type(item) == "table" then
      local path, is_main
      if type(item.worktree) == "table" then
        path, is_main = item.worktree.path, item.worktree.main
      else
        path, is_main = item.path, item.is_main
      end
      -- A literal true is what rex.json.decode gives for `"main": true`; the
      -- string form is read the same way, because a producer that quoted the
      -- flag would otherwise lose the main worktree and refuse the project.
      if (is_main == true or is_main == "true") and type(path) == "string" then
        return path
      end
    end
  end
  return nil
end

-- The session whose label is exactly the project's name. The label is the only
-- key: a session called pmm-iris-2 belongs to something else, and adopting it
-- would put the tab in the wrong place.
function M.session_for(sessions, project)
  for _, session in ipairs(type(sessions) == "table" and sessions or {}) do
    if type(session) == "table" and session.label == project
      and type(session.session_id) == "string" then
      return session.session_id
    end
  end
  return nil
end

-- The window labelled `label`, exactly: a tab is named after a branch, so a
-- near match is a different branch.
function M.find_tab(windows, label)
  for _, window in ipairs(type(windows) == "table" and windows or {}) do
    if type(window) == "table" and window.label == label
      and type(window.window_id) == "string" then
      return window.window_id
    end
  end
  return nil
end

-- A file beside this module, so new-work.sh is found wherever the plugin was
-- cloned to (normally ~/.config/rex/rex-config), nothing to configure.
local function beside_module(name)
  local source = (debug.getinfo(1, "S") or {}).source or ""
  local dir = source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+$")
  if dir == nil then
    return name
  end
  return dir .. "/" .. name
end

-- The settings setup() merges a caller's table into.
M.options = {
  agent = "pi",
  agent_args = {},
  -- The list the picker's agent question offers. Unset -- nil rather than left
  -- out, so it reads as a default -- means the one agent above. The picker
  -- always adds its own no-agent row after these, so "none" is never a name to
  -- configure.
  agents = nil,
  bead_prompt = "/brainstorming for bead {id}",
  no_bead_prompt = "/brainstorming",
  -- The base a new branch starts from when nobody answered for this tab. Unset
  -- -- nil rather than a value, so it reads as a default -- is auto-detect: the
  -- picker resolves the remote's own default branch and the cycle that opens on
  -- it. A string is that cycle's first entry, and false is "no revision at all"
  -- -- the field opens on nothing, no revision is passed, and the new workspace
  -- sits on main's working copy. Either way it is the create answer's base and no
  -- word of its own: the revision travels as one positional parameter, and only a
  -- create is given one (see new_tab_argv).
  base = nil,
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  script = beside_module("new-work.sh"),
}

-- The program the new tab runs, as fish (the tab gets it through `fish -c`,
-- see new_tab_argv below for the parameters). It exists because the pane has to
-- outlive the agent: switch to, attach or create the worktree, run the agent in
-- it, then leave a login shell there, so the hook output gws and worktrunk print
-- and the agent's own last lines stay readable above a prompt that works.
-- Exiting that shell closes the tab.
--
-- Every value the flow knows arrives as a positional parameter, so no branch,
-- base, agent name or prompt is ever written into this text: a branch with a
-- slash, a prompt with quotes and an agent name with a space each stay one
-- argument, because the shell hands them over as they were. The shell is fish
-- and not sh because gws is a fish function: a program on a PATH cannot be one.
M.new_tab_script = [==[
# $argv[1] = mode (switch, create or attach), $argv[2] = branch, $argv[3] = base
# (empty when there is none), then the agent and the arguments it is started
# with, the prompt last. The mode is the one thing the pane has to know before it
# runs anything, and it arrives as a word rather than a flag so that reading it
# is the same as reading the branch beside it. An empty agent is an answer -- the
# picker's "none" -- and the pane then goes straight to a login shell, with the
# prompt said out loud instead of dropped.

# A login shell is this program's last act, and every path below ends here: it
# is what keeps the pane alive once the agent is gone, with the output above it
# still readable, and exiting it is what closes the tab. A $SHELL naming a
# program that is not installed would leave the pane dead with exit 127, so the
# plain sh is the fallback.
function leave_shell
  if set -q SHELL; and test -n "$SHELL"; and command -q $SHELL
    exec $SHELL -l
  end
  exec /bin/sh -l
end

# What a caller is told when it does not know the contract: too few words before
# the agent, or a first word that is none of the three modes. One sentence, said
# from the two places that can learn it, so a caller that fixes one mistake is
# never answered in different words by the next.
set -l contract 'rex-config: the tab needs a mode, a branch and a base'

# The three words come before the agent, and they are read before they are used:
# the count here, and the mode word in the dispatch below. Reading them anyway
# would be harmless -- fish answers a missing word with nothing where sh's
# `shift` would end the shell -- but an empty branch would reach gws, and "could
# not enter ; not starting an agent" is a worse answer than naming the contract.
# The message names all three, so a caller that sends two learns about the
# third.
if test (count $argv) -lt 3
  printf '%s\n' $contract >&2
  leave_shell
end

set -l mode $argv[1]
set -l branch $argv[2]
set -l base $argv[3]
# An empty agent is a real answer, and the word after it may be absent
# entirely: `$argv[5..-1]` is the empty list then, so the agent below starts
# with nothing added.
set -l agent $argv[4]
set -l rest $argv[5..-1]

# gws and worktrunk both run the project's hooks, and a hook that talks to git
# in a pane nobody can type into must never stop on a credential prompt: it
# would hang there invisibly. So git's terminal prompt is off before either.
set -gx GIT_TERMINAL_PROMPT 0

# Named once so the messages below can name what is not started even when no
# agent was asked for: "not starting " is not a sentence.
set -l what "an agent"
if test -n "$agent"
  set what $agent
end

# The three modes are the three things a branch can want, and each is one
# program's:
#
#   switch  an existing worktree, which is worktrunk's: `wt switch --no-cd`
#           leaves this shell where it is, so the worktree's path is read from
#           the JSON reply rather than arrived at by changing directory.
#   create  a branch to make, which is gws's: jj has to make the workspace before
#           wt can see the branch, so gws runs `jj workspace add` (from the
#           wrapper's main workspace, fetching the revision first), attaches the
#           branch and runs the post-start hooks.
#   attach  a local branch with no worktree yet, which is also gws's: the
#           workspace is made for the branch that is already there, so nothing is
#           created from anything and no base is passed at all.
#
# A create and an attach are one program with two words, so they share the path
# file: this program cannot follow the cd gws ends with, so gws is handed a file
# and the new worktree's path is read out of it. The base is a revision, not a
# flag: it is only passed to a create, and only when there is one, since an empty
# word is a revision jj has no name for and a missing one means "start at main".
# To an attach it is never passed -- the branch exists, so it was not made from
# anything -- even when a caller sent one. gws and worktrunk say what they did on
# this pane themselves, so none of it is captured -- and gws does the fetching,
# which is why nothing here runs git at all.
#
# The worktree the answer named, and nothing else: the agent must never start in
# the wrong directory, so a create, attach or switch that failed -- and its own
# message is already on this pane -- or a path that cannot be read means the
# agent is not started at all. The path file is read and removed either way: it
# is this pane's litter, and an empty one is how "gws never wrote it" arrives
# here.
#
# The programs borrowed here are called through `command`, and the directory is
# entered with `builtin cd`. fish's function namespace belongs to the user: on
# this machine `rm` is a `trash` wrapper (so `rm -f` prints "Un-recognized
# argument -f" and leaves the file) and `cd` is a directory jumper that lands
# nowhere, so a plain `rm` or `cd` would put a line on every create and start the
# agent in the wrong place. The two exceptions are `gws` and `wt`, which are
# looked up as plain names because that is what they are: gws exists only as a
# fish function, and the user's `wt` is how worktrunk's shell integration gets
# in.
# wt_path and not path: fish keeps $path as a mirror of PATH, so a local with that
# name would shadow it -- harmless on the fish this was written against, a trap in
# a later one.
set -l wt_path
if test "$mode" = switch
  set -l listing (wt switch $branch --no-cd --format=json)
  # The substitution's status is the switch's own, captured before anything else
  # runs: a worktrunk that failed has already said why, on this pane's stderr.
  set -l switched $status
  if test $switched -eq 0
    set wt_path (printf '%s\n' $listing | command jq -r '.path // empty')
  end
  if test -z "$wt_path"
    # Two steps can leave no path: a switch that failed, whose own message is
    # already on this pane, or a switch that worked and a reply whose path cannot
    # be read (jq missing, or no path in it). Naming the step that went wrong is
    # the point of the line, so neither case says "no path (exit 0)".
    if test $switched -eq 0
      printf 'rex-config: could not read the worktree path of %s from the switch reply (jq missing, or no path in it); not starting %s\n' "$branch" "$what" >&2
    else
      printf 'rex-config: wt switch %s failed (exit %s); not starting %s\n' "$branch" "$switched" "$what" >&2
    end
    leave_shell
  end
else if test "$mode" = create -o "$mode" = attach
  set -l pf (command mktemp)
  # One gws, two words: an attach names the branch that is already there and is
  # given no base, and a create names the branch to make and the revision to make
  # it from when the picker answered one.
  if test "$mode" = attach
    gws --attach $branch --path-file $pf
  else if test -n "$base"
    gws $branch $base --path-file $pf
  else
    gws $branch --path-file $pf
  end
  # The command's own status, captured before anything else runs.
  set -l created $status
  if test $created -eq 0
    # the one line gws wrote, and not whatever else may have landed there
    set wt_path (command head -n 1 $pf)
  end
  command rm -f $pf
  if test $created -ne 0
    printf 'rex-config: gws %s failed (exit %s); not starting %s\n' "$branch" "$created" "$what" >&2
    leave_shell
  end
  if test -z "$wt_path"
    printf 'rex-config: could not read the worktree path of %s from the gws path file; not starting %s\n' "$branch" "$what" >&2
    leave_shell
  end
else
  # The first word is none of the three: a caller that does not know the
  # contract, or one still sending the old `1`/`0`. It is refused with the same
  # sentence too few words get, because it is the same mistake seen from the
  # other side -- and before either program runs, since guessing what worktrunk
  # or gws would make of the word happens on a pane nobody is watching.
  printf '%s\n' $contract >&2
  leave_shell
end

# A path that starts with a dash is a directory like any other, and fish's `cd`
# reads one as an option: unlike sh's it has no `--` to end them with, so the
# current-directory spelling is what keeps it a path. An absolute path, which is
# what gws and worktrunk report, is left alone -- and `builtin`, because a plain
# `cd` is the user's jumper (see above).
set -l dir (string replace -r '^-' './-' -- $wt_path)
builtin cd $dir
or begin
  printf 'rex-config: could not enter %s; not starting %s\n' "$wt_path" "$what" >&2
  leave_shell
end

# No agent was asked for: the pane is the worktree and a login shell. The
# prompt is the last word -- whatever else came with it belonged to an agent
# that is not running -- and it has nowhere to go now, so it is printed above
# the shell rather than disappearing with the float that collected it.
if test -z "$agent"
  set -l prompt
  if set -q rest[1]
    set prompt $rest[-1]
  end
  if test -n "$prompt"
    printf 'rex-config: no agent started; the prompt is:\n%s\n' "$prompt" >&2
  end
  leave_shell
end

# A ^C while the agent runs belongs to the agent: the terminal sends it to every
# process in the pane's group, so the agent dies (or handles it) -- and if this
# wrapper died with it there would be no shell left to hand over, which is the
# dead pane all over again. The wrapper therefore ignores INT for exactly the
# length of the agent's run: fish runs the empty handler below and carries on to
# the shell, while the agent -- a child of this shell, which gets the default
# disposition back -- still takes the signal. Outside this, INT is left alone:
# interrupting the create above (a hook approval prompt, say) still stops the
# wrapper as it did, so the window this handler opens is the agent's run and
# nothing more.
function rex_ignore_int --on-signal INT
end
$agent $rest
leave_shell
]==]

-- The command the new tab runs: that wrapper, with everything it needs as a
-- parameter --
--
--   fish -c SCRIPT <mode> <branch> <base> <agent> [agent_args...] <prompt>
--
-- because a parameter is the one way a branch, a base, a prompt or an agent
-- name reaches a shell without the shell parsing it as text. fish takes no $0
-- word, so there is nothing between the program and the first parameter: the
-- mode is already argv[4]. The prompt is the picker's own when it was
-- typed there, the bead's, or -- with neither -- the configured no-bead prompt.
-- An empty agent is the picker's "none": the wrapper starts nothing and hands
-- the pane to a login shell. An empty base is "no base revision at all", which
-- is what leaves gws to start the branch at main.
--
-- The prompt is not always there: a blank answer sends no prompt parameter at
-- all, so the argv ends after the agent and its arguments, and a prompt whose
-- first character is "-" travels with one leading space so the agent reads a
-- value rather than a flag.
function M.new_tab_argv(project, args)
  args = args or {}
  assert(type(args.branch) == "string" and args.branch ~= "",
    "new_tab_argv: a branch is required")
  -- The configured default is a program that has to exist: nobody may set an
  -- empty agent in a configuration file and quietly get no agent at all. A
  -- payload may answer none, and that is the only way to say it.
  assert(type(M.options.agent) == "string" and M.options.agent ~= "",
    "new_tab_argv: an agent is required")
  local agent = M.options.agent
  if type(args.agent) == "string" then
    agent = args.agent
  end
  local prompt = ""
  if type(args.prompt) == "string" and args.prompt ~= "" then
    -- What was typed at the picker beats both templates: it is an answer, where
    -- they are what the plugin says when nobody said anything.
    prompt = args.prompt
  elseif agent ~= "" then
    -- The templates are a prompt for an agent that is about to start, so with
    -- no agent there is nothing to deliver and nothing to say: the wrapper only
    -- prints a prompt the user really typed above the shell it leaves.
    if type(args.bead) == "string" and args.bead ~= "" then
      prompt = M.render_prompt(M.options.bead_prompt, {
        id = args.bead,
        title = args.title,
        branch = args.branch,
        project = project,
      })
    else
      prompt = M.options.no_bead_prompt
    end
  end

  -- What the pane has to do with the branch, as one word: switch to the worktree
  -- that already has it, create the branch, or attach a worktree to the local
  -- branch that has not got one. The picker decides it, from the two branch lists
  -- it already reads, and sends it as `worktree`; nothing here re-derives it, so
  -- the word the picker chose is the word the wrapper acts on.
  --
  -- A payload from before the mode existed says it with the boolean it used to
  -- have: `create = true` is a branch to make, and no `create` at all is the
  -- switch it always was. That is the whole of the fallback -- an absent
  -- `worktree` is never read as create -- so a hand-run `rex do` and a line
  -- copied out of an old dry run both keep doing what they said. An empty string
  -- is no word either: it says nothing, so it falls back like a field that was
  -- never sent.
  --
  -- Any other word is refused here, beside the branch and the agent: the wrapper
  -- would answer it with its contract line and start nothing, and a tab with
  -- nothing in it is a worse answer than a refusal the caller can read.
  local mode = "switch"
  if type(args.worktree) == "string" and args.worktree ~= "" then
    mode = args.worktree
    assert(mode == "switch" or mode == "create" or mode == "attach",
      'new_tab_argv: the mode is switch, create or attach, not "' .. mode .. '"')
  elseif args.create == true then
    mode = "create"
  end

  -- The base a new branch starts from. The picker resolves it -- no ref is read
  -- here -- so this only carries the answer, and it is three-valued: a string is
  -- the revision to create from, false is the picker's "start from nothing" (and
  -- travels as the empty parameter, which is gws's own default), and absent
  -- means the picker never answered -- a hand-run `rex do` -- so the configured
  -- base is the fallback. The remote a base lives on is part of the revision's
  -- own name (`main@origin`), so there is no word of its own for it.
  --
  -- Only a create is given one. A switch and an attach name a branch that already
  -- exists, so there is nothing to start it from: the word is empty whatever the
  -- payload or the configuration said, because a base reaching the tab for either
  -- of them is an answer to a question neither asked.
  local base = ""
  if mode == "create" then
    if type(args.base) == "string" then
      base = args.base
    elseif args.base == nil and type(M.options.base) == "string" then
      base = M.options.base
    end
  end

  local argv = {
    "fish", "-c", M.new_tab_script,
    mode,
    args.branch,
    base,
    agent,
  }
  -- An agent's arguments are the agent's, so they travel only when one starts.
  if agent ~= "" then
    for _, arg in ipairs(M.options.agent_args or {}) do
      argv[#argv + 1] = arg
    end
  end
  -- A blank answer is "an agent, and nothing to say": no prompt word at all,
  -- not an empty one, so the argv ends after the agent and its arguments and
  -- the templates above do not get to fill the place. That is how blank stays
  -- distinct from "the picker was never asked", where the template speaks.
  if args.blank == true then
    return argv
  end
  -- A prompt whose first character is "-" would be read by the agent as a flag.
  -- Nothing stops a person typing one, so exactly one space goes in front: one,
  -- because the prompt is still meant to read as what was typed, and here, in
  -- the builder that owns the argument contract, rather than in the wrapper
  -- whose whole job is to exec what it was handed.
  if prompt:sub(1, 1) == "-" then
    prompt = " " .. prompt
  end
  argv[#argv + 1] = prompt
  return argv
end

local OPTION_NAMES = { "agent", "agent_args", "agents", "bead_prompt", "no_bead_prompt", "base", "bounds", "script" }
local KNOWN_OPTION = {}
for _, name in ipairs(OPTION_NAMES) do
  KNOWN_OPTION[name] = true
end

-- Rex runs an action with its own PATH -- /usr/bin:/bin:/usr/sbin:/sbin on this
-- Mac -- which knows nothing of mise or Homebrew installs, while the design puts
-- fish, wt, jq, jj and bd on the login shell's PATH. wt and bd therefore run in
-- that shell, which is also where mise keeps the environment its shims need.
-- The new tab is a fish program for the same reason: gws exists only as a fish
-- function, so the flow has to reach it from fish -- which is also what the
-- picker's own check asks for (`fish -c 'functions -q gws'`). Nothing is
-- interpolated into the command text: a directory travels as rex.exec's cwd
-- option, never inside the command.
local function login_shell()
  local shell = os and os.getenv and os.getenv("SHELL")
  if type(shell) ~= "string" or shell == "" then
    return "/bin/sh"
  end
  return shell
end

-- Run argv, in cwd when one is given, and return rex.exec's reply: ok, code,
-- stdout and stderr. nil comes back instead, with the reason, when the program
-- could not be started at all, as when it is not on PATH.
local function run(argv, cwd)
  local options = {}
  if cwd ~= nil then
    options.cwd = cwd
  end
  local ok, reply, reason = pcall(rex.exec, argv, options)
  if not ok then
    return nil, tostring(reply)
  end
  if reply == nil then
    return nil, tostring(reason)
  end
  return reply
end

-- The same for a tool that lives on the login shell's PATH rather than Rex's.
local function run_in_shell(command, cwd)
  return run({ login_shell(), "-lc", command }, cwd)
end

-- The first line of a program's error output, for a one-line refusal.
local function first_line(text)
  local line = tostring(text or ""):match("^([^\n]*)") or ""
  if line == "" then
    return "no error output"
  end
  return (line:gsub("\r$", ""))
end

-- rex.call answers a request that failed with nil and a message rather than by
-- raising, the way rex.exec does, so this turns both that and a raise into the
-- same two values. The method names are the ones `rex api ls` lists, and the
-- server's own methods only answer a connection attached to the session.
local function call(method, request)
  local called, reply, reason = pcall(rex.call, method, request)
  if not called then
    return nil, tostring(reply)
  end
  if reply == nil then
    return nil, tostring(reason)
  end
  return reply
end

-- The project a directory belongs to: its root and name from git's common
-- directory, and the main worktree from worktrunk. Returns nil and a message
-- naming the reason when the directory is not in a repository this can use.
function M.project_for(cwd)
  local git, git_reason = run({ "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if git == nil then
    return nil, "git could not be run: " .. tostring(git_reason)
  end
  if git.code ~= 0 then
    return nil, "not a git repository: " .. cwd
  end

  -- Only the absolute form names a project: the plain one prints ".git", which
  -- project_from_common_dir refuses rather than turn into empty strings.
  local common_dir = (git.stdout or ""):gsub("%s+$", "")
  local project = M.project_from_common_dir(common_dir)
  if project == nil then
    return nil, "could not resolve the project root of " .. cwd
  end

  local listed, list_reason = run_in_shell("wt list --format=json", project.root)
  if listed == nil or listed.code ~= 0 then
    return nil, "worktrunk could not list worktrees for " .. project.root .. ": "
      .. first_line(listed and listed.stderr or list_reason)
  end

  -- main_worktree reads the decoded document, not raw text: raw JSON is never a
  -- table. rex.json.decode reports bad text by returning nil and a reason rather
  -- than raising, so the value decides -- and what it is, when it is not an
  -- object, is what the message names.
  local decoded, decode_reason = rex.json.decode(listed.stdout or "")
  if type(decoded) ~= "table" then
    local why
    if decode_reason ~= nil then
      why = tostring(decode_reason)
    else
      why = "the listing decoded to a " .. type(decoded) .. ", not an object"
    end
    return nil, "could not read the worktrunk listing for " .. project.root .. ": " .. why
  end
  local main = M.main_worktree(decoded)
  if main == nil then
    return nil, "no main worktree found for " .. project.root
  end

  return { root = project.root, name = project.name, main = main }
end

-- bd's own way of saying a directory has no database. A failure that says
-- something else is a different problem -- a shim that cannot find its program, a
-- locked database -- and calling that "no database" would be a lie.
local NO_DATABASE = "no beads database"

-- Whether the project has a beads database, asked from the main worktree: in
-- the worktrunk layout the root holds only .git, and main/.beads/redirect is
-- what resolves the database.
--
-- Returns true, or false and the reason bd gave: nil when bd ran and reported no
-- database itself, and a message when bd could not be started or failed.
function M.has_beads(main)
  local reply, reason = run_in_shell("bd ready --json", main)
  if reply == nil then
    return false, "bd could not be run in " .. main .. ": " .. tostring(reason)
  end
  if reply.code == 0 then
    return true
  end
  local said = first_line(reply.stderr)
  if said:lower():find(NO_DATABASE, 1, true) ~= nil then
    return false
  end
  -- bd ran and failed for a reason of its own; "could not be run" is for the
  -- reply == nil case above, where there was no bd to ask.
  return false, "bd failed in " .. main .. ": " .. said
end

-- What a tab is still running, so a teardown never closes on somebody's work: a
-- shell is what a tab idles at, and every other name -- and every name Rex cannot
-- produce -- is a program. The names are compared after program_basename, because
-- a login shell shows itself as `-fish` and a reply may carry a whole path.
local SHELLS = { fish = true, zsh = true, bash = true, sh = true, nu = true }

-- A program's name without its directory or the leading dash of a login shell.
function M.program_basename(name)
  local base = tostring(name or ""):match("([^/]+)$") or ""
  return (base:gsub("^%-", ""))
end

-- The program a process reply belongs to. An interpreter reports the script it
-- runs beside its own name, and the script is the program; a login shell's argv0
-- is the one name that still has the dash program_basename strips; and the
-- system's own name is the last resort. Both slots are read because Rex answers
-- with whichever process it could name -- the foreground first, the child when
-- the foreground is gone -- and a reply with neither names nothing at all.
function M.process_program(process)
  if type(process) ~= "table" then
    return ""
  end
  for _, slot in ipairs({ "foreground", "child" }) do
    local running = process[slot]
    if type(running) == "table" then
      for _, key in ipairs({ "script", "argv0", "name" }) do
        local name = running[key]
        if type(name) == "string" and name ~= "" then
          return M.program_basename(name)
        end
      end
    end
  end
  return ""
end

-- Whether a name is one of the shells a tab idles at.
function M.is_shell(name)
  return SHELLS[M.program_basename(name)] == true
end

-- Every block in a window: each layer's, and a window that lists its own. Rex's
-- window view puts blocks in layers, but a window handed over without them is
-- read rather than counted empty -- an empty list would let a teardown proceed.
function M.window_blocks(window)
  local blocks = {}
  if type(window) ~= "table" then
    return blocks
  end
  for _, block in ipairs(type(window.blocks) == "table" and window.blocks or {}) do
    blocks[#blocks + 1] = block
  end
  for _, layer in ipairs(type(window.layers) == "table" and window.layers or {}) do
    for _, block in ipairs(type(layer.blocks) == "table" and layer.blocks or {}) do
      blocks[#blocks + 1] = block
    end
  end
  return blocks
end

-- The window holding a block, or nil when no window does.
function M.window_of_block(windows, block_id)
  for _, window in ipairs(type(windows) == "table" and windows or {}) do
    for _, block in ipairs(M.window_blocks(window)) do
      if type(block) == "table" and block.block_id == block_id then
        return window
      end
    end
  end
  return nil
end

-- The working directory of the terminal behind ctx's block, or nil when Rex
-- cannot say: the foreground process first, since that is where the user
-- really is, then the shell the terminal started.
local function block_cwd(ctx)
  local called, process = pcall(rex.block.call, "com.superlogical.terminal", "process", {
    session_id = ctx.session_id,
    block_id = ctx.block_id,
  })
  if not called or type(process) ~= "table" then
    return nil
  end
  local foreground = process.foreground
  if type(foreground) == "table" and type(foreground.cwd) == "string" and foreground.cwd ~= "" then
    return foreground.cwd
  end
  local child = process.child
  if type(child) == "table" and type(child.cwd) == "string" and child.cwd ~= "" then
    return child.cwd
  end
  return nil
end

-- The picker this client opened last, so a second press replaces it instead of
-- stacking another float on top.
local picker = {}

local function close_picker()
  if picker.layer_id == nil then
    return
  end
  pcall(rex.session.close_layer, { session_id = picker.session_id, layer_id = picker.layer_id })
  picker.session_id, picker.layer_id = nil, nil
end

-- The agent names the picker's agent question offers, in the order it offers
-- them: the first is the one an unasked question takes. Unset means the one
-- configured agent, so a configuration that names no list still gets the
-- question -- the agent, or none -- rather than no question at all.
local function agent_choices()
  local agents = M.options.agents
  if type(agents) ~= "table" or #agents == 0 then
    return { M.options.agent }
  end
  return agents
end

-- argv for new-work.sh's picker, every word of it built here and nowhere else.
-- base = false means "let worktrunk choose", so there is no ref to pass on --
-- but the picker still has to be told, because a picker told nothing resolves
-- the remote's default branch itself and the screen would open on a base the
-- configuration opted out of. So false is --no-base: the cycle opens on the
-- worktrunk-default sentinel, and ctrl-r can still move off it.
local function picker_command(project)
  local command = {
    M.options.script, "pick",
    "--main", project.main,
    "--root", project.root,
    "--project", project.name,
  }
  if M.options.base == false then
    command[#command + 1] = "--no-base"
  elseif M.options.base ~= nil then
    command[#command + 1] = "--base"
    command[#command + 1] = M.options.base
  end
  -- The agent names are handed over only where the screen has a field to cycle
  -- them in: the picker seeds its header from the first, ctrl-a walks the rest and
  -- then none, and a list is the whole of what it needs to do that.
  for _, name in ipairs(agent_choices()) do
    if name ~= "" then
      command[#command + 1] = "--agents"
      command[#command + 1] = name
    end
  end
  return command
end

-- Open the picker in a floating terminal and return at once: a key-bound
-- action cannot wait for input, so the float asks the questions and hands its
-- answer back with `rex do work_new_go`.
local function open_picker(ctx, project)
  close_picker()
  local called, layer, reason = pcall(rex.session.new_layer, {
    session_id = ctx.session_id,
    bounds = M.options.bounds,
    focus = true,
    layout = {
      block = {
        flavor = "com.superlogical.terminal.shell",
        label = "new work",
        options = { command = picker_command(project), cwd = project.main },
      },
    },
  })
  if not called then
    error("could not open the picker: " .. tostring(layer), 0)
  end
  if type(layer) ~= "table" then
    error("could not open the picker: " .. tostring(reason), 0)
  end
  picker.session_id, picker.layer_id = ctx.session_id, layer.layer_id
  return { layer_id = layer.layer_id }
end

-- Action work_new: from the terminal's directory to the picker. Every reason
-- the flow cannot start is refused here, naming what stands in the way, so
-- nothing opens for a directory that would only fail later.
function M.work_new(ctx)
  ctx = ctx or {}
  local cwd = block_cwd(ctx)
  if cwd == nil then
    error("cannot tell which directory this terminal is in", 0)
  end
  local project, reason = M.project_for(cwd)
  if project == nil then
    error(reason, 0)
  end
  local beads, beads_reason = M.has_beads(project.main)
  if not beads then
    if beads_reason ~= nil then
      error(beads_reason, 0)
    end
    error("beads is required, but no beads database was found in " .. project.main, 0)
  end
  return open_picker(ctx, project)
end

-- Attach to the target session, because a session method only reaches a session
-- the connection is attached to: the app is attached to the session it shows,
-- which is not necessarily the project's, so without this session.new_window
-- below -- the call that makes the tab -- fails with "stream is not attached to
-- session". An attach adds to the attachments a connection already has, so it
-- takes nothing away from the session the user is looking at, and it stays for as
-- long as the connection does: nothing here detaches.
--
-- The reply carries the session's view, so this is where the tabs that already
-- exist are read too, which is what keeps a second press from making a second
-- tab. Returns the windows, or nil and the reason it could not attach.
local function attach_session(session_id)
  local attached, reason = call("session.attach", { session_id = session_id })
  if attached == nil then
    return nil, reason
  end
  -- No view means no list of tabs, and "no list of tabs" is not "no tabs": read
  -- as one it would make another tab, and take another claim, for a branch that
  -- already has one. So this is refused rather than guessed at.
  if type(attached) ~= "table" or type(attached.view) ~= "table" then
    return nil, "session.attach returned no view, so there is no list of tabs"
  end
  -- A view without windows is a session with none: the server leaves an empty
  -- list out (measured: a session created with no windows answers attach with
  -- label, revision and session_id only), so this is where the first tab comes
  -- from. A windows field that is there and is not a list is a third thing -- a
  -- shape this cannot read -- so it is refused by name rather than counted as
  -- an empty session: otherwise every press would make another tab and another
  -- claim.
  local windows = attached.view.windows
  if windows == nil then
    return {}
  end
  if type(windows) ~= "table" then
    return nil, "session.attach returned a view whose windows are a " .. type(windows)
      .. ", so there is no list of tabs"
  end
  return windows
end

-- The tab ctx's own terminal sits in, from the session's own view: the window
-- holding ctx's block. A tab that cannot be found is refused with a reason rather
-- than answered with nothing, because "no tab" would read as "nothing to stop".
function M.tab_window(ctx)
  local windows, reason = attach_session(ctx.session_id)
  if windows == nil then
    return nil, reason
  end
  local window = M.window_of_block(windows, ctx.block_id)
  if window == nil then
    return nil, "cannot tell which tab this terminal is in"
  end
  return window
end

-- The programs a tab is running that are not shells, in block order. A block
-- Rex cannot read counts as one: a wrong pass here kills somebody's agent, so
-- the only safe reading of "cannot tell" is "still running".
function M.tab_processes(ctx, window)
  local names = {}
  for _, block in ipairs(M.window_blocks(window)) do
    local called, process = pcall(rex.block.call, "com.superlogical.terminal", "process", {
      session_id = ctx.session_id,
      block_id = block.block_id,
    })
    local name = ""
    if called and type(process) == "table" then
      name = M.process_program(process)
    end
    if name == "" then
      name = "a program Rex could not name"
    end
    if not M.is_shell(name) then
      names[#names + 1] = name
    end
  end
  return names
end

-- The project's session, made when it is not there yet with one tab called
-- main in the main worktree: that is the convention the rest of the flow
-- assumes, so a project opened here for the first time starts out right.
local function session_to_use(project, main)
  local listed, list_reason = call("session.list")
  if listed == nil then
    return nil, "could not list Rex's sessions: " .. list_reason
  end
  local found = M.session_for(listed.sessions, project)
  if found ~= nil then
    return found
  end
  local created, create_reason = call("session.create", {
    label = project,
    initial_windows = {
      {
        window_label = "main",
        layout = rex.layout.block{
          flavor = "com.superlogical.terminal.shell",
          label = "main",
          options = { cwd = main },
        },
      },
    },
  })
  if created == nil then
    return nil, "could not create the " .. project .. " session: " .. create_reason
  end
  return created.session_id
end

-- The one thing from the hand-back that travels inside a command line is the
-- bead id, so it is checked against the shape bd's ids have before it goes in.
local BEAD_ID = "^[%w][%w%._%-]*$"

-- Claim the bead, from the main worktree, which is where the database is
-- reachable. nil means it is claimed; a message says why it is not.
local function claim_bead(bead, main)
  if bead:match(BEAD_ID) == nil then
    return "not a bead id: " .. bead
  end
  local reply, reason = run_in_shell("bd update " .. bead .. " --claim", main)
  if reply == nil then
    return "could not claim " .. bead .. ": " .. tostring(reason)
  end
  if reply.code ~= 0 then
    return "could not claim " .. bead .. ": " .. first_line(reply.stderr)
  end
  return nil
end

-- Show the session, and the tab in it. Rex runs an action from a key or the
-- palette itself, so a queued client action is accepted there; a hand-back
-- from `rex do` has no invocation to queue against, so the app's clients are
-- asked directly instead, which needs Remote Control on. nil means shown.
local function show_session(ctx, session_id, window_id)
  local origin = ctx.origin
  local args = { session_id = session_id }
  if window_id ~= nil then
    args.window_id = window_id
  end
  if origin == "key" or origin == "palette" then
    -- The closure, not the call's arguments: rex.client may be missing entirely,
    -- and that lookup is what has to be caught.
    local queued, reason = pcall(function()
      return rex.client.queue("session.select", args)
    end)
    if not queued then
      return tostring(reason)
    end
    return nil
  end

  local listed, list_reason = call("client.list", { kinds = { "app" } })
  if listed == nil then
    return list_reason
  end
  local clients = type(listed.clients) == "table" and listed.clients or {}
  if #clients == 0 then
    return "no app client is connected"
  end
  local said = {}
  for _, client in ipairs(clients) do
    local request = { client_id = client.client_id, action = "session.select", args = args }
    if type(origin) == "string" and origin ~= "" then
      request.origin = origin
    end
    local performed, reason = call("client.perform", request)
    if performed ~= nil then
      return nil
    end
    said[#said + 1] = tostring(reason)
  end
  return table.concat(said, "; ")
end

-- Action work_new_go: the picker's hand-back. It already holds the whole
-- answer, so this only has to start the work: the project's session, the tab
-- named after the branch, the claim, and the switch inside the tab. The
-- payload's root is the project's root rather than a place anything runs in, so
-- the tab and every bd call use the main worktree that came with them.
function M.work_new_go(ctx, args)
  ctx, args = ctx or {}, args or {}

  -- The hand-back is the only source of these, so one that is missing is
  -- refused before anything is made.
  for _, name in ipairs({ "project", "root", "main", "branch" }) do
    local value = args[name]
    if type(value) ~= "string" or value == "" then
      error("the picker's answer has no " .. name, 0)
    end
  end

  -- Rex reads the paths against its own working directory rather than the
  -- picker's, so a relative one would make the tab somewhere else entirely, and
  -- fail there with nothing on screen to explain it. new-work.sh refuses them
  -- for a picker run; this action is also a public `rex do` entry point, so it
  -- checks for itself.
  for _, name in ipairs({ "root", "main" }) do
    if args[name]:sub(1, 1) ~= "/" then
      error("the picker's answer has a relative " .. name .. ": " .. args[name], 0)
    end
  end

  local project, main, branch = args.project, args.main, args.branch

  local session, session_reason = session_to_use(project, main)
  if session == nil then
    error(session_reason, 0)
  end
  local windows, attach_reason = attach_session(session)
  if windows == nil then
    error("could not attach to the " .. project .. " session: " .. attach_reason, 0)
  end

  -- A second press for the same branch finds its tab here: one tab, one worktree
  -- and one claim, whatever the picker was asked.
  local existing = M.find_tab(windows, branch)
  if existing ~= nil then
    local show_reason = show_session(ctx, session, existing)
    if show_reason ~= nil then
      error("could not show " .. branch .. ": " .. show_reason, 0)
    end
    return { window_id = existing, created = false }
  end

  -- The bead is claimed before the tab exists, so an agent never starts on a
  -- bead that is not its own: a claim that fails leaves nothing behind.
  local bead = args.bead
  if type(bead) == "string" and bead ~= "" then
    local claim_reason = claim_bead(bead, main)
    if claim_reason ~= nil then
      error(claim_reason, 0)
    end
  end

  local created, create_reason = call("session.new_window", {
    session_id = session,
    window_label = branch,
    layout = rex.layout.block{
      flavor = "com.superlogical.terminal.shell",
      label = branch,
      options = {
        cwd = main,
        command = M.new_tab_argv(project, args),
        -- Nothing keeps the pane open: the command it runs ends in a login
        -- shell, so the pane lives as long as that shell does and the tab closes
        -- when the user leaves it. A kept-open pane with no program in it is
        -- exactly the dead tab this wrapper replaces.
      },
    },
  })
  if created == nil then
    -- The claim was taken before the tab, so this is the one failure that can
    -- leave a bead in progress with nothing working on it. Saying how to give
    -- it back is the remedy; without it the bead would have to be found and
    -- released by hand. `bd unclaim` is bd's own word for exactly that, with no
    -- quoting to mistype.
    local release = ""
    if type(args.bead) == "string" and args.bead ~= "" then
      release = "; the bead is still claimed, so release it with: bd unclaim " .. args.bead
    end
    error("could not make the " .. branch .. " tab in the " .. project .. " session: "
      .. create_reason .. release, 0)
  end

  -- The tab exists from here on: failing to show it is reported, and the tab
  -- is left where the user can still reach it.
  local show_reason = show_session(ctx, session, created.window_id)
  if show_reason ~= nil then
    error("the " .. branch .. " tab was created, but Rex could not show it: " .. show_reason, 0)
  end
  return { window_id = created.window_id, created = true }
end

-- Options from the configuration file, then the two actions. run takes the
-- action's context, and for work_new_go the hand-back payload as a second
-- argument.
local actions_registered = false

function M.setup(opts)
  -- Two passes: what cannot be used is refused before anything is applied, so a
  -- table with one bad value leaves the options as they were rather than half
  -- set, which assigning as pairs() walks the table would do.
  for key, value in pairs(opts or {}) do
    -- agent_args is spread into the tab's argv, so a string here is one step
    -- from an ipairs over a non-table: refused by name.
    if key == "agent_args" and type(value) ~= "table" then
      error(string.format(
        'rex-config: agent_args must be a list of arguments, not a %s', type(value)), 0)
    end
    -- agents reaches the picker as one --agents per name, so a string here is
    -- the same mistake in a different shape, and a name that is not a string
    -- would reach the float as nothing at all.
    if key == "agents" then
      if type(value) ~= "table" then
        error(string.format(
          'rex-config: agents must be a list of agent names, not a %s', type(value)), 0)
      end
      for _, name in ipairs(value) do
        if type(name) ~= "string" or name == "" then
          error('rex-config: agents must be a list of agent names, so each one is a non-empty string', 0)
        end
      end
    end
  end

  for key, value in pairs(opts or {}) do
    if KNOWN_OPTION[key] then
      M.options[key] = value
    else
      rex.log("warn", string.format('rex-config: unknown option "%s" ignored; options are %s',
        tostring(key), table.concat(OPTION_NAMES, ", ")))
    end
  end

  -- Registering twice would only warn about replacing an action, so a second
  -- setup{} keeps its options and leaves the actions alone.
  if actions_registered then
    return M
  end

  rex.action{
    name = "work_new",
    title = "New work: from a bead…",
    category = "New work",
    run = function(ctx)
      return M.work_new(ctx)
    end,
  }
  rex.action{
    name = "work_new_go",
    title = "New work: start the branch the picker chose",
    category = "New work",
    -- This Rex build refuses a *named* undeclared pair -- `rex do work_new_go
    -- blank=true` is rejected outright without the declaration -- while an
    -- `--args` object reaches the action whole, undeclared fields and all. The
    -- picker hands back exactly these pairs, so every one of them is declared
    -- here: the declaration is what the named path is checked against, and no
    -- pair the picker sends is left to depend on which path a caller took.
    args = {
      type = "object",
      properties = {
        project = { type = "string" },
        root = { type = "string" },
        main = { type = "string" },
        branch = { type = "string" },
        -- The agent the picker chose -- an empty string is its "none" -- and the
        -- prompt the user typed there, when they typed one.
        agent = { type = "string" },
        prompt = { type = "string" },
        bead = { type = "string" },
        title = { type = "string" },
        -- What the tab does with the branch, as one word: switch to the
        -- worktree that already has it, create the branch, or attach a worktree
        -- to the local branch that has none. A string, because it is read as a
        -- word -- and because the old boolean was the wrong shape for three
        -- answers. A payload from before the mode existed carries no `worktree`
        -- and says `create = true` instead; new_tab_argv still reads that.
        worktree = { type = "string" },
        -- The jj revision the new workspace is started from: a string is the
        -- revision, false is "no revision at all" (no -r, so the workspace sits
        -- on main's working copy), and absent means the picker never answered --
        -- so both types are declared: a `string` alone would call the picker's
        -- sentinel an illegal value, and a validator that took that at its word
        -- would drop it and let a configured base speak instead. There is no
        -- second field for where the base comes from: a revision carries its
        -- remote in its own @remote suffix, and two carriers could disagree.
        base = { type = { "string", "boolean" } },
        -- ctrl-n: an agent, and nothing to say. Not a prompt and not the
        -- configured template, so a payload without it keeps the template.
        blank = { type = "boolean" },
      },
      required = { "project", "root", "main", "branch" },
    },
    run = function(ctx, args)
      return M.work_new_go(ctx, args)
    end,
  }
  -- Set only once both are in, so a registration Rex rejects leaves the flag
  -- alone and a retry registers again.
  actions_registered = true

  return M
end

return M
