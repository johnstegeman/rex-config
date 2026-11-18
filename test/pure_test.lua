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

-- The rows new-work.sh prints, and what that script's verbs mean field by field.

eq("a row is split on its tabs", M.parse_rows("a\tb\tc\td\n"), { { "a", "b", "c", "d" } })
eq("an empty field is a field", M.parse_rows("a\t\tb")[1], { "a", "", "b" })
eq("a trailing empty field is a field too", M.parse_rows("a\t")[1], { "a", "" })
eq("an empty line is no row at all", M.parse_rows("a\t1\n\n"), { { "a", "1" } })
eq("a line without a trailing newline is still a row", M.parse_rows("a\t1"), { { "a", "1" } })
eq("a carriage return is not part of a field", M.parse_rows("a\t1\r\n")[1], { "a", "1" })
eq("no text is no rows", M.parse_rows(nil), {})

eq("a bead row carries the four fields it prints",
  M.bead_rows("p-1\tDiff the thing\tbug\t2\n"),
  { { id = "p-1", title = "Diff the thing", issue_type = "bug", priority = "2" } })
-- A bead bd gave no priority to prints an empty last field, and it stays empty:
-- a made-up rank would be shown as one.
eq("a missing priority is empty", M.bead_rows("p-1\tTitle\ttask\t")[1].priority, "")
-- A producer that is not bd itself can still make the title a number, and the
-- title is what the row shows.
eq("the title is the second field", M.bead_rows("p-1\t42\ttask\t1")[1].title, "42")

eq("a base row is a ref and the remote it lives on",
  M.base_rows("origin/main\torigin\n@\t\n"),
  { { ref = "origin/main", remote = "origin" }, { ref = "@", remote = "" } })
eq("a base row with no ref is worktrunk's default", M.base_rows("\t\n")[1].ref, "")

-- The rows that are answers rather than data carry ids no real answer can be: a
-- NUL is what makes that impossible rather than unlikely.
eq("the no-bead row cannot collide with a bead id", M.NO_BEAD, "\0none")
eq("the no-agent row cannot collide with an agent name", M.NO_AGENT, "\0none")
eq("the worktrunk-default base row cannot collide with a ref", M.WT_DEFAULT, "\0default")

