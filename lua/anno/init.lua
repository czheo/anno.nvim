local M = {}

function M.start()
  vim.notify("Anno mode started", vim.log.levels.INFO)
end

function M.stop()
  vim.notify("Anno mode ended", vim.log.levels.INFO)
end

return M
