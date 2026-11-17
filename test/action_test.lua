-- Tests for work_new_go: the session, the tab and the claim the picker's
-- hand-back asks for.
--
-- A stub `rex` global stands in for the app, as in setup_test.lua: rex.call
-- answers from a table per method, rex.exec answers through the stub shell, and
-- anything the module calls that a test has not stubbed raises rather than
-- answering plausibly. The shapes are the live ones: rex.call reports a failed
-- request by returning nil and a message, session.create and session.new_window
-- answer with the window they made, and rex.layout.block returns a layout node.

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

-- The guard on the guard: a map table whose value changed, and one that lost
-- its only key, each have to compare unequal. Without this the comparison
-- above could quietly go back to element lists and every map assertion in
-- this file would pass no matter what it was handed.
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

-- The guard on eq() itself, not only on same(): the two proofs above pass
-- whichever comparison eq() uses, so re-inlining the old element-wise one into
-- eq() would leave every map assertion in this file passing no matter what it
-- was handed. A probe that has to fail proves the wiring. Its own FAIL line is
-- sent to /dev/null -- a green run should not print one -- and the totals are
-- put back, so the probe leaves no trace in them.
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

-- One field of a returned table, so a false value is not lost to Lua's and/or.
local function field(value, key)
  if type(value) ~= "table" then return nil end
  return value[key]
end

