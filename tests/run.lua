-- Tests for the two pure parsers. Run with:
--   nvim --headless --clean -c "set rtp+=." -c "luafile tests/run.lua" -c "qa!"
--
-- These are worth having because a bug in either one *looks* like a rendering
-- problem in the UI when it is really a parse problem.

local ansi = require("fujjitive.ansi")
local graph = require("fujjitive.graph")
local status = require("fujjitive.status")
local conflict = require("fujjitive.conflict")

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

do
  -- Real jj output, captured from a MERGE conflict: side #1 is written as a
  -- diff from base, side #2 as literal content.
  local merge = vim.split(table.concat({
    "line one",
    "<<<<<<< Conflict 1 of 1",
    "%%%%%%% Changes from base to side #1",
    "-SHARED",
    "+AAA from side A",
    "+++++++ Contents of side #2",
    "BBB from side B",
    ">>>>>>> Conflict 1 of 1 ends",
    "line three",
  }, "\n"), "\n", { plain = true })
  local r = conflict.parse(merge)
  check("merge: conflicted", r.conflicted, true)
  check("merge: two sides", r.max_side, 2)
  check("merge: side 1 reconstructed", r.sides[1], { "line one", "AAA from side A", "line three" })
  check("merge: side 2 reconstructed", r.sides[2], { "line one", "BBB from side B", "line three" })
  check("merge: base reconstructed", r.base, { "line one", "SHARED", "line three" })
  check("merge: hunk range", { r.hunks[1].first, r.hunks[1].last }, { 2, 8 })
end

do
  -- Real jj output from a REBASE conflict. The sections SWAP: side #1 is now
  -- literal and side #2 is the diff. Anything that keys off position rather
  -- than the section headers silently reports these two sides backwards.
  local rebase = vim.split(table.concat({
    "a",
    "<<<<<<< Conflict 1 of 1",
    "+++++++ Contents of side #1",
    "SECOND",
    "%%%%%%% Changes from base to side #2",
    "-SHARED",
    "+FIRST",
    ">>>>>>> Conflict 1 of 1 ends",
    "c",
  }, "\n"), "\n", { plain = true })
  local r = conflict.parse(rebase)
  check("rebase: side 1 is the literal section", r.sides[1], { "a", "SECOND", "c" })
  check("rebase: side 2 is the diff section", r.sides[2], { "a", "FIRST", "c" })
  check("rebase: base reconstructed", r.base, { "a", "SHARED", "c" })
end

do
  -- Context lines inside a diff section are space-prefixed and belong to base
  -- AND to that side.
  local ctx = vim.split(table.concat({
    "p",
    "<<<<<<< Conflict 1 of 1",
    "%%%%%%% Changes from base to side #1",
    "-q",
    "+Q1",
    " r",
    "-s",
    "+S1",
    "+++++++ Contents of side #2",
    "WHOLE",
    ">>>>>>> Conflict 1 of 1 ends",
    "t",
  }, "\n"), "\n", { plain = true })
  local r = conflict.parse(ctx)
  check("context: kept in side 1", r.sides[1], { "p", "Q1", "r", "S1", "t" })
  check("context: kept in base", r.base, { "p", "q", "r", "s", "t" })
  check("context: side 2 literal", r.sides[2], { "p", "WHOLE", "t" })
end

do
  -- Two hunks; each carries its own per-side content, which is what d1o/d2o
  -- splice in.
  local multi = vim.split(table.concat({
    "top",
    "<<<<<<< Conflict 1 of 2",
    "%%%%%%% Changes from base to side #1",
    "-beta",
    "+BETA-A",
    "+++++++ Contents of side #2",
    "BETA-B",
    ">>>>>>> Conflict 1 of 2 ends",
    "gamma",
    "<<<<<<< Conflict 2 of 2",
    "%%%%%%% Changes from base to side #1",
    "-delta",
    "+DELTA-A",
    "+++++++ Contents of side #2",
    "DELTA-B",
    ">>>>>>> Conflict 2 of 2 ends",
    "bottom",
  }, "\n"), "\n", { plain = true })
  local r = conflict.parse(multi)
  check("multi: two hunks", #r.hunks, 2)
  check("multi: hunk 1 side 1", r.hunks[1].sides[1], { "BETA-A" })
  check("multi: hunk 2 side 2", r.hunks[2].sides[2], { "DELTA-B" })
  check("multi: hunk 2 range", { r.hunks[2].first, r.hunks[2].last }, { 10, 16 })
  check("multi: whole-file side 1", r.sides[1], { "top", "BETA-A", "gamma", "DELTA-A", "bottom" })
end

do
  local clean = conflict.parse({ "just", "normal", "lines" })
  check("clean file is not conflicted", clean.conflicted, false)
  check("clean file has no hunks", #clean.hunks, 0)
  check("is_conflicted says no", conflict.is_conflicted({ "a", "b" }), false)
  check("is_conflicted says yes", conflict.is_conflicted({ "<<<<<<< Conflict 1 of 1" }), true)
end

do
  -- Per-line roles drive the painting. The rebase shape is used here on
  -- purpose: side #1 literal, side #2 a diff.
  local r = conflict.regions({
    "a",
    "<<<<<<< Conflict 1 of 1",
    "+++++++ Contents of side #1",
    "SECOND",
    "%%%%%%% Changes from base to side #2",
    "-SHARED",
    "+FIRST",
    " ctx",
    ">>>>>>> Conflict 1 of 1 ends",
    "c",
  })
  check("plain line has no region", r[1], nil)
  check("start marker", r[2].role, "start")
  check("literal header knows its side", { r[3].role, r[3].side, r[3].diff }, { "header", 1, false })
  check("literal content is side 1", { r[4].role, r[4].side }, { "content", 1 })
  check("diff header knows its side", { r[5].role, r[5].side, r[5].diff }, { "header", 2, true })
  check("minus line is base", { r[6].role, r[6].side, r[6].mark }, { "content", 2, "-" })
  check("plus line is its side", { r[7].role, r[7].side, r[7].mark }, { "content", 2, "+" })
  check("context line is marked as such", r[8].mark, " ")
  check("finish marker", r[9].role, "finish")
  check("line after the block has no region", r[10], nil)
end

do
  -- Conflicts get no status letter, and jj may even say the working copy has
  -- no changes while a file is conflicted.
  local files, conflicted = status.parse_files({
    "The working copy has no changes.",
    "Working copy  (@) : abc 123 (conflict) merge",
    "Warning: There are unresolved conflicts at these paths:",
    "m.txt    2-sided conflict",
  })
  check("conflicted file is listed", files[4], "m.txt")
  check("conflicted file is flagged", conflicted["m.txt"], true)
  check("headers are not files", files[1], nil)
end

do
  local files, conflicted = status.parse_files({
    "Working copy changes:",
    "M plain.txt",
    "Warning: There are unresolved conflicts at these paths:",
    "m.txt    2-sided conflict",
  })
  check("modified file alongside a conflict", files[2], "plain.txt")
  check("conflicted file alongside a modification", files[4], "m.txt")
  check("modified file is not flagged conflicted", conflicted["plain.txt"], nil)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
end
vim.cmd("qa!")
