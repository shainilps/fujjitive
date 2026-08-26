-- Window management.
--
-- fujjitive owns exactly one window up front: a bottom-half panel holding
-- either the graph or the status list. The top half stays yours.
--
-- `v` and `dv` need somewhere to put a change, so they *borrow* the top window
-- -- we remember which buffer was in it and put that buffer back when you're
-- done. Nothing fujjitive opens is ever left behind.
local M = {}

local config = require("fujjitive.config")

-- state = {
--   win, buf, kind,      -- the bottom panel and what's currently in it
--   origin,              -- the window :JJ was invoked from
--   top_win, top_buf,    -- the borrowed top window and what it held before
--   top_owned,           -- true if we created the top window rather than borrowed it
--   top_extra,           -- windows dv opened alongside it
-- }
M.state = nil

local function win_ok(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function buf_ok(b)
  return b ~= nil and vim.api.nvim_buf_is_valid(b)
end

function M.is_open()
  return M.state ~= nil and win_ok(M.state.win)
end

function M.win()
  return M.is_open() and M.state.win or nil
end

function M.kind()
  return M.state and M.state.kind or nil
end

--- The jj repo root this session is pinned to.
function M.root()
  return M.state and M.state.root or nil
end

--- Create a scratch buffer for one of fujjitive's views.
function M.scratch(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  pcall(vim.api.nvim_buf_set_name, buf, name .. "-" .. buf)
  return buf
end

--- Put `buf` in the bottom panel, opening the panel if it isn't there yet.
--- `kind` is "graph" or "status" and is what :JJ log / :JJ status toggle.
function M.open(buf, kind, root)
  if M.is_open() then
    vim.api.nvim_win_set_buf(M.state.win, buf)
    M.state.buf, M.state.kind = buf, kind
    M.state.root = root or M.state.root
    vim.api.nvim_set_current_win(M.state.win)
    return M.state.win
  end

  local origin = vim.api.nvim_get_current_win()
  local height = math.max(5, math.floor(vim.o.lines * config.options.panel_height))
  local win = vim.api.nvim_open_win(buf, true, { split = "below", win = -1, height = height })

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].list = false
  vim.wo[win].winfixheight = true

  M.state = { win = win, buf = buf, kind = kind, root = root, origin = origin, top_extra = {} }
  return win
end

function M.focus()
  if M.is_open() then
    vim.api.nvim_set_current_win(M.state.win)
  end
end

--- The window occupying the top half: the one :JJ was called from, if it's
--- still around. Borrowing it (rather than splitting) is what keeps the layout
--- an honest two halves instead of three slivers.
function M.top_window()
  if not M.is_open() then
    return nil
  end
  local st = M.state
  if win_ok(st.top_win) then
    return st.top_win
  end

  local target = win_ok(st.origin) and st.origin or nil
  if not target then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= st.win then
        target = w
        break
      end
    end
  end

  if target then
    st.top_win = target
    st.top_buf = vim.api.nvim_win_get_buf(target)
    st.top_owned = false
  else
    -- The panel is the only window; make a top half for ourselves.
    st.top_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      split = "above",
      win = st.win,
    })
    st.top_buf, st.top_owned = nil, true
  end
  return st.top_win
end

--- Show `buf` in the top half and return its window.
function M.top(buf, opts)
  opts = opts or {}
  local win = M.top_window()
  if not win then
    return nil
  end
  M.close_extras()
  vim.api.nvim_win_set_buf(win, buf)
  if opts.focus then
    vim.api.nvim_set_current_win(win)
  end
  return win
end

--- dv opens a second window next to the borrowed one; register it here so
--- release() can clean it up.
function M.add_extra(win)
  if M.state then
    table.insert(M.state.top_extra, win)
  end
end

function M.close_extras()
  local st = M.state
  if not st then
    return
  end
  for _, w in ipairs(st.top_extra) do
    if win_ok(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  st.top_extra = {}
end

--- Give the top half back: turn off diff mode, close anything we opened, and
--- restore the buffer that was there before.
function M.release()
  local st = M.state
  if not st then
    return
  end
  M.close_extras()

  if win_ok(st.top_win) then
    pcall(vim.api.nvim_win_call, st.top_win, function()
      if vim.wo.diff then
        vim.cmd("diffoff")
      end
    end)
    if st.top_owned then
      pcall(vim.api.nvim_win_close, st.top_win, true)
    elseif buf_ok(st.top_buf) then
      pcall(vim.api.nvim_win_set_buf, st.top_win, st.top_buf)
    end
  end

  st.top_win, st.top_buf, st.top_owned = nil, nil, nil
end

function M.top_is_open()
  return M.state ~= nil and win_ok(M.state.top_win)
end

function M.close()
  local st = M.state
  if not st then
    return
  end
  M.release()
  M.state = nil
  if win_ok(st.win) then
    -- Closing the last window would quit Neovim; leave it alone if so.
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, st.win, true)
    end
  end
end

return M
