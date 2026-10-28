local M = dofile("init.lua")
local fails = 0
local count = 0
local function eq(name, got, want)
  count = count + 1
  local g = type(got) == "table" and table.concat(got, " ") or tostring(got)
  local w = type(want) == "table" and table.concat(want, " ") or tostring(want)
  if g ~= w then fails = fails + 1; io.stderr:write("FAIL " .. name .. "\n  got:  " .. g .. "\n  want: " .. w .. "\n") end
end

eq("render_prompt", M.render_prompt("/brainstorming for bead {id} ({title}) {id}", { id = "pmm-iris-58h", title = "Diff path" }),
   "/brainstorming for bead pmm-iris-58h (Diff path) pmm-iris-58h")
eq("render_prompt missing key", M.render_prompt("x{b}y", {}), "xy")
eq("project_from_common_dir", M.project_from_common_dir("/x/pmm-iris/.git").name, "pmm-iris")
eq("project_from_common_dir root", M.project_from_common_dir("/x/pmm-iris/.git/").root, "/x/pmm-iris")
eq("main_worktree schema2", M.main_worktree({ items = { { worktree = { path = "/r/main", main = true } }, { worktree = { path = "/r/feat", main = false } } } }), "/r/main")
eq("main_worktree legacy", M.main_worktree({ { path = "/r/main", is_main = true }, { path = "/r/feat" } }), "/r/main")
eq("main_worktree none", M.main_worktree({ items = {} }), "nil")
eq("wt create", M.wt_switch_argv{ branch = "bug/58h", create = true, base = "@", agent = "pi", prompt = "hello world" },
   { "wt", "switch", "--create", "--base", "@", "bug/58h", "-x", "pi", "--", "hello world" })
eq("wt existing", M.wt_switch_argv{ branch = "bug/58h", create = false, base = "@", agent = "pi" },
   { "wt", "switch", "bug/58h", "-x", "pi", "--" })
eq("wt agent_args", M.wt_switch_argv{ branch = "b", create = true, agent = "pi", agent_args = { "--thinking", "high" }, prompt = "p" },
   { "wt", "switch", "--create", "b", "-x", "pi", "--", "--thinking", "high", "p" })

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
