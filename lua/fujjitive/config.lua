-- Defaults for fujjitive. Kept in its own module so that every other module can
-- read config without requiring `init.lua` (which would create a require cycle).
local M = {}

M.defaults = {
  -- Revset shown in the graph. nil = whatever your `revsets.log` setting is.
  revset = nil,

  -- Commit template used for each change in the graph. Any jj template
  -- expression works; the change-id sentinel is prepended automatically.
  log_template = "builtin_log_compact",

  -- Height of the bottom panel, as a fraction of the screen. The panel is the
  -- only window fujjitive opens up front -- the top half stays yours until you
  -- press `v` or `dv`, which borrow it and give it back on `q`.
  panel_height = 0.5,

  -- Passed to `jj show` when you press `v`. "--color-words" is jj's word-level
  -- diff; "--git" gives a plain unified diff instead.
  show_format = "--color-words",

  -- Header printed above that diff. The default is the description and nothing
  -- else -- no commit ID, no change ID, no author, no timestamps, since those
  -- are noise when all you want is "what did this change do?".
  -- Set to nil for jj's own header if you do want the metadata.
  show_template = [[if(description, description, "(no description set)\n")]],

  -- `dv` / `ds` diff a file against this revision. "@-" is the parent of the
  -- working copy, which is the jj equivalent of Fugitive diffing against the
  -- index: it shows exactly what `jj status` is reporting as changed.
  diff_against = "@-",

  -- Characters jj may use to draw a node. Used to locate the node's column so
  -- that h/l can hop between graph lanes.
  node_glyphs = { "@", "○", "◆", "×", "●", "◉", "o", "+", "x", "*" },

  -- Set to false to define your own mappings instead.
  default_keymaps = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
