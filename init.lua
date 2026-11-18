-- rex-config: start new work from a bead (ctrl+space>n).
--
-- This module is loaded by the stock `lua` interpreter in the tests as well as
-- by Rex, so nothing at load time may touch the `rex` global (or any other
-- global). Pure helpers live at the top; the Rex-facing setup() and actions
-- call rex.* only inside their function bodies.
--
-- The flow asks its six questions with rex.ui.input and rex.ui.pick, which
-- pause the action's run until they are answered. That only works inside a
-- run: never under pcall, never at a script's top level. So the entry point is
-- the action, and rex do -e cannot drive it.
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

-- new-work.sh's rows, split into fields. Every verb that prints rows prints
-- them tab-separated, one row per line, and no field carries a tab of its own:
-- the script flattens what it reads. An empty line is nothing at all, which is
-- what an empty listing prints.
function M.parse_rows(text)
  local rows = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", "")
    if line ~= "" then
      local fields = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        fields[#fields + 1] = field
      end
      rows[#rows + 1] = fields
    end
  end
  return rows
end

-- `new-work.sh beads` rows as records: the id, the title, the issue type and
-- the priority. The priority is empty for a bead bd gave none to.
function M.bead_rows(text)
  local rows = {}
  for _, fields in ipairs(M.parse_rows(text)) do
    rows[#rows + 1] = {
      id = fields[1] or "",
      title = fields[2] or "",
      issue_type = fields[3] or "",
      priority = fields[4] or "",
    }
  end
  return rows
end

-- `new-work.sh bases` rows as records: the ref -- empty for worktrunk's own
-- default -- and the remote that ref lives on, empty when it is local.
function M.base_rows(text)
  local rows = {}
  for _, fields in ipairs(M.parse_rows(text)) do
    rows[#rows + 1] = { ref = fields[1] or "", remote = fields[2] or "" }
  end
  return rows
end

-- The rows that are answers rather than data, so their ids can never collide
-- with one: a NUL is not a character a bead id, a branch or an agent name can
-- hold. (This is the trick rex-projects uses for its "new worktree" rows.)
M.NO_BEAD = "\0none"
M.NO_AGENT = "\0none"
M.WT_DEFAULT = "\0default"

-- The icon a bead's row carries, by issue type: names the app's picker knows.
local BEAD_ICON = {
  epic = "package", feature = "star", bug = "branch", chore = "gear",
  spike = "code", decision = "tag",
}

-- The bead question's items: one per ready bead, then the row that says the
-- flow can go on with a branch and an agent and no bead. With nothing ready the
-- list is that row alone -- the pick still opens, because a branch and an agent
-- is work this can start -- and M.bead_question_title says why.
function M.bead_items(rows)
  local items = {}
  for _, row in ipairs(rows or {}) do
    local item = {
      id = row.id,
      title = row.title,
      subtitle = row.id .. (row.issue_type ~= "" and (" · " .. row.issue_type) or ""),
      icon = BEAD_ICON[row.issue_type] or "document",
    }
    -- A missing priority is not P0 and not a rank of its own: it is nothing to
    -- say, so the detail line stays empty rather than inventing one.
    if row.priority ~= "" then
      item.detail = "P" .. row.priority
    end
    items[#items + 1] = item
  end
  items[#items + 1] = {
    id = M.NO_BEAD,
    title = "No bead: a branch and an agent only",
    icon = "plus",
  }
  return items
end

-- What the bead question is called. The one row a project with nothing ready
-- has is the no-bead row, so the title is where the empty listing is said out
-- loud -- the pick cannot say it any other way.
function M.bead_question_title(project, rows)
  if #(rows or {}) == 0 then
    return "no ready beads in " .. tostring(project)
  end
  return "Bead for " .. tostring(project)
end

-- The base question's items, in new-work.sh's order: the first row is the
-- answer the question opens on. An empty ref is worktrunk choosing the base
-- itself, which is a real answer and not a missing one.
function M.base_items(rows)
  local items = {}
  for _, row in ipairs(rows or {}) do
    local default = row.ref == ""
    items[#items + 1] = {
      id = default and M.WT_DEFAULT or row.ref,
      title = default and "worktrunk's default" or row.ref,
      subtitle = row.remote ~= "" and ("on " .. row.remote) or "",
      icon = default and "gear" or "branch",
    }
  end
  return items
end

-- What the row that starts no agent is called. It is the value the remembered
-- "none" arrives as, so the two can never drift apart.
local NO_AGENT_TITLE = "(none)"

-- The agent question's items: the configured names in order, then the row that
-- starts none. A configured name may not be empty (setup refuses one), so the
-- row that starts nothing is the only empty answer there is.
function M.agent_items(names)
  local items = {}
  for _, name in ipairs(names or {}) do
    if name ~= "" then
      items[#items + 1] = { id = name, title = name, icon = "gear" }
    end
  end
  items[#items + 1] = {
    id = M.NO_AGENT,
    title = NO_AGENT_TITLE,
    subtitle = "a worktree and a shell, no agent",
    icon = "terminal",
  }
  return items
end

-- The word lists a branch with no bead is named from, so the name reads as a
-- name rather than as a number: feat/quiet-otter. Two dozen of each is plenty:
-- the name is a placeholder to type over.
local BRANCH_ADJECTIVES = {
  "amber", "bold", "brave", "bright", "calm", "clever", "crisp", "eager",
  "faint", "gentle", "grand", "hollow", "keen", "lucky", "mellow", "nimble",
  "plain", "quiet", "rapid", "sharp", "silent", "steady", "vivid", "warm",
}
local BRANCH_NOUNS = {
  "badger", "beacon", "cedar", "comet", "crane", "delta", "ember", "falcon",
  "ferry", "glade", "harbor", "heron", "lantern", "linnet", "marlin", "meadow",
  "otter", "pebble", "pilot", "quartz", "sparrow", "summit", "thistle", "willow",
}

local random_seeded = false

-- A branch name for a flow with no bead to take one from. PICK is how a test
-- makes it predictable: handed a list length it returns an index into it. The
-- generator is seeded once, on first use, so two presses in the same second
-- still get one name each.
function M.random_branch_name(pick)
  if pick == nil then
    if not random_seeded then
      random_seeded = true
      if math.randomseed ~= nil and os ~= nil and os.time ~= nil then
        math.randomseed(os.time())
      end
    end
    pick = math.random
  end
  return "feat/" .. BRANCH_ADJECTIVES[pick(#BRANCH_ADJECTIVES)] .. "-"
    .. BRANCH_NOUNS[pick(#BRANCH_NOUNS)]
end

-- The directory name worktrunk derives from a branch -- the rule its
-- worktree-path template applies: a branch is not a path, so every separator
-- becomes a dash. It is what the worktree question opens on.
function M.sanitize_branch(branch)
  return (tostring(branch or ""):gsub("[/\\:]", "-"))
end

-- Why this is not a worktree name, or nil when it is one. A name travels as
-- `--path ../<name>` from the main worktree, so it is a directory name and
-- nothing else: a separator would put the worktree where nobody named, and "."
-- or ".." would put it on top of an existing directory.
function M.worktree_problem(name)
  if name:find("[/\\]") ~= nil then
    return "a worktree name is a name, not a path: " .. name
  end
  if name == "." or name == ".." then
    return "a worktree name cannot be " .. name
  end
  return nil
end

-- Where this host keeps what it remembers between launches, from the two
-- variables that decide it: $XDG_STATE_HOME when it is absolute -- the spec says
-- a relative one means unset -- and $HOME/.local/state otherwise. With neither
-- set there is no per-user place to name, so the walk lands on /.local/state,
-- which is nobody's home and whose write fails into the same silence as every
-- other state this flow cannot keep: a memory lost, never a launch.
function M.state_dir_for(xdg_state_home, home)
  local base
  if type(xdg_state_home) == "string" and xdg_state_home:sub(1, 1) == "/" then
    base = xdg_state_home
  else
    base = tostring(home or "") .. "/.local/state"
  end
  return base .. "/rex-config"
end

-- The one file in it, which holds one `agent=<name>` line.
function M.state_file_for(xdg_state_home, home)
  return M.state_dir_for(xdg_state_home, home) .. "/state"
end

-- The agent a state file remembers: the value of its first `agent=` line, which
-- is the empty string for a remembered "none" and nil for a file that says
-- nothing about it. One key, written whole, and read back the way the old float
-- wrote it -- so a file left behind by an older install still reads, and every
-- way the file can be wrong is "nothing remembered" rather than an error.
function M.agent_from_state(text)
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local name = line:match("^agent=(.*)$")
    if name ~= nil then
      return name
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
  -- The list the agent question offers. Unset -- nil rather than left out, so
  -- it reads as a default -- means the one agent above. The question always
  -- adds its own (none) row after these, so "none" is never a name to configure.
  agents = nil,
  bead_prompt = "/brainstorming for bead {id}",
  -- A branch with no bead usually wants nothing said, so the default says
  -- nothing: the prompt question opens empty, and an accepted empty field means
  -- the agent starts bare.
  no_bead_prompt = "",
  -- The base a new branch starts from when nobody answered for this tab. Unset
  -- -- nil rather than a value, so it reads as a default -- is auto-detect: the
  -- base question opens on the remote's own default branch. A string is that
  -- question's first entry, and false is "let worktrunk choose" -- no --base
  -- word at all.
  base = nil,
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  script = beside_module("new-work.sh"),
}

-- The program the new tab runs, as POSIX sh (the tab gets it through
-- `sh -c`, see new_tab_argv below for the parameters). It exists because the
-- pane has to outlive the agent: switch the worktree, run the agent in it, then
-- leave a login shell there, so worktrunk's hook output and the agent's last
-- lines stay readable above a prompt that works. Exiting that shell closes the
-- tab.
--
-- Every value the flow knows arrives as a positional parameter, so no branch,
-- base, path, agent name or prompt is ever written into this text: a branch
-- with a slash, a prompt with quotes and an agent name with a space each stay
-- one argument, because the shell hands them over as they were. Nothing here is
-- bash -- it runs on whatever `sh` the machine has.
M.new_tab_script = [==[
# $1 = branch, $2 = base (empty when there is none), $3 = the remote the base
# lives on (empty when there is nothing to fetch), $4 = the worktree's directory
# (empty when worktrunk's own template should name it), then the agent and the
# arguments it is started with, the prompt last. An empty agent is an answer --
# the agent question's "(none)" -- and the pane then goes straight to a login
# shell, with the prompt said out loud instead of dropped.

# A login shell is this program's last act, and every path below ends here: it
# is what keeps the pane alive once the agent is gone, with the output above it
# still readable, and exiting it is what closes the tab. A $SHELL naming a
# program that is not installed would leave the pane dead with exit 127, so the
# plain sh is the fallback.
leave_shell() {
  if [ -n "${SHELL:-}" ] && command -v "$SHELL" >/dev/null 2>&1; then
    exec "$SHELL" -l
  fi
  exec /bin/sh -l
}

# The four parameters come before the agent, and `shift 4` on a short list is
# fatal in a non-interactive shell -- dash exits outright -- which would leave
# the pane with nothing in it. So a broken caller is answered with a shell too,
# and the message names all four.
if [ "$#" -lt 4 ]; then
  printf 'rex-config: the tab needs branch, base, remote and worktree\n' >&2
  leave_shell
fi

branch=$1
base=$2
remote=$3
worktree=$4
shift 4

# A fetch in a pane nobody can type into must never stop on a credential
# prompt: it would hang there invisibly. So git's terminal prompt is turned off
# before the fetch below and before worktrunk, whose hooks run git too.
export GIT_TERMINAL_PROMPT=0

# Named once so the messages below can name what is not started even when no
# agent was asked for: "not starting " is not a sentence. ${1-} rather than $1
# because a caller that sent the four parameters and nothing else leaves it
# unset, and `nounset` would end this wrapper before it could open a shell.
agent=${1-}
what=${agent:-an agent}

# A base that lives on a remote is fetched before the switch, so a new branch
# starts from what the remote has now rather than from whatever this machine
# saw last. The remote is the question's answer and is never derived from the
# ref's shape; an empty one means the base is local, so there is nothing to
# fetch.
#
# The fetch is bounded by timeout or gtimeout when the machine has one, and by
# nothing otherwise: the exported guard is what really prevents the invisible
# credential prompt, and a slow network is worth waiting out in a pane somebody
# asked for. Its stdin is /dev/null as well, so nothing can read from the pane.
#
# git's own last words are dropped: the line below says what failed and what
# happens next, and a failed fetch is not the reason to fill the pane.
fetch_base() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 git fetch --quiet "$remote" </dev/null >/dev/null 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 git fetch --quiet "$remote" </dev/null >/dev/null 2>&1
  else
    git fetch --quiet "$remote" </dev/null >/dev/null 2>&1
  fi
}

# worktrunk owns the switch: --create makes the branch and its worktree, --base
# says what the branch starts from, --path puts the worktree where the person
# named, and --no-cd leaves this shell where it is, so the worktree's path is
# read from the JSON reply rather than arrived at by changing directory. Either
# way the project's hooks run here, and their output belongs on this pane.
#
# --base and --path are only sent when there is something to send: an empty base
# means worktrunk chooses, and an empty path means its own worktree-path
# template does -- an empty word for either would be a value nobody gave.
switch_worktree() {
  set -- --create "$branch"
  if [ -n "$base" ]; then
    set -- "$@" --base "$base"
  fi
  if [ -n "$worktree" ]; then
    set -- "$@" --path "$worktree"
  fi
  set -- "$@" --no-cd --format=json
  wt switch "$@"
}

# A fetch that fails does not cost the work: one line says the ref is as it was,
# and the switch below runs from it anyway. The failure line names the base, so
# a remote sent without one is not fetched at all: there would be no ref to name
# and nothing the branch could start from.
if [ -n "$base" ] && [ -n "$remote" ]; then
  if ! fetch_base; then
    printf 'rex-config: could not fetch %s; %s starts from %s as it is\n' \
      "$remote" "$branch" "$base" >&2
  fi
fi

listing=$(switch_worktree)
# The assignment's status is the switch's own, captured before anything else
# runs: a worktrunk that failed has already said why, on this pane's stderr.
switched=$?

# The worktree the switch chose, and nothing else: the agent must never start in
# the wrong directory, so a path that cannot be read -- the switch failed, jq is
# missing, the reply carries none -- means the agent is not started at all.
path=
if [ "$switched" -eq 0 ]; then
  path=$(printf '%s\n' "$listing" | jq -r '.path // empty')
fi

if [ -z "$path" ]; then
  # Two steps can leave no path: a switch that failed, whose own message is already
  # on this pane, or a switch that worked and a reply whose path cannot be read
  # (jq missing, or no path in it). Naming the step that went wrong is the point of
  # the line, so neither case says "no path (exit 0)".
  if [ "$switched" -eq 0 ]; then
    printf 'rex-config: could not read the worktree path of %s from the switch reply (jq missing, or no path in it); not starting %s\n' \
      "$branch" "$what" >&2
  else
    printf 'rex-config: wt switch %s failed (exit %s); not starting %s\n' \
      "$branch" "$switched" "$what" >&2
  fi
  leave_shell
fi

# `cd --` ends the options: a path that starts with a dash is a directory like
# any other, not a flag the shell refuses.
cd -- "$path" || {
  printf 'rex-config: could not enter %s; not starting %s\n' "$path" "$what" >&2
  leave_shell
}

# No agent was asked for: the pane is the worktree and a login shell. The prompt
# is the last parameter -- whatever else came with it belonged to an agent that
# is not running -- and it has nowhere to go now, so it is printed above the
# shell rather than disappearing with the question that collected it.
if [ -z "$agent" ]; then
  prompt=
  for arg in "$@"; do
    prompt=$arg
  done
  if [ -n "$prompt" ]; then
    printf 'rex-config: no agent started; the prompt is:\n%s\n' "$prompt" >&2
  fi
  leave_shell
fi

# A ^C while the agent runs belongs to the agent: the terminal sends it to
# every process in the pane's group, so the agent dies (or handles it) -- and if
# this wrapper died with it there would be no shell left to hand over, which is
# the dead pane all over again. The wrapper therefore ignores INT for exactly
# the length of the agent's run, and the agent gets the default disposition
# back in its own child. Outside this, INT is left alone: interrupting the
# fetch above or the switch itself (a hook approval prompt, say) still stops the
# wrapper as it did -- neither sits inside the window this trap opens.
trap '' INT
( trap - INT; exec "$@" )
trap - INT
leave_shell
]==]

-- The command the new tab runs: that wrapper, with everything it needs as a
-- parameter --
--
--   sh -c SCRIPT sh <branch> <base> <remote> <worktree> <agent> [agent_args...] <prompt>
--
-- because a parameter is the one way a branch, a base, a remote, a path, a
-- prompt or an agent name reaches a shell without the shell parsing it as text.
-- The prompt is the one the person typed or accepted, or -- when they never
-- answered -- the configured template. An empty agent is the agent question's
-- "(none)": the wrapper starts nothing and hands the pane to a login shell. An
-- empty base is "no --base at all", an empty remote is "nothing to fetch", and
-- an empty worktree is worktrunk's own worktree-path template.
--
-- The prompt is not always there: a blank answer -- or a template that renders
-- to nothing -- sends no prompt parameter at all, so the argv ends after the
-- agent and its arguments, and a prompt whose first character is "-" travels
-- with one leading space so the agent reads a value rather than a flag.
function M.new_tab_argv(project, args)
  args = args or {}
  assert(type(args.branch) == "string" and args.branch ~= "",
    "new_tab_argv: a branch is required")
  -- The configured default is a program that has to exist: nobody may set an
  -- empty agent in a configuration file and quietly get no agent at all. An
  -- answer may say none, and that is the only way to say it.
  assert(type(M.options.agent) == "string" and M.options.agent ~= "",
    "new_tab_argv: an agent is required")
  local agent = M.options.agent
  if type(args.agent) == "string" then
    agent = args.agent
  end
  local prompt = ""
  if type(args.prompt) == "string" then
    -- What was answered at the prompt question beats both templates: it is an
    -- answer, where they are what the plugin says when nobody said anything. An
    -- empty answer is "nothing said", which the blank test below sends as no
    -- word at all.
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

  -- The base a new branch starts from, and the remote that base lives on. The
  -- base question resolves both -- no ref is read here -- so this only carries
  -- the answer, and the base is three-valued: a string is the ref to create
  -- from, false is the question's "let worktrunk choose" (and travels as the
  -- empty parameter, worktrunk's own default), and absent means the question
  -- was never asked -- a hand-run `rex do` -- so the configured base is the
  -- fallback.
  local base = ""
  if type(args.base) == "string" then
    base = args.base
  elseif args.base == nil and type(M.options.base) == "string" then
    base = M.options.base
  end
  -- The remote rides beside the base and is sent only when the question found
  -- the base on one: an empty parameter is nothing to fetch, which is what keeps
  -- a local base from costing a `git fetch` in the tab.
  local remote = ""
  if type(args.base_remote) == "string" then
    remote = args.base_remote
  end
  -- A worktree name is a directory name, and the tab runs in the main worktree,
  -- so `../<name>` is its sibling -- which is what worktrunk's own template
  -- builds. An empty name is "no --path word at all".
  local worktree = ""
  if type(args.worktree) == "string" and args.worktree ~= "" then
    worktree = "../" .. args.worktree
  end

  local argv = {
    "sh", "-c", M.new_tab_script,
    -- sh takes the word after the program as $0, so this is what keeps the
    -- branch in $1 rather than the program's own name.
    "sh",
    args.branch,
    base,
    remote,
    worktree,
    agent,
  }
  -- An agent's arguments are the agent's, so they travel only when one starts.
  if agent ~= "" then
    for _, arg in ipairs(M.options.agent_args or {}) do
      argv[#argv + 1] = arg
    end
  end
  -- A blank answer is "an agent, and nothing to say", and so is a template that
  -- renders to nothing: no prompt word at all, not an empty one, so the argv
  -- ends after the agent and its arguments and the agent is handed no argument
  -- nobody wrote. That is also how a cleared prompt field stays cleared.
  if args.blank == true or prompt == "" then
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
-- wt, jq and bd on the login shell's PATH. wt, bd and new-work.sh therefore run
-- in that shell, which is also where mise keeps the environment its shims need.
-- Every word handed to it is quoted; see quote() below.
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

-- One shell word holding `text`, quoted for a POSIX shell. A single-quoted word
-- needs nothing done to it but its own quotes escaped, so a path with a space, a
-- branch with a $ or an id with a quote reaches the command as one word and as
-- itself.
local function quote(text)
  local quoted = (tostring(text):gsub("'", "'\\''"))
  return "'" .. quoted .. "'"
end

-- new-work.sh, run the way the flow runs it: through the login shell, whose
-- PATH is what knows wt, bd and jq, with every word quoted so no branch, path or
-- id is ever parsed as shell text. WORDS are the verb and its arguments; the
-- script comes in front of them.
local function run_script(words, cwd)
  local parts = { quote(M.options.script) }
  for _, word in ipairs(words) do
    parts[#parts + 1] = quote(word)
  end
  return run_in_shell(table.concat(parts, " "), cwd)
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

-- The agent names the agent question offers, in the order it offers them: the
-- first is the one an unasked question takes. Unset means the one configured
-- agent, so a configuration that names no list still gets the question -- the
-- agent, or none -- rather than no question at all.
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

-- The ready beads as records, from new-work.sh's tested filter: the jq that
-- drops molecule steps and gate containers, and sorts by priority then id, is
-- the one thing this flow did not rewrite.
local function ready_beads(main)
  local reply, reason = run_script({ "beads", "--main", main }, main)
  if reply == nil then
    return nil, "could not list the ready beads in " .. main .. ": " .. tostring(reason)
  end
  if reply.code ~= 0 then
    return nil, "could not list the ready beads in " .. main .. ": " .. first_line(reply.stderr)
  end
  return M.bead_rows(reply.stdout)
end

-- The base question's rows, in the order new-work.sh prints them: the opening
-- answer first, then the short cycle around it.
local function base_choices(main)
  local words = { "bases", "--main", main }
  if M.options.base == false then
    words[#words + 1] = "--no-base"
  elseif type(M.options.base) == "string" then
    words[#words + 1] = "--base"
    words[#words + 1] = M.options.base
  end
  local reply, reason = run_script(words, main)
  if reply == nil then
    return nil, "could not read the bases of " .. main .. ": " .. tostring(reason)
  end
  if reply.code ~= 0 then
    return nil, "could not read the bases of " .. main .. ": " .. first_line(reply.stderr)
  end
  return M.base_rows(reply.stdout)
end

-- The branch name the bead derives, from new-work.sh's tested type-to-prefix
-- map: bug, chore and spike keep their prefix, feature and task read feat, and
-- only the last dash-separated segment of the id is kept. Nothing at all -- a
-- bead whose id leaves no name -- opens the question empty rather than stopping
-- it.
local function branch_default(main, bead, issue_type)
  if type(bead) ~= "string" or bead == "" then
    return M.random_branch_name()
  end
  local reply = run_script({ "branch-default", "--type",
    issue_type ~= "" and issue_type or "other", "--id", bead }, main)
  if reply == nil or reply.code ~= 0 then
    return ""
  end
  return (tostring(reply.stdout or ""):gsub("%s+$", ""))
end

-- Whether git would accept this as a branch name, asked of git itself. The
-- reply is compared with the name that went in because check-ref-format
-- *expands* a name like @{-1} and prints what it resolved to: only an answer
-- equal to the input says the input is a branch name.
local function branch_problem(name, cwd)
  if name == "" then
    return "the branch name is empty"
  end
  local reply, reason = run({ "git", "check-ref-format", "--branch", name }, cwd)
  if reply == nil then
    return "could not check the branch name " .. name .. ": " .. tostring(reason)
  end
  if reply.code ~= 0 then
    return "not a branch name: " .. name .. " (" .. first_line(reply.stderr) .. ")"
  end
  if (tostring(reply.stdout or ""):gsub("%s+$", "")) ~= name then
    return "not a branch name: " .. name
  end
  return nil
end

-- Whether this wt switch knows `--path`, which worktrunk calls experimental. A
-- wt from before it would ignore the flag and put the worktree wherever its
-- template says, so a worktree name is refused with a message rather than
-- quietly dropped.
local function switch_takes_path(main)
  local reply, reason = run_in_shell("wt switch --help", main)
  if reply == nil then
    return false, "could not ask wt switch whether it takes --path: " .. tostring(reason)
  end
  local help = tostring(reply.stdout or "") .. "\n" .. tostring(reply.stderr or "")
  if help:find("%-%-path") == nil then
    return false, "this wt switch has no --path, so a worktree name cannot be used; "
      .. "worktrunk 0.82 or later has it"
  end
  return true
end

-- The state directory and file this host's environment names, which is where the
-- last launch's agent is remembered: $XDG_STATE_HOME/rex-config/state, or
-- ~/.local/state/rex-config/state. Which one is M.state_dir_for's question, asked
-- here so it can be tested without an environment to set.
local function state_dir()
  local xdg = os and os.getenv and os.getenv("XDG_STATE_HOME")
  local home = os and os.getenv and os.getenv("HOME")
  return M.state_dir_for(xdg, home)
end

-- io is not there in every host Rex embeds (a sandboxed script has none of it),
-- so a file that cannot be opened is nil and never an error: the memory then
-- lives in this module alone, for the life of the process.
local function open_file(path, mode)
  if io == nil or io.open == nil then
    return nil
  end
  local ok, file = pcall(io.open, path, mode)
  if not ok then
    return nil
  end
  return file
end

-- The in-memory half of the memory: what this process wrote, read back by it.
-- nil means nothing has been remembered here, and an empty string is the
-- remembered "(none)" -- which is an answer, not a missing one.
local remembered_here = nil

-- The agent the last launch chose, or nil when nothing is remembered. A name the
-- list no longer offers is nothing remembered: the question would open filtered
-- to a row that is not there.
function M.remembered_agent(names)
  local name = remembered_here
  if name == nil then
    local file = open_file(state_dir() .. "/state", "r")
    if file ~= nil then
      local text = file:read("*a") or ""
      file:close()
      name = M.agent_from_state(text)
    end
  end
  if name == nil or name == "" then
    return name
  end
  for _, offered in ipairs(names or {}) do
    if offered == name then
      return name
    end
  end
  return nil
end

-- And the answer back into it, written before the tab is made so a launch that
-- fails still counts as the agent that was chosen. A directory that cannot be
-- made and a file that cannot be written are both discarded: a launch is worth
-- more than the memory of it.
function M.remember_agent(name)
  if type(name) ~= "string" then
    return false
  end
  remembered_here = name
  local dir = state_dir()
  -- mkdir in the host's own argv, no shell in the way, and only where rex is
  -- there to run it: a host that has neither is one whose memory this process
  -- keeps alone.
  if type(rex) == "table" and rex.exec ~= nil then
    pcall(rex.exec, { "mkdir", "-p", dir })
  end
  local file = open_file(dir .. "/state", "w")
  if file == nil then
    return false
  end
  file:write("agent=" .. name .. "\n")
  file:close()
  return true
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

-- The one thing from an answer that travels inside a command line is the bead
-- id, so it is checked against the shape bd's ids have before it goes in.
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
-- palette itself, so a queued client action is accepted there; a hand-run
-- `rex do` has no invocation to queue against, so the app's clients are asked
-- directly instead, which needs Remote Control on. nil means shown.
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

-- The second half of the flow, where the questions have been answered: the
-- project's session, the tab named after the branch, the claim, and the switch
-- inside the tab. It runs in the project's root and its main worktree rather
-- than anywhere the key was pressed, so the tab and every bd call are in the one
-- directory the database is reachable from.
local function start_work(ctx, project, answers)
  local main, branch = project.main, answers.branch

  local session, session_reason = session_to_use(project.name, main)
  if session == nil then
    error(session_reason, 0)
  end
  local windows, attach_reason = attach_session(session)
  if windows == nil then
    error("could not attach to the " .. project.name .. " session: " .. attach_reason, 0)
  end

  -- A second press for the same branch finds its tab here: one tab, one worktree
  -- and one claim, whatever the questions were answered with.
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
  local bead = answers.bead
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
        command = M.new_tab_argv(project.name, answers),
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
    if type(answers.bead) == "string" and answers.bead ~= "" then
      release = "; the bead is still claimed, so release it with: bd unclaim " .. answers.bead
    end
    error("could not make the " .. branch .. " tab in the " .. project.name .. " session: "
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

-- The answer to one question, or the end of the flow.
--
-- rex.ui answers nil and a reason when nobody answered. "cancelled" is the
-- person saying no: the action returns nothing and says nothing, because the
-- prompt closing is already the answer. Every other reason -- timeout, busy,
-- no_client, unsupported, failed -- is a refusal, and it names the question,
-- since a bare "timeout" would not say what went unanswered.
local function answered(step, value, reason)
  if value ~= nil then
    return value
  end
  if reason == "cancelled" then
    return nil
  end
  error(step .. " could not be answered: " .. tostring(reason or "failed"), 0)
end

-- Whether this Rex build can be asked anything. The lookup is inside a pcall
-- because rex.ui may not exist on an older server at all; the prompts
-- themselves are never inside one, since a prompt in a frame that cannot pause
-- is reported as unsupported and would answer nothing.
local function can_ask()
  local has_ui, ui = pcall(function() return rex.ui end)
  return has_ui and type(ui) == "table"
    and type(ui.input) == "function" and type(ui.pick) == "function"
end

-- Ask the six questions the flow has, skipping the ones a caller already
-- answered, then start the work.
--
-- The order is bead, branch, worktree, base, agent, prompt, and every one of
-- them is a rex.ui call inside this action's run -- a frame that can wait. The
-- whole float-and-hand-back architecture existed because a key-bound action
-- could not; that constraint is gone.
--
--   rex do work_new                          -- asks all six
--   rex do work_new bead=pmm-iris-608        -- asks the other five
--   rex do work_new bead= branch=feat/x worktree= base=@ agent=pi prompt=
--
-- An empty string is an answer where it means something: bead = "" is no bead,
-- agent = "" starts none, worktree = "" lets worktrunk name the directory, and
-- prompt = "" says nothing to the agent.
function M.work_new(ctx, args)
  ctx = ctx or {}
  args = args or {}

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
  if not can_ask() then
    error("this Rex build cannot ask anything (no rex.ui), so work_new has no questions to ask", 0)
  end

  -- a. The bead: the ready ones, or none.
  local bead, title, issue_type = args.bead, args.title, ""
  if bead == nil then
    local rows, rows_reason = ready_beads(project.main)
    if rows == nil then
      error(rows_reason, 0)
    end
    local choice = answered("the bead question", rex.ui.pick{
      title = M.bead_question_title(project.name, rows),
      placeholder = "Type to filter",
      items = M.bead_items(rows),
      confirm = "Start",
    })
    if choice == nil then
      return nil
    end
    if choice == M.NO_BEAD then
      bead, title = "", ""
    else
      bead = choice
      for _, row in ipairs(rows) do
        if row.id == choice then
          title, issue_type = row.title, row.issue_type
          break
        end
      end
    end
  end

  -- The bases are read before the branch is asked for, so that question can say
  -- what the new branch will start from; which of them is the answer is settled
  -- at (d).
  local bases, bases_reason = base_choices(project.main)
  if bases == nil then
    error(bases_reason, 0)
  end

  -- b. The branch: derived from the bead, or a name of its own when there is
  -- no bead. git is the judge of it, and the refusal says why.
  local branch = args.branch
  if branch == nil then
    local opening = bases[1] and bases[1].ref or ""
    local text = answered("the branch question", rex.ui.input{
      title = "Branch for the new worktree",
      placeholder = opening ~= "" and ("starts from " .. opening) or "starts from worktrunk's default",
      value = branch_default(project.main, bead, issue_type),
      confirm = "Create branch",
    })
    if text == nil then
      return nil
    end
    branch = (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
  end
  local branch_reason = branch_problem(branch, project.main)
  if branch_reason ~= nil then
    error(branch_reason, 0)
  end

  -- c. The worktree: a name, never a path. Blank is worktrunk's own
  -- worktree-path template, which is what the tab did before this question
  -- existed.
  local worktree = args.worktree
  if worktree == nil then
    local text = answered("the worktree question", rex.ui.input{
      title = "Worktree name",
      placeholder = "blank lets worktrunk name it",
      value = M.sanitize_branch(branch),
      confirm = "Use this worktree name",
    })
    if text == nil then
      return nil
    end
    worktree = (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
  end
  if worktree ~= "" then
    local problem = M.worktree_problem(worktree)
    if problem ~= nil then
      error(problem, 0)
    end
    local supported, why = switch_takes_path(project.main)
    if not supported then
      error(why, 0)
    end
  end

  -- d. The base: one of the rows, the first of which is the one a bare Return
  -- takes. An empty ref is worktrunk's own choice, and travels as false so the
  -- configured base cannot speak in its place.
  local base, base_remote = args.base, args.base_remote
  if base == nil then
    local choice = answered("the base question", rex.ui.pick{
      title = "Base for the new branch",
      placeholder = "Type to filter",
      items = M.base_items(bases),
      confirm = "Start",
    })
    if choice == nil then
      return nil
    end
    local row = bases[1] or { ref = "", remote = "" }
    for _, candidate in ipairs(bases) do
      if (candidate.ref ~= "" and candidate.ref or M.WT_DEFAULT) == choice then
        row = candidate
        break
      end
    end
    base = row.ref ~= "" and row.ref or false
    base_remote = row.remote ~= "" and row.remote or nil
  end

  -- e. The agent: the configured names, or none. The agent the last launch
  -- chose arrives as the filter, which narrows the list to that one row, so a
  -- bare Return takes it -- a single-choice pick has no other way to preselect.
  local agent = args.agent
  if agent == nil then
    local names = agent_choices()
    local remembered = M.remembered_agent(names)
    local choice = answered("the agent question", rex.ui.pick{
      title = "Agent for the new tab",
      placeholder = "Type to filter",
      value = remembered == "" and NO_AGENT_TITLE or (remembered or ""),
      items = M.agent_items(names),
      confirm = "Start",
    })
    if choice == nil then
      return nil
    end
    agent = choice == M.NO_AGENT and "" or choice
    -- Written before the tab, so a launch that fails still counts as the agent
    -- that was chosen.
    M.remember_agent(agent)
  end

  -- f. The prompt: the configured template for the bead -- or for no bead --
  -- as the field's text, which the person can edit or clear. A cleared field is
  -- an answer: the agent starts and is told nothing, and blank says so, because
  -- new_tab_argv would otherwise fill the place with the template's own text.
  local prompt = args.prompt
  local blank = args.blank
  if prompt == nil then
    local value
    if type(bead) == "string" and bead ~= "" then
      value = M.render_prompt(M.options.bead_prompt, {
        id = bead,
        title = title,
        branch = branch,
        project = project.name,
      })
    else
      value = M.options.no_bead_prompt
    end
    local text = answered("the prompt question", rex.ui.input{
      title = "Prompt for the agent",
      placeholder = "cleared means the agent is told nothing",
      value = value,
      confirm = "Start",
    })
    if text == nil then
      return nil
    end
    prompt = text
  end
  if prompt == "" then
    blank = true
  end

  return start_work(ctx, project, {
    bead = bead,
    title = title,
    branch = branch,
    worktree = worktree,
    base = base,
    base_remote = base_remote,
    agent = agent,
    prompt = prompt,
    blank = blank,
  })
end

-- Action work_new_go: the picker's hand-back, kept while new-work.sh still
-- hands one back. The key runs the wizard above; this only turns a payload into
-- the answers it would have collected and starts the work.
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

  return start_work(ctx, { name = args.project, root = args.root, main = args.main }, args)
end

-- Options from the configuration file, then the actions. run takes the
-- action's context, and for work_new its optional answers as a second argument.
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
    -- agents reaches the agent question as its rows, so a string here is the
    -- same mistake in a different shape, and a name that is not a string would
    -- reach the question as nothing at all.
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
    -- The answers as optional arguments: the flow asks only for the ones it was
    -- not given, which is what keeps a hand-run `rex do work_new bead=<id>`
    -- working without a person at the prompts.
    args = {
      type = "object",
      properties = {
        -- An id, or the empty string for "no bead".
        bead = { type = "string" },
        title = { type = "string" },
        branch = { type = "string" },
        -- A directory name, or the empty string to let worktrunk name it.
        worktree = { type = "string" },
        -- The base is three-valued here too: a string is the ref to create
        -- from, false is worktrunk's own default (no --base word at all), and
        -- absent is a question to ask. The remote is present only for a
        -- remote-tracking ref.
        base = { type = { "string", "boolean" } },
        base_remote = { type = "string" },
        -- An empty string is the "(none)" row: a worktree and a shell.
        agent = { type = "string" },
        -- An empty string is "an agent, and nothing said to it".
        prompt = { type = "string" },
        blank = { type = "boolean" },
      },
    },
    run = function(ctx, args)
      return M.work_new(ctx, args)
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
        create = { type = "boolean" },
        -- What the branch is created from, and the remote that ref lives on.
        -- The base is three-valued -- a string is the ref, false is worktrunk's
        -- own default (no --base word at all), and absent means the picker never
        -- answered -- so both types are declared: a `string` alone would call
        -- the picker's sentinel an illegal value, and a validator that took that
        -- at its word would drop it and let a configured base speak instead.
        -- The remote is present only for a remote-tracking ref.
        base = { type = { "string", "boolean" } },
        base_remote = { type = "string" },
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
