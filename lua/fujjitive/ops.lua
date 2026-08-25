-- :JJ subcommands. Each acts on the change under the cursor by default.
local M = {}

local jj = require("fujjitive.jj")
local graph = require("fujjitive.graph")
local diff = require("fujjitive.diff")

local function root()
  return graph.state and graph.state.root or jj.root()
end

local function current_change()
  local id = graph.current_change()
  if not id then
    vim.notify("fujjitive: no change under the cursor", vim.log.levels.WARN)
  end
  return id
end

--- Run a mutating jj command, then repaint the graph.
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
      diff.invalidate()
      graph.refresh({ keep_change = opts.keep_change })
    end,
  })
end

M.commands = {}

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
  local choice = vim.fn.confirm("Abandon change " .. id .. "?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  run_op(vim.list_extend({ "abandon", id }, args))
end

M.commands["undo"] = function(args)
  run_op(vim.list_extend({ "undo" }, args), { keep_change = graph.current_change() })
end

--- Opens the description in a scratch buffer; `:w` applies it.
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

      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, buf)
      vim.api.nvim_win_set_height(0, math.max(8, math.min(15, #lines + 4)))

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
              pcall(vim.api.nvim_buf_delete, buf, { force = true })
              diff.invalidate()
              graph.refresh({ keep_change = id })
            end,
          })
        end,
      })
    end,
  })
end

function M.dispatch(fargs)
  if #fargs == 0 then
    graph.open()
    return
  end

  local name = fargs[1]
  local rest = vim.list_slice(fargs, 2)
  local fn = M.commands[name]
  if not fn then
    vim.notify(
      ("fujjitive: unknown command %q (try: %s)"):format(name, table.concat(M.names(), ", ")),
      vim.log.levels.ERROR
    )
    return
  end

  if not graph.valid() and name ~= "undo" then
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
  return vim.tbl_filter(function(name)
    return name:find(arg_lead, 1, true) == 1
  end, M.names())
end

return M
