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

--- Remove all extmarks and tracked entries in one buffer.
---
--- This helper is used by both runtime commands and tests so they keep the same cleanup logic.
---
--- @param bufnr integer
function M.clear_buffer_annotations(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.annotations[bufnr] = nil
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
  M.annotations[bufnr] = nil
end

--- Reset all plugin state to defaults.
---
--- @param opts table|nil
--- @field keep_config boolean|nil When true, preserve current setup() values.
function M.reset(opts)
  opts = opts or {}

  for bufnr, _ in pairs(M.annotations) do
    M.clear_buffer_annotations(bufnr)
  end

  M.show_virtuals = true
  if not opts.keep_config then
    M.config.highlight = "Todo"
    M.config.prefix = "↳ "
    M.config.yank_format = nil
  end
end

return M
