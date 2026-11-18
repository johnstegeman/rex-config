-- The module under Rex's own Lua, which is the only host where the parsers can
-- be wrong: `(tostring(x) .. "\n"):gmatch("([^\n]*)\n")` is legal in stock Lua
-- and panics Rex's host with "invalid memory address or nil pointer dereference"
-- -- a Go nil dereference that no pcall catches and that costs the whole action.
-- test/pure_test.lua and friends run under stock Lua, so nothing in them can see
-- it. This file runs where the config really runs:
--
--     rex do test/host.lua
--
-- It needs no fixture on disk beyond test/fixtures/, and no server state: only
-- `rex do`, because that is how a script gets Rex's Lua rather than this
-- machine's. test/host_test.sh runs it and skips when there is no server.

-- The repository root, from this file's own path: `arg` is nil under `rex do`.
local function repo_root()
  local source = (debug and debug.getinfo and debug.getinfo(1, "S") or {}).source or ""
  local path = source:gsub("^@", "")
  local dir = path:match("^(.*)[/\\][^/\\]+$") or "."
  return dir:gsub("/[^/]*$", "")
end

local root = repo_root()
local M = dofile(root .. "/init.lua")

local fails = 0
local count = 0

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

local notes = {}

local function eq(name, got, want)
  count = count + 1
  if not same(got, want) then
    fails = fails + 1
    notes[#notes + 1] = "FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want)
  end
end

-- The listing new-work.sh prints, read from the fixture the shell tests use so
-- this host and that one are looking at the same rows.
local function fixture(name)
  local path = root .. "/test/fixtures/" .. name
  local file = io and io.open and io.open(path, "r")
  if file ~= nil then
    local text = file:read("*a")
    file:close()
    return text or ""
  end
  local reply = rex.exec({ "cat", path })
  return reply and reply.stdout or ""
end

local expected = fixture("ready.expected")

-- parse_rows: the verb output as rows of fields. A trailing newline and the
-- blank line it leaves are not a row; a missing trailing newline still ends the
-- last row.
local rows = M.parse_rows(expected)
eq("parse_rows: one row per bead", #rows, 3)
eq("parse_rows: four fields a row", rows[1], { "pmm-iris-58h",
  "Phase 3 follow-on: implement bootstrap-vs-delta diff path", "task", "1" })
eq("parse_rows: a title keeps its pipe", rows[2][2],
  "Per-component grain config on RootSpec (reference | prose | auto)")
eq("parse_rows: no trailing newline still ends the last row", #M.parse_rows("a\tb"), 1)
eq("parse_rows: a blank line is not a row", #M.parse_rows("a\tb\n\nc\td\n"), 2)
eq("parse_rows: CRLF does not reach a field", M.parse_rows("a\tb\r\n")[1][2], "b")
eq("parse_rows: empty text is no rows", #M.parse_rows(""), 0)
eq("parse_rows: nil text is no rows", #M.parse_rows(nil), 0)

-- The shapes that panic Rex's Lua when the receiver is not hoisted: a title with
-- characters outside ASCII, which is what the real listing carries.
local unicode = "pmm-x-1\tcaf\u{e9} \u{2194} \u{2014} dash\tbug\t2\n"
eq("parse_rows: unicode title survives", M.parse_rows(unicode)[1][2],
  "caf\u{e9} \u{2194} \u{2014} dash")

-- bead_rows: the four fields as named ones, with an empty priority where bd gave
-- none rather than a rank of its own.
local beads = M.bead_rows(expected)
eq("bead_rows: id", beads[3].id, "pmm-iris-a4l")
eq("bead_rows: issue_type", beads[3].issue_type, "bug")
eq("bead_rows: priority", beads[3].priority, "2")
eq("bead_rows: a missing field is empty, not nil", M.bead_rows("only-an-id")[1].priority, "")

-- base_rows: the ref and the remote it lives on. The empty ref is worktrunk's
-- own default, which is an answer.
local bases = M.base_rows("origin/main\torigin\n\t\n")
eq("base_rows: a remote ref", bases[1], { ref = "origin/main", remote = "origin" })
eq("base_rows: worktrunk's default", bases[2], { ref = "", remote = "" })

-- agent_from_state: the remembered agent, read the way the old float wrote it.
eq("agent_from_state: a name", M.agent_from_state("agent=pi\n"), "pi")
eq("agent_from_state: the remembered none", M.agent_from_state("agent=\n"), "")
eq("agent_from_state: nothing written", M.agent_from_state(""), nil)
eq("agent_from_state: nothing about the agent", M.agent_from_state("other=1\n"), nil)
eq("agent_from_state: no trailing newline", M.agent_from_state("agent=pi"), "pi")

-- The rows the questions show. The last row of each is the answer that is not
-- data, and its id carries a NUL so no real id can collide with it.
local items = M.bead_items(beads)
eq("bead_items: one row a bead and then the no-bead row", #items, 4)
eq("bead_items: last row is not a bead", items[4].id, M.NO_BEAD)
eq("bead_items: the type picks the icon", items[3].icon, "branch")
eq("bead_items: the priority is the detail", items[3].detail, "P2")
eq("bead_items: no priority says nothing",
  M.bead_items(M.bead_rows("id\ttitle\ttask\n"))[1].detail, nil)

eq("bead_question_title: a list", M.bead_question_title("pmm", beads), "Bead for pmm")
eq("bead_question_title: nothing ready",
  M.bead_question_title("pmm", {}), "no ready beads in pmm")

local base_items = M.base_items(bases)
eq("base_items: the opening answer first", base_items[1].id, "origin/main")
eq("base_items: the remote is the subtitle", base_items[1].subtitle, "on origin")
eq("base_items: worktrunk's default is not a ref", base_items[2].id, M.WT_DEFAULT)
eq("base_items: and it is spelled out", base_items[2].title, "worktrunk's default")

local agent_items = M.agent_items({ "pi", "claude" })
eq("agent_items: the names in order", #agent_items, 3)
eq("agent_items: the last row starts no agent", agent_items[3].id, M.NO_AGENT)
eq("agent_items: and it says so", agent_items[3].title, "(none)")

-- The branch, the worktree name and the two directories the state lives in.
eq("sanitize_branch: a slash becomes a dash", M.sanitize_branch("bug/a4l"), "bug-a4l")
eq("sanitize_branch: every separator does",
  M.sanitize_branch("a/b\\c:d"), "a-b-c-d")
eq("worktree_problem: a plain name is one", M.worktree_problem("feat-x"), nil)
eq("worktree_problem: a path is not",
  M.worktree_problem("a/b"), "a worktree name is a name, not a path: a/b")
eq("worktree_problem: dot is refused", M.worktree_problem("."), "a worktree name cannot be .")
eq("random_branch_name: a name from the lists",
  M.random_branch_name(function() return 1 end), "feat/amber-badger")
eq("state_dir_for: an absolute XDG_STATE_HOME",
  M.state_dir_for("/tmp/state", "/home/x"), "/tmp/state/rex-config")
eq("state_dir_for: a relative one means unset",
  M.state_dir_for("relative", "/home/x"), "/home/x/.local/state/rex-config")
eq("state_dir_for: neither set lands on nobody's home",
  M.state_dir_for(nil, nil), "/.local/state/rex-config")

if fails > 0 then
  error(table.concat(notes, "\n") .. string.format("\n%u of %u assertions failed", fails, count), 0)
end

return { ok = true, assertions = count }
