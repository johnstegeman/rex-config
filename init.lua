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
  local dir = (common_dir or ""):gsub("/+$", "")
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
      if is_main == true and type(path) == "string" then
        return path
      end
    end
  end
  return nil
end

-- argv for `wt switch`: worktrunk owns worktree creation, so this plugin only
-- ever builds its command line. --base is meaningful only when creating.
function M.wt_switch_argv(args)
  args = args or {}
  assert(type(args.branch) == "string" and type(args.agent) == "string",
    "wt_switch_argv: branch and agent are required")
  local argv = { "wt", "switch" }
  if args.create then
    argv[#argv + 1] = "--create"
    if args.base ~= nil and args.base ~= false then
      argv[#argv + 1] = "--base"
      argv[#argv + 1] = args.base
    end
  end
  argv[#argv + 1] = args.branch
  argv[#argv + 1] = "-x"
  argv[#argv + 1] = args.agent
  argv[#argv + 1] = "--"
  for _, arg in ipairs(args.agent_args or {}) do
    argv[#argv + 1] = arg
  end
  if args.prompt ~= nil and args.prompt ~= false then
    argv[#argv + 1] = args.prompt
  end
  return argv
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
  bead_prompt = "/brainstorming for bead {id}",
  no_bead_prompt = "/brainstorming",
  base = "@",
  bounds = { 0.15, 0.1, 0.7, 0.8 },
  script = beside_module("new-work.sh"),
}

local OPTION_NAMES = { "agent", "agent_args", "bead_prompt", "no_bead_prompt", "base", "bounds", "script" }
local KNOWN_OPTION = {}
for _, name in ipairs(OPTION_NAMES) do
  KNOWN_OPTION[name] = true
end

-- Rex runs an action with its own PATH -- /usr/bin:/bin:/usr/sbin:/sbin on this
-- Mac -- which knows nothing of mise or Homebrew installs, while the design puts
-- wt, fzf, jq and bd on the login shell's PATH. wt and bd therefore run in that
-- shell, which is also where mise keeps the environment its shims need. Nothing
-- is interpolated into the command text: a directory travels as rex.exec's cwd
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

  -- main_worktree compares the main flag with true, so it needs the decoded
  -- document; raw JSON text is never a boolean. rex.json.decode reports bad text
  -- by returning nil and a reason rather than raising, so the value decides.
  local decoded, decode_reason = rex.json.decode(listed.stdout or "")
  if type(decoded) ~= "table" then
    return nil, "could not read the worktrunk listing for " .. project.root .. ": "
      .. (decode_reason and tostring(decode_reason) or "no JSON value")
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

-- argv for new-work.sh's picker. base = false means "let worktrunk choose",
-- so there is no --base to pass on.
local function picker_command(project)
  local command = {
    M.options.script, "pick",
    "--main", project.main,
    "--root", project.root,
    "--project", project.name,
  }
  if M.options.base ~= nil and M.options.base ~= false then
    command[#command + 1] = "--base"
    command[#command + 1] = M.options.base
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

-- Action work_new_go: the picker's hand-back. It already holds the whole
-- answer, so this only has to start the work.
function M.work_new_go(_ctx, _args)
  error("work_new_go is not implemented yet", 0)
end

-- Options from the configuration file, then the two actions. run takes the
-- action's context, and for work_new_go the hand-back payload as a second
-- argument.
local actions_registered = false

function M.setup(opts)
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
