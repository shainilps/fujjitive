-- :JJ subcommands.
--
-- Nothing here requires a view to be open. With the graph up, commands act on
-- the change under the cursor; otherwise they act on the working copy (@),
-- which is what plain `jj` would have done anyway.
--
-- Anything not handled explicitly is passed straight through to jj, so
-- `:JJ bookmark set main`, `:JJ config list` and `:JJ op log` all work without
-- this file knowing about them. jj writes data to stdout and progress to
-- stderr, so stdout goes in a buffer to read and stderr becomes a message.
local M = {}

local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local graph = require("fujjitive.graph")

local function root()
  return panel.root() or jj.root()
end

--- The change commands act on: the cursor's in the graph, else the working copy.
local function target_change()
  if panel.kind() == "graph" and graph.valid() then
    return graph.current_change() or "@"
  end
  return "@"
end

--- Split trailing args into "the revision to act on" and "flags for jj".
--- An explicit revision wins over the cursor: `:JJ edit xyz` edits xyz, while
--- `:JJ new --no-edit` still acts on the cursor's change. A leading `-` marks
--- a flag rather than a revset.
local function target_and_args(args)
  if args[1] and not args[1]:match("^%-") then
    return args[1], vim.list_slice(args, 2)
  end
  return target_change(), args
end

local function refresh_view(keep_change)
  if not panel.is_open() then
    return
  end
  if panel.kind() == "status" then
    require("fujjitive.status").refresh()
  else
    graph.refresh({ keep_change = keep_change })
  end
end

local function report(out, err)
  local msg = vim.trim(jj.strip_ansi(err ~= "" and err or out))
  if msg ~= "" then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

--- Run a mutating jj command, then repaint whichever view is showing.
local function run_op(args, opts)
  opts = opts or {}
  jj.run({
    root = root(),
    args = args,
    color = false,
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      report(out, err)
      require("fujjitive.show").invalidate()
      refresh_view(opts.keep_change)
    end,
  })
end