local function sorted_keys(table_)
  local keys = {}
  for key in pairs(table_ or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- The stub `rex` global. call_replies and exec_replies are keyed by the method
-- or command the module asks for; a reply may be a value or a function.
local function stub_rex()
  local stub = {
    actions = {},
    calls = {},
    exec_calls = {},
    queued = {},
    call_replies = {},
    exec_replies = {},
    -- What happened, in order: a rex.call by method name, a rex.exec by the
    -- command it ran. Ordering is half of the safety of the flow, so it is
    -- asserted rather than assumed.
    events = {},
  }

  function stub.action(spec) stub.actions[#stub.actions + 1] = spec end

  function stub.log(level, message) end

  -- Anything this task's code does not call raises rather than answering: a stub
  -- that returned a plausible value would hide a future misuse instead of
  -- failing on it.
  local function unused(name)
    return function()
      error("action_test: rex." .. name .. " was called, but no test stubs it", 2)
    end
  end

  -- rex.call answers a failed request with nil and a message, which is what the
  -- running server does; a test that wants a failure stubs that.
  function stub.call(method, request)
    stub.calls[#stub.calls + 1] = { method = method, request = request }
    stub.events[#stub.events + 1] = method
    local reply = stub.call_replies[method]
    if type(reply) == "function" then return reply(method, request) end
    if reply == nil then
      error("action_test: rex.call(" .. tostring(method) .. ") was called, but no test stubs it", 2)
    end
    return reply
  end

  -- A login-shell probe is one argv away from the command itself, so the reply
  -- is keyed by the command the way setup_test.lua does it.
  function stub.exec(argv, opts)
    stub.exec_calls[#stub.exec_calls + 1] = { argv = argv, cwd = opts and opts.cwd }
    local program = argv[1]
    if argv[2] == "-lc" then program = argv[3] end
    stub.events[#stub.events + 1] = program
    local reply = stub.exec_replies[program]
    if type(reply) == "function" then return reply(argv, opts) end
    if reply == nil then return nil, program .. ": executable file not found in PATH" end
    return reply
  end

  function stub.client_queue(action, args)
    stub.queued[#stub.queued + 1] = { action = action, args = args }
  end
  stub.client = { queue = function(action, args) return stub.client_queue(action, args) end }

  -- Confirmed against the running app: rex.layout.block returns the layout node
  -- itself, so a caller can hand it straight to a window or layer request.
  stub.layout = { block = function(spec) return { block = spec } end }

  stub.block = { call = unused("block.call") }
  stub.session = { new_layer = unused("session.new_layer"), close_layer = unused("session.close_layer") }
  stub.json = { decode = unused("json.decode"), encode = unused("json.encode") }
  return stub
end

local function fresh_rex()
  _G.rex = stub_rex()
  return _G.rex
end

local rex_stub = fresh_rex()
local M = dofile(here .. "/../init.lua")
M.setup{}

-- The project every test uses: a worktrunk repository whose main worktree is
-- main/, with a beads database reachable from it.
local PROJECT = "pmm-iris"
local ROOT = "/x/pmm-iris"
local MAIN = "/x/pmm-iris/main"
local BRANCH = "bug/58h"
local BEAD = "pmm-iris-58h"

-- What the picker hands back for a new branch on that bead.
local function payload(overrides)
  local args = {
    project = PROJECT, root = ROOT, main = MAIN,
    branch = BRANCH, bead = BEAD, title = "Diff the thing", create = true,
  }
  for key, value in pairs(overrides or {}) do args[key] = value end
  return args
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

-- The recorded argv and cwd of NAME, or an empty table when it never ran, so an
-- absent call gives a named FAIL rather than a Lua error.
local function exec_for(stub, name)
  for _, call in ipairs(stub.exec_calls) do
    if program(call) == name then return call end
  end
  return {}
end

-- The one recorded rex.call for a method, and how many there were. The request
-- is empty rather than nil for the same reason: a missing call has to read as a
-- failed assertion, not as a crash.
local function call_for(stub, method)
  for _, call in ipairs(stub.calls) do
    if call.method == method then return call end
  end
  return {}
end

local function request_of(stub, method)
  return call_for(stub, method).request or {}
end

local function calls_to(stub, method)
  local found = {}
  for _, call in ipairs(stub.calls) do
    if call.method == method then found[#found + 1] = call end
  end
  return found
end

-- A stub for a project with no tab for the branch yet: the session does not
-- exist, so it is created, then the tab is made.
local function new_branch_stub()
  local stub = fresh_rex()
  stub.call_replies["session.list"] = { sessions = { { session_id = "session:rex", label = "rex-config" } } }
  stub.call_replies["session.create"] = {
    session_id = "session:iris",
    initial_windows = { { window_id = "window:main", block_ids = { "block:main" }, revision = 1 } },
  }
  -- The attach reply carries the session's view, which is where the existing
  -- tabs come from.
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = {
      session_id = "session:iris",
      windows = { { window_id = "window:main", label = "main" } },
    },
  }
  stub.call_replies["session.new_window"] = {
    window_id = "window:tab", block_ids = { "block:tab" }, revision = 2,
  }
  stub.call_replies["client.list"] = { clients = { { client_id = "client:app" } } }
  stub.call_replies["client.perform"] = { performed_by = "client:app" }
  stub.exec_replies["bd update " .. BEAD .. " --claim"] = { ok = true, code = 0, stdout = "", stderr = "" }
  return stub
end

-- The same project, but the tab for the branch is already there.
local function existing_tab_stub()
  local stub = new_branch_stub()
  stub.call_replies["session.list"] = { sessions = { { session_id = "session:iris", label = PROJECT } } }
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = {
      session_id = "session:iris",
      windows = {
        { window_id = "window:main", label = "main" },
        { window_id = "window:tab", label = BRANCH },
      },
    },
  }
  return stub
end

-- session_for() ---------------------------------------------------------------

eq("session_for finds the project's session",
  M.session_for({ { label = PROJECT, session_id = "s1" } }, PROJECT), "s1")
eq("session_for ignores a session whose label only starts the same way",
  M.session_for({ { label = PROJECT .. "-2", session_id = "s2" } }, PROJECT), nil)
eq("session_for takes the exact label among many", M.session_for({
  { label = "rex-config", session_id = "s0" },
  { label = PROJECT, session_id = "s1" },
  { label = PROJECT .. "-2", session_id = "s2" },
}, PROJECT), "s1")
eq("session_for with no sessions", M.session_for(nil, PROJECT), nil)

-- find_tab() ------------------------------------------------------------------

eq("find_tab finds the branch's tab",
  M.find_tab({ { label = BRANCH, window_id = "w1" } }, BRANCH), "w1")
eq("find_tab needs the whole label",
  M.find_tab({ { label = BRANCH, window_id = "w1" } }, "bug/58"), nil)
eq("find_tab takes the branch's tab among the others", M.find_tab({
  { label = "main", window_id = "w0" },
  { label = BRANCH, window_id = "w1" },
}, BRANCH), "w1")
eq("find_tab with no windows", M.find_tab(nil, BRANCH), nil)

-- new_tab_argv() --------------------------------------------------------------

-- The tab does not run one program any more: it runs a POSIX sh wrapper that
-- switches the worktree, starts the agent in it, and leaves a login shell
-- behind when the agent exits. Everything the flow knows travels as a
-- positional parameter --
--
--   sh -c SCRIPT sh <create 0|1> <branch> <base> <remote> <agent> <agent args…>
--
-- because that is the only way a branch, a prompt or an agent name can reach
-- the wrapper without any shell parsing it as text. These assertions pin the
-- shape element by element.

-- The program the wrapper's sh is handed, as the module builds it: the one
-- string an interpolating implementation would have rewritten with the answer.
local WRAPPER = M.new_tab_argv(PROJECT, { branch = BRANCH, create = false })[3]
eq("the wrapper program is text", type(WRAPPER), "string")

-- sh -c takes the program, then the *next* word as $0: naming it "sh" is what
-- keeps $1 the create flag rather than the program's own name.
eq("sh is told what $0 is", M.new_tab_argv(PROJECT, { branch = BRANCH })[4], "sh")

eq("new_tab_argv for an existing worktree",
  M.new_tab_argv(PROJECT, { branch = BRANCH, create = false, bead = BEAD, title = "Diff" }),
  { "sh", "-c", WRAPPER, "sh", "0", BRANCH, "", "", "pi", "/brainstorming for bead " .. BEAD })

-- A create with no base answered and none configured: the picker resolves the
-- default itself, so the wrapper is told nothing and adds no --base.
eq("new_tab_argv for a new branch",
  M.new_tab_argv(PROJECT, { branch = BRANCH, create = true, bead = BEAD, title = "Diff" }),
  { "sh", "-c", WRAPPER, "sh", "1", BRANCH, "", "", "pi", "/brainstorming for bead " .. BEAD })

eq("new_tab_argv without a bead asks for plain brainstorming",
  M.new_tab_argv(PROJECT, { branch = "x", create = true, bead = "" }),
  { "sh", "-c", WRAPPER, "sh", "1", "x", "", "", "pi", "/brainstorming" })

-- A missing bead and an empty one are the same answer: no bead.
eq("new_tab_argv with no bead field at all",
  M.new_tab_argv(PROJECT, { branch = "x", create = false }),
  { "sh", "-c", WRAPPER, "sh", "0", "x", "", "", "pi", "/brainstorming" })

-- A hand-back always says whether to create, but leaving the field out must not
-- read as "create": that would add a worktree nobody asked for.
eq("new_tab_argv with no create field switches, creating nothing",
  M.new_tab_argv(PROJECT, { branch = "x", bead = "" }),
  { "sh", "-c", WRAPPER, "sh", "0", "x", "", "", "pi", "/brainstorming" })

-- base = false is the picker's "let worktrunk choose": an empty base parameter,
-- which is the wrapper's "no --base at all" -- and no remote to fetch.
do
  local base = M.options.base
  M.options.base = false
  eq("no base parameter when the option says so",
    M.new_tab_argv(PROJECT, { branch = "x", create = true })[7], "")
  eq("no remote parameter when the option says so",
    M.new_tab_argv(PROJECT, { branch = "x", create = true })[8], "")
  M.options.base = base
end

-- The answer is data, never program text: a prompt with spaces, quotes and a
-- newline, and a branch with a slash, each arrive as one argument, and none of
-- it appears in the script the shell parses. A bead title can carry a newline,
-- and a newline is the one character that would split a value into two
-- commands if it were pasted into a program.
do
  local bead_prompt, agent_args = M.options.bead_prompt, M.options.agent_args
  M.options.bead_prompt = 'work on {branch}: "don\'t" $(id)\nsecond line; {id}'
  M.options.agent_args = { "--thinking", "high" }
  local prompt = 'work on bug/58h: "don\'t" $(id)\nsecond line; ' .. BEAD
  local argv = M.new_tab_argv(PROJECT, { branch = BRANCH, create = true, bead = BEAD })
  eq("the branch is one argument", argv[6], BRANCH)
  eq("the agent's arguments and the prompt are arguments too",
    { argv[9], argv[10], argv[11], argv[12] }, { "pi", "--thinking", "high", prompt })
  eq("the prompt keeps its newline", argv[12]:match("\n(.*)$"), "second line; " .. BEAD)
  eq("the number of arguments is the number of values", #argv, 12)
  eq("the branch is not pasted into the program text", argv[3]:find(BRANCH, 1, true), nil)
  eq("the prompt is not pasted into the program text", argv[3]:find(prompt, 1, true), nil)
  eq("the prompt's second line is not in the program text",
    argv[3]:find("second line", 1, true), nil)
  M.options.bead_prompt, M.options.agent_args = bead_prompt, agent_args
end

-- The configured placeholders all arrive: the prompt is the plugin's, not one
-- baked into this file.
do
  local bead_prompt, agent = M.options.bead_prompt, M.options.agent
  M.options.bead_prompt = "work on {project}/{branch} for {id}: {title}"
  M.options.agent = "claude"
  eq("new_tab_argv renders the configured prompt",
    M.new_tab_argv(PROJECT, { branch = BRANCH, create = false, bead = BEAD, title = "Diff" }),
    { "sh", "-c", WRAPPER, "sh", "0", BRANCH, "", "", "claude",
      "work on pmm-iris/bug/58h for " .. BEAD .. ": Diff" })
  M.options.bead_prompt, M.options.agent = bead_prompt, agent
end

-- Without a branch or an agent there is nothing to start, and a tab that ran
-- something arbitrary would be worse than a refusal. A *configured* agent has to
-- be a program; only the picker's answer may be "none".
eq("a tab needs a branch", pcall(M.new_tab_argv, PROJECT, {}), false)
do
  local agent = M.options.agent
  M.options.agent = ""
  eq("a tab needs an agent", pcall(M.new_tab_argv, PROJECT, { branch = "x" }), false)
  M.options.agent = agent
end

-- The picker's two other answers. The agent it names is the one this tab starts
-- -- it is an answer about one tab, so it overrides the configured default per
-- tab rather than changing it -- and the prompt typed there is what the agent is
-- asked, in place of either template.
eq("new_tab_argv starts the agent the picker chose",
  M.new_tab_argv(PROJECT, { branch = BRANCH, create = false, bead = BEAD, title = "Diff", agent = "claude" }),
  { "sh", "-c", WRAPPER, "sh", "0", BRANCH, "", "", "claude", "/brainstorming for bead " .. BEAD })

eq("new_tab_argv sends the prompt the picker was given",
  M.new_tab_argv(PROJECT, { branch = "x", create = true, prompt = "why is the guard flaky?" }),
  { "sh", "-c", WRAPPER, "sh", "1", "x", "", "", "pi", "why is the guard flaky?" })

eq("a typed prompt wins over the bead's",
  M.new_tab_argv(PROJECT, { branch = "x", bead = BEAD, title = "Diff", prompt = "just look" })[10],
  "just look")

-- "none" is an empty agent parameter, and an empty parameter is what keeps the
-- wrapper from exec'ing nothing. With no agent there is nobody to be prompted,
-- so a prompt the user did not type themselves is not sent at all -- the
-- templates are for an agent that is about to start -- and the one they did type
-- is, because the wrapper prints it above the shell it leaves. The agent's own
-- arguments stop with the agent: there is no program left to give them to.
do
  local agent_args = M.options.agent_args
  M.options.agent_args = { "--thinking", "high" }
  eq("new_tab_argv with no agent",
    M.new_tab_argv(PROJECT, { branch = "x", agent = "" }),
    { "sh", "-c", WRAPPER, "sh", "0", "x", "", "", "", "" })
  eq("new_tab_argv with no agent keeps a prompt that was typed",
    M.new_tab_argv(PROJECT, { branch = "x", agent = "", prompt = "look first" })[10],
    "look first")
  M.options.agent_args = agent_args
end

-- work_new_go(): the whole flow ----------------------------------------------

-- The hand-back from the picker arrives from `rex do`, whose origin is not a
-- key: the app clients are asked to show the session directly.
local stub = new_branch_stub()
local ok, result = pcall(M.work_new_go, { origin = "cli", session_id = "session:rex" }, payload())

eq("work_new_go succeeds", ok, true)
eq("work_new_go reports the tab it made", field(result, "window_id"), "window:tab")
eq("work_new_go reports that it created the tab", field(result, "created"), true)

-- The session: looked up by label, made when it is not there, and attached to so
-- that the session's own methods answer this connection.
eq("the sessions are listed", #calls_to(stub, "session.list"), 1)
eq("the session is created from the hand-back's project name",
  request_of(stub, "session.create").label, PROJECT)
do
  local window = request_of(stub, "session.create").initial_windows[1]
  eq("the new session opens with a main tab", window.window_label, "main")
  eq("the main tab starts in the main worktree", window.layout.block.options.cwd, MAIN)
  eq("the main tab is a shell", window.layout.block.flavor, "com.superlogical.terminal.shell")
end
eq("the session is attached to", request_of(stub, "session.attach").session_id, "session:iris")
-- The tabs come from that reply, not from a second session.view call: an
-- unstubbed rex.call raises, so the attach assertion above is what proves it
-- -- a view request here would abort this file, not assert.

-- The bead is claimed from the main worktree, through the login shell that has
-- bd on its PATH.
eq("the bead is claimed", exec_for(stub, "bd update " .. BEAD .. " --claim").argv,
  { shell(), "-lc", "bd update " .. BEAD .. " --claim" })
eq("the claim runs in the main worktree", exec_for(stub, "bd update " .. BEAD .. " --claim").cwd, MAIN)

-- The order matters: the bead is claimed before the tab is made, so an agent
-- never starts on a bead that is not its own.
do
  local claim_at, tab_at
  for i, event in ipairs(stub.events) do
    if event == "bd update " .. BEAD .. " --claim" then claim_at = i end
    if event == "session.new_window" then tab_at = i end
  end
  eq("the flow starts by listing Rex's sessions", stub.events[1], "session.list")
  eq("the bead is claimed before the tab is made",
    claim_at ~= nil and tab_at ~= nil and claim_at < tab_at, true)
end

-- The tab: one window, in the project's session, labelled with the branch, in
-- the main worktree, running the wrapper that switches, starts the agent and
-- leaves a login shell behind.
do
  local request = request_of(stub, "session.new_window")
  local options = request.layout.block.options
  eq("the tab is made in the project's session", request.session_id, "session:iris")
  eq("the tab is labelled with the branch", request.window_label, BRANCH)
  eq("the tab's block is labelled too", request.layout.block.label, BRANCH)
  eq("the tab starts in the main worktree", options.cwd, MAIN)
  eq("the tab runs the wrapper", options.command, M.new_tab_argv(PROJECT, payload()))
  eq("the wrapper is asked to create the worktree", options.command[5], "1")
  eq("the wrapper is given the branch", options.command[6], BRANCH)
  eq("the wrapper is given the prompt", options.command[#options.command],
    "/brainstorming for bead " .. BEAD)
  -- The login shell the wrapper leaves behind is the tab's last program, so the
  -- pane closes when the shell exits; a kept-open pane with no program in it is
  -- the dead tab this task exists to remove. Asserted as a property, not as
  -- "nothing is set": what the requirement forbids is a pane outliving its
  -- program, which is what an exit of on_completion = false asks for. A future
  -- exit setting that still closes the pane with its program is not this
  -- regression, and is not refused here.
  local exit = options.exit
  eq("the tab is not kept open after the agent exits",
    exit == nil or exit.on_completion ~= false, true)
end

-- Showing it: the app client is asked, and asked for the tab rather than just
-- the session, so the branch is what comes into view.
eq("the app client is asked to show it", request_of(stub, "client.perform").client_id, "client:app")
eq("the client shows the session", request_of(stub, "client.perform").action, "session.select")
do
  local args = request_of(stub, "client.perform").args
  eq("the client's args name the session", args.session_id, "session:iris")
  eq("the client shows the tab", args.window_id, "window:tab")
end
eq("the client is told where the request came from",
  request_of(stub, "client.perform").origin, "cli")
eq("nothing is queued without an invocation", #stub.queued, 0)

-- From a key the app is running the action itself, so the selection is queued
-- instead of being performed by another client.
stub = new_branch_stub()
ok = pcall(M.work_new_go, { origin = "key", session_id = "session:rex" }, payload())
eq("a key press succeeds", ok, true)
eq("a key press queues the selection", stub.queued[1] and stub.queued[1].action, "session.select")
do
  local args = stub.queued[1] and stub.queued[1].args or {}
  eq("the queued selection names the session", args.session_id, "session:iris")
  eq("the queued selection names the tab", args.window_id, "window:tab")
end
eq("a key press asks no client directly", #calls_to(stub, "client.perform"), 0)

-- The palette goes the same way as a key.
stub = new_branch_stub()
pcall(M.work_new_go, { origin = "palette", session_id = "session:rex" }, payload())
eq("the palette queues the selection", stub.queued[1] and stub.queued[1].action, "session.select")

-- A second press for the same branch: the tab is there, so it is selected and
-- nothing else happens -- one tab, one worktree, one claim.
stub = existing_tab_stub()
local ok_again, again = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a repeat press succeeds", ok_again, true)
eq("a repeat press selects the tab that is already there", field(again, "window_id"), "window:tab")
eq("a repeat press creates nothing", field(again, "created"), false)
eq("a repeat press makes no tab", #calls_to(stub, "session.new_window"), 0)
eq("a repeat press claims nothing", #stub.exec_calls, 0)
eq("a repeat press makes no session", #calls_to(stub, "session.create"), 0)
do
  local args = request_of(stub, "client.perform").args
  eq("a repeat press still shows the session", args.session_id, "session:iris")
  eq("a repeat press still shows the tab", args.window_id, "window:tab")
end

-- A session whose label merely starts with the project's name is not the
-- project's session: the flow makes the right one.
stub = new_branch_stub()
stub.call_replies["session.list"] = { sessions = {
  { session_id = "session:other", label = PROJECT .. "-2" },
} }
pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a look-alike session is not adopted", request_of(stub, "session.create").label, PROJECT)
eq("the tab goes to the session the flow made",
  request_of(stub, "session.new_window").session_id, "session:iris")

-- A session that cannot be attached to is refused before anything is made: the
-- attach is what every later session method depends on.
stub = new_branch_stub()
stub.call_replies["session.attach"] = function() return nil, "session not found" end
local ok_unattached, unattached = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a session that cannot be attached to fails", ok_unattached, false)
contains("the failure says it could not attach", unattached, "could not attach to the " .. PROJECT .. " session")
contains("the failure says what Rex said", unattached, "session not found")
eq("a session that cannot be attached to claims nothing", #stub.exec_calls, 0)
eq("a session that cannot be attached to makes no tab", #calls_to(stub, "session.new_window"), 0)

-- An attach that answers without a view leaves the flow with no list of tabs, and
-- "no list" is not "no tabs": read as one, every press would make another tab and
-- take another claim. It is refused instead.
stub = new_branch_stub()
stub.call_replies["session.attach"] = { client_id = "client:app" }
local ok_no_view, no_view = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("an attach with no view fails", ok_no_view, false)
contains("the failure says the view is missing", no_view, "returned no view")
contains("the failure names the tab list", no_view, "list of tabs")
eq("an attach with no view claims nothing", #stub.exec_calls, 0)
eq("an attach with no view makes no tab", #calls_to(stub, "session.new_window"), 0)

-- A view without windows is a session with no tabs -- the server leaves an empty
-- list out -- so that is where a first tab comes from, not a reason to refuse.
stub = new_branch_stub()
stub.call_replies["session.attach"] = {
  client_id = "client:app",
  view = { session_id = "session:iris", label = PROJECT, revision = 0 },
}
local ok_empty, empty = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a session with no windows still gets its tab", ok_empty, true)
eq("a session with no windows makes the tab", field(empty, "created"), true)
eq("a session with no windows still claims the bead", #stub.exec_calls, 1)

-- A windows field that is there and is not a list is a shape this cannot read,
-- not a session with no tabs: refused by name, so a second press cannot make a
-- second tab and take a second claim.
stub = new_branch_stub()
stub.call_replies["session.attach"] = {
  client_id = "client:app",
  view = { session_id = "session:iris", windows = "main, tab" },
}
local ok_bad_windows, bad_windows = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a view whose windows are not a list fails", ok_bad_windows, false)
contains("the failure names what the windows were", bad_windows, "windows are a string")
contains("the failure still names the tab list", bad_windows, "list of tabs")
eq("a view whose windows are not a list makes no tab", #calls_to(stub, "session.new_window"), 0)
eq("a view whose windows are not a list claims nothing", #stub.exec_calls, 0)

-- A bead that cannot be claimed stops the flow before a tab is made: an agent
-- started on an unclaimed bead is worse than an error.
stub = new_branch_stub()
stub.exec_replies["bd update " .. BEAD .. " --claim"] = {
  ok = false, code = 1, stdout = "", stderr = "mise ERROR bd is not a valid shim.\nsecond line\n",
}
local ok_unclaimed, unclaimed = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a bead that cannot be claimed fails", ok_unclaimed, false)
contains("the failure names the bead", unclaimed, BEAD)
contains("the failure says what bd said", unclaimed, "mise ERROR bd is not a valid shim.")
eq("a bead that cannot be claimed makes no tab", #calls_to(stub, "session.new_window"), 0)

-- A bd that cannot even start is the same: no tab.
stub = new_branch_stub()
stub.exec_replies["bd update " .. BEAD .. " --claim"] = nil
local ok_no_bd, no_bd = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a bd that cannot start fails", ok_no_bd, false)
contains("a bd that cannot start is named", no_bd, "executable file not found in PATH")
eq("a bd that cannot start makes no tab", #calls_to(stub, "session.new_window"), 0)

-- A bead id is the one thing from the hand-back that travels inside a command
-- line, so one that is not id-shaped is refused rather than run.
stub = new_branch_stub()
local ok_bad_id, bad_id = pcall(M.work_new_go, { origin = "cli" }, payload{ bead = "x; rm -rf /" })
eq("a bead id that is not one fails", ok_bad_id, false)
contains("a bead id that is not one is named", bad_id, "not a bead id")
eq("a bead id that is not one runs nothing", #stub.exec_calls, 0)
eq("a bead id that is not one makes no tab", #calls_to(stub, "session.new_window"), 0)

-- No bead: no claim at all, and the plain prompt.
stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, payload{ bead = "", title = "" })
eq("no bead means no claim", #stub.exec_calls, 0)
eq("no bead means the plain prompt",
  request_of(stub, "session.new_window").layout.block.options.command,
  M.new_tab_argv(PROJECT, payload{ bead = "", title = "" }))

-- The picker's other two answers reach the tab as well: an empty agent is its
-- "none", and the prompt it could not deliver still travels, because the wrapper
-- is what prints it above the shell it leaves behind.
stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" },
  payload{ bead = "", title = "", agent = "", prompt = "look before you leap" })
do
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("no agent means a tab that starts none", command[9], "")
  eq("no agent still carries the prompt", command[#command], "look before you leap")
end

stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, payload{ agent = "claude" })
eq("the agent the picker chose is the one the tab starts",
  request_of(stub, "session.new_window").layout.block.options.command[9], "claude")
eq("the configured agent is left alone", M.options.agent, "pi")

-- Switching to a worktree that already exists, with no tab for it yet: the tab
-- is made without --create, so no second worktree appears.
stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, payload{ create = false })
eq("an existing worktree is switched to",
  request_of(stub, "session.new_window").layout.block.options.command,
  M.new_tab_argv(PROJECT, payload{ create = false }))
eq("an existing worktree sends no base",
  request_of(stub, "session.new_window").layout.block.options.command[7], "")

-- A session that cannot be shown leaves the tab in place and says so, rather
-- than throwing the work away.
stub = new_branch_stub()
stub.call_replies["client.list"] = { clients = {} }
local ok_no_client, no_client = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a session that cannot be shown fails", ok_no_client, false)
contains("the failure says the tab was made", no_client, "was created")
contains("the failure names the reason", no_client, "no app client")
eq("the tab is still there", #calls_to(stub, "session.new_window"), 1)

-- A client that refuses is reported the same way.
stub = new_branch_stub()
stub.call_replies["client.perform"] = function() return nil, "no app client is connected" end
local ok_refused, refused = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a client that refuses fails", ok_refused, false)
contains("a client that refuses is named", refused, "no app client is connected")

-- A hand-back that is missing what the flow needs is refused before anything is
-- made.
stub = new_branch_stub()
local ok_no_branch, no_branch = pcall(M.work_new_go, { origin = "cli" }, payload{ branch = "" })
eq("a hand-back with no branch fails", ok_no_branch, false)
contains("the failure names the branch", no_branch, "branch")
eq("a hand-back with no branch makes nothing", #stub.calls, 0)
eq("a hand-back with no branch claims nothing", #stub.exec_calls, 0)

stub = new_branch_stub()
local ok_no_project, no_project = pcall(M.work_new_go, { origin = "cli" }, { branch = BRANCH, main = MAIN })
eq("a hand-back with no project fails", ok_no_project, false)
contains("the failure names the project", no_project, "project")
eq("a hand-back with no project makes nothing", #stub.calls, 0)

-- The hand-back's paths are the one part of it that Rex resolves against its
-- own working directory rather than the float's, so a relative one has to be
-- refused where it arrives. new-work.sh refuses them for the picker's own
-- runs; this action is also a `rex do` entry point, so it checks for itself.
for _, name in ipairs({ "main", "root" }) do
  stub = new_branch_stub()
  local ok_relative, relative = pcall(M.work_new_go, { origin = "cli" }, payload{
    [name] = "pmm-iris/main",
  })
  eq("a relative " .. name .. " fails", ok_relative, false)
  contains("a relative " .. name .. " is named", relative, "relative " .. name)
  eq("a relative " .. name .. " makes nothing", #stub.calls, 0)
  eq("a relative " .. name .. " claims nothing", #stub.exec_calls, 0)
end

-- The bead is claimed before the tab is made, so a tab that cannot be made is
-- the one failure that leaves a claim behind: the error has to say how to
-- give it back, or the bead stays in progress with nothing working on it.
stub = new_branch_stub()
stub.call_replies["session.new_window"] = function() return nil, "no such session" end
local ok_no_tab, no_tab = pcall(M.work_new_go, { origin = "cli" }, payload())
eq("a tab that cannot be made fails", ok_no_tab, false)
contains("the failure says what Rex said", no_tab, "no such session")
contains("the failure says the bead is claimed", no_tab, "still claimed")
contains("the failure says how to release the claim", no_tab, 'bd unclaim ' .. BEAD)

-- With no bead there is no claim to release, so the remedy has no business
-- in the message.
stub = new_branch_stub()
stub.call_replies["session.new_window"] = function() return nil, "no such session" end
local ok_no_tab_no_bead, no_tab_no_bead = pcall(M.work_new_go, { origin = "cli" },
  payload{ bead = "", title = "" })
eq("a tab that cannot be made fails without a bead too", ok_no_tab_no_bead, false)
contains("no bead means no claim to release", no_tab_no_bead, "no such session")
eq("no bead means no release advice", tostring(no_tab_no_bead):find("bd unclaim", 1, true), nil)

-- The action's declaration ----------------------------------------------------

-- Rex silently drops KEY=VALUE pairs an action does not declare, so work_new_go
-- has to declare every field the picker hands back.
do
  local go
  for _, spec in ipairs(rex_stub.actions) do
    if spec.name == "work_new_go" then go = spec end
  end
  eq("work_new_go is registered", type(go), "table")
  eq("work_new_go declares its arguments", sorted_keys(go and go.args and go.args.properties),
    { "agent", "base", "base_remote", "bead", "blank", "branch", "create",
      "main", "project", "prompt", "root", "title" })
  eq("work_new_go requires what the picker always sends",
    go and go.args.required, { "project", "root", "main", "branch" })
  eq("the arguments are typed", go and go.args.properties.create, { type = "boolean" })
  eq("blank is declared a boolean", go and go.args.properties.blank,
    { type = "boolean" })
  eq("base admits both the ref and the wt-default sentinel",
    go and go.args.properties.base, { type = { "string", "boolean" } })
  eq("base_remote is declared a string", go and go.args.properties.base_remote,
    { type = "string" })
end

-- The answers the last two tasks added, taken through Rex rather than handed
-- to the action directly. An action only sees the pairs its schema declares --
-- `rex do work_new_go blank=true` is refused outright without the declaration,
-- and a payload filtered against it loses the field -- so a field the picker
-- sends but the action never names can be gone before new_tab_argv sees it, and
-- the flow then falls back to the old behaviour (a configured base, the no-bead
-- prompt) with nothing on screen to show for it. Filtering the payload through
-- the registered declaration pins the declaration and the tab's argv together.
local function as_rex_passes(name, args)
  local declared = {}
  for _, spec in ipairs(rex_stub.actions) do
    if spec.name == name then
      declared = (spec.args and spec.args.properties) or {}
    end
  end
  local typed = {}
  for key, value in pairs(args or {}) do
    if declared[key] ~= nil then typed[key] = value end
  end
  return typed
end

stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, as_rex_passes("work_new_go", payload{
  base = "upstream/main", base_remote = "upstream", blank = true,
}))
do
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("the base the picker chose reaches the tab", command[7], "upstream/main")
  eq("the remote that base lives on reaches the tab", command[8], "upstream")
  eq("a blank answer appends no prompt word", #command, 9)
  eq("a blank answer leaves the agent last", command[#command], M.options.agent)
end

-- The wt-default sentinel is false, and it has to stay false all the way: a
-- configuration naming a base must not undo the picker's answer, and a
-- declaration that turned it into the string "false" would send `--base false`
-- to worktrunk.
do
  local saved = M.options.base
  M.options.base = "main"
  stub = new_branch_stub()
  pcall(M.work_new_go, { origin = "cli" }, as_rex_passes("work_new_go", payload{
    base = false,
  }))
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("the wt-default sentinel reaches the tab as no base", command[7], "")
  eq("the wt-default sentinel carries no remote", command[8], "")
  M.options.base = saved
end

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
