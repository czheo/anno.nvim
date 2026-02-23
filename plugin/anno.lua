--- User-command entrypoints for anno.nvim.
---
--- This file intentionally stays thin: it wires Ex commands to functions implemented in
--- `lua/anno/init.lua`, keeping plugin loading predictable and easy to audit.
local anno = require("anno")

--- Declarative command spec so adding/removing commands is a data-only change.
local command_specs = {
  {
    name = "AnnoAdd",
    handler = function(opts)
      anno.add(opts)
    end,
    opts = { desc = "Add annotation at cursor", range = true },
  },
  {
    name = "AnnoYank",
    handler = function()
      anno.yank()
    end,
    opts = { desc = "Yank annotations" },
  },
  {
    name = "AnnoList",
    handler = function()
      anno.list()
    end,
    opts = { desc = "List annotations in quickfix" },
  },
  {
    name = "AnnoRemoveAll",
    handler = function()
      anno.remove_all()
    end,
    opts = { desc = "Remove all annotations" },
  },
  {
    name = "AnnoEdit",
    handler = function()
      anno.edit()
    end,
    opts = { desc = "Edit annotation at cursor line" },
  },
  {
    name = "AnnoRemove",
    handler = function()
      anno.remove()
    end,
    opts = { desc = "Remove annotation at cursor line" },
  },
  {
    name = "AnnoToggle",
    handler = function()
      anno.toggle()
    end,
    opts = { desc = "Toggle annotation display" },
  },
  {
    name = "AnnoNext",
    handler = function()
      anno.next()
    end,
    opts = { desc = "Jump to next annotation" },
  },
  {
    name = "AnnoPrev",
    handler = function()
      anno.prev()
    end,
    opts = { desc = "Jump to previous annotation" },
  },
  {
    name = "AnnoLoad",
    handler = function(opts)
      anno.load(opts.args)
    end,
    opts = { desc = "Load annotations from file", nargs = 1, complete = "file" },
  },
  {
    name = "AnnoSave",
    handler = function(opts)
      anno.save(opts.args)
    end,
    opts = { desc = "Save annotations to file", nargs = 1, complete = "file" },
  },
}

for _, spec in ipairs(command_specs) do
  vim.api.nvim_create_user_command(spec.name, spec.handler, spec.opts)
end
