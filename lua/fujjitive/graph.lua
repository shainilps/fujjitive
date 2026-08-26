-- The graph view: renders `jj log` in the bottom panel, maps buffer lines back
-- to change IDs, and owns the j/k/h/l motions.
--
-- Nothing here opens a diff on its own. Moving the cursor is free; `v` is what
-- asks to see a change.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local config = require("fujjitive.config")

-- state = { root, bufnr, lines, highlights, nodes, line_to_node }
M.state = nil

--- The sentinel wraps the change ID so we can recover it from any line. jj adds
--- the graph prefix (edges + node glyph) before our template output, so the
--- sentinel always sits immediately after the prefix.
---
--- The payload also carries the parent IDs, separated by \1, because columns
--- cannot tell branches apart: jj draws sibling branches in the same lane.
--- Topology can.
local function template()
  return string.format(
    '"\\x00" ++ change_id.short(12) ++ "\\x01"'
      .. ' ++ parents.map(|p| p.change_id().short(12)).join(",") ++ "\\x00" ++ (%s)',
    config.options.log_template
  )
end

--- Shift highlight spans left to account for the excised sentinel.
local function adjust_spans(spans, cut_start, cut_len)
  if not spans then
    return nil
  end
  local out = {}
  for _, span in ipairs(spans) do
    local c0, c1 = span[1], span[2]
    if c0 > cut_start then
      c0 = math.max(cut_start, c0 - cut_len)
    end
    if c1 > cut_start then
      c1 = math.max(cut_start, c1 - cut_len)
    end
    if c1 > c0 then
      out[#out + 1] = { c0, c1, span[3] }
    end
  end
  return #out > 0 and out or nil
end

--- Byte column of the node glyph within the graph prefix.
--- Prefer a known node character; fall back to the last non-space, which covers
--- merge rows where an edge is drawn to the right of the node.
local function node_col(prefix)
  local glyphs = {}
  for _, g in ipairs(config.options.node_glyphs) do
    glyphs[g] = true
  end

  local found, last_nonspace = nil, nil
  for pos, char in prefix:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
    if char ~= " " then
      last_nonspace = pos - 1
    end
    if glyphs[char] then
      found = pos - 1
    end
  end
  return found or last_nonspace or 0
end

--- Turn raw `jj log` bytes into renderable lines plus a line -> change map.
function M.parse_output(data)
  local plain, hls = ansi.parse(data)
  local st = { lines = {}, highlights = {}, nodes = {}, line_to_node = {} }
  local current

  for i, line in ipairs(plain) do
    local spans = hls[i]
    local s, e, payload = line:find("%z(.-)%z")

    if s then
      local prefix = line:sub(1, s - 1)
      line = prefix .. line:sub(e + 1)
      spans = adjust_spans(spans, s - 1, e - s + 1)
      local id, parents = payload:match("^([^\1]*)\1?(.*)$")
      current = #st.nodes + 1
      st.nodes[current] = {
        lnum = i,
        col = node_col(prefix),
        change_id = id,
        parents = parents ~= "" and vim.split(parents, ",", { plain = true }) or {},
      }
    end

    st.lines[i] = line
    if spans then
      st.highlights[i] = spans
    end
    -- Continuation lines belong to the change above them.
    if current then
      st.line_to_node[i] = current
    end
  end

  -- A head is a change nothing else in view descends from -- one per branch
  -- tip, which is what <Tab> cycles through.
  local is_parent = {}
  for _, n in ipairs(st.nodes) do
    for _, parent in ipairs(n.parents) do
      is_parent[parent] = true
    end
  end
  st.heads = {}
  for i, n in ipairs(st.nodes) do
    if not is_parent[n.change_id] then
      st.heads[#st.heads + 1] = i
    end
  end

  return st
end

local function valid()
  local st = M.state
  return st ~= nil
    and st.bufnr ~= nil
    and vim.api.nvim_buf_is_valid(st.bufnr)
    and panel.is_open()
    and panel.kind() == "graph"
end

M.valid = valid

function M.root()
  return M.state and M.state.root or panel.root()
end

function M.node_at_cursor()
  if not valid() then
    return nil
  end
  local st = M.state
  local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
  local idx = st.line_to_node[lnum]
  return idx and st.nodes[idx] or nil
end

--- The change ID under the cursor, which every :JJ command defaults to.
function M.current_change()
  local node = M.node_at_cursor()
  return node and node.change_id or nil
end

local function goto_node(node)
  if not node then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, panel.win(), { node.lnum, node.col })
end

--- Move by change, not by line, so multi-line entries never need two presses.
function M.move_change(delta)
  local st = M.state
  if not valid() or #st.nodes == 0 then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
  local idx = st.line_to_node[lnum] or 1
  goto_node(st.nodes[math.max(1, math.min(#st.nodes, idx + delta))])
end

--- Hop to the adjacent graph lane: nearest occupied column in that direction,
--- then the nearest change within that column.
---
--- `opts.wrap` comes back around when you run out of lanes, which is what makes
--- <Tab> cycle through the branches rather than dead-ending at the edge.
function M.hop_lane(dir, opts)
  opts = opts or {}
  local st = M.state
  local cur = M.node_at_cursor()
  if not cur then
    return
  end

  local target_col
  for _, n in ipairs(st.nodes) do
    if dir > 0 and n.col > cur.col then
      if not target_col or n.col < target_col then
        target_col = n.col
      end
    elseif dir < 0 and n.col < cur.col then
      if not target_col or n.col > target_col then
        target_col = n.col
      end
    end
  end

  if not target_col and opts.wrap then
    -- No lane that way: wrap to the far side (leftmost going right, and back).
    for _, n in ipairs(st.nodes) do
      if not target_col
        or (dir > 0 and n.col < target_col)
        or (dir < 0 and n.col > target_col)
      then
        target_col = n.col
      end
    end
    if target_col == cur.col then
      return -- only one lane; nothing to cycle to
    end
  end
  if not target_col then
    return
  end

  local best, best_dist
  for _, n in ipairs(st.nodes) do
    if n.col == target_col then
      local d = math.abs(n.lnum - cur.lnum)
      if not best_dist or d < best_dist then
        best, best_dist = n, d
      end
    end
  end
  goto_node(best)
end

--- Cycle through branch tips. This is what <Tab> does, and it deliberately
--- ignores columns: jj draws sibling branches in the same lane, so a
--- column-based hop can never reach all of them. Falls back to a lane hop if
--- the graph has no branching to speak of.
function M.next_branch(dir)
  local st = M.state
  if not valid() then
    return
  end
  if not st.heads or #st.heads < 2 then
    return M.hop_lane(dir, { wrap = true })
  end

  local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
  local cur = st.line_to_node[lnum]
  local pick

  if dir > 0 then
    for _, idx in ipairs(st.heads) do
      if not cur or idx > cur then
        pick = idx
        break
      end
    end
    pick = pick or st.heads[1]
  else
    for i = #st.heads, 1, -1 do
      local idx = st.heads[i]
      if not cur or idx < cur then
        pick = idx
        break
      end
    end
    pick = pick or st.heads[#st.heads]
  end

  goto_node(st.nodes[pick])
end

--- Re-run `jj log` and repaint. `opts.keep_change` restores the cursor to that
--- change ID if it still exists, so operations don't lose your place.
function M.refresh(opts)
  opts = opts or {}
  local st = M.state
  if not st then
    return
  end

  local args = { "log", "-T", template() }
  if config.options.revset then
    vim.list_extend(args, { "-r", config.options.revset })
  end

  jj.run({
    root = st.root,
    args = args,
    color = true,
    -- No --ignore-working-copy here: we want a fresh snapshot so @ is honest.
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      if not valid() then
        return
      end

      local parsed = M.parse_output(out)
      st.lines = parsed.lines
      st.highlights = parsed.highlights
      st.nodes = parsed.nodes
      st.heads = parsed.heads
      st.line_to_node = parsed.line_to_node

      ansi.render(st.bufnr, st.lines, st.highlights)

      local target
      if opts.keep_change then
        for _, n in ipairs(st.nodes) do
          if n.change_id == opts.keep_change then
            target = n
            break
          end
        end
      end
      goto_node(target or st.nodes[1])
    end,
  })
end

local function set_keymaps(buf)
  if not config.options.default_keymaps then
    return
  end
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  local function op(name)
    return function()
      require("fujjitive.ops").commands[name]({})
    end
  end

  map("j", function() M.move_change(1) end, "Next change")
  map("k", function() M.move_change(-1) end, "Previous change")
  map("<Tab>", function() M.next_branch(1) end, "Jump to the next branch")
  map("<S-Tab>", function() M.next_branch(-1) end, "Jump to the previous branch")
  map("K", function() M.view() end, "View this change in the top half")
  map("<CR>", function() M.view({ focus = true }) end, "View this change and jump to it")
  map("e", op("edit"), "jj edit this change")
  map("n", op("new"), "jj new on top of this change")
  map("s", op("squash"), "jj squash this change into its parent")
  map("a", op("abandon"), "jj abandon this change")
  map("d", op("describe"), "Describe this change")
  map("gs", function() require("fujjitive.status").open() end, "Switch to jj status")
  map("R", function() M.refresh({ keep_change = M.current_change() }) end, "Refresh")
  map("q", function() M.close() end, "Close fujjitive")
  map("g?", function() M.help() end, "Show keymaps")
end

--- Open the change under the cursor in the top half. On demand, always -- this
--- is the only thing that puts a diff on screen.
function M.view(opts)
  require("fujjitive.show").open(M.current_change(), opts)
end

function M.help()
  vim.notify(table.concat({
    "fujjitive — graph keymaps",
    "",
    "  j / k     next / previous change",
    "  <Tab>     jump to the next branch (<S-Tab> for the previous)",
    "  K         view this change in the top half",
    "  <CR>      view it and jump into that window",
    "",
    "  e         jj edit          n    jj new",
    "  s         jj squash        a    jj abandon",
    "  d         describe this change (:w applies it)",
    "",
    "  gs        switch to jj status",
    "  R         refresh          q    close",
    "",
    "  :JJ log | status | new | edit | describe | squash | abandon | undo",
  }, "\n"), vim.log.levels.INFO)
end

function M.close()
  M.state = nil
  require("fujjitive.show").invalidate()
  require("fujjitive.status").state = nil
  panel.close()
end

function M.open()
  if valid() then
    panel.focus()
    return
  end

  local root = panel.root() or jj.root()
  if not root then
    vim.notify("fujjitive: not inside a jj repo", vim.log.levels.ERROR)
    return
  end

  local buf = panel.scratch("fujjitive://graph", "fujjitive")
  set_keymaps(buf)

  M.state = {
    root = root,
    bufnr = buf,
    lines = {},
    highlights = {},
    nodes = {},
    heads = {},
    line_to_node = {},
  }

  panel.open(buf, "graph", root)

  local group = vim.api.nvim_create_augroup("FujjitiveGraph" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      M.state = nil
    end,
  })

  M.refresh()
end

return M
