--- Shared mutable state for anno.nvim.
---
--- Keeping state in a separate module gives every command handler a single source of truth
--- without threading large context objects through each public function call.
local M = {
  -- annotations[bufnr] = { { bufnr, extmark_id, path, text }, ... }
  annotations = {},
  namespace = vim.api.nvim_create_namespace("anno"),
  show_virtuals = true,
  config = {
    highlight = "Todo",
    prefix = "↳ ",
    yank_format = nil,
  },
}

--- Track an annotation item under its buffer.
---
--- Invariant: `item.extmark_id` points to an extmark in `M.namespace` for `bufnr`.
---
--- @param bufnr integer
--- @param item table
function M.add(bufnr, item)
  M.annotations[bufnr] = M.annotations[bufnr] or {}
  table.insert(M.annotations[bufnr], item)
end

return M
