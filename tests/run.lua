-- Tests for the two pure parsers. Run with:
--   nvim --headless --clean -c "set rtp+=." -c "luafile tests/run.lua" -c "qa!"
--
-- These are worth having because a bug in either one *looks* like a rendering
-- problem in the UI when it is really a parse problem.

local ansi = require("fujjitive.ansi")
local graph = require("fujjitive.graph")
local status = require("fujjitive.status")

local passed, failed = 0, 0

local function check(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

-- ---------------------------------------------------------------- ansi.parse

do
  local lines = ansi.parse("hello\nworld\n")
  check("plain text splits into lines", lines, { "hello", "world" })
end

do
  local lines, hls = ansi.parse("plain text only\n")
  check("plain text has no highlights", hls, {})
  check("plain text preserved", lines, { "plain text only" })
end

do
  -- Escapes must be removed from the text and become byte ranges instead.
  local lines, hls = ansi.parse("\27[31mred\27[0m tail\n")
  check("SGR stripped from text", lines, { "red tail" })
  check("span covers only the coloured run", { hls[1][1][1], hls[1][1][2] }, { 0, 3 })
end

do
  -- SGR state carries across a newline until it is reset.
  local lines, hls = ansi.parse("\27[32mone\ntwo\27[0m\n")
  check("state carries across lines (text)", lines, { "one", "two" })
  check("line 1 highlighted", { hls[1][1][1], hls[1][1][2] }, { 0, 3 })
  check("line 2 still highlighted", { hls[2][1][1], hls[2][1][2] }, { 0, 3 })
end

do
  -- 256-colour and truecolour must not leak digits into the text.
  local lines = ansi.parse("\27[38;5;208mA\27[38;2;10;20;30mB\27[0m\n")
  check("extended colour params consumed", lines, { "AB" })
end

do
  -- Non-SGR CSI sequences are dropped without eating text.
  local lines = ansi.parse("\27[Kcleared\n")
  check("non-SGR CSI dropped", lines, { "cleared" })
end

do
  -- A line with no trailing newline still flushes.
  local lines = ansi.parse("no newline")
  check("unterminated final line flushes", lines, { "no newline" })
end

-- --------------------------------------------------------- graph.parse_output

do
  local fixture = table.concat({
    "@  \0aaaaaaaaaaaa\0first change",
    "\226\148\130  description line",
    "\226\148\130 \226\151\139  \0bbbbbbbbbbbb\0second change",
    "\226\151\134  \0cccccccccccc\0root",
  }, "\n") .. "\n"

  local st = graph.parse_output(fixture)

  check("sentinel removed from rendered lines", st.lines[1], "@  first change")
  check("three changes found", #st.nodes, 3)
  check("change ids recovered", {
    st.nodes[1].change_id, st.nodes[2].change_id, st.nodes[3].change_id,
  }, { "aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc" })

  -- The node glyph column is what h/l navigate by.
  check("working copy is in lane 0", st.nodes[1].col, 0)
  check("indented node reports its byte column", st.nodes[2].col, 4)

  -- A line with no sentinel belongs to the change above it.
  check("continuation line maps to its change", st.line_to_node[2], 1)
  check("node line maps to itself", st.line_to_node[3], 2)

  for i, line in ipairs(st.lines) do
    if line:find("%z") then
      failed = failed + 1
      print("FAIL sentinel leaked into line " .. i)
    end
  end
end

do
  -- Highlight spans must shift left by exactly the excised sentinel width.
  local fixture = "\27[32m@  \0abc123\0hello\27[0m\n"
  local st = graph.parse_output(fixture)
  check("line after excision", st.lines[1], "@  hello")
  check("span clipped to the shortened line",
    { st.highlights[1][1][1], st.highlights[1][1][2] }, { 0, 8 })
end

do
  -- Branch tips come from parent topology, not columns. Here A and B are
  -- siblings drawn in the SAME column (4) at different rows -- the case a
  -- column-based hop can never cycle through correctly.
  local fixture = table.concat({
    "@  \0tipC\1base\0branch C",
    "\1 o  \0tipB\1base\0branch B",
    "|-/",
    "\1 o  \0tipA\1base\0branch A",
    "|-/",
    "o  \0base\1root\0base",
    "o  \0root\1\0root",
  }, "\n"):gsub("\1 ", "| ")
  local st = graph.parse_output(fixture)
  check("all five changes parsed", #st.nodes, 5)
  check("parents recovered", st.nodes[1].parents, { "base" })
  check("root has no parents", st.nodes[5].parents, {})
  check("three branch tips found", #st.heads, 3)
  check("tips are the three branches",
    { st.nodes[st.heads[1]].change_id, st.nodes[st.heads[2]].change_id, st.nodes[st.heads[3]].change_id },
    { "tipC", "tipB", "tipA" })
  check("siblings really do share a column", st.nodes[2].col, st.nodes[3].col)
end

do
  -- `jj status` file lines vs its header lines. Headers start with W/P, which
  -- is why a bare "<flag> <path>" match is safe here.
  local files = status.parse_files({
    "Working copy changes:",
    "M src/a.rs",
    "D b.txt",
    "A c.txt",
    "Working copy  (@) : tvlmlwnv 8249553c feat: colors",
    "Parent commit (@-): rpkkzytq cc285c3e init files",
  })
  check("modified file", files[2], "src/a.rs")
  check("deleted file", files[3], "b.txt")
  check("added file", files[4], "c.txt")
  check("section header is not a file", files[1], nil)
  check("working-copy header is not a file", files[5], nil)
  check("parent header is not a file", files[6], nil)
end

do
  -- A rename reports both sides; the working-copy file is the right-hand one.
  local files = status.parse_files({ "R old/name.rs => new/name.rs" })
  check("rename maps to its new path", files[1], "new/name.rs")
end

do
  local files = status.parse_files({ "The working copy has no changes." })
  check("clean working copy yields no files", next(files), nil)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
end
vim.cmd("qa!")
