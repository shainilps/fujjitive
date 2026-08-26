-- `dv` — Fugitive's diff keys, for jj.
--
-- Two shapes, picked automatically:
--
--   normal file      2-way Vim diff. The file as of `diff_against` on the
--                    left, your working copy on the right.
--   conflicted file  one pane, the real file, with each side of every
--                    conflict painted in place.
--
-- The conflicted case deliberately is NOT a side-by-side diff. The working
-- file carries markers that the clean sides don't, so Vim's diff algorithm
-- lines them up against text that isn't really there and the result reads
-- wrong. Painting the real bytes has nothing to misalign.
--
-- Fugitive diffs against the git index. jj has no index, so the equivalent is
-- the parent of the working copy (`@-`): exactly what `jj status` reports on.
local M = {}

local jj = require("fujjitive.jj")
local panel = require("fujjitive.panel")
local conflict = require("fujjitive.conflict")
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

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  return ft ~= "" and ft or nil
end

--- A read-only buffer holding one version of a file.
local function version_buf(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function map(buf, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end

function M.close()
  panel.release()
  panel.focus()
end

--- Replace the conflict block under the cursor with side `n` (or both sides,
--- in order, when `n` is "both").
---
--- This deliberately does NOT use Vim's |diffget|. Vim computes its hunks by
--- diffing the marker-laden middle buffer against a clean side, and those
--- boundaries do not line up with the marker blocks -- diffget leaves marker
--- fragments and half-applied sides behind. So we re-parse the buffer (cheap,
--- and correct after earlier edits shift the line numbers) and replace exactly
--- the block the cursor is in.
---
--- After accepting, the cursor moves to the next conflict, so resolving a file
--- is the same key tapped repeatedly rather than alternating with ]x.
local function take_side(mid, midbuf, n)
  if not vim.api.nvim_win_is_valid(mid) then
    return
  end
  vim.api.nvim_set_current_win(mid)

  local parsed = conflict.parse(vim.api.nvim_buf_get_lines(midbuf, 0, -1, false))
  if #parsed.hunks == 0 then
    vim.notify("fujjitive: no conflicts left — :w to finish", vim.log.levels.INFO)
    return
  end

  -- The conflict the cursor is in, else the next one below it, else the first.
  local lnum = vim.api.nvim_win_get_cursor(mid)[1]
  local target
  for _, hunk in ipairs(parsed.hunks) do
    if lnum >= hunk.first and lnum <= hunk.last then
      target = hunk
      break
    end
  end
  if not target then
    for _, hunk in ipairs(parsed.hunks) do
      if hunk.first >= lnum then
        target = hunk
        break
      end
    end
  end
  target = target or parsed.hunks[1]

  local replacement
  if n == "both" then
    replacement = {}
    for side = 1, parsed.max_side do
      for _, line in ipairs(target.sides[side] or {}) do
        replacement[#replacement + 1] = line
      end
    end
  else
    replacement = target.sides[n] or target.base
  end
  vim.api.nvim_buf_set_lines(midbuf, target.first - 1, target.last, false, replacement)

  -- Land on the next conflict so the same key can just be tapped again.
  local after = conflict.parse(vim.api.nvim_buf_get_lines(midbuf, 0, -1, false))
  if #after.hunks == 0 then
    vim.notify("fujjitive: all conflicts resolved — :w to finish", vim.log.levels.INFO)
    return
  end
  local next_hunk = after.hunks[1]
  for _, hunk in ipairs(after.hunks) do
    if hunk.first >= target.first then
      next_hunk = hunk
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, mid, { next_hunk.first, 0 })
end

local NS = vim.api.nvim_create_namespace("fujjitive-conflict")
local HL_READY = false

--- Link to the standard diff groups so this follows your colourscheme.
local function setup_highlights()
  if HL_READY then
    return
  end
  HL_READY = true
  local links = {
    FujjitiveConflictMarker = "Comment",
    FujjitiveConflictLabel = "Comment",
    FujjitiveConflictBase = "DiffDelete",
    FujjitiveConflictSide1 = "DiffAdd",
    FujjitiveConflictSide2 = "DiffChange",
    FujjitiveConflictSide3 = "DiffText",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

local function side_group(n)
  return "FujjitiveConflictSide" .. math.min(n, 3)
end

--- Paint the conflicts in place.
---
--- The whole point of doing it this way: the buffer IS the file, so what you
--- read is exactly what jj wrote and what jj will read back. A side-by-side
--- diff can't be accurate here -- the middle buffer carries markers the side
--- buffers don't, so Vim's diff algorithm aligns them against text that isn't
--- really there. Painting the real bytes has nothing to misalign.
local function paint(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return 0
  end
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local regions = conflict.regions(lines)

  local total = 0
  for _, r in pairs(regions) do
    if r.role == "start" then
      total = total + 1
    end
  end

  local index = 0
  for lnum = 1, #lines do
    local r = regions[lnum]
    if r then
      local group, label

      if r.role == "start" then
        index = index + 1
        group = "FujjitiveConflictMarker"
        label = ("  conflict %d of %d — co: side #1 · ct: side #2 · cb: both")
          :format(index, total)
      elseif r.role == "finish" then
        group = "FujjitiveConflictMarker"
      elseif r.role == "header" then
        group = "FujjitiveConflictMarker"
        label = r.diff and ("  side #%d, as a diff from base"):format(r.side)
          or ("  side #%d"):format(r.side)
      elseif r.role == "content" then
        if r.mark == "-" then
          group = "FujjitiveConflictBase"
        else
          group = side_group(r.side)
        end
      end

      if group then
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum - 1, 0, {
          line_hl_group = group,
          virt_text = label and { { label, "FujjitiveConflictLabel" } } or nil,
          virt_text_pos = label and "eol" or nil,
        })
      end
    end
  end
  return total
end

--- The conflict view: one pane, the real file, conflicts painted in place.
local function open_conflict(root, path, abs, parsed)
  local win = panel.top_window()
  if not win then
    return
  end
  panel.close_extras()

  vim.api.nvim_win_call(win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end)
  local buf = vim.api.nvim_win_get_buf(win)
  vim.wo[win].wrap = false
  vim.api.nvim_set_current_win(win)

  paint(buf)

  local function resolve_with(tool)
    jj.run({
      root = root,
      color = false,
      args = { "resolve", "--tool", tool, path },
      on_done = function(ok, out, err)
        if not ok then
          vim.notify("fujjitive: " .. jj.strip_ansi(err), vim.log.levels.ERROR)
          return
        end
        local msg = vim.trim(jj.strip_ansi(err ~= "" and err or out))
        if msg ~= "" then
          vim.notify(msg, vim.log.levels.INFO)
        end
        M.close()
        vim.cmd("checktime") -- jj rewrote the file underneath us
        require("fujjitive.status").schedule_refresh()
      end,
    })
  end

  local function accept(n)
    take_side(win, buf, n)
    paint(buf)
  end

  map(buf, "co", function() accept(1) end, "Take side #1 for this conflict")
  map(buf, "ct", function() accept(2) end, "Take side #2 for this conflict")
  map(buf, "cb", function() accept("both") end, "Take both sides for this conflict")
  map(buf, "]x", function() vim.fn.search(conflict.START, "W") end, "Next conflict")
  map(buf, "[x", function() vim.fn.search(conflict.START, "bW") end, "Previous conflict")
  map(buf, "cO", function() resolve_with(":ours") end, "Take side #1 for the WHOLE file")
  map(buf, "cT", function() resolve_with(":theirs") end, "Take side #2 for the WHOLE file")
  map(buf, "q", M.close, "Close the conflict view")
  map(buf, "g?", function()
    vim.notify(table.concat({
      "fujjitive — conflict keymaps",
      "",
      "  co        take side #1 for the conflict under the cursor",
      "  ct        take side #2 for it",
      "  cb        take BOTH, side #1 then side #2",
      "",
      "  the cursor jumps to the next conflict after each one, so you",
      "  can just tap co / ct / cb until the file is done.",
      "",
      "  ]x / [x   next / previous conflict",
      "  cO / cT   take side #1 / #2 for the WHOLE file (jj resolve)",
      "",
      "  or edit by hand -- jj notices when the markers are gone.",
      "  :w closes this view either way.",
      "",
      "  q         close",
    }, "\n"), vim.log.levels.INFO)
  end, "Show keymaps")

  local group = vim.api.nvim_create_augroup("FujjitiveConflict" .. buf, { clear = true })
  -- Repaint after any edit, so hand-editing stays as legible as using the keys.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      paint(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      if not conflict.is_conflicted(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        M.close()
      end
    end,
  })

  if parsed.hunks[1] then
    pcall(vim.api.nvim_win_set_cursor, win, { parsed.hunks[1].first, 0 })
  end
  vim.notify(
    ("fujjitive: %d conflict(s) in %s — co / ct / cb to accept, g? for keys")
      :format(#parsed.hunks, path),
    vim.log.levels.INFO
  )
end

--- Open `path` diffed against `config.diff_against`, or as a painted page if it
--- is conflicted.
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
  local on_disk = vim.uv.fs_stat(abs) ~= nil

  -- A conflicted file is materialized with markers in the working copy, so the
  -- file itself tells us -- no need to trust the status parse.
  if on_disk and not opts.no_merge then
    local ok, lines = pcall(vim.fn.readfile, abs)
    if ok and conflict.is_conflicted(lines) then
      local parsed = conflict.parse(lines)
      if parsed.max_side >= 2 then
        return open_conflict(root, path, abs, parsed)
      end
    end
  end

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
    local lbuf = version_buf(("fujjitive://%s/%s"):format(rev, path), to_lines(text), filetype_for(path))

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

    map(lbuf, "q", M.close, "Close the diff")
    map(vim.api.nvim_win_get_buf(right), "q", M.close, "Close the diff")
  end)
end

return M
