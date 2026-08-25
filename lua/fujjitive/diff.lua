-- The diff pane: follows the cursor in the graph, debounced.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local config = require("fujjitive.config")

M.state = nil -- { bufnr, winid }

local timer, job, last_change
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

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

local function stop_job()
  if job then
    pcall(function()
      job:kill("sigterm")
    end)
    job = nil
  end
end

local function alive()
  return M.state
    and vim.api.nvim_buf_is_valid(M.state.bufnr)
    and vim.api.nvim_win_is_valid(M.state.winid)
end

--- Split below the current (graph) window.
function M.open()
  if alive() then
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "fujjitive-diff"
  pcall(vim.api.nvim_buf_set_name, buf, "fujjitive://diff-" .. buf)

  local origin = vim.api.nvim_get_current_win()
  vim.cmd("belowright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false

  local total = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    total = total + vim.api.nvim_win_get_height(w)
  end
  vim.api.nvim_win_set_height(win, math.max(3, math.floor(total * config.options.diff_height)))

  vim.keymap.set("n", "q", function()
    require("fujjitive.graph").close()
  end, { buffer = buf, nowait = true, silent = true, desc = "Close fujjitive" })

  M.state = { bufnr = buf, winid = win }
  vim.api.nvim_set_current_win(origin)
end

function M.focus()
  if alive() then
    vim.api.nvim_set_current_win(M.state.winid)
  end
end

function M.toggle()
  if alive() then
    vim.api.nvim_win_close(M.state.winid, true)
    M.state = nil
    last_change = nil
  else
    local graph = require("fujjitive.graph")
    if graph.valid() then
      vim.api.nvim_set_current_win(graph.state.winid)
      M.open()
      M.show(graph.current_change(), { force = true })
    end
  end
end

function M.reset()
  stop_timer()
  stop_job()
  M.state = nil
  last_change = nil
end

local function render(lines, highlights)
  if alive() then
    ansi.render(M.state.bufnr, lines, highlights)
  end
end

function M.load(change_id)
  stop_job()

  local graph = require("fujjitive.graph")
  local root = graph.state and graph.state.root
  if not root then
    return
  end

  job = jj.run({
    root = root,
    color = true,
    -- Without this, every cursor move snapshots the working copy and writes an
    -- entry to the op log. This flag is the whole difference between a viewer
    -- and a repo-churning machine.
    ignore_working_copy = true,
    args = { "show", "-r", change_id, config.options.diff_format },
    on_done = function(ok, out, err)
      job = nil
      local data = ok and out or ("fujjitive: " .. jj.strip_ansi(err))
      local lines, highlights = ansi.parse(data)
      if ok then
        cache_put(change_id, { lines = lines, highlights = highlights })
      end
      -- The cursor may have moved on while we were running.
      if last_change == change_id then
        render(lines, highlights)
      end
    end,
  })
end

--- Show the diff for a change. Cheap to call on every CursorMoved.
function M.show(change_id, opts)
  opts = opts or {}
  if not alive() or not change_id then
    return
  end
  if change_id == last_change and not opts.force then
    return
  end
  last_change = change_id

  local hit = cache[change_id]
  if hit and not opts.force then
    stop_timer()
    render(hit.lines, hit.highlights)
    return
  end

  stop_timer()
  timer = vim.uv.new_timer()
  timer:start(config.options.diff_debounce, 0, vim.schedule_wrap(function()
    stop_timer()
    M.load(change_id)
  end))
end

--- Drop cached diffs for changes whose content may have moved.
function M.invalidate()
  cache, cache_order = {}, {}
  last_change = nil
end

return M
