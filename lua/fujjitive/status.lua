-- The status view: `jj status` in the bottom panel, with Fugitive's diff keys.
--
-- The buffer is jj's own output verbatim (colour and all), so what you read
-- here is exactly what `jj status` would tell you in a terminal. On top of that
-- we keep a line -> path map, which is what `dv`, `<CR>` and `X` act on.
local M = {}

local ansi = require("fujjitive.ansi")
local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local config = require("fujjitive.config")

M.state = nil -- { bufnr, root, files = { [lnum] = path } }

local refresh_timer

local function alive()
  return M.state ~= nil
    and vim.api.nvim_buf_is_valid(M.state.bufnr)
    and panel.is_open()
    and panel.kind() == "status"
end

M.alive = alive

--- Pull the changed-file list out of `jj status` output.
--- Status lines look like "M path", "A path", "D path"; a rename is
--- "R old => new", where the working-copy file is the right-hand side.
---
--- Conflicts live in their own section and do NOT get a status letter -- jj
--- will happily say "The working copy has no changes" while a file is
--- conflicted -- so they need separate handling or they'd be invisible here:
---
---     Warning: There are unresolved conflicts at these paths:
---     f.txt    2-sided conflict
---
--- Returns the line -> path map and the set of conflicted paths.
function M.parse_files(lines)
  local files, conflicted = {}, {}
  local in_conflicts = false

  for i, line in ipairs(lines) do
    if line:find("unresolved conflicts at these paths") then
      in_conflicts = true
    else
      local path = in_conflicts and line:match("^(%S.-)%s%s+%d+%-sided") or nil
      if path then
        files[i] = path
        conflicted[path] = true
      else
        in_conflicts = false
        local flag, rest = line:match("^([MADCR])%s(.+)$")
        if flag and rest ~= "" then
          local _, renamed = rest:match("^(.-)%s+=>%s+(.+)$")
          files[i] = renamed or rest
        end
      end
    end
  end
  return files, conflicted
end

function M.file_at_cursor()
  if not alive() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
  local path = M.state.files[lnum]
  if not path then
    vim.notify("fujjitive: no file on this line", vim.log.levels.WARN)
  end
  return path
end

--- Move to the next/previous line that actually has a file on it.
function M.move_file(delta)
  if not alive() then
    return
  end
  local win = panel.win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local total = vim.api.nvim_buf_line_count(M.state.bufnr)
  local i = lnum + delta
  while i >= 1 and i <= total do
    if M.state.files[i] then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      return
    end
    i = i + delta
  end
end

local function first_file_line()
  local best
  for lnum in pairs(M.state.files) do
    if not best or lnum < best then
      best = lnum
    end
  end
  return best
end

function M.refresh(opts)
  opts = opts or {}
  if not M.state then
    return
  end
  jj.run({
    root = M.state.root,
    color = true,
    -- No --ignore-working-copy: status is *about* the working copy, so we want
    -- jj to snapshot it and tell us the truth.
    args = { "status" },
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      if not alive() then
        return
      end
      local lines, highlights = ansi.parse(out)
      M.state.files, M.state.conflicted = M.parse_files(lines)
      ansi.render(M.state.bufnr, lines, highlights)
      if opts.keep_line then
        local last = vim.api.nvim_buf_line_count(M.state.bufnr)
        pcall(vim.api.nvim_win_set_cursor, panel.win(), { math.min(opts.keep_line, last), 0 })
      else
        local lnum = first_file_line()
        if lnum then
          pcall(vim.api.nvim_win_set_cursor, panel.win(), { lnum, 0 })
        end
      end
    end,
  })
end

local function stop_refresh_timer()
  if refresh_timer then
    refresh_timer:stop()
    if not refresh_timer:is_closing() then
      refresh_timer:close()
    end
    refresh_timer = nil
  end
end

