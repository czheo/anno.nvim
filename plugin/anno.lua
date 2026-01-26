local anno = require("anno")

vim.api.nvim_create_user_command("AnnoAdd", function(opts)
  anno.add_anno(opts)
end, { desc = "Add annotation at cursor", range = true })

vim.api.nvim_create_user_command("AnnoYank", function()
  anno.yank_annos()
end, { desc = "Yank annotations" })

vim.api.nvim_create_user_command("AnnoRemoveAll", function()
  anno.remove_all()
end, { desc = "Remove all annotations" })

vim.api.nvim_create_user_command("AnnoRemove", function()
  anno.remove_at_cursor()
end, { desc = "Remove annotation at cursor line" })