-- The bead question's rows: what the person reads -- title, id, type, rank and
-- an icon to tell one kind of work from another -- then the row that says this
-- can start without a bead.
do
  local items = M.bead_items({
    { id = "p-1", title = "Diff the thing", issue_type = "bug", priority = "2" },
    { id = "p-2", title = "Something else", issue_type = "epic", priority = "" },
    { id = "p-3", title = "A third", issue_type = "nonsense", priority = "1" },
  })
  eq("one row per bead, then the no-bead row", #items, 4)
  eq("a bead's row is its title", items[1].title, "Diff the thing")
  eq("the subtitle names the id and the type", items[1].subtitle, "p-1 · bug")
  eq("the detail is the priority", items[1].detail, "P2")
  eq("a bug is a branch", items[1].icon, "branch")
  eq("an epic is a package", items[2].icon, "package")
  eq("no priority is no detail", items[2].detail, nil)
  eq("an unknown type is a document", items[3].icon, "document")
  eq("the last row is the no-bead answer", items[4].id, M.NO_BEAD)
  eq("the no-bead row still says what it is",
    items[4].title, "No bead: a branch and an agent only")
end

eq("the bead question names the project to choose from",
  M.bead_question_title("pmm-iris", { { id = "p-1" } }), "Bead for pmm-iris")
-- The one row an empty listing leaves is the no-bead row, so the title is the
-- only place the empty listing can be said at all.
eq("an empty listing says so in the title",
  M.bead_question_title("pmm-iris", {}), "no ready beads in pmm-iris")

-- The base question's rows: the script's first row is the one a bare Return
-- takes, and an empty ref means worktrunk chooses.
do
  local items = M.base_items({
    { ref = "origin/main", remote = "origin" },
    { ref = "@", remote = "" },
    { ref = "", remote = "" },
  })
  eq("one row per base", #items, 3)
  eq("a ref is its own title", items[1].title, "origin/main")
  eq("a ref on a remote says so", items[1].subtitle, "on origin")
  eq("a ref is a branch", items[1].icon, "branch")
  eq("a local ref has nothing to fetch", items[2].subtitle, "")
  eq("an empty ref is the worktrunk-default row", items[3].id, M.WT_DEFAULT)
  eq("the worktrunk-default row says what it is", items[3].title, "worktrunk's default")
end

-- The agent question's rows: the configured names in order, then none.
do
  local items = M.agent_items({ "pi", "claude" })
  eq("one row per name, then none", #items, 3)
  eq("a name is its own title", { items[1].title, items[2].title }, { "pi", "claude" })
  eq("the last row starts nothing", items[3].id, M.NO_AGENT)
  eq("the none row says what it is", items[3].title, "(none)")
  eq("an empty name is not a row", #M.agent_items({ "", "pi" }), 2)
end

-- The worktree name is derived from the branch the way worktrunk's
-- worktree-path template derives it, and it is a directory name and nothing
-- else.
eq("a branch's slashes become dashes in its directory name",
  M.sanitize_branch("bug/58h"), "bug-58h")
eq("a colon and a backslash go too", M.sanitize_branch("a:b\\c"), "a-b-c")
eq("a name is a name", M.worktree_problem("bug-58h"), nil)
eq("a path is refused", M.worktree_problem("a/b"),
  "a worktree name is a name, not a path: a/b")
eq("a backslash is a separator too", M.worktree_problem("a\\b"),
  "a worktree name is a name, not a path: a\\b")
eq("the directory itself is refused", M.worktree_problem("."),
  "a worktree name cannot be .")
eq("the parent directory is refused", M.worktree_problem(".."),
  "a worktree name cannot be ..")

-- A branch with no bead to name it: a name and not a number, and one a test can
-- repeat by handing in its own picker.
eq("a random name is a feat branch of two words",
  M.random_branch_name(function() return 1 end), "feat/amber-badger")
eq("the two picks choose independently",
  M.random_branch_name((function()
    local n = 0
    return function() n = n + 1; return n end
  end)()),
  "feat/amber-beacon")
do
  local name = M.random_branch_name()
  eq("the generated name is a feat branch",
    name:match("^feat/[a-z]+%-[a-z]+$") ~= nil, true)
end

-- Where the agent memory lives, and what a state file means. Both are pure so
-- that the rule is pinned here rather than only in a run against a home
-- directory a test must not touch.

eq("an absolute XDG_STATE_HOME is the location",
  M.state_dir_for("/state", "/home/j"), "/state/rex-config")
eq("the state file is the one file in it",
  M.state_file_for("/state", "/home/j"), "/state/rex-config/state")
-- XDG says a relative XDG_STATE_HOME counts as unset: joining one to nothing
-- would put the file under whatever directory the run happened in.
eq("a relative XDG_STATE_HOME is not a location",
  M.state_dir_for("state", "/home/j"), "/home/j/.local/state/rex-config")
eq("with no XDG_STATE_HOME the home directory decides",
  M.state_dir_for(nil, "/home/j"), "/home/j/.local/state/rex-config")
eq("with neither there is still a path, not an error",
  M.state_dir_for(nil, nil), "/.local/state/rex-config")

eq("a remembered agent is read back",
  M.agent_from_state("agent=claude\n"), "claude")
-- The format is one key written whole, so the first line is the answer and a
-- value can be anything after the "=" -- including nothing, which is the
-- remembered "none".
eq("the first agent line is the answer",
  M.agent_from_state("agent=pi\nagent=claude\n"), "pi")
eq("a remembered none is the empty string, not nothing remembered",
  M.agent_from_state("agent=\n"), "")
eq("a file with no agent line remembers nothing",
  M.agent_from_state("other=1\n"), nil)
eq("an empty file remembers nothing", M.agent_from_state(""), nil)
eq("no file at all remembers nothing", M.agent_from_state(nil), nil)
eq("a last line without a newline still counts",
  M.agent_from_state("agent=pi"), "pi")

-- new_tab_argv: the tab's four positional words
--
-- The tab runs a POSIX sh wrapper, and everything the flow knows reaches it as
-- a positional parameter --
--
--   sh -c SCRIPT sh <branch> <base> <remote> <worktree> <agent> [args] <prompt>
--
-- so argv[4] is $0 and the words start at argv[5]: the branch, the base, the
-- remote and the worktree. The base is three-valued -- a string is the ref to
-- create from, false is worktrunk's own default (no --base word at all), and
-- absent means the question was never asked, so the configured base is the
-- fallback -- and the remote rides beside it, sent only when the question
-- resolved the base to a remote-tracking ref. An empty remote is nothing to
-- fetch, and an empty worktree is worktrunk's own template naming the directory.
do
  local saved = M.options.base
  M.options.base = nil

  local answered = M.new_tab_argv("proj", { branch = "feat/x1",
    base = "origin/main", base_remote = "origin" })
  eq("the branch travels as the first positional word", answered[5], "feat/x1")
  eq("the base travels as the second positional word", answered[6], "origin/main")
  eq("the remote travels as the third positional word", answered[7], "origin")
  eq("no worktree name is no --path word", answered[8], "")
  -- The configured no-bead prompt is empty by default, and an empty prompt is
  -- nothing to say rather than an empty word: the argv ends after the agent.
  eq("an empty prompt is no prompt word", #answered, 9)
  eq("the agent is the last word when there is nothing to say", answered[9], "pi")

  -- A worktree name is a sibling of the main worktree, which is what worktrunk's
  -- own template builds: relative, so the tab's own directory settles where it
  -- goes.
  eq("a worktree name travels as a sibling directory",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "bug-58h" })[8],
    "../bug-58h")
  eq("a blank worktree name sends no path",
    M.new_tab_argv("proj", { branch = "feat/x1", worktree = "" })[8], "")

  -- The answer beats the configuration: base = false is the question saying
  -- "let worktrunk choose", and a configured fallback must not quietly undo it.
  M.options.base = "main"
  eq("a configured base does not replace the answer",
    M.new_tab_argv("proj", { branch = "feat/x1", base = "origin/main" })[6],
    "origin/main")
  eq("base = false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1", base = false })[6], "")
  eq("base = false carries no remote",
    M.new_tab_argv("proj", { branch = "feat/x1", base = false })[7], "")

  -- No base in the answers is a hand-run `rex do`: the configuration is the
  -- fallback, and only when it names a ref.
  eq("no base in the payload falls back to the configured one",
    M.new_tab_argv("proj", { branch = "feat/x1" })[6], "main")
  M.options.base = false
  eq("a configured base of false sends an empty base",
    M.new_tab_argv("proj", { branch = "feat/x1" })[6], "")
  M.options.base = nil
  eq("a base the picker never answered and no configuration sends nothing",
    M.new_tab_argv("proj", { branch = "feat/x1" })[6], "")
  eq("a base with no remote of its own carries an empty remote",
    M.new_tab_argv("proj", { branch = "feat/x1", base = "@" })[7], "")
  eq("a base_remote that is not a string is no remote to fetch",
    M.new_tab_argv("proj", { branch = "feat/x1",
      base = "@", base_remote = false })[7],
    "")

  M.options.base = saved
end

-- The prompt is the argv's last word -- unless there is nothing to say.
--
-- A blank answer is the flow saying "an agent, and nothing to say", which is
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
    return M.new_tab_argv("proj", { branch = "feat/x1", prompt = prompt })
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
  local blank = M.new_tab_argv("proj", { branch = "feat/x1",
    prompt = "hello", blank = true })
  eq("a blank answer appends no prompt word", #blank, 11)
  eq("a blank answer puts no word after the agent's arguments",
    { blank[10], blank[11] }, { "--mode", "plan" })
  eq("a blank answer is not an empty prompt word", blank[12], nil)

  M.options.agent_args, M.options.base = saved_args, saved_base
end

-- The answer is data, never program text: a prompt with spaces, quotes, a
-- $(...) and a newline, and a branch with a slash, each arrive as one argument,
-- and none of it appears in the script the shell parses. A bead title can carry
-- a newline, and a newline is the one character that would split a value into
-- two commands if it were pasted into a program.
do
  local saved_prompt, saved_args = M.options.bead_prompt, M.options.agent_args
  M.options.bead_prompt = 'work on {branch}: "don\'t" $(id)\nsecond line; {id}'
  M.options.agent_args = { "--thinking", "high" }
  local prompt = 'work on bug/58h: "don\'t" $(id)\nsecond line; pmm-iris-58h'
  local argv = M.new_tab_argv("proj", { branch = "bug/58h", bead = "pmm-iris-58h" })

  eq("sh is told what $0 is", argv[4], "sh")
  eq("the branch is one argument", argv[5], "bug/58h")
  eq("the agent's arguments and the prompt are arguments too",
    { argv[9], argv[10], argv[11], argv[12] }, { "pi", "--thinking", "high", prompt })
  eq("the prompt keeps its newline", argv[12]:match("\n(.*)$"), "second line; pmm-iris-58h")
  eq("the number of arguments is the number of values", #argv, 12)
  eq("the branch is not pasted into the program text", argv[3]:find("bug/58h", 1, true), nil)
  eq("the prompt is not pasted into the program text", argv[3]:find(prompt, 1, true), nil)
  eq("the prompt's second line is not in the program text",
    argv[3]:find("second line", 1, true), nil)

  M.options.bead_prompt, M.options.agent_args = saved_prompt, saved_args
end

-- What the templates say, with no agent arguments in the way: an answer given
-- as the empty string is "nothing said", exactly as blank is, and the templates
-- are what the plugin says when nobody said anything at all.
do
  local saved_args = M.options.agent_args
  M.options.agent_args = {}

  eq("an empty answer is no prompt word",
    #M.new_tab_argv("proj", { branch = "feat/x1", prompt = "" }), 9)
  eq("the bead's template is sent when the question was never asked",
    M.new_tab_argv("proj", { branch = "feat/x1", bead = "p-1" })[10],
    "/brainstorming for bead p-1")
  -- no_bead_prompt's default is the empty string, so a flow with no bead and no
  -- answer sends the agent no prompt word rather than an empty one.
  eq("the no-bead template is empty by default, so nothing is sent",
    #M.new_tab_argv("proj", { branch = "feat/x1", bead = "" }), 9)
  eq("a configured no-bead prompt is still sent",
    (function()
      local no_bead = M.options.no_bead_prompt
      M.options.no_bead_prompt = "/brainstorming"
      local argv = M.new_tab_argv("proj", { branch = "feat/x1", bead = "" })
      M.options.no_bead_prompt = no_bead
      return argv[10]
    end)(),
    "/brainstorming")

  M.options.agent_args = saved_args
end

-- The `wt switch` words themselves are asserted where they are executed:
-- test/wrapper_test.sh runs the tab's wrapper with a stand-in `wt` and reads
-- the words it was given, with and without a worktree name.

if fails > 0 then os.exit(1) end
print("ok " .. count .. " assertions")
