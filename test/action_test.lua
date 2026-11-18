-- Tests for work_new: the six questions it asks, and the session, tab and claim
-- it makes once they are answered.
--
-- A stub `rex` global stands in for the app, as in setup_test.lua: rex.call
-- answers from a table per method, rex.exec answers through the stub shell, and
-- anything the module calls that a test has not stubbed raises rather than
-- answering plausibly. rex.ui is the same seam: a test scripts the answers it
-- wants, in the order the flow asks for them, and every question is recorded so
-- the prompt a person would have read can be asserted.
--
-- No test here reads or writes the developer's own agent memory: the flow is
-- run with io taken away, which is the module's own "this host has no io" path,
-- so the memory lives in the process and every case starts from what it put
-- there.

local here = (arg and arg[0] or ""):match("^(.*)/") or "."
-- The stock `lua` here is 5.5, where unpack moved to the table library; the
-- module itself is written for what Rex embeds (5.1), so the tests stay portable
-- the same way.
local unpack = table.unpack or unpack
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
-- its only key, each have to compare unequal, as in the other files.
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
-- or command the module asks for; exec_matches answers by a fragment of the
-- command, which is how a test keys the one word it cares about instead of
-- reproducing the argv the module builds.
local function stub_rex()
  local stub = {
    actions = {},
    calls = {},
    exec_calls = {},
    queued = {},
    call_replies = {},
    exec_replies = {},
    exec_matches = {},
    questions = {},
    -- What happened, in order: a rex.call by method name, a rex.exec by the
    -- command it ran. Ordering is half of the safety of the flow, so it is
    -- asserted rather than assumed.
    events = {},
  }

  function stub.action(spec) stub.actions[#stub.actions + 1] = spec end

  function stub.log(level, message) end

  -- Anything this file's code does not call raises rather than answering: a stub
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
  -- is keyed by the command the way setup_test.lua does it. A reply that is not
  -- keyed exactly is looked up by fragment next, last registered first, so a
  -- test overrides one reply of a project stub by registering it again.
  local function reply_for(argv)
    local program = argv[1]
    if argv[2] == "-lc" then program = argv[3] end
    return stub.exec_replies[program], program
  end

  function stub.exec(argv, opts)
    stub.exec_calls[#stub.exec_calls + 1] = { argv = argv, cwd = opts and opts.cwd }
    local reply, program = reply_for(argv)
    if reply == nil then
      local joined = table.concat(argv, " ")
      for index = #stub.exec_matches, 1, -1 do
        local match = stub.exec_matches[index]
        if joined:find(match.needle, 1, true) ~= nil then
          reply = match.reply
          break
        end
      end
    end
    stub.events[#stub.events + 1] = program
    if type(reply) == "function" then return reply(argv, opts) end
    if reply == nil then return nil, program .. ": executable file not found in PATH" end
    return reply
  end

  -- The answer to a rex.exec whose argv contains NEEDLE anywhere.
  function stub.on_exec(needle, reply)
    stub.exec_matches[#stub.exec_matches + 1] = { needle = needle, reply = reply }
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
  stub.ui = { pick = unused("ui.pick"), input = unused("ui.input") }

  -- The answers a test scripts, one per question in the order the flow asks
  -- them. An entry is the value to answer with, a function of the question, or
  -- a table { value = ..., reason = ... } for a question nobody answers. Every
  -- question is recorded as { kind, question }, so what the person was shown is
  -- assertable, and one asked with nothing scripted for it fails by name.
  function stub.ask(...)
    local queue = { ... }
    local asked = 0
    local function next_answer(kind, question)
      asked = asked + 1
      stub.questions[#stub.questions + 1] = { kind = kind, question = question }
      local answer = queue[asked]
      if answer == nil then
        error("action_test: question " .. asked .. " (" .. kind .. ", " .. tostring(question.title)
          .. ") was asked with no scripted answer", 2)
      end
      if type(answer) == "function" then return answer(question) end
      if type(answer) == "table" and (answer.value ~= nil or answer.reason ~= nil) then
        return answer.value, answer.reason
      end
      return answer
    end
    stub.ui.pick = function(question) return next_answer("pick", question) end
    stub.ui.input = function(question) return next_answer("input", question) end
  end

  -- The question with this title, which is how a test finds one of the six
  -- without counting. last_question is the same for a test that runs the flow
  -- more than once and cares what a later run opened on.
  function stub.question(title)
    for _, asked in ipairs(stub.questions) do
      if asked.question.title == title then return asked.question, asked.kind end
    end
    return nil
  end

  function stub.last_question(title)
    for index = #stub.questions, 1, -1 do
      if stub.questions[index].question.title == title then return stub.questions[index].question end
    end
    return nil
  end

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
-- main/, with a beads database reachable from it. The key was pressed in a
-- directory inside that worktree.
local PROJECT = "pmm-iris"
local ROOT = "/x/pmm-iris"
local MAIN = "/x/pmm-iris/main"
local CWD = "/x/pmm-iris/main/lib"
local BRANCH = "bug/58h"
local BEAD = "pmm-iris-58h"

-- new-work.sh's rows, exactly as that script prints them.
local BEAD_ROWS = "pmm-iris-58h\tPhase 3 follow-on\ttask\t1\n"
  .. "pmm-iris-a4l\tTreat index pages as non-extractable\tbug\t2\n"
local BASE_ROWS = "origin/main\torigin\n@\t\nmain\t\n"

-- What the picker questions are called, so a test can find one by name.
local BEAD_Q = "Bead for " .. PROJECT
local BRANCH_Q = "Branch for the new worktree"
local WORKTREE_Q = "Worktree name"
local BASE_Q = "Base for the new branch"
local AGENT_Q = "Agent for the new tab"
local PROMPT_Q = "Prompt for the agent"

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

-- The words of a command the module built. It quotes every word for the shell,
-- so "… 'beads' '--main' '/x/main'" reads back as the list it started as. Only
-- a word holding a single quote would need more than this, and no path, branch,
-- id or agent name in these tests does.
local function words(command)
  local list = {}
  for word in tostring(command):gmatch("'([^']*)'") do list[#list + 1] = word end
  return list
end

-- The recorded argv and cwd of the call whose command contains NEEDLE, or an
-- empty table when it never ran, so an absent call gives a named FAIL rather
-- than a Lua error.
local function exec_with(stub, needle)
  for _, call in ipairs(stub.exec_calls) do
    if program(call):find(needle, 1, true) ~= nil then return call end
  end
  return {}
end

-- Whether a command ran at all, for the assertions that are about it not
-- running.
local function ran(stub, needle)
  return exec_with(stub, needle).argv ~= nil
end

-- The one recorded rex.call for a method. The request is empty rather than nil
-- for the same reason: a missing call has to read as a failed assertion, not as
-- a crash.
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

-- The flow is run with io taken away: the agent memory is a file in whoever runs
-- the tests' own state directory, and a test may neither read nor write it. No
-- io is the module's own path for a host without it -- the memory then lives in
-- the process -- so what a case sees is what it put there.
local function in_memory(fn, ...)
  local saved = io
  io = nil
  local ok, result, extra = pcall(fn, ...)
  io = saved
  if not ok then error(result, 0) end
  return result, extra
end

-- A stub for the whole flow: the project resolves, bd has a database, the
-- script prints its rows, and a new branch on BEAD gets its tab. A test that
-- wants one step to fail overrides that one reply and nothing else.
local function project_stub(overrides)
  local stub = fresh_rex()
  overrides = overrides or {}

  stub.block = {
    call = function(creator, method, request)
      if overrides.no_cwd then return nil, "no terminal here" end
      return { foreground = { name = "pi", cwd = CWD } }
    end,
  }

  -- Project resolution: git names the repository, worktrunk names the main
  -- worktree.
  stub.json = {
    decode = function(text)
      if text == overrides.wt_json_in then
        return overrides.wt_json
      end
      return { items = { { worktree = { path = MAIN, main = true } } } }
    end,
    encode = function() error("action_test: rex.json.encode was called, but no test stubs it", 2) end,
  }
  stub.on_exec("rev-parse --path-format=absolute",
    { ok = true, code = 0, stdout = ROOT .. "/.git\n", stderr = "" })
  stub.on_exec("wt list --format=json", { ok = true, code = 0, stdout = "wt list", stderr = "" })
  -- A database is there: bd answers.
  stub.on_exec("bd ready --json", { ok = true, code = 0, stdout = "[]", stderr = "" })
  -- The script's three listing verbs.
  stub.on_exec("'beads'", { ok = true, code = 0, stdout = overrides.beads or BEAD_ROWS, stderr = "" })
  stub.on_exec("'bases'", { ok = true, code = 0, stdout = overrides.bases or BASE_ROWS, stderr = "" })
  stub.on_exec("'branch-default'",
    { ok = true, code = 0, stdout = overrides.branch_default or (BRANCH .. "\n"), stderr = "" })
  -- git is the judge of the branch name, and wt says it knows --path.
  stub.on_exec("check-ref-format", function(argv)
    if overrides.branch_check ~= nil then return overrides.branch_check end
    return { ok = true, code = 0, stdout = argv[4] .. "\n", stderr = "" }
  end)
  stub.on_exec("wt switch --help", { ok = true, code = 0, stdout = "Options:\n  --path <PATH>\n", stderr = "" })
  -- The claim, and the tab it makes.
  stub.on_exec("bd update " .. BEAD .. " --claim", { ok = true, code = 0, stdout = "", stderr = "" })

  stub.call_replies["session.list"] = { sessions = { { session_id = "session:rex", label = "rex-config" } } }
  stub.call_replies["session.create"] = {
    session_id = "session:iris",
    initial_windows = { { window_id = "window:main", block_ids = { "block:main" }, revision = 1 } },
  }
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = { session_id = "session:iris", windows = { { window_id = "window:main", label = "main" } } },
  }
  stub.call_replies["session.new_window"] = {
    window_id = "window:tab", block_ids = { "block:tab" }, revision = 2,
  }
  stub.call_replies["client.list"] = { clients = { { client_id = "client:app" } } }
  stub.call_replies["client.perform"] = { performed_by = "client:app" }
  return stub
end

-- A key press: the app is running the action, so the selection is queued.
local function ctx()
  return { origin = "key", session_id = "session:rex", block_id = "block:1" }
end

-- The six answers the flow wants for a new branch on BEAD, in the order it asks
-- them, so a test overrides only the one it is about.
local function answers(overrides)
  local scripted = {
    BEAD,                                   -- a. the bead
    BRANCH,                                 -- b. the branch
    "bug-58h",                              -- c. the worktree
    "origin/main",                          -- d. the base
    "pi",                                   -- e. the agent
    "/brainstorming for bead " .. BEAD,      -- f. the prompt
  }
  for index, value in pairs(overrides or {}) do scripted[index] = value end
  return scripted
end

-- Script a run's answers, or several runs' in order: one table of six per run.
-- They are flattened here rather than by `{ answers(), answers() }`, because a
-- table constructor keeps only the first value of every call but the last.
local function script(stub, ...)
  local flat = {}
  for _, run in ipairs({ ... }) do
    for index = 1, #run do flat[#flat + 1] = run[index] end
  end
  stub.ask(unpack(flat, 1, #flat))
end

-- session_for() and find_tab() -------------------------------------------------

eq("session_for finds the project's session",
  M.session_for({ { label = PROJECT, session_id = "s1" } }, PROJECT), "s1")
eq("session_for ignores a session whose label only starts the same way",
  M.session_for({ { label = PROJECT .. "-2", session_id = "s2" } }, PROJECT), nil)
eq("find_tab finds the branch's tab",
  M.find_tab({ { label = BRANCH, window_id = "w1" } }, BRANCH), "w1")
eq("find_tab needs the whole label",
  M.find_tab({ { label = BRANCH, window_id = "w1" } }, "bug/58"), nil)

-- The front door ---------------------------------------------------------------

-- Every reason the flow cannot start is refused before a question is asked: a
-- prompt for something that would only fail later is a prompt nobody should
-- have seen.
do
  local stub = project_stub{ no_cwd = true }
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a terminal with no directory fails", ok, false)
  contains("a terminal with no directory is named", message, "cannot tell which directory")
  eq("a terminal with no directory asks nothing", #stub.questions, 0)
end

do
  local stub = project_stub()
  stub.on_exec("rev-parse --path-format=absolute",
    { ok = false, code = 128, stdout = "", stderr = "fatal: not a git repository\n" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a directory outside a repository fails", ok, false)
  eq("a directory outside a repository is named", message, "not a git repository: " .. CWD)
  eq("a directory outside a repository asks nothing", #stub.questions, 0)
end

do
  local stub = project_stub()
  stub.on_exec("bd ready --json",
    { ok = false, code = 1, stdout = "", stderr = "Error: no beads database found\n" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a project without beads fails", ok, false)
  contains("a project without beads says beads is required", message, "beads is required")
  eq("a project without beads asks nothing", #stub.questions, 0)
end

do
  local stub = project_stub()
  stub.on_exec("bd ready --json",
    { ok = false, code = 1, stdout = "", stderr = "mise ERROR bd is not a valid shim.\n" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a bd that cannot be asked fails", ok, false)
  contains("a bd that cannot be asked is not called a missing database", message,
    "bd failed in " .. MAIN .. ": mise ERROR bd is not a valid shim.")
  eq("a bd that cannot be asked asks nothing", #stub.questions, 0)
end

do
  local stub = project_stub()
  stub.ui = nil
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a Rex build without rex.ui fails", ok, false)
  contains("a Rex build without rex.ui says so", message, "cannot ask anything")
  eq("a Rex build without rex.ui makes nothing", #stub.calls, 0)
end

-- Nobody answered ---------------------------------------------------------------

-- A cancelled question is the person saying no: the action returns nothing and
-- says nothing, and nothing is made. It is asked at each of the six in turn, so
-- a cancel at any point in the flow ends it the same way.
do
  local titles = { BEAD_Q, BRANCH_Q, WORKTREE_Q, BASE_Q, AGENT_Q, PROMPT_Q }
  local cancel = { value = nil, reason = "cancelled" }
  for index = 1, 6 do
    local scripted = answers()
    scripted[index] = cancel
    local stub = project_stub()
    stub.ask(unpack(scripted, 1, index))
    local ok, result = pcall(in_memory, M.work_new, ctx(), {})
    eq("a cancel at question " .. index .. " succeeds quietly", ok, true)
    eq("a cancel at question " .. index .. " returns nothing", result, nil)
    eq("a cancel at question " .. index .. " was the one asked last",
      #stub.questions, index)
    eq("a cancel at question " .. index .. " is the " .. titles[index] .. " question",
      stub.questions[index].question.title, titles[index])
    eq("a cancel at question " .. index .. " makes no session", #calls_to(stub, "session.create"), 0)
    eq("a cancel at question " .. index .. " claims nothing", ran(stub, "bd update"), false)
    eq("a cancel at question " .. index .. " makes no tab", #calls_to(stub, "session.new_window"), 0)
  end
end

-- Any other reason is a refusal that names the question: a bare "timeout" says
-- nothing about what went unanswered.
do
  for _, reason in ipairs({ "timeout", "busy", "no_client", "unsupported", "failed" }) do
    local refused = { value = nil, reason = reason }
    local stub = project_stub()
    stub.ask(refused)
    local ok, message = pcall(in_memory, M.work_new, ctx(), {})
    eq("a " .. reason .. " answer fails", ok, false)
    contains("a " .. reason .. " answer names the question", message, "the bead question could not be answered")
    contains("a " .. reason .. " answer names the reason", message, reason)
    eq("a " .. reason .. " answer makes nothing", #stub.calls, 0)
  end
end

-- The bead ---------------------------------------------------------------------

do
  local stub = project_stub()
  script(stub, answers())
  local ok, result = pcall(in_memory, M.work_new, ctx(), {})

  eq("a bead run succeeds", ok, true)
  eq("a bead run reports the tab it made", field(result, "window_id"), "window:tab")
  eq("a bead run reports that it created the tab", field(result, "created"), true)

  -- The six questions, in order, and what each one showed.
  eq("six questions were asked", #stub.questions, 6)
  eq("the questions are the six the flow has, in order", {
    stub.questions[1].question.title, stub.questions[2].question.title,
    stub.questions[3].question.title, stub.questions[4].question.title,
    stub.questions[5].question.title, stub.questions[6].question.title,
  }, { BEAD_Q, BRANCH_Q, WORKTREE_Q, BASE_Q, AGENT_Q, PROMPT_Q })
  eq("the bead question is a pick", stub.questions[1].kind, "pick")
  eq("the branch question is typed", stub.questions[2].kind, "input")

  local bead_items = stub.questions[1].question.items
  eq("the ready beads are the rows the script printed, then no bead", #bead_items, 3)
  eq("a bead row is its title", bead_items[1].title, "Phase 3 follow-on")
  eq("a bead row says its id and type", bead_items[1].subtitle, "pmm-iris-58h · task")
  eq("a bead row says its priority", bead_items[1].detail, "P1")
  eq("the last row is the no-bead answer", bead_items[3].id, M.NO_BEAD)

  eq("the branch question opens on the name the bead derives",
    stub.questions[2].question.value, BRANCH)
  eq("the branch question says what it starts from",
    stub.questions[2].question.placeholder, "starts from origin/main")
  eq("the worktree question opens on the branch's directory name",
    stub.questions[3].question.value, "bug-58h")
  eq("the base question opens on the script's first row",
    stub.questions[4].question.items[1].id, "origin/main")
  eq("the agent question offers the configured agent, then none",
    { stub.questions[5].question.items[1].id, stub.questions[5].question.items[2].id },
    { "pi", M.NO_AGENT })
  eq("the prompt question opens on the bead's template",
    stub.questions[6].question.value, "/brainstorming for bead " .. BEAD)

  -- The claim, and the tab it is claimed for. The claim comes first: an agent
  -- never starts on a bead that is not its own.
  eq("the bead is claimed from the main worktree",
    exec_with(stub, "bd update " .. BEAD .. " --claim").cwd, MAIN)
  eq("the bead is claimed",
    program(exec_with(stub, "bd update " .. BEAD .. " --claim")),
    "bd update " .. BEAD .. " --claim")
  do
    local claim_at, tab_at
    for i, event in ipairs(stub.events) do
      if event == "bd update " .. BEAD .. " --claim" then claim_at = i end
      if event == "session.new_window" then tab_at = i end
    end
    eq("the bead is claimed before the tab is made",
      claim_at ~= nil and tab_at ~= nil and claim_at < tab_at, true)
  end

  -- The rows the script printed came from the main worktree, through the login
  -- shell whose PATH knows bd and jq.
  do
    local listing = exec_with(stub, "'beads'")
    eq("the ready beads are listed by the script", words(listing.argv[3]),
      { M.options.script, "beads", "--main", MAIN })
    eq("the beads are listed in the main worktree", listing.cwd, MAIN)
    eq("the bases are read from the script", words(exec_with(stub, "'bases'").argv[3]),
      { M.options.script, "bases", "--main", MAIN })
    eq("the branch name the bead derives comes from the script",
      words(exec_with(stub, "'branch-default'").argv[3]),
      { M.options.script, "branch-default", "--type", "task", "--id", BEAD })
  end

  -- The tab: one window, in the project's session, labelled with the branch, in
  -- the main worktree, running the wrapper with the answers as parameters.
  do
    local request = request_of(stub, "session.new_window")
    local options = request.layout.block.options
    eq("the tab is made in the project's session", request.session_id, "session:iris")
    eq("the tab is labelled with the branch", request.window_label, BRANCH)
    eq("the tab starts in the main worktree", options.cwd, MAIN)
    eq("the tab runs the wrapper",
      options.command, M.new_tab_argv(PROJECT, {
        branch = BRANCH, bead = BEAD, title = "Phase 3 follow-on",
        worktree = "bug-58h", base = "origin/main", base_remote = "origin",
        agent = "pi", prompt = "/brainstorming for bead " .. BEAD,
      }))
    eq("the wrapper is given the branch", options.command[5], BRANCH)
    eq("the wrapper is given the base", options.command[6], "origin/main")
    eq("the wrapper is given the remote to fetch", options.command[7], "origin")
    eq("the wrapper is given the worktree name", options.command[8], "../bug-58h")
    local exit = options.exit
    eq("the tab is not kept open after the agent exits",
      exit == nil or exit.on_completion ~= false, true)
  end

  eq("the session is created from the project's name", request_of(stub, "session.create").label, PROJECT)
  eq("the session is attached to", request_of(stub, "session.attach").session_id, "session:iris")
  eq("a key press queues the selection",
    stub.queued[1] and stub.queued[1].action, "session.select")
  eq("a key press asks no client directly", #calls_to(stub, "client.perform"), 0)
end

-- The no-bead row ---------------------------------------------------------------

do
  local stub = project_stub()
  script(stub, { M.NO_BEAD, "feat/x", "", "origin/main", "pi", "/brainstorming" })
  local ok, result = pcall(in_memory, M.work_new, ctx(), {})

  eq("the no-bead row starts the work", ok, true)
  eq("the no-bead row makes a tab", field(result, "created"), true)
  eq("the no-bead row claims nothing", ran(stub, "bd update"), false)
  eq("the no-bead row sends the no-bead prompt",
    request_of(stub, "session.new_window").layout.block.options.command[10], "/brainstorming")
end

-- An empty ready list still opens, with the no-bead row, and says why in the
-- title: the pick cannot say it any other way.
do
  local stub = project_stub{ beads = "" }
  script(stub, { M.NO_BEAD, "feat/x", "", "origin/main", "pi", "" })
  local ok = pcall(in_memory, M.work_new, ctx(), {})
  eq("an empty ready list still starts the work", ok, true)
  eq("an empty ready list opens on the no-bead row alone",
    #stub.questions[1].question.items, 1)
  eq("an empty ready list says so in the title",
    stub.questions[1].question.title, "no ready beads in " .. PROJECT)
end

-- The branch ---------------------------------------------------------------------

-- With no bead there is no name to derive, so the question opens on a made-up
-- one -- a name, not a number, and still one git accepts. Accepting what it was
-- opened on is a bare Return, which is what answer() here does.
do
  local stub = project_stub()
  script(stub, { M.NO_BEAD, function(question) return question.value end, "", "origin/main", "pi", "" })
  local ok = pcall(in_memory, M.work_new, ctx(), {})
  local opened = stub.question(BRANCH_Q).value
  eq("a flow with no bead starts the work", ok, true)
  eq("a flow with no bead opens the branch question on a random name",
    opened:match("^feat/[a-z]+%-[a-z]+$") ~= nil, true)
  eq("the random name travels as the branch",
    request_of(stub, "session.new_window").layout.block.options.command[5], opened)
  eq("no branch-default is asked for a flow with no bead",
    ran(stub, "'branch-default'"), false)
end

-- A name git will not take is refused with git's own reason, rather than being
-- handed to worktrunk in the tab.
do
  local stub = project_stub()
  stub.on_exec("check-ref-format",
    { ok = false, code = 128, stdout = "", stderr = "fatal: 'bad name' is not a valid branch name\n" })
  stub.ask(BEAD, "bad name")
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a branch name git refuses fails", ok, false)
  contains("a branch name git refuses is named", message, "not a branch name: bad name")
  contains("a branch name git refuses says what git said", message, "is not a valid branch name")
  eq("a branch name git refuses claims nothing", ran(stub, "bd update"), false)
  eq("a branch name git refuses makes no tab", #calls_to(stub, "session.new_window"), 0)
end

-- git *expands* a name like @{-1} and prints what it resolved to, so the reply
-- has to be the name that went in.
do
  local stub = project_stub()
  stub.on_exec("check-ref-format", { ok = true, code = 0, stdout = "feat/other\n", stderr = "" })
  stub.ask(BEAD, "@{-1}")
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a name git only expands fails", ok, false)
  contains("a name git only expands is refused", message, "not a branch name: @{-1}")
end

-- The worktree -------------------------------------------------------------------

-- Blank is worktrunk's own worktree-path template: no --path word at all.
do
  local stub = project_stub()
  script(stub, answers{ [3] = "" })
  local ok = pcall(in_memory, M.work_new, ctx(), {})
  eq("a blank worktree name still starts the work", ok, true)
  eq("a blank worktree name sends no --path word",
    request_of(stub, "session.new_window").layout.block.options.command[8], "")
  eq("a blank worktree name asks wt nothing about --path",
    ran(stub, "wt switch --help"), false)
end

do
  local stub = project_stub()
  script(stub, answers())
  pcall(in_memory, M.work_new, ctx(), {})
  eq("a worktree name sends its sibling directory",
    request_of(stub, "session.new_window").layout.block.options.command[8], "../bug-58h")
  eq("a worktree name is checked against this wt",
    program(exec_with(stub, "wt switch --help")), "wt switch --help")
end

do
  local stub = project_stub()
  script(stub, answers{ [3] = "a/b" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a worktree path is refused", ok, false)
  contains("a worktree path is refused by name", message, "not a path: a/b")
  eq("a worktree path claims nothing", ran(stub, "bd update"), false)
end

-- --path is experimental in worktrunk 0.82: a wt without it would ignore the
-- name, so the name is refused with a message instead.
do
  local stub = project_stub()
  stub.on_exec("check-ref-format", function(argv)
    return { ok = true, code = 0, stdout = argv[4] .. "\n", stderr = "" }
  end)
  stub.on_exec("wt switch --help", { ok = true, code = 0, stdout = "Options:\n  --create\n", stderr = "" })
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a wt without --path fails", ok, false)
  contains("a wt without --path says so", message, "no --path")
  contains("a wt without --path says what has it", message, "0.82")
  eq("a wt without --path claims nothing", ran(stub, "bd update"), false)
end

-- The base ------------------------------------------------------------------------

-- The base question is asked whenever it was not answered -- create-only means
-- every branch needs one -- and the answer travels with the remote it lives on.
do
  local stub = project_stub()
  script(stub, answers{ [4] = "@" })
  pcall(in_memory, M.work_new, ctx(), {})
  eq("the base question is asked", type(stub.question(BASE_Q)), "table")
  eq("a base answer travels as the base",
    request_of(stub, "session.new_window").layout.block.options.command[6], "@")
  eq("a local base carries no remote",
    request_of(stub, "session.new_window").layout.block.options.command[7], "")
end

-- An empty ref is worktrunk's own choice, and travels as false so a configured
-- base cannot speak in its place.
do
  local saved = M.options.base
  M.options.base = "main"
  local stub = project_stub{ bases = "\torigin\n@" .. "\t\n" }
  script(stub, answers{ [4] = M.WT_DEFAULT })
  pcall(in_memory, M.work_new, ctx(), {})
  eq("the worktrunk-default row sends no --base word",
    request_of(stub, "session.new_window").layout.block.options.command[6], "")
  eq("the worktrunk-default row says what it is",
    stub.question(BASE_Q).items[1].title, "worktrunk's default")
  M.options.base = saved
end

-- The agent --------------------------------------------------------------------

do
  local stub = project_stub()
  script(stub, answers{ [5] = M.NO_AGENT })
  pcall(in_memory, M.work_new, ctx(), {})
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("the none row starts no agent", command[9], "")
  eq("the none row still carries the prompt", command[#command],
    "/brainstorming for bead " .. BEAD)
  eq("the configured agent is left alone", M.options.agent, "pi")
end

do
  local stub = project_stub()
  script(stub, answers{ [5] = "claude" })
  pcall(in_memory, M.work_new, ctx(), {})
  eq("the agent the pick chose is the one the tab starts",
    request_of(stub, "session.new_window").layout.block.options.command[9], "claude")
end

-- The remembered agent arrives as the question's filter, which is the only way
-- a single-choice pick can open on an answer: the list narrows to that row and a
-- bare Return takes it.
do
  local agents = M.options.agents
  M.setup{ agents = { "pi", "claude" } }
  local stub = project_stub()
  script(stub, answers{ [5] = "claude" }, answers{ [5] = M.NO_AGENT }, answers())
  pcall(in_memory, M.work_new, ctx(), {})
  pcall(in_memory, M.work_new, ctx(), {})
  eq("the agent the last launch chose is what the next question opens filtered on",
    stub.last_question(AGENT_Q).value, "claude")
  pcall(in_memory, M.work_new, ctx(), {})
  eq("the remembered none opens on the row named for it",
    stub.last_question(AGENT_Q).value, "(none)")
  M.options.agents = agents
end

-- The prompt -------------------------------------------------------------------

-- A cleared field is an answer: the agent starts and is told nothing. The
-- template's text must not be put back in its place on the way to the tab.
do
  local stub = project_stub()
  script(stub, answers{ [6] = "" })
  pcall(in_memory, M.work_new, ctx(), {})
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("a cleared prompt sends no prompt word", #command, 9)
  eq("a cleared prompt leaves the agent last", command[#command], "pi")
end

do
  local stub = project_stub()
  script(stub, answers{ [6] = "why is the guard flaky?" })
  pcall(in_memory, M.work_new, ctx(), {})
  eq("a typed prompt is the prompt",
    request_of(stub, "session.new_window").layout.block.options.command[10],
    "why is the guard flaky?")
end

-- A bead-less flow opens the prompt question empty, because the configured
-- no-bead prompt now says nothing.
do
  local stub = project_stub()
  script(stub, { M.NO_BEAD, "feat/x", "", "origin/main", "pi", "" })
  pcall(in_memory, M.work_new, ctx(), {})
  eq("a bead-less flow opens the prompt question empty",
    stub.question(PROMPT_Q).value, "")
end

-- The rest of the flow --------------------------------------------------------

-- Nothing requires the answers to come from the questions: a hand-run
-- `rex do work_new bead=<id> branch=<name>` asks only for what it was not given.
do
  local stub = project_stub()
  script(stub, answers())
  local ok, result = pcall(in_memory, M.work_new, ctx(),
    { bead = BEAD, branch = BRANCH, worktree = "", base = "origin/main", base_remote = "origin",
      agent = "pi", prompt = "/brainstorming for bead " .. BEAD })
  eq("an answer given as an argument is not asked for", ok, true)
  eq("only the ungiven questions are asked", #stub.questions, 0)
  eq("a fully answered run makes the tab", field(result, "created"), true)
end

-- A second press for the same branch finds its tab: one tab, one worktree and
-- one claim, whatever the questions were answered with.
do
  local stub = project_stub()
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
  script(stub, answers())
  local ok, result = pcall(in_memory, M.work_new, ctx(), {})
  eq("a repeat press succeeds", ok, true)
  eq("a repeat press selects the tab that is already there", field(result, "window_id"), "window:tab")
  eq("a repeat press creates nothing", field(result, "created"), false)
  eq("a repeat press makes no tab", #calls_to(stub, "session.new_window"), 0)
  eq("a repeat press claims nothing", ran(stub, "bd update"), false)
  eq("a repeat press makes no session", #calls_to(stub, "session.create"), 0)
end

-- A session whose label merely starts with the project's name is not the
-- project's session: the flow makes the right one.
do
  local stub = project_stub()
  stub.call_replies["session.list"] = { sessions = { { session_id = "session:other", label = PROJECT .. "-2" } } }
  script(stub, answers())
  pcall(in_memory, M.work_new, ctx(), {})
  eq("a look-alike session is not adopted", request_of(stub, "session.create").label, PROJECT)
end

-- A view without windows is a session with no tabs -- the server leaves an empty
-- list out -- so that is where a first tab comes from, not a reason to refuse.
do
  local stub = project_stub()
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = { session_id = "session:iris", label = PROJECT, revision = 0 },
  }
  script(stub, answers())
  local ok, result = pcall(in_memory, M.work_new, ctx(), {})
  eq("a session with no windows still gets its tab", ok, true)
  eq("a session with no windows makes the tab", field(result, "created"), true)
end

-- An attach with no view leaves no list of tabs, and "no list" is not "no tabs".
do
  local stub = project_stub()
  stub.call_replies["session.attach"] = { client_id = "client:app" }
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("an attach with no view fails", ok, false)
  contains("an attach with no view says the view is missing", message, "returned no view")
  eq("an attach with no view claims nothing", ran(stub, "bd update"), false)
end

-- A windows field that is there and is not a list is a shape this cannot read.
do
  local stub = project_stub()
  stub.call_replies["session.attach"] = {
    client_id = "client:app",
    view = { session_id = "session:iris", windows = "main, tab" },
  }
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a view whose windows are not a list fails", ok, false)
  contains("a view whose windows are not a list names them", message, "windows are a string")
end

-- A bd that cannot even start is no claim, and no tab.
do
  local stub = project_stub()
  -- Registered with no reply, which is a program Rex cannot start.
  stub.on_exec("bd update " .. BEAD .. " --claim", nil)
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a bd that cannot start fails", ok, false)
  contains("a bd that cannot start is named", message, "executable file not found in PATH")
  eq("a bd that cannot start makes no tab", #calls_to(stub, "session.new_window"), 0)
end

-- A bead id is the one answer that travels inside a command line, so one that is
-- not id-shaped is refused rather than run.
do
  local stub = project_stub()
  script(stub, answers{ [1] = "x; rm -rf /" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a bead id that is not one fails", ok, false)
  contains("a bead id that is not one is named", message, "not a bead id")
  eq("a bead id that is not one makes no tab", #calls_to(stub, "session.new_window"), 0)
end

-- A tab that cannot be made is the one failure that leaves a claim behind, so
-- the error has to say how to give it back.
do
  local stub = project_stub()
  stub.call_replies["session.new_window"] = function() return nil, "no such session" end
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a tab that cannot be made fails", ok, false)
  contains("a tab that cannot be made says what Rex said", message, "no such session")
  contains("a tab that cannot be made says the bead is claimed", message, "still claimed")
  contains("a tab that cannot be made says how to release the claim", message, "bd unclaim " .. BEAD)
end

do
  local stub = project_stub()
  stub.call_replies["session.new_window"] = function() return nil, "no such session" end
  script(stub, { M.NO_BEAD, "feat/x", "", "origin/main", "pi", "" })
  local ok, message = pcall(in_memory, M.work_new, ctx(), {})
  eq("a tab that cannot be made fails without a bead too", ok, false)
  eq("no bead means no release advice", tostring(message):find("bd unclaim", 1, true), nil)
end

-- A session that cannot be shown leaves the tab in place and says so, rather
-- than throwing the work away.
do
  local stub = project_stub()
  stub.call_replies["client.list"] = { clients = {} }
  script(stub, answers())
  local ok, message = pcall(in_memory, M.work_new, { origin = "cli" }, {})
  eq("a session that cannot be shown fails", ok, false)
  contains("a session that cannot be shown says the tab was made", message, "was created")
  contains("a session that cannot be shown names the reason", message, "no app client")
  eq("the tab is still there", #calls_to(stub, "session.new_window"), 1)
end

-- Hand-run from `rex do`, there is no invocation to queue against, so the app's
-- clients are asked directly and told where the request came from.
do
  local stub = project_stub()
  script(stub, answers())
  local ok = pcall(in_memory, M.work_new, { origin = "cli" }, {})
  eq("a hand-run flow succeeds", ok, true)
  eq("a hand-run flow asks the app client", request_of(stub, "client.perform").client_id, "client:app")
  eq("a hand-run flow tells the client where it came from",
    request_of(stub, "client.perform").origin, "cli")
  eq("a hand-run flow queues nothing", #stub.queued, 0)
end

-- The action's declaration -------------------------------------------------------

-- Rex silently drops KEY=VALUE pairs an action does not declare, so every answer
-- a hand-run `rex do work_new` may name has to be declared.
do
  local spec
  for _, candidate in ipairs(rex_stub.actions) do
    if candidate.name == "work_new" then spec = candidate end
  end
  eq("work_new is registered", type(spec), "table")
  eq("work_new declares its optional answers", sorted_keys(spec and spec.args and spec.args.properties),
    { "agent", "base", "base_remote", "bead", "blank", "branch", "prompt", "title", "worktree" })
  eq("work_new requires nothing: an ungiven answer is a question", spec and spec.args.required, nil)
  eq("base admits both the ref and the wt-default sentinel",
    spec and spec.args.properties.base, { type = { "string", "boolean" } })
  eq("blank is declared a boolean", spec and spec.args.properties.blank, { type = "boolean" })
end

-- work_new_go is the picker's hand-back, and until the picker is gone it has to
-- keep starting the work from a payload. It is deleted with the float.
do
  local stub = project_stub()
  local ok, result = pcall(in_memory, M.work_new_go,
    { origin = "cli" },
    { project = PROJECT, root = ROOT, main = MAIN, branch = BRANCH,
      bead = BEAD, title = "Phase 3 follow-on", agent = "pi",
      base = "origin/main", base_remote = "origin", worktree = "bug-58h",
      prompt = "/brainstorming for bead " .. BEAD })
  eq("work_new_go still starts the work", ok, true)
  eq("work_new_go makes the tab", field(result, "created"), true)
  eq("work_new_go asks no questions", #stub.questions, 0)
  eq("work_new_go hands the answers to the tab",
    request_of(stub, "session.new_window").layout.block.options.command[8], "../bug-58h")
end

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