--- Reload the file list without you having to ask. Debounced, because a
--- :wall or a formatter can fire BufWritePost several times in a row.
function M.schedule_refresh()
  if not alive() then
    return
  end
  stop_refresh_timer()
  refresh_timer = vim.uv.new_timer()
  refresh_timer:start(120, 0, vim.schedule_wrap(function()
    stop_refresh_timer()
    if not alive() then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
    M.refresh({ keep_line = lnum })
  end))
end

--- Keep the list honest on its own: after any write inside the repo, when you
--- come back to the window, and when Neovim regains focus (something may have
--- changed the tree from outside).
local function setup_autorefresh(buf)
  local group = vim.api.nvim_create_augroup("FujjitiveStatus" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local st = M.state
      if not st then
        return
      end
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= "" and vim.startswith(name, st.root) then
        M.schedule_refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
    group = group,
    buffer = buf,
    callback = function()
      M.schedule_refresh()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      stop_refresh_timer()
      M.state = nil
    end,
  })
end

--- Throw away the working-copy changes to one file.
function M.discard()
  local path = M.file_at_cursor()
  if not path then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(panel.win())[1]
  if vim.fn.confirm(("Discard changes to %s?"):format(path), "&Yes\n&No", 2) ~= 1 then
    return
  end
  jj.run({
    root = M.state.root,
    color = false,
    args = { "restore", "--from", config.options.diff_against, path },
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      local msg = vim.trim(jj.strip_ansi(err ~= "" and err or out))
      if msg ~= "" then
        vim.notify(msg, vim.log.levels.INFO)
      end
      require("fujjitive.show").invalidate()
      M.refresh({ keep_line = lnum })
    end,
  })
end

--- Open the file itself in the top half.
function M.edit_file()
  local path = M.file_at_cursor()
  if not path then
    return
  end
  local win = panel.top_window()
  if not win then
    return
  end
  panel.close_extras()
  vim.api.nvim_win_call(win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(M.state.root .. "/" .. path))
  end)
  vim.api.nvim_set_current_win(win)
end

local function diff_file(vertical)
  local path = M.file_at_cursor()
  if path then
    require("fujjitive.vdiff").open(path, { vertical = vertical })
  end
end

local function set_keymaps(buf)
  if not config.options.default_keymaps then
    return
  end
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map("dv", function() diff_file(true) end, "Diff this file side by side")
  map("ds", function() diff_file(false) end, "Diff this file, stacked")
  map("dd", function() diff_file(true) end, "Diff this file side by side")
  map("<CR>", function() M.edit_file() end, "Open this file")
  map("X", function() M.discard() end, "Discard changes to this file")
  map("gl", function() require("fujjitive.graph").open() end, "Switch to the graph")
  map("J", function() M.move_file(1) end, "Next file")
  map("K", function() M.move_file(-1) end, "Previous file")
  map("R", function() M.refresh() end, "Refresh")
  map("q", function() require("fujjitive.graph").close() end, "Close fujjitive")
  map("g?", function() M.help() end, "Show keymaps")
end

function M.help()
  vim.notify(table.concat({
    "fujjitive — status keymaps",
    "",
    "  dv        diff this file side by side (dd does the same)",
    "            on a conflicted file this paints the conflicts instead",
    "  ds        diff this file, stacked",
    "  <CR>      open this file",
    "  X         discard changes to this file",
    "  J / K     next / previous file",
    "  gl        switch to the graph",
    "  R         refresh (it also reloads itself after any write)",
    "  q         close",
    "",
    "  diffs compare against " .. config.options.diff_against,
  }, "\n"), vim.log.levels.INFO)
end

function M.open()
  local root = panel.root() or jj.root()
  if not root then
    vim.notify("fujjitive: not inside a jj repo", vim.log.levels.ERROR)
    return
  end

  if alive() then
    panel.focus()
    M.refresh()
    return
  end

  local buf = panel.scratch("fujjitive://status", "fujjitive-status")
  set_keymaps(buf)
  M.state = { bufnr = buf, root = root, files = {}, conflicted = {} }
  panel.open(buf, "status", root)
  setup_autorefresh(buf)
  M.refresh()
end

return M
