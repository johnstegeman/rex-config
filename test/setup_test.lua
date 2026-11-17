-- Tests for the Rex-facing half of init.lua: setup(), project resolution and the
-- work_new and work_done actions.
--
-- A stub `rex` global stands in for the app, so these run with no Rex server,
-- no git repository and no beads database: every call the module makes is
-- recorded, and the answers come from tables each test fills in. The stub's
-- shapes are the ones the real API hands back (rex.exec replies with ok, code,
-- stdout and stderr; the session and block helpers return nil plus a message
-- when they fail).

local here = (arg and arg[0] or ""):match("^(.*)/") or "."
local fails = 0
local count = 0

local function show(value)
  if value == nil then return "<nil>" end
  if type(value) == "table" then
    local parts = {}
    for i = 1, #value do parts[i] = show(value[i]) end
    -- A map table has no array part at all, so its keys have to be shown too:
    -- otherwise every map prints as {} and a failure names nothing.
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "number" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = tostring(key) .. " = " .. show(value[key])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

-- Whether two values are the same. Tables are compared key by key, not just
-- element by element: a map table carries no array part, so looking only at
-- its elements compares every two maps equal -- which is how a declaration
-- that lost its `type`, or changed it, passed anyway.
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

-- The guard on the guard, as in action_test.lua: a map table whose value
-- changed, and one that lost its only key, each have to compare unequal, so
-- the comparison cannot quietly go back to element lists.
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

-- The guard on eq() itself, not only on same(), as in action_test.lua: the two
-- proofs above pass whichever comparison eq() uses, so re-inlining the old
-- element-wise one into eq() would leave every map assertion here passing no
-- matter what it was handed. A probe that has to fail proves the wiring; its
-- FAIL line is swallowed and the totals are put back afterwards.
do
  local fails_before, count_before = fails, count
  local saved_stderr, sink = io.stderr, io.open("/dev/null", "w")
  if sink ~= nil then
    io.stderr = sink
  end
  eq("the eq wiring probe", { type = "string" }, { type = "boolean" })
  if sink ~= nil then
    io.stderr = saved_stderr
    sink:close()
  end
  local recorded = fails - fails_before
  fails, count = fails_before, count_before
  eq("eq records a map mismatch", recorded, 1)
end

-- For messages, where only the part that names the problem matters.
local function contains(name, text, needle)
  count = count + 1
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    fails = fails + 1
    io.stderr:write("FAIL " .. name .. "\n  got:  " .. show(text) .. "\n  want: a message containing " .. show(needle) .. "\n")
  end
end

