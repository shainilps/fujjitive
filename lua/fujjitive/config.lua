-- Defaults for fujjitive. Kept in its own module so that every other module can
-- read config without requiring `init.lua` (which would create a require cycle).
local M = {}

M.defaults = {
  -- Revset shown in the graph. nil = whatever your `revsets.log` setting is.
  revset = nil,

  -- Commit template used for each change in the graph. Any jj template
  -- expression works; the change-id sentinel is prepended automatically.
  log_template = "builtin_log_compact",

  -- Height of the diff pane, as a fraction of the tab page.
  diff_height = 0.55,

  -- How long to wait after the cursor stops before loading a diff (ms).
  diff_debounce = 60,

  -- Passed to `jj show`. "--color-words" is jj's word-level diff; "--git" gives
  -- a plain unified diff instead.
  diff_format = "--color-words",

  -- Characters jj may use to draw a node. Used to locate the node's column so
  -- that h/l can hop between graph lanes.
  node_glyphs = { "@", "○", "◆", "×", "●", "◉", "o", "+", "x", "*" },

  -- Set to false to define your own graph mappings instead.
  default_keymaps = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
