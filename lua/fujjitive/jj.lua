-- Thin async wrapper around the jj CLI.
--
-- Two flags matter on every call and are easy to forget:
--   --no-pager   `ui.paginate` defaults to "auto" and we are not a tty
--   -R <root>    so the user's cwd never affects which repo we talk to
local M = {}

local root_cache = {}

--- Find the jj repo root for a directory, or nil if it isn't in a repo.
--- Synchronous, but `jj root` is cheap and we cache the answer.
function M.root(dir)
  dir = dir or vim.uv.cwd()
  if root_cache[dir] then
    return root_cache[dir]
  end
  local ok, res = pcall(function()
    return vim.system({ "jj", "root", "--no-pager" }, { cwd = dir, text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  local root = vim.trim(res.stdout or "")
  if root == "" then
    return nil
  end
  root_cache[dir] = root
  return root
end

function M.clear_cache()
  root_cache = {}
end

--- Run a jj command asynchronously.
---
--- opts.args                list of arguments, e.g. { "log", "--graph" }
--- opts.root                repo root
--- opts.color               true to request ANSI output (log/show); default false
--- opts.ignore_working_copy true to skip snapshotting the working copy
--- opts.stdin               optional string piped to the command
--- opts.on_done             function(ok, stdout, stderr)
---
--- Returns the vim.system handle so the caller can :kill() an in-flight job.
function M.run(opts)
  local cmd = { "jj", "--no-pager" }

  table.insert(cmd, opts.color and "--color=always" or "--color=never")
  if opts.ignore_working_copy then
    table.insert(cmd, "--ignore-working-copy")
  end
  if opts.root then
    vim.list_extend(cmd, { "-R", opts.root })
  end
  vim.list_extend(cmd, opts.args)

  -- Safety net: several jj commands fall back to $EDITOR (squash combining two
  -- descriptions, `config edit`, an interactive split). Spawned from here that
  -- editor has no terminal and never returns, which freezes Neovim. Making the
  -- editor fail turns a hang into an error message we can show.
  return vim.system(cmd, {
    text = true,
    stdin = opts.stdin,
    env = { JJ_EDITOR = "false", GIT_EDITOR = "false" },
  }, function(res)
    vim.schedule(function()
      opts.on_done(res.code == 0, res.stdout or "", res.stderr or "")
    end)
  end)
end

--- Strip ANSI escapes. Used for error messages, which we render as plain text.
function M.strip_ansi(s)
  return (s:gsub("\27%[[%d;]*%a", ""))
end

return M
