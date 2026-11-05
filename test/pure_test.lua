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

-- What a tab is still running --------------------------------------------------
--
-- The done flow closes a tab only when nothing in it is somebody's work. A shell
-- is what a tab idles at, so the names below are compared against the shell list
-- after a directory and the leading dash of a login shell are stripped: `-fish`
-- and `/usr/bin/fish` are the same program as `fish`. A process reply carries
-- three possible names -- an interpreter's script, the argv0 a login shell shows,
-- the system's own name -- in two slots, the foreground first and the child after
-- it, because the one that answers is whichever the terminal could name.

eq("a program's directory is stripped", M.program_basename("/usr/bin/fish"), "fish")
eq("a login shell's dash is stripped", M.program_basename("-zsh"), "zsh")
eq("a bare name is left alone", M.program_basename("fish"), "fish")
eq("a trailing slash still names the program", M.program_basename("/usr/bin/fish/"), "fish")
eq("slashes alone name nothing", M.program_basename("///"), "")
eq("nothing names nothing", M.program_basename(nil), "")

eq("a login shell names a shell", M.is_shell("-fish"), true)
eq("a full path names a shell", M.is_shell("/bin/sh"), true)
eq("a bare shell name is a shell", M.is_shell("fish"), true)
eq("an agent is not a shell", M.is_shell("pi"), false)
eq("a program is not a shell", M.is_shell("node"), false)
eq("an unnamed program is not a shell", M.is_shell(""), false)

eq("an interpreter's script is the program it runs",
  M.process_program({ foreground = { name = "node", script = "/p/x/bin/pi" } }), "pi")
eq("argv0 beats the system's name",
  M.process_program({ foreground = { argv0 = "-fish", name = "fish" } }), "fish")
eq("the child answers when the foreground cannot",
  M.process_program({ child = { name = "zsh" } }), "zsh")
eq("an empty reply names nothing", M.process_program({}), "")
eq("a reply that is not a table names nothing", M.process_program(42), "")

