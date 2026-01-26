local anno = require("anno")

vim.api.nvim_create_user_command("AnnoStart", function()
  anno.start()
end, { desc = "Start Anno mode" })

vim.api.nvim_create_user_command("AnnoEnd", function()
  anno.stop()
end, { desc = "End Anno mode" })
