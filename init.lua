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

return M