-- The stub `rex` global. exec_replies and json_replies are keyed by what the
-- module asks for (a program name, a whole JSON document); process_reply is
-- what com.superlogical.terminal's process method answers.
local function stub_rex()
  local stub = {
    actions = {},
    warns = {},
    calls = {},
    exec_calls = {},
    block_calls = {},
    layers = {},
    closed_layers = {},
    call_replies = {},
    exec_replies = {},
    json_replies = {},
  }

  function stub.action(spec) stub.actions[#stub.actions + 1] = spec end

  function stub.log(level, message) stub.warns[#stub.warns + 1] = { level = level, message = message } end

  -- Anything this task's code does not call raises rather than answering: a stub
  -- that returned a plausible value would hide a future misuse instead of failing.
  local function unused(name)
    return function()
      error("setup_test: rex." .. name .. " was called, but no test stubs it", 2)
    end
  end
  stub.bind = unused("bind")

  -- The server's methods answer from call_replies, keyed by method, the way
  -- action_test.lua does it: a method no test stubs raises rather than
  -- answering plausibly, which is what keeps a new call from going unnoticed.
  function stub.call(method, request)
    stub.calls[#stub.calls + 1] = { method = method, request = request }
    local reply = stub.call_replies[method]
    if type(reply) == "function" then return reply(method, request) end
    if reply == nil then
      error("setup_test: rex.call(" .. tostring(method) .. ") was called, but no test stubs it", 2)
    end
    return reply
  end

  -- nil is a program Rex could not start, which is also what the real one
  -- returns, with a message as its second value. A login-shell probe is one
  -- argv away from the command itself, so it answers by that instead.
  function stub.exec(argv, opts)
    stub.exec_calls[#stub.exec_calls + 1] = { argv = argv, cwd = opts and opts.cwd }
    local program = argv[1]
    if argv[2] == "-lc" then program = argv[3] end
    local reply = stub.exec_replies[program]
    if type(reply) == "function" then return reply(argv, opts) end
    if reply == nil then return nil, program .. ": executable file not found in PATH" end
    return reply
  end

  -- rex.json.decode does not raise on bad text: it returns nil and this message
  -- (measured against the running server), so the stub does the same.
  stub.json = {
    decode = function(text)
      local value = stub.json_replies[text]
      if value == nil then return nil, "rex.json.decode: text is not valid JSON" end
      return value
    end,
    encode = unused("json.encode"),
  }

  -- process_reply is either the one answer every block gets or a function of the
  -- request, for the flows that ask several blocks and depend on which is which.
  function stub.block_call(creator, method, request)
    stub.block_calls[#stub.block_calls + 1] = { creator = creator, method = method, request = request }
    if stub.process_reply == nil then return nil, "no terminal here" end
    if type(stub.process_reply) == "function" then return stub.process_reply(request) end
    return stub.process_reply
  end
  stub.block = { call = function(creator, method, request) return stub.block_call(creator, method, request) end }

  stub.session = {
    new_layer = function(request)
      stub.layers[#stub.layers + 1] = request
      return { layer_id = "layer:" .. #stub.layers, block_ids = { "block:" .. #stub.layers } }
    end,
    close_layer = function(request)
      stub.closed_layers[#stub.closed_layers + 1] = request
      return { revision = 1 }
    end,
  }

  stub.layout = { block = unused("layout.block") }
  return stub
end

local function fresh_rex()
  _G.rex = stub_rex()
  return _G.rex
end

local rex_stub = fresh_rex()
local M = dofile(here .. "/../init.lua")

-- A stub that answers the way a worktrunk project with a beads database does,
-- so each refusal test only has to break the one thing it is about.
local function project_stub()
  local stub = fresh_rex()
  stub.exec_replies.git = { ok = true, code = 0, stdout = "/x/pmm-iris/.git\n", stderr = "" }
  stub.exec_replies["wt list --format=json"] = { ok = true, code = 0, stdout = "wt list", stderr = "" }
  stub.json_replies["wt list"] = {
    items = {
      { worktree = { path = "/x/pmm-iris/main", main = true } },
      { worktree = { path = "/x/pmm-iris/bug-1", main = false } },
    },
  }
  stub.exec_replies["bd ready --json"] = { ok = true, code = 0, stdout = "[]", stderr = "" }
  stub.process_reply = {
    foreground = { name = "pi", cwd = "/x/pmm-iris/main" },
    child = { name = "login" },
  }
  return stub
end

local function action_names(actions)
  local names = {}
  for i, spec in ipairs(actions) do names[i] = spec.name end
  return names
end

-- The login shell is the module's SHELL, and the stub answers for it by that
-- same path.
local function shell()
  return os.getenv("SHELL") or "/bin/sh"
end

-- What a recorded call ran: the program itself, or the command a login-shell
-- probe handed to the shell.
local function program(call)
  if call.argv[2] == "-lc" then return call.argv[3] end
  return call.argv[1]
end

-- The first exec call that ran NAME, so assertions do not count how many probes
-- the module made before it.
local function call_for(stub, name)
  for _, call in ipairs(stub.exec_calls) do
    if program(call) == name then return call end
  end
end

-- The request a recorded server method was called with, found by method rather
-- than by position: an assertion that took the first call would only hold while
-- nothing else happens to call rex.call first. Empty rather than nil for a
-- method that was never called, so the assertion fails by name instead.
local function request_of(stub, method)
  for _, call in ipairs(stub.calls) do
    if call.method == method then return call.request end
  end
  return {}
end

-- setup() -------------------------------------------------------------------

eq("setup returns the module", M.setup{} == M, true)
eq("agent default", M.options.agent, "pi")
eq("agent_args default", M.options.agent_args, {})
eq("bead_prompt default", M.options.bead_prompt, "/brainstorming for bead {id}")
eq("no_bead_prompt default", M.options.no_bead_prompt, "/brainstorming")
-- Unset, so the picker resolves the remote's own default branch rather than
-- being told one here: a configured base moves the cycle's first entry instead.
eq("base default", M.options.base, nil)
eq("bounds default", M.options.bounds, { 0.15, 0.1, 0.7, 0.8 })
eq("script default is new-work.sh", (tostring(M.options.script):match("/new%-work%.sh$") ~= nil), true)
local script_file = io.open(tostring(M.options.script), "r")
eq("script default exists beside the module", script_file ~= nil, true)
if script_file then script_file:close() end

local done = rex_stub.actions[3] or {}
local done_go = rex_stub.actions[4] or {}

eq("setup registers four actions", #rex_stub.actions, 4)
eq("action names", action_names(rex_stub.actions),
  { "work_new", "work_new_go", "work_done", "work_done_go" })
eq("work_new title", rex_stub.actions[1].title, "New work: from a bead…")
eq("work_new category", rex_stub.actions[1].category, "New work")
eq("work_new_go category", rex_stub.actions[2].category, "New work")
eq("work_new run", type(rex_stub.actions[1].run), "function")
eq("work_new_go run", type(rex_stub.actions[2].run), "function")

-- The teardown is key-bound, so it takes no arguments: everything it needs is
-- the terminal it was pressed in.
eq("work_done title", done.title, "Done: tear down this worktree")
eq("work_done category", done.category, "New work")
eq("work_done takes no arguments", done.args, nil)
eq("work_done run", type(done.run), "function")

-- Its hand-back is registered now, though its action arrives in the next
-- task, so the palette order does not move later: the declaration is what a
-- named call is checked against.
eq("work_done_go title", done_go.title, "Done: remove the worktree the audit approved")
eq("work_done_go category", done_go.category, "New work")
eq("work_done_go run", type(done_go.run), "function")
eq("work_done_go declares its five fields",
  table.concat((done_go.args and done_go.args.required) or {}, ","),
  "project,root,main,workspace,path")
eq("work_done_go declares every field as a string",
  (done_go.args and done_go.args.properties) or {}, {
    project = { type = "string" }, root = { type = "string" },
    main = { type = "string" }, workspace = { type = "string" },
    path = { type = "string" },
  })

M.setup{ agent = "claude" }
eq("a caller's agent wins", M.options.agent, "claude")

local warns_before = #rex_stub.warns
M.setup{ nope = 1 }
eq("an unknown option warns exactly once", #rex_stub.warns - warns_before, 1)
eq("the warning's level", rex_stub.warns[#rex_stub.warns].level, "warn")
contains("the warning names the option", rex_stub.warns[#rex_stub.warns].message, "nope")
eq("an unknown option is not kept", M.options.nope, nil)
eq("an unknown option leaves the others alone", M.options.agent, "claude")
eq("a repeated setup registers nothing new", #rex_stub.actions, 4)

-- A string where a list belongs is one ipairs away from failing in the middle of
-- building a tab, so setup refuses it by name.
local ok_args, args_message = pcall(M.setup, { agent_args = "--thinking high" })
eq("a non-table agent_args is refused", ok_args, false)
contains("a non-table agent_args names the option", args_message, "agent_args")
eq("a refused agent_args leaves the option a list", type(M.options.agent_args), "table")

-- A table with one bad value applies none of it: the refusal comes before
-- anything is assigned, which is `setup`'s two visible passes (validate, then
-- assign).
--
-- The table is plain on purpose. An earlier version fixed the iteration order
-- with a `__pairs` metamethod, which only some interpreters honour -- Lua 5.4
-- removed it and LuaJIT never has it on -- so the assertion would have been
-- order-dependent where it mattered most. A plain table gives the guarantee for
-- every order instead: on any interpreter and any hash seed, a correct `setup`
-- leaves every option as it was. What a plain table cannot do is promise to
-- notice a single-pass regression on every run -- a single pass applies
-- whatever it meets before the bad key, which is some keys in some orders -- so
-- this is a guard, not a proof, and this comment is the honest half of it.
local options_before = {}
for key, value in pairs(M.options) do options_before[key] = value end
local ok_mixed, mixed_message = pcall(M.setup, {
  bead_prompt = "work on {id}", agent = "aider", agent_args = "--thinking high",
})
eq("a table with one bad value is refused", ok_mixed, false)
contains("a table with one bad value names the option", mixed_message, "agent_args")
eq("a table with one bad value applies none of it", M.options, options_before)

-- The login shell -------------------------------------------------------
--
-- Rex runs an action with its own PATH, which has no mise or Homebrew installs
-- on it, so wt and bd -- the tools the design puts on the login shell's PATH --
-- are asked for through SHELL, in place of Rex's PATH.

local stub = fresh_rex()
stub.exec_replies.git = { ok = false, code = 128, stdout = "", stderr = "fatal: not a git repository\n" }
M.project_for("/tmp")
eq("git runs as given, with no shell in the way", call_for(stub, "git").argv,
  { "git", "-C", "/tmp", "rev-parse", "--path-format=absolute", "--git-common-dir" })

stub = project_stub()
stub.exec_replies["wt list --format=json"] = nil
M.project_for("/x/pmm-iris/main")
eq("wt is run in the login shell", call_for(stub, "wt list --format=json").argv,
  { shell(), "-lc", "wt list --format=json" })
eq("wt still runs in the project root", call_for(stub, "wt list --format=json").cwd, "/x/pmm-iris")

-- project_for() -------------------------------------------------------------

stub = fresh_rex()
stub.exec_replies.git = { ok = false, code = 128, stdout = "",
  stderr = "fatal: not a git repository (or any of the parent directories): .git\n" }
local project, message = M.project_for("/tmp")
eq("not a repository returns nil", project, nil)
eq("not a repository message", message, "not a git repository: /tmp")
eq("git is asked for the absolute common dir", call_for(stub, "git").argv,
  { "git", "-C", "/tmp", "rev-parse", "--path-format=absolute", "--git-common-dir" })

stub = project_stub()
project = M.project_for("/x/pmm-iris/main")
eq("project root", project and project.root, "/x/pmm-iris")
eq("project name", project and project.name, "pmm-iris")
eq("project main worktree", project and project.main, "/x/pmm-iris/main")
eq("wt list is one command in the login shell", call_for(stub, "wt list --format=json").argv,
  { shell(), "-lc", "wt list --format=json" })
eq("wt list runs in the project root", call_for(stub, "wt list --format=json").cwd, "/x/pmm-iris")

-- The path that matters: worktrunk reports schema 2, and only a decoded
-- boolean main flag finds the main worktree.
stub.json_replies["wt list"] = { items = { { worktree = { path = "/x/pmm-iris/main", main = false } } } }
eq("no main worktree message", select(2, M.project_for("/x/pmm-iris/main")),
  "no main worktree found for /x/pmm-iris")

stub = project_stub()
stub.exec_replies["wt list --format=json"] = { ok = false, code = 1, stdout = "", stderr = "not a worktrunk repo\nsecond line\n" }
eq("wt failure message", select(2, M.project_for("/x/pmm-iris/main")),
  "worktrunk could not list worktrees for /x/pmm-iris: not a worktrunk repo")

stub = project_stub()
stub.exec_replies["wt list --format=json"] = { ok = false, code = 127, stdout = "", stderr = "wt: command not found\n" }
eq("a wt the login shell cannot find is reported", select(2, M.project_for("/x/pmm-iris/main")),
  "worktrunk could not list worktrees for /x/pmm-iris: wt: command not found")

-- The cross-task contract: a relative common dir names no project, so it is
-- refused rather than turned into empty strings.
stub = project_stub()
stub.exec_replies.git = { ok = true, code = 0, stdout = ".git\n", stderr = "" }
local relative_project, relative_message = M.project_for("/x/pmm-iris/main")
eq("a relative common dir returns nil", relative_project, nil)
contains("a relative common dir names the directory", relative_message, "/x/pmm-iris/main")

stub = project_stub()
stub.exec_replies.git = nil
eq("a git that cannot start says so", select(2, M.project_for("/tmp")),
  "git could not be run: git: executable file not found in PATH")

-- An unreadable listing is not the same as a listing with no main worktree, and
-- rex.json.decode answers bad text with nil plus a reason instead of raising.
stub = project_stub()
stub.json_replies["wt list"] = nil          -- stdout was not JSON
eq("garbage listing message", select(2, M.project_for("/x/pmm-iris/main")),
  "could not read the worktrunk listing for /x/pmm-iris: rex.json.decode: text is not valid JSON")

stub = project_stub()
stub.exec_replies["wt list --format=json"] = { ok = true, code = 0, stdout = "", stderr = "" }
eq("empty listing message", select(2, M.project_for("/x/pmm-iris/main")),
  "could not read the worktrunk listing for /x/pmm-iris: rex.json.decode: text is not valid JSON")

-- Valid JSON that is not an object -- a string, a number, null -- decodes without
-- a reason, so the message has to say what arrived instead of claiming there was
-- no value at all.
stub = project_stub()
stub.json_replies["wt list"] = "just a string"
eq("a listing that is not an object message", select(2, M.project_for("/x/pmm-iris/main")),
  "could not read the worktrunk listing for /x/pmm-iris: the listing decoded to a string, not an object")

-- has_beads() ---------------------------------------------------------------

stub = fresh_rex()
stub.exec_replies["bd ready --json"] = { ok = true, code = 0, stdout = "[]", stderr = "" }
eq("has_beads true", M.has_beads("/x/main"), true)
eq("bd ready is run in the login shell", call_for(stub, "bd ready --json").argv,
  { shell(), "-lc", "bd ready --json" })
eq("bd ready runs in the main worktree", call_for(stub, "bd ready --json").cwd, "/x/main")
stub.exec_replies["bd ready --json"] = { ok = false, code = 1, stdout = "",
  stderr = "Error: no beads database found\nHint: run 'bd where'\n" }
local beads, beads_reason = M.has_beads("/x/main")
eq("has_beads false", beads, false)
eq("bd reporting no database is no reason to give", beads_reason, nil)

-- bd ran but failed for a reason of its own: a broken mise shim is the real one.
stub.exec_replies["bd ready --json"] = { ok = false, code = 1, stdout = "",
  stderr = "mise ERROR bd is not a valid shim.\nsecond line\n" }
beads, beads_reason = M.has_beads("/x/main")
eq("has_beads false", beads, false)
eq("bd failing on its own reports why", beads_reason,
  "bd failed in /x/main: mise ERROR bd is not a valid shim.")

-- bd ran and failed without saying anything: it still ran.
stub.exec_replies["bd ready --json"] = { ok = false, code = 2, stdout = "", stderr = "" }
beads, beads_reason = M.has_beads("/x/main")
eq("a silent bd failure still counts as a run", beads_reason, "bd failed in /x/main: no error output")

-- bd could not even start.
stub.exec_replies["bd ready --json"] = nil
beads, beads_reason = M.has_beads("/x/main")
eq("has_beads false when bd cannot start", beads, false)
eq("bd that cannot start reports why", beads_reason,
  "bd could not be run in /x/main: bd ready --json: executable file not found in PATH")

-- work_new() ----------------------------------------------------------------

-- The options at their defaults: an earlier assertion in this file left the
-- agent set to claude, and the picker's default list is built from it.
M.setup{ agent = "pi" }

stub = project_stub()
local ok, result = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("work_new opens the picker", ok, true)
eq("work_new returns the layer id", type(result) == "table" and result.layer_id or result, "layer:1")
eq("the terminal's process is asked about this block", stub.block_calls[1].request.block_id, "block:1")
eq("the terminal's process is asked in this session", stub.block_calls[1].request.session_id, "session:1")
eq("the terminal's process is the terminal's", stub.block_calls[1].creator, "com.superlogical.terminal")
eq("the terminal's process method", stub.block_calls[1].method, "process")

eq("one float is opened", #stub.layers, 1)
local layer = stub.layers[1]
eq("the float opens in the terminal's session", layer.session_id, "session:1")
eq("the float uses the configured bounds", layer.bounds, { 0.15, 0.1, 0.7, 0.8 })
eq("the float takes focus", layer.focus, true)
eq("the float holds a shell", layer.layout.block.flavor, "com.superlogical.terminal.shell")
eq("the float's label", layer.layout.block.label, "new work")
eq("the picker starts in the main worktree", layer.layout.block.options.cwd, "/x/pmm-iris/main")
eq("the picker command", layer.layout.block.options.command,
  { M.options.script, "pick", "--main", "/x/pmm-iris/main", "--root", "/x/pmm-iris",
    "--project", "pmm-iris", "--agents", "pi" })

-- A second press replaces the picker instead of stacking another one.
local ok_again, result_again = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("a second press succeeds", ok_again, true)
eq("the second press opens its own float", type(result_again) == "table" and result_again.layer_id or result_again, "layer:2")
eq("the first float is closed", #stub.closed_layers, 1)
eq("the float that closed is the first one", stub.closed_layers[1].layer_id, "layer:1")

-- A terminal whose directory Rex cannot tell.
stub = project_stub()
stub.process_reply = nil
local ok_no_cwd, no_cwd_message = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("an unknown directory fails", ok_no_cwd, false)
contains("an unknown directory is named as the reason", no_cwd_message, "cannot tell which directory")
eq("an unknown directory opens nothing", #stub.layers, 0)

-- The foreground process has no directory, so the shell behind it answers.
stub = project_stub()
stub.process_reply = { foreground = { name = "login" }, child = { name = "login", cwd = "/tmp" } }
pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("the shell's directory is used when the foreground has none", call_for(stub, "git").argv[3], "/tmp")

stub = project_stub()
stub.exec_replies.git = { ok = false, code = 128, stdout = "", stderr = "fatal: not a git repository\n" }
local ok_outside, outside_message = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("a directory outside a repository fails", ok_outside, false)
eq("a directory outside a repository is named", outside_message, "not a git repository: /x/pmm-iris/main")
eq("a directory outside a repository opens nothing", #stub.layers, 0)

stub = project_stub()
stub.exec_replies["bd ready --json"] = { ok = false, code = 1, stdout = "", stderr = "no beads database found\n" }
local ok_no_beads, no_beads_message = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("a project without beads fails", ok_no_beads, false)
eq("a project without beads says beads is required", no_beads_message,
  "beads is required, but no beads database was found in /x/pmm-iris/main")
eq("a project without beads opens nothing", #stub.layers, 0)

-- A beads database that is there but cannot be asked is not a missing one.
stub = project_stub()
stub.exec_replies["bd ready --json"] = { ok = false, code = 1, stdout = "",
  stderr = "mise ERROR bd is not a valid shim.\n" }
local ok_broken_bd, broken_bd_message = pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("a bd that cannot be consulted fails", ok_broken_bd, false)
eq("a bd that cannot be consulted is not called a missing database", broken_bd_message,
  "bd failed in /x/pmm-iris/main: mise ERROR bd is not a valid shim.")
eq("a bd that cannot be consulted opens nothing", #stub.layers, 0)

-- base = false means "let worktrunk choose", so there is no ref to name -- and
-- the picker is told so, because a picker that is told nothing resolves the
-- remote's default branch and opens the screen on a base the configuration
-- opted out of. The screen then opens on "wt default" and ctrl-r can still move
-- off it: the opt-out sets the answer it starts on, it does not pin the field.
stub = project_stub()
M.setup{ base = false }
pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("no --base when base is false", stub.layers[1].layout.block.options.command,
  { M.options.script, "pick", "--main", "/x/pmm-iris/main", "--root", "/x/pmm-iris",
    "--project", "pmm-iris", "--no-base", "--agents", "pi" })

-- The agent question is a list, so every name is handed over in order: the first
-- is the one the picker offers as its default. A configured list replaces the
-- single agent rather than adding to it.
stub = project_stub()
M.setup{ base = "@", agents = { "pi", "claude" } }
pcall(M.work_new, { block_id = "block:1", session_id = "session:1" })
eq("configured agent names are all offered, in order",
  stub.layers[1].layout.block.options.command,
  { M.options.script, "pick", "--main", "/x/pmm-iris/main", "--root", "/x/pmm-iris",
    "--project", "pmm-iris", "--base", "@", "--agents", "pi", "--agents", "claude" })

-- agents is the picker's list, so it reaches the float as one --agents per name:
-- a string here is the same mistake as a string agent_args, and a name that is
-- not a name would reach the picker as nothing at all. pairs() cannot carry a
-- nil, so the unset state is put back by hand.
M.options.agents = nil
eq("agents has no default of its own", M.options.agents, nil)
local ok_agents, agents_message = pcall(M.setup, { agents = "pi" })
eq("a non-table agents is refused", ok_agents, false)
contains("a non-table agents names the option", agents_message, "agents")
eq("a refused agents leaves the option unset", M.options.agents, nil)
local ok_blank, blank_message = pcall(M.setup, { agents = { "pi", "" } })
eq("an empty agent name is refused", ok_blank, false)
contains("an empty agent name names the option", blank_message, "agents")
local ok_number, number_message = pcall(M.setup, { agents = { 3 } })
eq("a number in agents is refused", ok_number, false)
contains("a number in agents names the option", number_message, "agents")

-- work_done() ---------------------------------------------------------------
--
-- The teardown opens one float on the pane's own tab: the directory the audit is
-- about, the tab it will close, and -- the part only Rex can know -- what that
-- tab is still running. Nothing else is resolved here; the float's script asks
-- the project for the rest.

-- A worktrunk project whose session has one tab, feat/6c4, holding the pane the
-- action was pressed in and one other (blocks lists them, two by default).
-- What each block is running is answered per block, because "the pane's own
-- directory" and "what the tab is running" are the same question asked about
-- different blocks.
local function done_stub(by_block, blocks)
  local stub = project_stub()
  local held = {}
  for _, id in ipairs(blocks or { "block:1", "block:2" }) do
    held[#held + 1] = { block_id = id }
  end
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = {
      session_id = "session:1",
      windows = { {
        window_id = "window:feat",
        label = "feat/6c4",
        layers = { { blocks = held } },
      } },
    },
  }
  stub.process_reply = function(request)
    local reply = by_block[request.block_id]
    if type(reply) == "function" then return reply() end
    return reply
  end
  return stub
end

-- A tab of shells: the audit opens on the pane's own worktree, and the tab it
-- will close travels with it.
stub = done_stub({
  ["block:1"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
  ["block:2"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
})
local ok_done, done_layer = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1", origin = "key" })
eq("work_done opens the audit", ok_done, true)
eq("work_done returns the layer id",
  type(done_layer) == "table" and done_layer.layer_id or done_layer, "layer:1")
eq("the tab is read from the pane's own session",
  request_of(stub, "session.attach").session_id, "session:1")
eq("one float is opened", #stub.layers, 1)
local done_float = stub.layers[1]
eq("the done float opens in the terminal's session", done_float.session_id, "session:1")
eq("the done float uses the configured bounds", done_float.bounds, { 0.15, 0.1, 0.7, 0.8 })
eq("the done float takes focus", done_float.focus, true)
eq("the done float holds a shell",
  done_float.layout.block.flavor, "com.superlogical.terminal.shell")
eq("the done float's label", done_float.layout.block.label, "done")
eq("the audit starts in the main worktree", done_float.layout.block.options.cwd,
  "/x/pmm-iris/main")
eq("the audit command", done_float.layout.block.options.command,
  { M.options.script, "done", "--main", "/x/pmm-iris/main", "--root", "/x/pmm-iris",
    "--project", "pmm-iris", "--cwd", "/x/pmm-iris/feat-6c4",
    "--session", "session:1", "--window", "window:feat" })

-- A second press replaces the audit instead of stacking another one, the way
-- the picker does: two `done` runs in a tab would each be willing to remove the
-- worktree, so the one already on screen goes first. The counts are relative to
-- this stub, so the case holds wherever it sits.
stub = done_stub({
  ["block:1"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
  ["block:2"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
})
local ok_press, first_press = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1", origin = "key" })
local closed_after_first = #stub.closed_layers
local ok_press_again, second_press = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1", origin = "key" })
eq("a first press succeeds", ok_press, true)
eq("a second press succeeds", ok_press_again, true)
eq("the second press opens its own float",
  first_press.layer_id ~= second_press.layer_id, true)
eq("the second press closes exactly one float", #stub.closed_layers - closed_after_first, 1)
eq("the float that closed is the one the first press opened",
  stub.closed_layers[#stub.closed_layers].layer_id, first_press.layer_id)
eq("the float is closed in the terminal's session",
  stub.closed_layers[#stub.closed_layers].session_id, "session:1")

-- The tab's other blocks are somebody's programs, so each travels along as its
-- own --running: the script cannot see the tab, and this is the one blocker it
-- could never work out for itself. Two of them, in the order the tab lists
-- them, because the refusal names them in that order.
stub = done_stub({
  ["block:1"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
  ["block:2"] = { foreground = { name = "node" } },
  ["block:3"] = { foreground = { name = "pi" } },
}, { "block:1", "block:2", "block:3" })
pcall(M.work_done, { block_id = "block:1", session_id = "session:1", origin = "key" })
eq("the running programs travel with the audit", stub.layers[1].layout.block.options.command,
  { M.options.script, "done", "--main", "/x/pmm-iris/main", "--root", "/x/pmm-iris",
    "--project", "pmm-iris", "--cwd", "/x/pmm-iris/feat-6c4",
    "--session", "session:1", "--window", "window:feat",
    "--running", "node", "--running", "pi" })

-- A terminal whose directory Rex cannot tell: refused before anything opens, so
-- no float is left to close.
stub = done_stub({})
local ok_done_no_cwd, done_no_cwd_message = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1" })
eq("work_done with an unknown directory fails", ok_done_no_cwd, false)
contains("work_done's unknown directory is named", done_no_cwd_message,
  "cannot tell which directory")
eq("work_done with an unknown directory opens nothing", #stub.layers, 0)

-- A directory in no repository: there would be no project to audit.
stub = done_stub({ ["block:1"] = { foreground = { name = "fish", cwd = "/tmp" } } })
stub.exec_replies.git = { ok = false, code = 128, stdout = "",
  stderr = "fatal: not a git repository\n" }
local ok_done_outside, done_outside_message = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1" })
eq("work_done outside a repository fails", ok_done_outside, false)
eq("work_done outside a repository names the directory", done_outside_message,
  "not a git repository: /tmp")
eq("work_done outside a repository opens nothing", #stub.layers, 0)

-- A pane in no tab: the flow cannot name the window whose tab it would close,
-- so it refuses rather than open an audit whose last step would fail.
stub = done_stub({
  ["block:1"] = { foreground = { name = "fish", cwd = "/x/pmm-iris/feat-6c4" } },
})
stub.call_replies["session.attach"] = {
  client_id = "client:app",
  view = { session_id = "session:1", windows = {} },
}
local ok_done_no_tab, done_no_tab_message = pcall(M.work_done,
  { block_id = "block:1", session_id = "session:1" })
eq("work_done with no tab fails", ok_done_no_tab, false)
contains("work_done's refusal names the tab", done_no_tab_message, "cannot tell which tab")
eq("work_done with no tab opens nothing", #stub.layers, 0)

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
