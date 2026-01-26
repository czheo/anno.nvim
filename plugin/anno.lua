local anno = require("anno")

vim.api.nvim_create_user_command("AnnoAdd", function()
  anno.add_anno()
end, { desc = "Add annotation at cursor" })

vim.api.nvim_create_user_command("AnnoList", function()
  anno.list_annos()
end, { desc = "List annotations" })

vim.api.nvim_create_user_command("AnnoRemoveAll", function()
  anno.remove_all()
end, { desc = "Remove all annotations" })
