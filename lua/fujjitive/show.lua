-- The change viewer: what `v` opens in the top half.
--
-- This is `jj show` for one change -- description plus jj's own colour-words
-- rendering of what that change did. It only appears when you ask for it, so
-- moving around the graph costs nothing.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local config = require("fujjitive.config")

M.state = nil -- { bufnr, change_id }

local job
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

local function alive()
  return M.state ~= nil
    and vim.api.nvim_buf_is_valid(M.state.bufnr)
    and panel.top_is_open()
end

function M.is_open()
  return alive()
end

local function buffer()
  if alive() then
    return M.state.bufnr
  end
  local buf = panel.scratch("fujjitive://show", "fujjitive-show")
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, nowait = true, silent = true, desc = "Close the change view" })
  vim.keymap.set("n", "<Tab>", function()
    panel.focus()
  end, { buffer = buf, nowait = true, silent = true, desc = "Back to the panel" })
  M.state = { bufnr = buf }
  return buf
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
  local win = panel.top(buf, { focus = opts.focus })
  if not win then
    return
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
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
      -- You may have pressed `v` on something else while this was running.
      if alive() and M.state.change_id == change_id then
        ansi.render(M.state.bufnr, lines, highlights)
      end
    end,
  })
end

function M.close()
  stop_job()
  M.state = nil
  panel.release()
  panel.focus()
end

--- Drop cached output for changes whose content may have moved.
function M.invalidate()
  cache, cache_order = {}, {}
end

return M
