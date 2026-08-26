-- fujjitive — Fugitive-style jj change review for Neovim.
local M = {}

local config = require("fujjitive.config")

--- Optional. Call with a table to override any default in `config.lua`.
function M.setup(opts)
  config.setup(opts)
end

--- The graph in the bottom half.
function M.open()
  require("fujjitive.graph").open()
end

--- `jj status` in the bottom half.
function M.status()
  require("fujjitive.status").open()
end

function M.close()
  require("fujjitive.graph").close()
end

function M.refresh()
  local panel = require("fujjitive.panel")
  if panel.kind() == "status" then
    require("fujjitive.status").refresh()
  else
    local graph = require("fujjitive.graph")
    graph.refresh({ keep_change = graph.current_change() })
  end
end

return M
