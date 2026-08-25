-- The graph pane: renders `jj log`, maps buffer lines back to change IDs, and
-- owns the j/k/h/l motions.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local config = require("fujjitive.config")

-- state = { root, bufnr, winid, tabpage, lines, highlights, nodes, line_to_node }
M.state = nil

--- The sentinel wraps the change ID so we can recover it from any line. jj adds
--- the graph prefix (edges + node glyph) before our template output, so the
--- sentinel always sits immediately after the prefix.
local function template()
  return string.format(
    '"\\x00" ++ change_id.short(12) ++ "\\x00" ++ (%s)',
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
    local s, e, id = line:find("%z(.-)%z")

    if s then
      local prefix = line:sub(1, s - 1)
      line = prefix .. line:sub(e + 1)
      spans = adjust_spans(spans, s - 1, e - s + 1)
      current = #st.nodes + 1
      st.nodes[current] = { lnum = i, col = node_col(prefix), change_id = id }
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

  return st
end

local function valid()
  local st = M.state
  return st
    and st.bufnr
    and vim.api.nvim_buf_is_valid(st.bufnr)
    and st.winid
    and vim.api.nvim_win_is_valid(st.winid)
end

M.valid = valid

function M.node_at_cursor()
  if not valid() then
    return nil
  end
  local st = M.state
  local lnum = vim.api.nvim_win_get_cursor(st.winid)[1]
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
  pcall(vim.api.nvim_win_set_cursor, M.state.winid, { node.lnum, node.col })
end

--- Move by change, not by line, so multi-line entries never need two presses.
function M.move_change(delta)
  local st = M.state
  if not valid() or #st.nodes == 0 then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(st.winid)[1]
  local idx = st.line_to_node[lnum] or 1
  goto_node(st.nodes[math.max(1, math.min(#st.nodes, idx + delta))])
end

--- Hop to the adjacent graph lane: nearest occupied column in that direction,
--- then the nearest change within that column.
function M.hop_lane(dir)
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

      require("fujjitive.diff").show(M.current_change(), { force = true })
    end,
  })
end

local function create_buf(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = ft
  pcall(vim.api.nvim_buf_set_name, buf, name .. "-" .. buf)
  return buf
end

local function set_keymaps(buf)
  if not config.options.default_keymaps then
    return
  end
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map("j", function() M.move_change(1) end, "Next change")
  map("k", function() M.move_change(-1) end, "Previous change")
  map("l", function() M.hop_lane(1) end, "Hop to the lane on the right")
  map("h", function() M.hop_lane(-1) end, "Hop to the lane on the left")
  map("<CR>", function() require("fujjitive.diff").focus() end, "Focus the diff pane")
  map("d", function() require("fujjitive.diff").toggle() end, "Toggle the diff pane")
  map("R", function() M.refresh({ keep_change = M.current_change() }) end, "Refresh")
  map("q", function() M.close() end, "Close fujjitive")
  map("g?", function() M.help() end, "Show keymaps")
end

function M.help()
  local lines = {
    "fujjitive — graph keymaps",
    "",
    "  j / k     next / previous change",
    "  h / l     hop between graph lanes",
    "  <CR>      focus the diff pane",
    "  d         toggle the diff pane",
    "  R         refresh the graph",
    "  q         close",
    "  g?        this help",
    "",
    "  :JJ new | edit | describe | squash | abandon | undo",
    "  (each acts on the change under the cursor)",
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.close()
  local st = M.state
  M.state = nil
  require("fujjitive.diff").reset()
  if st and st.tabpage and vim.api.nvim_tabpage_is_valid(st.tabpage) then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.api.nvim_set_current_tabpage(st.tabpage)
      vim.cmd("tabclose")
    end
  end
end

function M.open()
  if valid() then
    vim.api.nvim_set_current_tabpage(M.state.tabpage)
    vim.api.nvim_set_current_win(M.state.winid)
    return
  end

  local root = jj.root()
  if not root then
    vim.notify("fujjitive: not inside a jj repo", vim.log.levels.ERROR)
    return
  end

  local gbuf = create_buf("fujjitive://graph", "fujjitive")

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local gwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(gwin, gbuf)

  vim.wo[gwin].wrap = false
  vim.wo[gwin].number = false
  vim.wo[gwin].relativenumber = false
  vim.wo[gwin].signcolumn = "no"
  vim.wo[gwin].cursorline = true
  vim.wo[gwin].list = false

  M.state = {
    root = root,
    bufnr = gbuf,
    winid = gwin,
    tabpage = tabpage,
    lines = {},
    highlights = {},
    nodes = {},
    line_to_node = {},
  }

  set_keymaps(gbuf)
  require("fujjitive.diff").open()
  vim.api.nvim_set_current_win(gwin)

  local group = vim.api.nvim_create_augroup("FujjitiveGraph" .. gbuf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = gbuf,
    callback = function()
      require("fujjitive.diff").show(M.current_change())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = gbuf,
    callback = function()
      M.state = nil
      require("fujjitive.diff").reset()
    end,
  })

  M.refresh()
end

return M
