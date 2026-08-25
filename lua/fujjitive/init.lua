-- fujjitive — Fugitive-style jj change review for Neovim.
local M = {}

local config = require("fujjitive.config")

--- Optional. Call with a table to override any default in `config.lua`.
function M.setup(opts)
  config.setup(opts)
end

function M.open()
  require("fujjitive.graph").open()
end

function M.close()
  require("fujjitive.graph").close()
end

function M.refresh()
  local graph = require("fujjitive.graph")
  graph.refresh({ keep_change = graph.current_change() })
end

return M
