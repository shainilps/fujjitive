if vim.g.loaded_fujjitive then
  return
end
vim.g.loaded_fujjitive = 1

vim.api.nvim_create_user_command("JJ", function(opts)
  require("fujjitive.ops").dispatch(opts.fargs)
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line)
    return require("fujjitive.ops").complete(arg_lead, cmd_line)
  end,
  desc = "Open the fujjitive graph, or run a jj operation on the change under the cursor",
})

vim.api.nvim_create_user_command("Fujjitive", function()
  require("fujjitive.graph").open()
end, { desc = "Open the fujjitive graph" })
