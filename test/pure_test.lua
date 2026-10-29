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

-- The guard on eq() itself, as in the other two files: the two proofs above pass
-- whichever comparison eq() uses, so re-inlining the old element-wise one into
-- eq() would leave this file passing no matter what it was handed. A probe that
-- has to fail proves the wiring; its FAIL line is swallowed and the totals are
-- put back afterwards.
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

-- new_tab_argv: the tab's four positional words
--
-- The tab runs a POSIX sh wrapper, and everything the flow knows reaches it as
-- a positional parameter --
--
--   sh -c SCRIPT sh <create> <branch> <base> <remote> <agent> [args] <prompt>
--
-- so argv[4] is $0 and the words start at argv[5]: the create flag, the
-- branch, the base, the remote. The base is three-valued -- a string is the
-- ref to create from, false is worktrunk's own default (no --base word at
-- all), and absent means the picker never answered, so the configured base is
-- the fallback -- and the remote rides beside it, sent only when the picker
-- resolved the base to a remote-tracking ref. An empty remote is nothing to
-- fetch.
do
  local saved = M.options.base
  M.options.base = nil

  local answered = M.new_tab_argv("proj", { branch = "feat/x1", create = true,
    base = "origin/main", base_remote = "origin" })
  eq("the base travels as the third positional word", answered[7], "origin/main")
  eq("the remote travels as the fourth positional word", answered[8], "origin")
  eq("the answer's words leave the agent and the prompt after them",
    { answered[9], answered[10] }, { "pi", "/brainstorming" })

  -- The answer beats the configuration: base = false is the picker saying "let
  -- worktrunk choose", and a configured fallback must not quietly undo it.
  M.options.base = "main"
  eq("a configured base does not replace the answer",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true, base = "origin/main" })[7],
    "origin/main")
  eq("base = false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true, base = false })[7], "")
  eq("base = false carries no remote",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true, base = false })[8], "")

  -- No base in the payload is a hand-run `rex do`: the configuration is the
  -- fallback, and only when it names a ref.
  eq("no base in the payload falls back to the configured one",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true })[7], "main")
  M.options.base = false
  eq("a configured base of false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true })[7], "")
  M.options.base = nil
  eq("a base the picker never answered and no configuration sends nothing",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true })[7], "")
  eq("a base with no remote of its own carries an empty remote",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true, base = "@" })[8], "")
  eq("a base_remote that is not a string is no remote to fetch",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true,
      base = "@", base_remote = false })[8],
    "")

  M.options.base = saved
end

-- The prompt is the argv's last word -- unless there is nothing to say.
--
-- A blank answer is the picker saying "an agent, and nothing to say", which is
-- neither the configured templates nor an empty word: it sends no prompt
-- parameter at all, so the argv ends after the agent and its arguments. And a
-- prompt whose first byte is "-" would be read by the agent as a flag, so it
-- gains exactly one leading space in front -- here, where the argument contract
-- lives, rather than in the wrapper that only execs what it was given.
do
  local saved_args, saved_base = M.options.agent_args, M.options.base
  M.options.base = false
  M.options.agent_args = { "--mode", "plan" }

  local function prompt_argv(prompt)
    return M.new_tab_argv("proj", { branch = "feat/x1", create = true,
      prompt = prompt })
  end

  -- Nine words take the argv to the agent, two more are its own arguments, and
  -- the prompt is the one after them: so word 12 is where a prompt lands.
  eq("a prompt is the word after the agent's arguments",
    prompt_argv("plain")[12], "plain")
  eq("a prompt that does not start with a dash is untouched",
    #prompt_argv("plain"), 12)
  eq("a prompt starting with a dash gains one leading space",
    prompt_argv("-x")[12], " -x")
  eq("a prompt of a bare dash gains the same one space",
    prompt_argv("-")[12], " -")
  eq("a prompt of two dashes gains the same one space",
    prompt_argv("--")[12], " --")
  eq("the dash guard is one space, not two", #prompt_argv("--"), 12)
  eq("a quoted prompt with a template sequence stays one word",
    prompt_argv('fix "it" {{ now }}')[12], 'fix "it" {{ now }}')

  -- blank with a prompt set is the interesting case: the payload never carries
  -- both, but the picker's answer has the last word either way, so a blank
  -- answer must drop a prompt even when one was handed over.
  local blank = M.new_tab_argv("proj", { branch = "feat/x1", create = true,
    prompt = "hello", blank = true })
  eq("a blank answer appends no prompt word", #blank, 11)
  eq("a blank answer puts no word after the agent's arguments",
    { blank[10], blank[11] }, { "--mode", "plan" })
  eq("a blank answer is not an empty prompt word", blank[12], nil)

  M.options.agent_args, M.options.base = saved_args, saved_base
end

-- The `wt switch` words themselves are asserted where they are executed:
-- test/wrapper_test.sh runs the tab's wrapper with a stand-in `wt` and reads
-- the words it was given, for a create run and for an existing worktree.

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
