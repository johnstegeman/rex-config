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

-- The project every test uses, on disk: project_for finds the wrapper by walking
-- for `.jj/repo` as a directory, so the fixture is a real one -- a mktemp -d per
-- run, removed with the file as setup_test.lua's is -- with main and the branch
-- workspace beneath it.
local function mktemp_dir()
  local pipe = io.popen("mktemp -d 2>/dev/null")
  if pipe == nil then return nil end
  local path = pipe:read("l")
  pipe:close()
  if path == nil or path == "" then return nil end
  return (path:gsub("/+$", ""))
end

-- One shell word, whatever the path holds, so a TMPDIR with a space in it is a
-- directory rather than two arguments. Quoted here rather than through the
-- module's own shell_quote, so the fixture does not lean on the code under test.
local function quote(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end

local function mkdirp(path)
  os.execute("mkdir -p " .. quote(path))
end

local PROJECT = "pmm-iris"
local TMP = assert(mktemp_dir(), "mktemp -d failed")
local ROOT = TMP .. "/" .. PROJECT
local MAIN = ROOT .. "/main"
local BRANCH = "bug/58h"
local WORKTREE = ROOT .. "/bug-58h"
local BEAD = "pmm-iris-58h"
mkdirp(ROOT .. "/.jj/repo")
mkdirp(MAIN)
mkdirp(WORKTREE)

-- jj's workspace list, as project_for and the done flow read it: one name, one
-- tab, the root, one newline per row.
local WORKSPACES = [[jj --ignore-working-copy workspace list -T 'name ++ "\t" ++ root ++ "\n"']]

-- jj's answer as that template prints it. A non-zero code is jj refusing -- a
-- failed read rather than a listing without the row -- and its line is on stderr
-- the way a real jj's is.
local function jj_rows(stdout, code)
  code = code or 0
  return { ok = code == 0, code = code, stdout = code == 0 and stdout or "",
    stderr = code == 0 and "" or stdout }
end

-- The fixture's rows: the wrapper's default workspace, main, and the branch
-- workspace the tab is in.
local JJ_ROWS = "default\t" .. ROOT .. "\nmain\t" .. MAIN
  .. "\n" .. BRANCH .. "\t" .. WORKTREE .. "\n"

-- What the picker hands back for a new branch on that bead.
local function payload(overrides)
  local args = {
    project = PROJECT, root = ROOT, main = MAIN,
    branch = BRANCH, bead = BEAD, title = "Diff the thing", worktree = "create",
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

-- What the first call that ran NAME was handed: the program itself, or the
-- command text a login-shell probe gave the shell. nil when it never ran, so an
-- absent call reads as a failed assertion instead of a crash.
local function command_for(stub, name)
  local call = exec_for(stub, name)
  return call.argv and program(call)
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

-- tab_window() and tab_processes() ------------------------------------------
--
-- The done flow closes a tab only when nothing in it is somebody's work. The
-- tab is found from ctx's own block in the session's own view, and then every
-- block in that window is asked what it is running: a shell is what a tab idles
-- at, and anything else -- including a block whose process Rex cannot read -- is
-- somebody's work. The window below carries its blocks in a layer, which is where
-- Rex puts them.

local TAB_VIEW = {
  view = {
    session_id = "session:iris",
    windows = { {
      window_id = "window:tab",
      label = BRANCH,
      layers = { { blocks = { { block_id = "block:one" }, { block_id = "block:two" } } } },
    } },
  },
}

-- A stub whose attach reply is TAB_VIEW and whose process reply is chosen per
-- block id: a reply that is a function is called, so a test can make the call
-- fail. The requests are kept, because asking the right session about the right
-- block is half of the answer.
local function tab_stub(by_block)
  local stub = fresh_rex()
  stub.call_replies["session.attach"] = TAB_VIEW
  stub.asked = {}
  stub.block = {
    call = function(creator, method, request)
      stub.asked[#stub.asked + 1] = { creator = creator, method = method, request = request }
      local reply = by_block[request.block_id]
      if type(reply) == "function" then return reply() end
      return reply
    end,
  }
  return stub
end

do
  local stub = tab_stub({
    ["block:one"] = { foreground = { name = "fish" } },
    ["block:two"] = { foreground = { name = "node" } },
  })
  local ctx = { session_id = "session:iris", block_id = "block:two" }
  local window, reason = M.tab_window(ctx)
  eq("the tab is the window holding the block", window and window.window_id, "window:tab")
  eq("a tab that is found has no reason to give", reason, nil)
  eq("the block's session is the one attached",
    request_of(stub, "session.attach").session_id, "session:iris")

  -- The whole window is read, in the order Rex lists it: a node in the second
  -- block still stops the close, and the shell beside it does not.
  eq("a node in the tab is named", M.tab_processes(ctx, window), { "node" })
  eq("every block in the tab is asked", #stub.asked, 2)
  eq("each block is asked in ctx's session",
    { stub.asked[1].request.session_id, stub.asked[2].request.session_id },
    { "session:iris", "session:iris" })
  eq("each block is asked about itself",
    { stub.asked[1].request.block_id, stub.asked[2].request.block_id },
    { "block:one", "block:two" })
  eq("the terminal's process is the terminal's",
    { stub.asked[1].creator, stub.asked[1].method },
    { "com.superlogical.terminal", "process" })
end

-- A tab of shells is what a teardown may close.
do
  local stub = tab_stub({ ["block:one"] = { foreground = { name = "fish" } } })
  local window = { window_id = "window:main", label = "main",
    layers = { { blocks = { { block_id = "block:one" } } } } }
  eq("a tab of shells runs nothing",
    M.tab_processes({ session_id = "session:iris", block_id = "block:one" }, window), {})
  eq("a shell is still asked about", #stub.asked, 1)
end

-- A block whose process cannot be read is the one that matters most: the flow
-- must refuse, so it is named as a program rather than counted as idle.
do
  tab_stub({ ["block:one"] = function() error("no process") end })
  local window = { layers = { { blocks = { { block_id = "block:one" } } } } }
  eq("a block Rex cannot read is named",
    M.tab_processes({ session_id = "session:iris", block_id = "block:one" }, window),
    { "a program Rex could not name" })
end

-- A call that answers with nothing to name is the same refusal: a reply without
-- a foreground or a child says nothing about what is running.
do
  tab_stub({ ["block:one"] = {} })
  local window = { blocks = { { block_id = "block:one" } } }
  eq("a block that names nothing is named",
    M.tab_processes({ session_id = "session:iris", block_id = "block:one" }, window),
    { "a program Rex could not name" })
end

-- A block Rex hands over in a shape this cannot read is the same refusal as a
-- block whose process reply cannot be read: an index on it would raise, and an
-- entry skipped would let a teardown through with somebody's program in it. A
-- layer is where the blocks usually are, so an unreadable layer is the case.
do
  -- The readable block is a shell, so only the unreadable one is named: a tab of
  -- shells is what the close may close.
  tab_stub({ ["block:one"] = { foreground = { name = "fish" } } })
  local layered = { window_id = "window:tab",
    layers = { { blocks = { { block_id = "block:one" } } }, 42 } }
  eq("a layer that cannot be read is named",
    M.tab_processes({ session_id = "session:iris", block_id = "block:one" }, layered),
    { "a program Rex could not name" })
  local blocks = { window_id = "window:tab", blocks = { { block_id = "block:one" }, "x" } }
  eq("a block that is not a table is named",
    M.tab_processes({ session_id = "session:iris", block_id = "block:one" }, blocks),
    { "a program Rex could not name" })
end

-- The tab cannot be found either way, and both are refusals with a reason
-- rather than an empty answer that would read as "no tab, nothing to stop".
do
  local stub = fresh_rex()
  stub.call_replies["session.attach"] = { client_id = "client:app" }
  local window, reason = M.tab_window({ session_id = "session:iris", block_id = "block:one" })
  eq("an attach without a view finds no tab", window, nil)
  contains("the refusal says why the tab is unknown", reason, "no list of tabs")
end

do
  tab_stub({})
  local window, reason = M.tab_window({ session_id = "session:iris", block_id = "block:zz" })
  eq("a block in no window finds no tab", window, nil)
  contains("the refusal says the tab cannot be told", reason, "cannot tell which tab")
end

-- work_done() ------------------------------------------------------------------
--
-- The teardown, end to end from the pane: the audit is opened on the pane's own
-- tab, and what that tab is still running travels with it. The per-block
-- process replies are what these cases turn on -- a tab is where a person
-- leaves work behind, and a block Rex cannot read has to reach the audit as a
-- program rather than as an idle pane -- so they sit beside tab_processes,
-- whose stub already answers per block.
local function done_stub(by_block)
  local stub = tab_stub(by_block)
  -- The project is the fixture's, so project_for finds the wrapper and the main
  -- workspace it holds, as it does in setup_test.lua.
  stub.exec_replies[WORKSPACES] = jj_rows(JJ_ROWS)
  -- The float itself: one layer, recorded, because the argv it is opened with
  -- is the whole of what this action decides.
  stub.layers = {}
  stub.session.new_layer = function(request)
    stub.layers[#stub.layers + 1] = request
    return { layer_id = "layer:done", block_ids = { "block:done" } }
  end
  return stub
end

do
  local stub = done_stub({
    ["block:one"] = { foreground = { name = "fish", cwd = WORKTREE } },
    ["block:two"] = { foreground = { name = "node" } },
  })
  local ok = pcall(M.work_done,
    { session_id = "session:iris", block_id = "block:one", origin = "key" })
  eq("work_done opens the audit", ok, true)
  eq("the audit names the tab it will close, and what that tab is running",
    stub.layers[1].layout.block.options.command,
    { M.options.script, "done", "--main", MAIN, "--root", ROOT, "--project", PROJECT,
      "--cwd", WORKTREE, "--session", "session:iris",
      "--window", "window:tab", "--running", "node" })
end

-- The block Rex cannot read is the one that matters most: it reaches the audit
-- as a program, so the script refuses rather than tearing down somebody's
-- work.
do
  local stub = done_stub({
    ["block:one"] = { foreground = { name = "fish", cwd = WORKTREE } },
    ["block:two"] = function() error("no process") end,
  })
  local ok = pcall(M.work_done,
    { session_id = "session:iris", block_id = "block:one", origin = "key" })
  eq("a tab with an unreadable block still opens the audit", ok, true)
  local command = stub.layers[1].layout.block.options.command
  eq("the unreadable block is passed along as a program",
    { command[#command - 1], command[#command] },
    { "--running", "a program Rex could not name" })
end

-- work_done_go() ----------------------------------------------------------------
--
-- The audit's answer, carried out: one removal through the login shell in the
-- main worktree -- dojjo forgets the workspace, deletes its directory and
-- deletes its bookmark -- and then the three reads that decide whether it
-- happened: the jj workspace row, the directory itself, and the bookmark. Each
-- is read rather than inferred from an exit code, and each has its own one line
-- when it disagrees. A command the flow did not run has no reply at all, so a
-- wrong argv fails here instead of answering plausibly.

-- -y because nobody is there to answer a prompt, and no --keep-bookmark because
-- the branch is merged and goes with the workspace it named. The workspace is
-- what dojjo takes, so it is the workspace that is quoted -- the path never
-- reaches a shell at all.
local REMOVE = "djo remove 'feat/6c4' -y"
-- The workspace read is WORKSPACES, defined with the project fixture above: it
-- reads the op log rather than the working copy, because another jj in the same
-- repository may hold that lock. The bookmark read is the same way round for the
-- same reason.
-- The bookmark itself is read as a live target rather than as a name in a
-- listing: `jj bookmark delete` -- which is what dojjo's remove does -- only
-- marks a remote-tracked bookmark deleted, so `jj bookmark list` goes on printing
-- its name and a listing cannot tell a deleted bookmark from a kept one. A revset
-- that resolves to no commit can.
local BOOKMARK = [[jj --ignore-working-copy log --no-graph -r 'bookmarks(exact:"feat/6c4")' -T 'commit_id ++ "\n"']]
-- The listing a tombstone still shows up in: a command this action must not read,
-- kept here so a case can answer it and prove it was never asked.
local BOOKMARKS_LIST = [[jj bookmark list -T 'name ++ "\n"']]
-- What the flow runs itself when the wait still finds the row: one `jj
-- workspace forget` for the workspace, its name quoted like every other word
-- handed to the shell.
local FORGET = "jj workspace forget 'feat/6c4'"
-- The directory check is not a shell line: it is one `test` argv, so the path is
-- never parsed as text and needs no quoting.
local DIRECTORY = "test"

-- What dojjo and the three checks answer on a teardown that finished: dojjo's
-- own exit, a directory already gone, and two listings without the workspace in
-- them. The two after that are what a teardown that did not finish leaves.
local REMOVED = { code = 0, stdout = "", stderr = "" }
local GONE = { code = 0, stdout = "", stderr = "" }
local MISSING = { code = 1, stdout = "", stderr = "" }
local WORKSPACES_CLEAR = {
  code = 0, stdout = "default\t/p/demo\nmain\t/p/demo/main\n", stderr = "",
}
-- The bookmark read's two answers: a commit id while the bookmark is there, and
-- nothing at all once it is gone -- which is also what a tombstone leaves, since
-- a deleted bookmark resolves to no commit.
local BOOKMARK_GONE = { code = 0, stdout = "", stderr = "" }
local BOOKMARK_LIVE = {
  code = 0, stdout = "7281e13e7df372cd62d2d6bc8286ef06091b0f82\n", stderr = "",
}
-- A workspace row the flow still sees: the removal exited 0 and the row is
-- nevertheless there.
local ROW_LEFT = { code = 0, stdout = "feat/6c4\t/p/demo/feat-6c4\n", stderr = "" }

-- The audit's hand-back: the five keys, as the float sends them back.
local function removal(overrides)
  local args = { project = "demo", root = "/p/demo", main = "/p/demo/main",
    workspace = "feat/6c4", path = "/p/demo/feat-6c4" }
  for key, value in pairs(overrides or {}) do args[key] = value end
  return args
end

-- The four reads answer with the clear replies unless the case says otherwise.
-- rex.json.decode is left as the stub's own refusal: this action reads no
-- document at all any more, so a decode is a fault in the code, not an answer.
local function go_stub(by_command)
  local stub = fresh_rex()
  stub.exec_replies[REMOVE] = REMOVED
  stub.exec_replies[WORKSPACES] = WORKSPACES_CLEAR
  stub.exec_replies[DIRECTORY] = GONE
  stub.exec_replies[BOOKMARK] = BOOKMARK_GONE
  for command, value in pairs(by_command or {}) do stub.exec_replies[command] = value end
  return stub
end

-- How many times a command ran, so a wait can be shown to be a wait.
local function runs(stub, name)
  local count = 0
  for _, call in ipairs(stub.exec_calls) do
    if program(call) == name then count = count + 1 end
  end
  return count
end

-- The clean path: one removal, then the three verifications, and nothing else.
do
  local stub = go_stub()
  local ok, result = pcall(M.work_done_go, {}, removal())
  eq("a complete removal succeeds", ok, true)
  eq("a complete removal returns nothing", result, nil)
  eq("the removal runs first, then the three verifications", stub.events,
    { REMOVE, WORKSPACES, DIRECTORY, BOOKMARK })
  -- The removal's three properties said out loud, rather than the stub's key
  -- compared with itself: `-y` because nobody is there to answer, and no
  -- --keep-bookmark because the merged branch goes with the workspace.
  contains("the removal is dojjo's own remove", command_for(stub, REMOVE), "djo remove")
  contains("the removal answers dojjo's prompt", command_for(stub, REMOVE), " -y")
  eq("the removal does not ask dojjo to keep the bookmark",
    tostring(command_for(stub, REMOVE)):find("keep-bookmark", 1, true), nil)
  eq("the removal runs in the main worktree", exec_for(stub, REMOVE).cwd, "/p/demo/main")
  -- The verifications run there too: the pane's own directory is the one the
  -- removal just unlinked, so a process started in it may not even exec.
  eq("the jj read runs in the main worktree", exec_for(stub, WORKSPACES).cwd, "/p/demo/main")
  eq("the directory check is one test argv, path and all",
    exec_for(stub, DIRECTORY).argv, { "test", "!", "-e", "/p/demo/feat-6c4" })
  eq("the directory check runs in the main worktree", exec_for(stub, DIRECTORY).cwd, "/p/demo/main")
  eq("the bookmark read runs in the main worktree", exec_for(stub, BOOKMARK).cwd, "/p/demo/main")
  contains("the bookmark read asks jj for a live target",
    command_for(stub, BOOKMARK), [[bookmarks(exact:"feat/6c4")]])
  -- Not the listing: a tombstone keeps printing its name there, so a listing
  -- cannot tell a deleted bookmark from a kept one.
  eq("the bookmark read is not a listing",
    tostring(command_for(stub, BOOKMARK)):find("bookmark list", 1, true), nil)
  -- The block that would be closed is the one whose script called this action, so
  -- this action makes no rex.call at all: there is nothing it could close.
  eq("a complete removal closes nothing", #stub.calls, 0)
  -- A teardown that is already clean has nothing to wait for.
  eq("a clean teardown never sleeps", runs(stub, "sleep"), 0)
end

-- Nothing in this action is worktrunk's any more: no word of an argv it runs is
-- the tool the flow used to shell out to. A word, not a substring of the joined
-- line -- a workspace under a path with `wt` in it is nobody's worktrunk -- but
-- an argv element can be a whole shell line (`sh -lc '… wt …'`), so each one is
-- cut into the words a shell would see before it is read. The separators are
-- the ones a shell breaks a command line on, `=` included, so an assignment
-- spelled `x=wt` is caught too.
local function names_worktrunk(call)
  for _, argument in ipairs(call.argv or {}) do
    local text = tostring(argument)
    if text:find("worktrunk", 1, true) then
      return true
    end
    for word in text:gmatch("[^%s;|&()<>=]+") do
      if word == "wt" then
        return true
      end
    end
  end
  return false
end

-- The scan has to reach inside a shell line, and it has to leave a path that
-- merely holds the letters alone: both said here, on the reader itself, so a
-- scan that went back to whole-argument comparisons fails this instead of
-- quietly passing every case below.
eq("the worktrunk scan reads the words of a shell line",
  names_worktrunk({ argv = { "sh", "-lc", "wt step copy-ignored && echo done" } }), true)
eq("the worktrunk scan is not fooled by a path that holds the letters",
  names_worktrunk({ argv = { "sh", "-lc", "/p/demo-wt/main done" } }), false)

do
  local stub = go_stub()
  pcall(M.work_done_go, {}, removal())
  local stray = {}
  for _, call in ipairs(stub.exec_calls) do
    if names_worktrunk(call) then
      stray[#stray + 1] = table.concat(call.argv, " ")
    end
  end
  eq("nothing the action runs names worktrunk", stray, {})
end

-- dojjo deletes the bookmark with the workspace, so a bookmark that still
-- resolves after the removal is the one thing left to report: the flow does not
-- delete it, and the command that would is the person's to run. dojjo has no
-- merged check, so a bookmark left behind is the only "kept" case there is.
do
  local stub = go_stub({ [BOOKMARK] = BOOKMARK_LIVE })
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a bookmark dojjo left behind fails", ok, false)
  contains("the kept bookmark is named", said, "the bookmark feat/6c4 was kept")
  contains("the kept bookmark names the command that would finish it", said,
    "run jj bookmark delete 'feat/6c4'")
  eq("a kept bookmark closes nothing", #stub.calls, 0)
end

-- The tombstone a remote-tracked bookmark leaves behind, which is the case that
-- makes the live-target read the only correct one: `jj bookmark delete` -- what
-- dojjo's remove does -- only marks the bookmark deleted, and `jj bookmark list`
-- goes on printing its name (twice: the deleted local one and the remote one). A
-- listing therefore reports a perfectly finished teardown as a kept bookmark, in
-- a line whose remedy cannot work -- `jj bookmark delete` answers "no matching
-- bookmarks". Nothing resolves, so nothing was kept.
do
  local stub = go_stub({
    [BOOKMARK] = BOOKMARK_GONE,
    -- What the tombstone leaves in the listing, answered only so that reading it
    -- would be a failure of this case rather than a missing reply.
    [BOOKMARKS_LIST] = { code = 0, stdout = "feat/6c4\nfeat/6c4\nmain\n", stderr = "" },
  })
  local ok, result = pcall(M.work_done_go, {}, removal())
  eq("a tombstone does not fail a finished teardown", ok, true)
  eq("a torn-down branch returns nothing", result, nil)
  eq("the tombstone's listing is never read",
    exec_for(stub, BOOKMARKS_LIST).argv, nil)
end

-- A bookmark read that cannot be run is a failure, not a proof that nothing is
-- left: a check that answered "no bookmark" because it could not see the
-- repository would pass a teardown that kept one.
do
  go_stub({ [BOOKMARK] = { code = 1, stdout = "", stderr = "no jj repo here\n" } })
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a bookmark read that failed fails the teardown", ok, false)
  contains("the bookmark read failure is named", said,
    "could not read the bookmark of feat/6c4")
  contains("the bookmark read failure carries jj's line", said, "no jj repo here")
end

-- A name jj's own revset syntax would choke on: the quote and the backslash
-- are escaped inside the string literal, so jj parses the revset instead of
-- failing on it -- and a failure there is reported as a failed read rather than
-- read as a kept bookmark.
do
  local name = 'odd"name'
  local path = '/p/demo/odd"name'
  local remove = [[djo remove 'odd"name' -y]]
  local listing = 'main\t/p/demo/main\n'
  local bookmark = [[jj --ignore-working-copy log --no-graph -r 'bookmarks(exact:"odd\"name")' -T 'commit_id ++ "\n"']]
  local stub = go_stub({
    [remove] = REMOVED,
    [WORKSPACES] = { code = 0, stdout = listing, stderr = "" },
    [DIRECTORY] = GONE,
    [bookmark] = BOOKMARK_GONE,
  })
  local ok, result = pcall(M.work_done_go, {}, removal{ workspace = name, path = path })
  eq("a name holding a quote is torn down", ok, true)
  eq("a name holding a quote returns nothing", result, nil)
  eq("the bookmark revset escapes the name's own quote",
    exec_for(stub, bookmark).argv ~= nil, true)
end

-- And the same read with nothing to run it: a shell that could not start jj has
-- no exit code and no jj line to carry, so the reason the exec gave is what the
-- report names -- and it still fails rather than reading as "no bookmark".
do
  local stub = go_stub()
  stub.exec_replies[BOOKMARK] = nil
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a bookmark read that could not run fails the teardown", ok, false)
  contains("the bookmark read that could not run is named", said,
    "could not read the bookmark of feat/6c4")
  contains("the reason the bookmark read could not run is carried", said,
    "executable file not found in PATH")
end

-- And the directory itself, which is what a person looks for when they doubt the
-- removal: `test ! -e` is the whole of that check -- `-e` and not `-d`, since
-- anything at all left at the path is a leftover -- and it is an argv rather
-- than a shell line, so the path is one word whatever it holds.
do
  local stub = go_stub({ [DIRECTORY] = MISSING })
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a directory still there fails", ok, false)
  contains("the surviving directory is named", said, "/p/demo/feat-6c4 is still there")
  contains("the surviving directory names the listing to read", said,
    "run djo list -f in /p/demo/main")
  eq("a surviving directory never reads the bookmark",
    exec_for(stub, BOOKMARK).argv, nil)
end

-- A check that cannot be run is not a proof of absence either.
do
  local stub = go_stub()
  stub.exec_replies[DIRECTORY] = nil
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a directory check that could not run fails", ok, false)
  contains("the failure says the check could not be run", said,
    "could not check whether /p/demo/feat-6c4 is still there")
end

-- dojjo's own remove is synchronous, so the row should already be gone -- but
-- the exit code is not what this believes. The row is, so it is read again after
-- a bounded wait, and only a row still there at the end of it is a leftover. The
-- wait is what the next cases turn on; the sleep is stubbed, so they cost
-- nothing to run.

-- The fallback is the belt to dojjo's braces: a row the wait still names is
-- forgotten by the flow itself, once, from the main worktree, with the name
-- quoted like every other word the shell is handed.
do
  -- The row never goes on its own; only the flow's own forget ends it.
  local forgot = false
  local stub = go_stub({
    [WORKSPACES] = function()
      if forgot then return WORKSPACES_CLEAR end
      return ROW_LEFT
    end,
    [FORGET] = function()
      forgot = true
      return { code = 0, stdout = "", stderr = "" }
    end,
  })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, result = pcall(M.work_done_go, {}, removal())
  eq("a row nothing else clears is forgotten by the flow", ok, true)
  eq("a forgotten row returns nothing", result, nil)
  local forget = exec_for(stub, FORGET)
  eq("the forget names the workspace as one quoted word",
    command_for(stub, FORGET), FORGET)
  eq("the forget is run once", runs(stub, FORGET), 1)
  eq("the forget runs in the main worktree", forget.cwd, "/p/demo/main")
  eq("the row is re-read after the forget, then the directory and bookmarks asked",
    { stub.events[#stub.events - 3], stub.events[#stub.events - 2],
      stub.events[#stub.events - 1], stub.events[#stub.events] },
    { FORGET, WORKSPACES, DIRECTORY, BOOKMARK })
  eq("a forgotten row closes nothing", #stub.calls, 0)
end

-- And a forget of the flow's own that fails is the leftover it always was: the
-- report names the command rather than the shell's line, and nothing below the
-- jj row is asked.
do
  local stub = go_stub({
    [WORKSPACES] = ROW_LEFT,
    [FORGET] = { code = 1, stdout = "", stderr = "jj: workspace is locked\n" },
  })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a forget that fails fails the teardown", ok, false)
  contains("the failed forget names the command that would clear the row", said,
    "jj workspace forget 'feat/6c4'")
  contains("the failed forget says the row is still registered", said,
    "is still registered")
  contains("the failed forget carries jj's own reason", said,
    "jj: workspace is locked")
  eq("the failed forget is tried once", runs(stub, FORGET), 1)
  eq("the surviving row is read again before it is believed",
    runs(stub, WORKSPACES) > 1, true)
  -- Ten reads in the wait, each after the first preceded by a sleep, then one
  -- immediate re-read after the forget: the re-read is what this believes, so
  -- nothing is slept for it.
  eq("the wait reads ten times", runs(stub, WORKSPACES), 11)
  eq("every wait read after the first waits first", runs(stub, "sleep"), 9)
  eq("a surviving jj row stops before the directory is checked",
    exec_for(stub, DIRECTORY).argv, nil)
end

-- And the other way round, which is the narrower window this whole mechanism
-- exists for: the row clears in the gap before the flow's own forget, so that
-- forget fails against a workspace that is already gone. The row is what is
-- believed, so this is a finished teardown, not a leftover.
do
  local forgot = false
  local stub = go_stub({
    [WORKSPACES] = function()
      if forgot then return WORKSPACES_CLEAR end
      return ROW_LEFT
    end,
    [FORGET] = function()
      forgot = true
      return { code = 1, stdout = "", stderr = "jj: workspace is locked\n" }
    end,
  })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, result = pcall(M.work_done_go, {}, removal())
  eq("a forget whose row is already gone is not a failure", ok, true)
  eq("a row gone after a failed forget returns nothing", result, nil)
  eq("that teardown closes nothing", #stub.calls, 0)
  eq("the row is believed over the exit code, so nothing is reported",
    runs(stub, FORGET), 1)
end

-- A forget that exits 0 and leaves the row is a leftover too: the row is what
-- is checked, not the exit code of the command the flow ran to clear it.
do
  local stub = go_stub({
    [WORKSPACES] = ROW_LEFT,
    [FORGET] = { code = 0, stdout = "", stderr = "" },
  })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a row that survives the flow's own forget fails", ok, false)
  contains("the row that survived names the command", said,
    "jj workspace forget 'feat/6c4'")
  eq("a row that survived is re-read after the forget",
    runs(stub, "sleep"), runs(stub, WORKSPACES) - 2)
end

-- A row that is still there for the first read and gone by the next: the wait is
-- what keeps a false "still registered" off the screen, and it closes nothing.
do
  local reads = 0
  local stub = go_stub({ [WORKSPACES] = function()
    reads = reads + 1
    if reads == 1 then return ROW_LEFT end
    return WORKSPACES_CLEAR
  end })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, result = pcall(M.work_done_go, {}, removal())
  eq("a row cleared a moment later is not a failure", ok, true)
  eq("a row that cleared returns nothing", result, nil)
  eq("the wait reads the list again after the sleep", stub.events,
    { REMOVE, WORKSPACES, "sleep", WORKSPACES, DIRECTORY, BOOKMARK })
  eq("a row that cleared is read exactly twice", reads, 2)
  eq("a row that cleared is never forgotten by the flow", runs(stub, FORGET), 0)
  eq("a row that cleared closes nothing", #stub.calls, 0)
end

-- A read that fails during the wait is a failure, not more waiting: jj's own
-- line is the report, and a wait does not paper over it.
do
  local reads = 0
  local stub = go_stub({ [WORKSPACES] = function()
    reads = reads + 1
    if reads == 1 then return ROW_LEFT end
    return { code = 1, stdout = "", stderr = "jj: workspace is locked\n" }
  end })
  stub.exec_replies["sleep"] = { code = 0, stdout = "", stderr = "" }
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a read that fails during the wait fails the teardown", ok, false)
  contains("the mid-wait failure is named as the listing", said,
    "could not list jj workspaces")
  contains("the mid-wait failure carries jj's line", said, "workspace is locked")
  eq("a failed read ends the wait", reads, 2)
end

-- A listing that cannot be read at all is a failure, not a proof of absence: a
-- check that answered "nothing there" because it could not see the list would
-- pass a removal that did not happen.
do
  local stub = go_stub({ [WORKSPACES] = { code = 1, stdout = "", stderr = "no jj repo here\n" } })
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a jj listing that failed fails the teardown", ok, false)
  contains("the jj listing failure is named", said, "could not list jj workspaces")
  eq("nothing below a failed listing is asked", exec_for(stub, DIRECTORY).argv, nil)
end

-- dojjo refused outright: its own first line is the report, and the rest of its
-- output is not. Nothing is verified, because nothing was removed.
do
  local stub = go_stub({ [REMOVE] = {
    code = 1, stdout = "", stderr = "no workspace named feat/6c4\nand another line\n",
  } })
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a failed removal fails", ok, false)
  contains("the failure carries dojjo's line", said, "no workspace named feat/6c4")
  contains("the failure names the workspace and its directory",
    said, "could not remove the workspace feat/6c4 (/p/demo/feat-6c4)")
  eq("only the first line is carried", tostring(said):find("another line", 1, true), nil)
  eq("a failed removal verifies nothing", #stub.exec_calls, 1)
end

-- A dojjo that never ran is its own failure rather than an exit code: a login
-- shell with nothing on PATH says so.
do
  local stub = go_stub()
  stub.exec_replies[REMOVE] = nil
  local ok, said = pcall(M.work_done_go, {}, removal())
  eq("a removal that could not run fails", ok, false)
  contains("the failure says djo could not be run", said, "could not run djo")
end

-- A workspace name with a space and an apostrophe is one argument to dojjo, not
-- three (Review Focus 2): the word is single-quoted, and an apostrophe inside it
-- is closed, escaped and reopened. The path needs no quoting at all any more --
-- it is one argv element of the directory check.
do
  eq("a quoted name keeps its apostrophe", M.shell_quote("/p/demo/it's here"),
    "'/p/demo/it'\\''s here'")
  eq("a plain name is one quoted word", M.shell_quote("feat/6c4"), "'feat/6c4'")

  local awkward = "djo remove 'feat/6c4-it'\\''s' -y"
  -- The bookmark read carries the same name inside a revset, so it is quoted the
  -- same way: one shell word, apostrophe and all.
  local awkward_bookmark = "jj --ignore-working-copy log --no-graph -r "
    .. [['bookmarks(exact:"feat/6c4-it'\''s")' -T 'commit_id ++ "\n"']]
  local stub = go_stub({ [awkward] = REMOVED, [awkward_bookmark] = BOOKMARK_GONE })
  local ok = pcall(M.work_done_go, {},
    removal{ workspace = "feat/6c4-it's", path = "/p/demo/it's here" })
  eq("the removal quotes the workspace as one word", ok, true)
  eq("the quoted workspace is what the login shell ran",
    stub.exec_calls[1] and program(stub.exec_calls[1]), awkward)
  eq("the path reaches the directory check as one word",
    exec_for(stub, DIRECTORY).argv, { "test", "!", "-e", "/p/demo/it's here" })
end

-- The hand-back is also a `rex do` entry point, where an --args object is not
-- filtered against the declaration, so a key it needs and does not have is
-- refused before anything is removed.
do
  local stub = go_stub()
  local ok, said = pcall(M.work_done_go, {}, removal{ path = "" })
  eq("a hand-back with an empty path fails", ok, false)
  contains("the failure says what the removal needs", said, "work_done_go needs")
  contains("the failure names the key that is missing", said, "path")
  eq("a hand-back with an empty path removes nothing", #stub.exec_calls, 0)
end

do
  local stub = go_stub()
  local args = removal()
  args.workspace = nil
  local ok, said = pcall(M.work_done_go, {}, args)
  eq("a hand-back with no workspace fails", ok, false)
  contains("the failure names the workspace", said, "no workspace")
  eq("a hand-back with no workspace removes nothing", #stub.exec_calls, 0)
end

-- work_done_go()'s declaration ---------------------------------------------------

-- The five keys are the float's whole contract, and a removal with one missing
-- has nothing to remove -- so they are declared, and required.
do
  local go
  for _, spec in ipairs(rex_stub.actions) do
    if spec.name == "work_done_go" then go = spec end
  end
  eq("work_done_go is registered", type(go), "table")
  eq("work_done_go declares the hand-back's five keys",
    sorted_keys(go and go.args and go.args.properties),
    { "main", "path", "project", "root", "workspace" })
  eq("work_done_go requires every one of them", go and go.args.required,
    { "project", "root", "main", "workspace", "path" })
end

-- new_tab_argv() --------------------------------------------------------------
-- The tab does not run one program any more: it runs a fish wrapper that
-- switches to, attaches or creates the worktree, starts the agent in it, and
-- leaves a login shell behind when the agent exits. Everything the flow knows
-- travels as a positional parameter --
--
--   fish -c SCRIPT <mode> <branch> <base> <agent> <agent args…>
--
-- because that is the only way a branch, a prompt or an agent name can reach
-- the wrapper without any shell parsing it as text. These assertions pin the
-- shape element by element.

-- The program fish is handed, as the module builds it: the one string an
-- interpolating implementation would have rewritten with the answer.
local WRAPPER = M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "switch" })[3]
eq("the wrapper program is text", type(WRAPPER), "string")

-- fish has no $0 slot to fill, so no spare word sits between the program and
-- the first parameter: the word after `-c SCRIPT` is already the mode.
eq("fish takes no $0: the mode follows the program",
  { M.new_tab_argv(PROJECT, { branch = BRANCH })[1],
    M.new_tab_argv(PROJECT, { branch = BRANCH })[2],
    M.new_tab_argv(PROJECT, { branch = BRANCH })[4] },
  { "fish", "-c", "switch" })

eq("new_tab_argv for an existing worktree",
  M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "switch", bead = BEAD, title = "Diff" }),
  { "fish", "-c", WRAPPER, "switch", BRANCH, "", "pi", "/brainstorming for bead " .. BEAD })

-- A create with no base answered and none configured: the picker resolves the
-- default itself, so the wrapper is told nothing and passes jws no base word.
eq("new_tab_argv for a new branch",
  M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "create", bead = BEAD, title = "Diff" }),
  { "fish", "-c", WRAPPER, "create", BRANCH, "", "pi", "/brainstorming for bead " .. BEAD })

eq("new_tab_argv without a bead asks for plain brainstorming",
  M.new_tab_argv(PROJECT, { branch = "x", worktree = "create", bead = "" }),
  { "fish", "-c", WRAPPER, "create", "x", "", "pi", "/brainstorming" })

-- A missing bead and an empty one are the same answer: no bead.
eq("new_tab_argv with no bead field at all",
  M.new_tab_argv(PROJECT, { branch = "x", worktree = "switch" }),
  { "fish", "-c", WRAPPER, "switch", "x", "", "pi", "/brainstorming" })

-- A hand-back always says which mode it means, but leaving the field out must
-- not read as "create": that would add a worktree nobody asked for.
eq("new_tab_argv with no mode field switches, creating nothing",
  M.new_tab_argv(PROJECT, { branch = "x", bead = "" }),
  { "fish", "-c", WRAPPER, "switch", "x", "", "pi", "/brainstorming" })

-- base = false is the picker's "start from nothing": an empty base parameter,
-- which is the wrapper's "no base word at all" -- and no remote word either,
-- because the remote a base lives on is part of the revision's own name.
do
  local base = M.options.base
  M.options.base = false
  eq("no base parameter when the option says so",
    M.new_tab_argv(PROJECT, { branch = "x", worktree = "create" })[6], "")
  eq("no remote word: the agent follows the empty base",
    M.new_tab_argv(PROJECT, { branch = "x", worktree = "create" })[7], "pi")
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
  local argv = M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "create", bead = BEAD })
  eq("the branch is one argument", argv[5], BRANCH)
  eq("the agent's arguments and the prompt are arguments too",
    { argv[7], argv[8], argv[9], argv[10] }, { "pi", "--thinking", "high", prompt })
  eq("the prompt keeps its newline", argv[10]:match("\n(.*)$"), "second line; " .. BEAD)
  eq("the number of arguments is the number of values", #argv, 10)
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
    M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "switch", bead = BEAD, title = "Diff" }),
    { "fish", "-c", WRAPPER, "switch", BRANCH, "", "claude",
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
  M.new_tab_argv(PROJECT, { branch = BRANCH, worktree = "switch", bead = BEAD, title = "Diff", agent = "claude" }),
  { "fish", "-c", WRAPPER, "switch", BRANCH, "", "claude", "/brainstorming for bead " .. BEAD })

eq("new_tab_argv sends the prompt the picker was given",
  M.new_tab_argv(PROJECT, { branch = "x", worktree = "create", prompt = "why is the guard flaky?" }),
  { "fish", "-c", WRAPPER, "create", "x", "", "pi", "why is the guard flaky?" })

eq("a typed prompt wins over the bead's",
  M.new_tab_argv(PROJECT, { branch = "x", bead = BEAD, title = "Diff", prompt = "just look" })[8],
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
    { "fish", "-c", WRAPPER, "switch", "x", "", "", "" })
  eq("new_tab_argv with no agent keeps a prompt that was typed",
    M.new_tab_argv(PROJECT, { branch = "x", agent = "", prompt = "look first" })[8],
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
  eq("the wrapper is asked to create the worktree", options.command[4], "create")
  eq("the wrapper is given the branch", options.command[5], BRANCH)
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
  eq("no agent means a tab that starts none", command[7], "")
  eq("no agent still carries the prompt", command[#command], "look before you leap")
end

stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, payload{ agent = "claude" })
eq("the agent the picker chose is the one the tab starts",
  request_of(stub, "session.new_window").layout.block.options.command[7], "claude")
eq("the configured agent is left alone", M.options.agent, "pi")

-- Switching to a worktree that already exists, with no tab for it yet: the tab
-- is made in switch mode, so no second worktree appears.
stub = new_branch_stub()
pcall(M.work_new_go, { origin = "cli" }, payload{ worktree = "switch" })
eq("an existing worktree is switched to",
  request_of(stub, "session.new_window").layout.block.options.command,
  M.new_tab_argv(PROJECT, payload{ worktree = "switch" }))
eq("an existing worktree sends no base",
  request_of(stub, "session.new_window").layout.block.options.command[6], "")

-- A hand-run payload from before the mode existed: `rex do work_new_go --args`
-- with `create = true` and no `worktree`. An --args object is not filtered
-- against the declaration, so the old boolean reaches the action, and the argv
-- builder is where it is read -- so the tab still creates the branch rather than
-- switching to a worktree that is not there.
do
  local old = payload()
  old.worktree = nil
  old.create = true
  stub = new_branch_stub()
  pcall(M.work_new_go, { origin = "cli" }, old)
  eq("an old payload's create = true still makes the worktree",
    request_of(stub, "session.new_window").layout.block.options.command[4],
    "create")
end

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
    { "agent", "base", "bead", "blank", "branch", "main",
      "project", "prompt", "root", "title", "worktree" })
  eq("work_new_go requires what the picker always sends",
    go and go.args.required, { "project", "root", "main", "branch" })
  eq("the arguments are typed", go and go.args.properties.worktree, { type = "string" })
  -- The mode is what the tab dispatches on, so it is a string and not the old
  -- boolean: a declaration left as `create` would filter the mode out before the
  -- action saw it, and every tab would switch.
  eq("the old create boolean is gone",
    go and go.args.properties.create, nil)
  eq("blank is declared a boolean", go and go.args.properties.blank,
    { type = "boolean" })
  eq("base admits both the revision and the no-revision sentinel",
    go and go.args.properties.base, { type = { "string", "boolean" } })
  -- The remote a base comes from is the @remote in the revision itself, so a
  -- second carrier is not declared: an undeclared pair is filtered before the
  -- action, which is exactly what should happen to one.
  eq("no second carrier for the base's remote is declared",
    go and go.args.properties.base_remote, nil)
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
  base = "main@upstream", blank = true,
}))
do
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("the base the picker chose reaches the tab", command[6], "main@upstream")
  eq("the base carries its remote in its own name, and nowhere else",
    command[7], M.options.agent)
  eq("a blank answer appends no prompt word", #command, 7)
  eq("a blank answer leaves the agent last", command[#command], M.options.agent)
end

-- The no-revision sentinel is false, and it has to stay false all the way: a
-- configuration naming a base must not undo the picker's answer, and a
-- declaration that turned it into the string "false" would send `false` to
-- jws as the base revision.
do
  local saved = M.options.base
  M.options.base = "main"
  stub = new_branch_stub()
  pcall(M.work_new_go, { origin = "cli" }, as_rex_passes("work_new_go", payload{
    base = false,
  }))
  local command = request_of(stub, "session.new_window").layout.block.options.command
  eq("the no-revision sentinel reaches the tab as no base", command[6], "")
  eq("no revision carries no remote word either", command[7], M.options.agent)
  M.options.base = saved
end

-- The fixture wrapper goes with the file on either way out: a run that failed
-- is the one most likely to be re-run, and a mktemp tree left under it is litter
-- nobody goes looking for. So the removal and the exit are one step, the removal
-- first. TMP is this file's own, so nothing else is named.
local function finish()
  os.execute("rm -rf " .. quote(TMP))
  if fails > 0 then os.exit(1) end
  print("ok " .. count .. " assertions")
end

finish()
