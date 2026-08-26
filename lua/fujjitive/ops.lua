-- :JJ subcommands.
--
-- In the graph these act on the change under the cursor; in the status view
-- they act on the working copy, since that is what status is about.
local M = {}

local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local graph = require("fujjitive.graph")

local function root()
  return panel.root() or jj.root()
end

local function current_change()
  if panel.kind() == "status" then
    return "@"
  end
  local id = graph.current_change()
  if not id then
    vim.notify("fujjitive: no change under the cursor", vim.log.levels.WARN)
  end
  return id
end

local function refresh_view(keep_change)
  if panel.kind() == "status" then
    require("fujjitive.status").refresh()
  else
    graph.refresh({ keep_change = keep_change })
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
      -- jj reports what it did on stderr.
      local msg = vim.trim(jj.strip_ansi(err ~= "" and err or out))
      if msg ~= "" then
        vim.notify(msg, vim.log.levels.INFO)
      end
      require("fujjitive.show").invalidate()
      refresh_view(opts.keep_change)
    end,
  })
end

M.commands = {}

M.commands["log"] = function()
  graph.open()
end

M.commands["status"] = function()
  require("fujjitive.status").open()
end

M.commands["new"] = function(args)
  local id = current_change()
  if not id then return end
  run_op(vim.list_extend({ "new", id }, args))
end

M.commands["edit"] = function(args)
  local id = current_change()
  if not id then return end
  run_op(vim.list_extend({ "edit", id }, args), { keep_change = id })
end

M.commands["squash"] = function(args)
  local id = current_change()
  if not id then return end
  run_op(vim.list_extend({ "squash", "-r", id }, args))
end

M.commands["abandon"] = function(args)
  local id = current_change()
  if not id then return end
  if vim.fn.confirm("Abandon change " .. id .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  run_op(vim.list_extend({ "abandon", id }, args))
end

M.commands["undo"] = function(args)
  run_op(vim.list_extend({ "undo" }, args), { keep_change = graph.current_change() })
end

--- Opens the description in the top half; `:w` applies it.
M.commands["describe"] = function()
  local id = current_change()
  if not id then return end
  local repo = root()

  jj.run({
    root = repo,
    color = false,
    ignore_working_copy = true,
    args = { "log", "--no-graph", "-r", id, "-T", "description" },
    on_done = function(ok, out, err)
      if not ok then
        vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
        return
      end

      local lines = vim.split(out, "\n", { plain = true })
      if lines[#lines] == "" then
        table.remove(lines)
      end
      if #lines == 0 then
        lines = { "" }
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "acwrite"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false
      vim.bo[buf].filetype = "gitcommit"
      pcall(vim.api.nvim_buf_set_name, buf, "fujjitive://describe/" .. id)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modified = false

      if not panel.top(buf, { focus = true }) then
        vim.cmd("botright split")
        vim.api.nvim_win_set_buf(0, buf)
      end

      vim.keymap.set("n", "q", function()
        panel.release()
        panel.focus()
      end, { buffer = buf, nowait = true, silent = true, desc = "Abandon this edit" })

      vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
          local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          jj.run({
            root = repo,
            color = false,
            args = { "describe", id, "--stdin" },
            stdin = text,
            on_done = function(ok2, _, err2)
              if not ok2 then
                vim.notify("fujjitive: " .. jj.strip_ansi(err2), vim.log.levels.ERROR)
                return
              end
              vim.bo[buf].modified = false
              panel.release()
              panel.focus()
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
              require("fujjitive.show").invalidate()
              refresh_view(id)
            end,
          })
        end,
      })
    end,
  })
end

-- Commands that stand on their own; everything else needs a view open first.
local STANDALONE = { log = true, status = true, undo = true }

-- Short forms. `names()` stays canonical so the error hint isn't cluttered,
-- but these complete and dispatch just like the full spelling.
local ALIASES = { st = "status", stat = "status", l = "log" }

function M.dispatch(fargs)
  if #fargs == 0 then
    graph.open()
    return
  end

  local name = ALIASES[fargs[1]] or fargs[1]
  local rest = vim.list_slice(fargs, 2)
  local fn = M.commands[name]
  if not fn then
    vim.notify(
      ("fujjitive: unknown command %q (try: %s)"):format(name, table.concat(M.names(), ", ")),
      vim.log.levels.ERROR
    )
    return
  end

  if not panel.is_open() and not STANDALONE[name] then
    vim.notify("fujjitive: open the graph with :JJ first", vim.log.levels.WARN)
    return
  end
  fn(rest)
end

function M.names()
  local names = vim.tbl_keys(M.commands)
  table.sort(names)
  return names
end

function M.complete(arg_lead, cmd_line)
  -- Only complete the subcommand itself; flags are passed through to jj.
  if cmd_line:match("^%s*JJ%s+%S+%s") then
    return {}
  end
  local candidates = M.names()
  for alias in pairs(ALIASES) do
    candidates[#candidates + 1] = alias
  end
  table.sort(candidates)
  return vim.tbl_filter(function(name)
    return name:find(arg_lead, 1, true) == 1
  end, candidates)
end

return M
