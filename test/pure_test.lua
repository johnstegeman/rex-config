-- Resolve init.lua relative to this file so the test runs from any cwd.
local here = (arg and arg[0] or ""):match("^(.*)/") or "."
local M = dofile(here .. "/../init.lua")
local fails = 0
local count = 0

-- Render a value for a failure message: strings are quoted (so element
-- boundaries and embedded whitespace are visible), tables element by element.
local function show(value)
  if value == nil then return "<nil>" end
  if type(value) == "table" then
    local parts = {}
    for i = 1, #value do parts[i] = show(value[i]) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

-- Whether two values are the same. Tables are compared key by key, not just
-- element by element, as in the other two files: a map table carries no array
-- part, so looking only at its elements compares every two maps equal.
local function same(got, want)
  if type(got) ~= type(want) then return false end
  if type(want) ~= "table" then return got == want end
  if #got ~= #want then return false end
  for i = 1, #want do
    if not same(got[i], want[i]) then return false end
  end
  for key, value in pairs(want) do
    if not same(got[key], value) then return false end
  end
  for key in pairs(got) do
    if want[key] == nil then return false end
  end
  return true
end

local function eq(name, got, want)
  count = count + 1
  if not same(got, want) then
    fails = fails + 1
    io.stderr:write("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want) .. "\n")
  end
end

-- The guard on the guard, as in the other two files: a map table whose value
-- changed, and one that lost its only key, each have to compare unequal, so the
-- comparison cannot quietly go back to element lists.
local function not_eq(name, got, want)
  count = count + 1
  if same(got, want) then
    fails = fails + 1
    io.stderr:write("FAIL " .. name .. "\n  got and want compared equal: " .. show(got) .. "\n")
  end
end

not_eq("a map whose value changed does not compare equal",
  { type = "string" }, { type = "boolean" })
not_eq("a map that lost its key does not compare equal", {}, { type = "boolean" })

eq("version", M.version, "0.1.0")
eq("render_prompt", M.render_prompt("/brainstorming for bead {id} ({title}) {id}", { id = "pmm-iris-58h", title = "Diff path" }),
   "/brainstorming for bead pmm-iris-58h (Diff path) pmm-iris-58h")
eq("render_prompt missing key", M.render_prompt("x{b}y", {}), "xy")
eq("project_from_common_dir", M.project_from_common_dir("/x/pmm-iris/.git").name, "pmm-iris")
eq("project_from_common_dir root", M.project_from_common_dir("/x/pmm-iris/.git/").root, "/x/pmm-iris")
eq("project_from_common_dir relative", M.project_from_common_dir(".git"), nil)
-- A value that is not a path at all, as a wrong argument or a decoded null would
-- be: nil rather than a Lua error, the way wt_switch_argv guards.
eq("project_from_common_dir non-string", M.project_from_common_dir(42), nil)
eq("project_from_common_dir nil", M.project_from_common_dir(nil), nil)
eq("main_worktree schema2", M.main_worktree({ items = { { worktree = { path = "/r/main", main = true } }, { worktree = { path = "/r/feat", main = false } } } }), "/r/main")
eq("main_worktree legacy", M.main_worktree({ { path = "/r/main", is_main = true }, { path = "/r/feat" } }), "/r/main")
-- A producer that quoted the flag: "true" is the main worktree too, since the
-- alternative is losing the project altogether.
eq("main_worktree string flag", M.main_worktree({ items = { { worktree = { path = "/r/main", main = "true" } } } }), "/r/main")
eq("main_worktree string flag false", M.main_worktree({ items = { { worktree = { path = "/r/main", main = "false" } } } }), nil)
eq("main_worktree none", M.main_worktree({ items = {} }), nil)
eq("main_worktree non-table items", M.main_worktree({ items = "x" }), nil)
-- The `wt switch` words themselves are asserted where they are executed:
-- test/wrapper_test.sh runs the tab's wrapper with a stand-in `wt` and reads
-- the words it was given, for a create run and for an existing worktree.

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