do
  local window = { layers = {
    { blocks = { { block_id = "b1" } } },
    { blocks = { { block_id = "b2" } } },
  } }
  eq("every layer is read", #M.window_blocks(window), 2)
  eq("a window carrying blocks directly is read",
    #M.window_blocks({ blocks = { { block_id = "b9" } } }), 1)
  eq("a window with no blocks has none", #M.window_blocks({ window_id = "w0" }), 0)
  eq("a window that is not a table has none", #M.window_blocks(nil), 0)
  -- A layer whose blocks cannot be read is counted as an unreadable entry
  -- rather than dropped: it may hold a program, and tab_processes names what it
  -- cannot read instead of raising on the index.
  eq("a layer that cannot be read is counted",
    #M.window_blocks({ layers = { 42 } }), 1)
  eq("a layer that cannot be read finds no block",
    M.window_of_block({ { layers = { 42 } } }, "b1"), nil)
  eq("a block finds its window",
    M.window_of_block({ { window_id = "w0" }, window }, "b2"), window)
  eq("an unknown block finds nothing", M.window_of_block({ window }, "zz"), nil)
  eq("no windows find nothing", M.window_of_block(nil, "b2"), nil)
end

-- new_tab_argv: the tab's positional words
--
-- The tab runs a fish wrapper, and everything the flow knows reaches it as a
-- positional parameter --
--
--   fish -c SCRIPT <mode> <branch> <base> <agent> [args] <prompt>
--
-- because a parameter is the one way a branch, a base, a prompt or an agent
-- name reaches a shell without the shell parsing it as text. fish has no $0
-- slot, so the words start at argv[4] with nothing between: the mode (switch,
-- create or attach), the branch, the base, the agent. The base is
-- three-valued -- a string is the revision to create from, false is "start
-- from nothing" (the wrapper passes no base word to gws at all), and absent
-- means the picker never answered, so the configured base is the fallback.
-- The remote a base lives on is part of the revision's own name
-- (`main@origin`), so it travels with the base rather than as a word of its
-- own.
do
  local saved = M.options.base
  M.options.base = nil

  -- The program is fish's -c, and the word after it is already the first
  -- parameter: a spare name there, the way sh takes $0, would silently shift
  -- every word below it.
  local plain = M.new_tab_argv("proj", { branch = "feat/x1" })
  eq("the program is fish's -c", { plain[1], plain[2], plain[3] },
    { "fish", "-c", M.new_tab_script })
  eq("no word stands between the program and the mode", plain[4], "switch")

  -- The three modes, said outright by the picker as one word before the
  -- branch. They are the whole of what the wrapper dispatches on, so each is
  -- pinned here rather than only where it is executed.
  eq("switch is the word a worktree branch sends",
    { M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch" })[4],
      M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch" })[5] },
    { "switch", "feat/x1" })
  eq("attach is the word a branch with no worktree sends",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "attach" })[4],
    "attach")
  eq("create is the word a new branch sends",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create" })[4],
    "create")
  -- A payload written before the mode existed says it with the old boolean:
  -- `create = true` is a branch to make, and nothing said at all is the switch
  -- it always was. Neither is read as a mode of its own, so an old dry run
  -- pasted back into `rex do` still does what it said.
  eq("an old payload's create = true is still a create",
    M.new_tab_argv("proj", { branch = "feat/x1", create = true })[4],
    "create")
  eq("a payload with no mode and no create is a switch",
    M.new_tab_argv("proj", { branch = "feat/x1" })[4], "switch")
  eq("a payload with create = false is a switch",
    M.new_tab_argv("proj", { branch = "feat/x1", create = false })[4], "switch")
  -- The mode word beats the old boolean when both are there: only a caller
  -- that knows about modes sends both, and what it said last is the answer.
  eq("the mode wins over the old boolean",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "attach",
      create = true })[4], "attach")
  -- An empty string is no word: it says nothing, so it falls back like a field
  -- that was never sent -- rather than building a tab the wrapper would refuse.
  eq("an empty mode word falls back to the old boolean",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "",
      create = true })[4], "create")
  eq("an empty mode word and nothing else is a switch",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "" })[4], "switch")
  -- Any other word is refused where the branch and the agent are refused: the
  -- wrapper would print its contract line and start nothing, and a tab that
  -- does nothing quietly is worse than a caller's own error.
  local built, refused = pcall(M.new_tab_argv, "proj",
    { branch = "feat/x1", worktree = "attatch" })
  eq("a mode word that is none of the three is refused", built, false)
  eq("the refusal says which words there are",
    type(refused) == "string" and
      refused:find("switch, create or attach", 1, true) ~= nil, true)

  -- The mode-bearing path is the one that carries a base: a create is the only
  -- mode with a revision to start from, and these assertions drive the word the
  -- picker really sends rather than the old boolean it falls back to.
  local answered = M.new_tab_argv("proj", { branch = "feat/x1",
    worktree = "create", base = "origin/main", base_remote = "origin" })
  eq("the base travels as the third positional word", answered[6], "origin/main")
  eq("the answer's words leave the agent and the prompt after them",
    { answered[7], answered[8] }, { "pi", "/brainstorming" })

  -- The answer beats the configuration: base = false is the picker saying
  -- "start from nothing", and a configured fallback must not quietly undo it.
  M.options.base = "main"
  eq("a configured base does not replace the answer",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create",
      base = "origin/main" })[6], "origin/main")
  eq("base = false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create",
      base = false })[6], "")
  -- A remote handed over anyway is not a word: the agent follows the base
  -- whether or not there is one, so nothing sits between them.
  eq("a base_remote in the payload is not a word of its own",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create",
      base = false, base_remote = "origin" })[7], "pi")

  -- No base in the payload is a hand-run `rex do`: the configuration is the
  -- fallback, and only when it names a revision.
  eq("no base in the payload falls back to the configured one",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create" })[6], "main")
  M.options.base = false
  eq("a configured base of false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create" })[6], "")
  M.options.base = nil
  eq("a base the picker never answered and no configuration sends nothing",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create" })[6], "")

  -- A switch and an attach are given no base at all -- not the payload's, not
  -- the configuration's. The branch already exists, so there is nothing to start
  -- it from, and the wrapper hands its base word to a create alone: a base here
  -- would be an answer to a question neither mode asked.
  M.options.base = "main"
  eq("a switch sends no base, whatever was configured",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch" })[6], "")
  eq("a switch sends no base even when the payload named one",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "switch",
      base = "origin/main" })[6], "")
  eq("an attach sends no base, whatever was configured",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "attach" })[6], "")
  eq("an attach sends no base even when the payload named one",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "attach",
      base = "origin/main" })[6], "")
  M.options.base = nil

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
    return M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create",
      prompt = prompt })
  end
  -- Seven words take the argv to the agent, two more are its own arguments,
  -- and the prompt is the one after them: so word 10 is where a prompt lands.
  eq("a prompt is the word after the agent's arguments",
    prompt_argv("plain")[10], "plain")
  eq("a prompt that does not start with a dash is untouched",
    #prompt_argv("plain"), 10)
  eq("a prompt starting with a dash gains one leading space",
    prompt_argv("-x")[10], " -x")
  eq("a prompt of a bare dash gains the same one space",
    prompt_argv("-")[10], " -")
  eq("a prompt of two dashes gains the same one space",
    prompt_argv("--")[10], " --")
  eq("the dash guard is one space, not two", #prompt_argv("--"), 10)
  eq("a quoted prompt with a template sequence stays one word",
    prompt_argv('fix "it" {{ now }}')[10], 'fix "it" {{ now }}')

  -- blank with a prompt set is the interesting case: the payload never carries
  -- both, but the picker's answer has the last word either way, so a blank
  -- answer must drop a prompt even when one was handed over.
  local blank = M.new_tab_argv("proj", { branch = "feat/x1", worktree = "create",
    prompt = "hello", blank = true })
  eq("a blank answer appends no prompt word", #blank, 9)
  eq("a blank answer puts no word after the agent's arguments",
    { blank[8], blank[9] }, { "--mode", "plan" })
  eq("a blank answer is not an empty prompt word", blank[10], nil)

  M.options.agent_args, M.options.base = saved_args, saved_base
end

-- The words the create and the switch are given are asserted where they are
-- executed: test/wrapper_test.sh runs the tab's wrapper with a stand-in `gws`
-- and a stand-in `wt` and reads the words each was given, for a create and for
-- an existing worktree.

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
