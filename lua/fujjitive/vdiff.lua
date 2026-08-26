-- Fugitive's `dv`, for jj.
--
-- Fugitive diffs the working tree against the index. jj has no index, so the
-- equivalent is the parent of the working copy (`@-`): that is exactly the
-- comparison `jj status` reports on. Left window = the file as of that
-- revision, right window = the file as it is now, both in real Vim diff mode.
local M = {}

local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local config = require("fujjitive.config")

--- Read a file's contents at a revision. Missing (added/deleted) is not an
--- error here -- it just means one side of the diff is empty.
local function file_at(root, rev, path, cb)
  jj.run({
    root = root,
    color = false,
    ignore_working_copy = true,
    args = { "file", "show", "-r", rev, path },
    on_done = function(ok, out)
      cb(ok and out or "")
    end,
  })
end

local function to_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Open `path` diffed against `config.diff_against`.
--- opts.vertical  true for a side-by-side split (dv), false for stacked (ds)
function M.open(path, opts)
  opts = opts or {}
  local vertical = opts.vertical ~= false
  local root = panel.root() or jj.root()
  if not root or not path or path == "" then
    return
  end
  local rev = opts.rev or config.options.diff_against
  local abs = root .. "/" .. path

  file_at(root, rev, path, function(text)
    if not panel.is_open() then
      return
    end

    -- Right side: the working copy. Use the real file so you can edit it here.
    local right = panel.top_window()
    if not right then
      return
    end
    panel.close_extras()

    local on_disk = vim.uv.fs_stat(abs) ~= nil
    if on_disk then
      vim.api.nvim_win_call(right, function()
        vim.cmd("edit " .. vim.fn.fnameescape(abs))
      end)
    else
      -- Deleted in the working copy: diff against an empty buffer rather than
      -- opening a phantom file you might accidentally write.
      local buf = panel.scratch("fujjitive://deleted/" .. path, "fujjitive-deleted")
      vim.api.nvim_win_set_buf(right, buf)
    end

    -- Left side: the file as of `rev`, read-only.
    local lbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[lbuf].buftype = "nofile"
    vim.bo[lbuf].bufhidden = "wipe"
    vim.bo[lbuf].swapfile = false
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, to_lines(text))
    vim.bo[lbuf].modifiable = false
    vim.bo[lbuf].modified = false
    pcall(vim.api.nvim_buf_set_name, lbuf, ("fujjitive://%s/%s"):format(rev, path))
    -- Borrow the real file's filetype so the old side is syntax highlighted too.
    local ft = vim.filetype.match({ filename = path }) or ""
    if ft ~= "" then
      vim.bo[lbuf].filetype = ft
    end

    local lwin = vim.api.nvim_open_win(lbuf, false, {
      split = vertical and "left" or "above",
      win = right,
    })
    panel.add_extra(lwin)

    for _, w in ipairs({ lwin, right }) do
      vim.api.nvim_win_call(w, function()
        vim.cmd("diffthis")
      end)
    end
    vim.api.nvim_set_current_win(right)

    local function map(buf)
      vim.keymap.set("n", "q", function()
        M.close()
      end, { buffer = buf, nowait = true, silent = true, desc = "Close the diff" })
    end
    map(lbuf)
    map(vim.api.nvim_win_get_buf(right))
  end)
end

function M.close()
  panel.release()
  panel.focus()
end

return M
