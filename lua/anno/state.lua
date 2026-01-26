local M = {
  annotations = {},
  namespace = vim.api.nvim_create_namespace("anno"),
  show_virtuals = true,
  config = {
    highlight = "Todo",
    prefix = "↳ ",
    yank_format = nil,
  },
}

function M.add(bufnr, item)
  M.annotations[bufnr] = M.annotations[bufnr] or {}
  table.insert(M.annotations[bufnr], item)
end

return M
