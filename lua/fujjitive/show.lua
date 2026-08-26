-- The read pane: what `K` opens, and where passthrough commands print.
--
-- With the panel up this borrows the top half. Without it -- someone ran
-- `:JJ op log` straight from their code -- it opens its own split and closes
-- that split again on `q`, so nothing is left behind either way.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local config = require("fujjitive.config")

M.state = nil -- { bufnr, change_id }

local job
local standalone -- a window we opened ourselves, when there is no panel
local cache, cache_order = {}, {}
local CACHE_MAX = 50

local function cache_put(key, value)
  if not cache[key] then
    cache_order[#cache_order + 1] = key
    if #cache_order > CACHE_MAX then
      cache[table.remove(cache_order, 1)] = nil
    end
  end
  cache[key] = value
end

local function show_args(change_id)
  local args = { "show", "-r", change_id, config.options.show_format }
  if config.options.show_template then
    vim.list_extend(args, { "-T", config.options.show_template })
  end
  return args
end

local function stop_job()
  if job then
    pcall(function()
      job:kill("sigterm")
    end)
    job = nil
  end
end

local function standalone_ok()
  return standalone ~= nil and vim.api.nvim_win_is_valid(standalone)
end

local function alive()
  return M.state ~= nil
    and vim.api.nvim_buf_is_valid(M.state.bufnr)
    and (panel.top_is_open() or standalone_ok())
end

function M.is_open()
  return alive()
end

function M.close()
  stop_job()
  M.state = nil
  if standalone_ok() and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, standalone, true)
  end
  standalone = nil
  panel.release()
  panel.focus()
end

local function buffer()
  if M.state and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    return M.state.bufnr
  end
  local buf = panel.scratch("fujjitive://show", "fujjitive-show")
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, nowait = true, silent = true, desc = "Close this pane" })
  vim.keymap.set("n", "<Tab>", function()
    panel.focus()
  end, { buffer = buf, nowait = true, silent = true, desc = "Back to the panel" })
  M.state = { bufnr = buf }
  return buf
end

--- Put the pane on screen: the panel's top half if there is one, else a split
--- of our own.
local function place(buf, focus)
  local win = panel.top(buf, { focus = focus })
  if win then
    standalone = nil
    return win
  end
  if standalone_ok() then
    vim.api.nvim_win_set_buf(standalone, buf)
  else
    vim.cmd("botright split")
    standalone = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(standalone, buf)
    vim.api.nvim_win_set_height(standalone, math.max(10, math.floor(vim.o.lines * 0.5)))
  end
  if focus then
    vim.api.nvim_set_current_win(standalone)
  end
  return standalone
end

local function dress(win)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
end

--- Render arbitrary jj output (op log, bookmark list, config list, ...).
function M.text(name, data, opts)
  opts = opts or {}
  local buf = buffer()
  local win = place(buf, opts.focus)
  if not win then
    return
  end
  dress(win)
  M.state.change_id = nil
  pcall(vim.api.nvim_buf_set_name, M.state.bufnr, "fujjitive://" .. name .. "-" .. buf)
  local lines, highlights = ansi.parse(data)
  ansi.render(buf, lines, highlights)
end

--- Open (or update) the change view for `change_id`.
function M.open(change_id, opts)
  opts = opts or {}
  if not change_id then
    vim.notify("fujjitive: no change under the cursor", vim.log.levels.WARN)
    return
  end

  local root = panel.root() or jj.root()
  if not root then
    return
  end

  local buf = buffer()
  local win = place(buf, opts.focus)
  if not win then
    return
  end
  dress(win)
  M.state.change_id = change_id

  local hit = cache[change_id]
  if hit then
    ansi.render(buf, hit.lines, hit.highlights)
    return
  end

  ansi.render(buf, { "fujjitive: loading " .. change_id .. "…" }, {})
  stop_job()
  job = jj.run({
    root = root,
    color = true,
    -- On demand or not, reading a change must never snapshot the working copy.
    ignore_working_copy = true,
    args = show_args(change_id),
    on_done = function(ok, out, err)
      job = nil
      local data = ok and out or ("fujjitive: " .. jj.strip_ansi(err))
      local lines, highlights = ansi.parse(data)
      if ok then
        cache_put(change_id, { lines = lines, highlights = highlights })
      end
      -- You may have pressed K on something else while this was running.
      if alive() and M.state.change_id == change_id then
        ansi.render(M.state.bufnr, lines, highlights)
      end
    end,
  })
end

--- Drop cached output for changes whose content may have moved.
function M.invalidate()
  cache, cache_order = {}, {}
end

return M