--- Put a buffer somewhere sensible and hand back a function that undoes it.
--- Without the panel there is no top half to borrow, so we open our own split
--- and must close it again -- otherwise writing the buffer leaves an empty
--- window behind.
local function place(buf)
  if panel.top(buf, { focus = true }) then
    return function()
      panel.release()
      panel.focus()
    end
  end

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, 12)
  return function()
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- A small split for typing a message into. Deliberately its own window rather
--- than the panel's top half: writing a one-line description shouldn't evict
--- whatever you were looking at.
local function message_split(buf, lines)
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(6, math.min(14, #lines + 3)))
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixheight = true
  return function()
    if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Open `lines` in a scratch buffer; `:w` hands the text to `apply`, which
--- calls its `done` argument once jj has accepted it.
local function message_buffer(name, lines, apply)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "jj"
  pcall(vim.api.nvim_buf_set_name, buf, "fujjitive://" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  local dismiss = message_split(buf, lines)

  vim.keymap.set("n", "q", function()
    dismiss()
  end, { buffer = buf, nowait = true, silent = true, desc = "Abandon this edit" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      apply(text, function()
        vim.bo[buf].modified = false
        dismiss()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end)
    end,
  })
end

--- One revision's description, or "" if it has none.
local function description_of(repo, rev, cb)
  jj.run({
    root = repo,
    color = false,
    ignore_working_copy = true,
    args = { "log", "--no-graph", "-r", rev, "-T", "description" },
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      cb(out)
    end,
  })
end

local function to_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

M.commands = {}

M.commands["log"] = function()
  graph.open()
end

M.commands["status"] = function()
  require("fujjitive.status").open()
end

M.commands["new"] = function(args)
  local id, rest = target_and_args(args)
  run_op(vim.list_extend({ "new", id }, rest))
end

M.commands["edit"] = function(args)
  local id, rest = target_and_args(args)
  run_op(vim.list_extend({ "edit", id }, rest), { keep_change = id })
end

--- `jj squash -r X` moves X's changes into its parent.
---
--- Note `--from X` alone would NOT do this: `--into` defaults to @, so
--- `--from @` squashes @ into itself and reports "Nothing changed".
---
--- When both revisions have a description jj wants to know what the combined
--- one should be, and reaches for $EDITOR to ask. We ask here instead, so it
--- never tries.
M.commands["squash"] = function(args)
  local id, rest = target_and_args(args)
  local repo = root()
  if #rest > 0 then
    return run_op(vim.list_extend({ "squash", "-r", id }, rest))
  end

  description_of(repo, id, function(source)
    description_of(repo, id .. "-", function(dest)
      if vim.trim(source) == "" or vim.trim(dest) == "" then
        -- Only one description in play; jj just keeps it, no prompt.
        return run_op({ "squash", "-r", id })
      end
      local lines = to_lines(dest)
      table.insert(lines, "")
      vim.list_extend(lines, to_lines(source))
      message_buffer("squash/" .. id, lines, function(text, done)
        jj.run({
          root = repo,
          color = false,
          args = { "squash", "-r", id, "-m", text },
          on_done = function(ok, out, err)
            if not ok then
              vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
              return
            end
            done()
            report(out, err)
            require("fujjitive.show").invalidate()
            refresh_view()
          end,
        })
      end)
      vim.notify("fujjitive: both changes have a description — edit the combined one, :w to squash",
        vim.log.levels.INFO)
    end)
  end)
end

M.commands["abandon"] = function(args)
  local id, rest = target_and_args(args)
  args = rest
  if vim.fn.confirm("Abandon change " .. id .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  run_op(vim.list_extend({ "abandon", id }, args))
end

M.commands["undo"] = function(args)
  run_op(vim.list_extend({ "undo" }, args), { keep_change = target_change() })
end

M.commands["redo"] = function(args)
  run_op(vim.list_extend({ "redo" }, args), { keep_change = target_change() })
end

--- `jj split` needs two things we have to supply, or it reaches for an editor:
--- the paths to peel off (otherwise it opens its own diff editor) and a
--- description for the new revision. We ask for the description here.
M.commands["split"] = function(args)
  if #args == 0 then
    vim.notify(
      "fujjitive: :JJ split needs paths, e.g. :JJ split src/a.lua\n"
        .. "(jj's interactive split opens its own diff editor, which can't run from here)",
      vim.log.levels.WARN
    )
    return
  end

  local id = target_change()
  for _, arg in ipairs(args) do
    if arg == "-m" or arg == "--message" then
      -- Message already supplied; nothing to ask.
      return run_op(vim.list_extend({ "split", "-r", id }, args))
    end
  end

  message_buffer("split/" .. id, { "" }, function(text, done)
    local cmd = { "split", "-r", id, "-m", text }
    vim.list_extend(cmd, args)
    jj.run({
      root = root(),
      color = false,
      args = cmd,
      on_done = function(ok, out, err)
        if not ok then
          vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
          return
        end
        done()
        report(out, err)
        require("fujjitive.show").invalidate()
        refresh_view()
      end,
    })
  end)
  vim.notify("fujjitive: describe the split-off change, :w to split", vim.log.levels.INFO)
end

--- Opens the description in a buffer; `:w` applies it.
M.commands["describe"] = function(args)
  local id = target_and_args(args or {})
  local repo = root()
  if not repo then
    vim.notify("fujjitive: not inside a jj repo", vim.log.levels.ERROR)
    return
  end

  description_of(repo, id, function(out)
    message_buffer("describe/" .. id, to_lines(out), function(text, done)
      jj.run({
        root = repo,
        color = false,
        args = { "describe", id, "--stdin" },
        stdin = text,
        on_done = function(ok, out2, err2)
          if not ok then
            vim.notify("fujjitive: " .. jj.strip_ansi(err2), vim.log.levels.ERROR)
            return
          end
          done()
          report(out2, err2)
          require("fujjitive.show").invalidate()
          refresh_view(id)
        end,
      })
    end)
  end)
end

--- `jj config edit` would spawn $EDITOR and hang; open the file ourselves.
local function config_edit(args)
  local scope = args[1] or "--user"
  jj.run({
    root = root(),
    color = false,
    args = { "config", "path", scope },
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      local path = vim.trim(out)
      if path == "" then
        return
      end
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      place(buf)
    end,
  })
end

--- Anything jj knows that we don't handle: run it and show what came back.
function M.passthrough(fargs)
  if fargs[1] == "config" and fargs[2] == "edit" then
    return config_edit(vim.list_slice(fargs, 3))
  end

  jj.run({
    root = root(),
    color = true,
    args = fargs,
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end
      -- jj puts data on stdout and progress on stderr.
      if vim.trim(out) ~= "" then
        require("fujjitive.show").text("jj " .. table.concat(fargs, " "), out)
      end
      report("", err)
      require("fujjitive.show").invalidate()
      refresh_view(target_change())
    end,
  })
end

-- Short forms. `names()` stays canonical so the error hint isn't cluttered,
-- but these complete and dispatch just like the full spelling.
local ALIASES = {
  st = "status",
  stat = "status",
  l = "log",
  desc = "describe",
  d = "describe",
}

function M.dispatch(fargs)
  if #fargs == 0 then
    graph.open()
    return
  end
  if not root() then
    vim.notify("fujjitive: not inside a jj repo", vim.log.levels.ERROR)
    return
  end

  local name = ALIASES[fargs[1]] or fargs[1]
  local fn = M.commands[name]
  if fn then
    fn(vim.list_slice(fargs, 2))
  else
    M.passthrough(fargs)
  end
end

function M.names()
  local names = vim.tbl_keys(M.commands)
  table.sort(names)
  return names
end

--- Complete our own subcommands plus the jj commands people reach for most.
local EXTRA = { "bookmark", "config", "op", "diff", "show", "restore", "rebase", "duplicate" }

function M.complete(arg_lead, cmd_line)
  if cmd_line:match("^%s*JJ%s+%S+%s") then
    return {}
  end
  local candidates = M.names()
  for alias in pairs(ALIASES) do
    candidates[#candidates + 1] = alias
  end
  vim.list_extend(candidates, EXTRA)
  table.sort(candidates)
  return vim.tbl_filter(function(name)
    return name:find(arg_lead, 1, true) == 1
  end, candidates)
end

return M
