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

-- Compares tables element by element (arg boundaries matter for a command
-- vector) and scalars by identity, so nil never collides with the string "nil".
local function eq(name, got, want)
  count = count + 1
  local ok
  if type(want) == "table" then
    ok = type(got) == "table" and #got == #want
    if ok then
      for i = 1, #want do
        if got[i] ~= want[i] then ok = false end
      end
    end
  else
    ok = got == want
  end
  if not ok then fails = fails + 1; io.stderr:write("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want) .. "\n") end
end

eq("version", M.version, "0.1.0")
eq("render_prompt", M.render_prompt("/brainstorming for bead {id} ({title}) {id}", { id = "pmm-iris-58h", title = "Diff path" }),
   "/brainstorming for bead pmm-iris-58h (Diff path) pmm-iris-58h")
eq("render_prompt missing key", M.render_prompt("x{b}y", {}), "xy")
eq("project_from_common_dir", M.project_from_common_dir("/x/pmm-iris/.git").name, "pmm-iris")
eq("project_from_common_dir root", M.project_from_common_dir("/x/pmm-iris/.git/").root, "/x/pmm-iris")
eq("project_from_common_dir relative", M.project_from_common_dir(".git"), nil)
eq("main_worktree schema2", M.main_worktree({ items = { { worktree = { path = "/r/main", main = true } }, { worktree = { path = "/r/feat", main = false } } } }), "/r/main")
eq("main_worktree legacy", M.main_worktree({ { path = "/r/main", is_main = true }, { path = "/r/feat" } }), "/r/main")
eq("main_worktree none", M.main_worktree({ items = {} }), nil)
eq("main_worktree non-table items", M.main_worktree({ items = "x" }), nil)
eq("wt create", M.wt_switch_argv{ branch = "bug/58h", create = true, base = "@", agent = "pi", prompt = "hello world" },
   { "wt", "switch", "--create", "--base", "@", "bug/58h", "-x", "pi", "--", "hello world" })
eq("wt existing", M.wt_switch_argv{ branch = "bug/58h", create = false, base = "@", agent = "pi" },
   { "wt", "switch", "bug/58h", "-x", "pi", "--" })
eq("wt agent_args", M.wt_switch_argv{ branch = "b", create = true, agent = "pi", agent_args = { "--thinking", "high" }, prompt = "p" },
   { "wt", "switch", "--create", "b", "-x", "pi", "--", "--thinking", "high", "p" })
eq("wt base suppressed when creating from false", M.wt_switch_argv{ branch = "b", create = true, base = false, agent = "pi" },
   { "wt", "switch", "--create", "b", "-x", "pi", "--" })
eq("wt requires branch", pcall(M.wt_switch_argv, { agent = "pi" }), false)
eq("wt requires agent", pcall(M.wt_switch_argv, { branch = "b" }), false)

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
