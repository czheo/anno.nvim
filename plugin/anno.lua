--- User-command entrypoints for anno.nvim.
---
--- This file intentionally stays thin: it wires Ex commands to functions implemented in
--- `lua/anno/init.lua`, keeping plugin loading predictable and easy to audit.
local anno = require("anno")

--- Register one user command with a consistent wrapper shape.
---
--- @param name string
--- @param fn function
--- @param opts table
local function register(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts)
end

register("AnnoAdd", function(opts)
  anno.add(opts)
end, { desc = "Add annotation at cursor", range = true })

register("AnnoYank", function()
  anno.yank()
end, { desc = "Yank annotations" })

register("AnnoRemoveAll", function()
  anno.remove_all()
end, { desc = "Remove all annotations" })

register("AnnoRemove", function()
  anno.remove()
end, { desc = "Remove annotation at cursor line" })

register("AnnoToggle", function()
  anno.toggle()
end, { desc = "Toggle annotation display" })

register("AnnoNext", function()
  anno.next()
end, { desc = "Jump to next annotation" })

register("AnnoPrev", function()
  anno.prev()
end, { desc = "Jump to previous annotation" })

register("AnnoLoad", function(opts)
  anno.load(opts.args)
end, { desc = "Load annotations from file", nargs = 1, complete = "file" })

register("AnnoSave", function(opts)
  anno.save(opts.args)
end, { desc = "Save annotations to file", nargs = 1, complete = "file" })
