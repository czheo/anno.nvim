--- Shared mutable state for anno.nvim.
---
--- Keeping state in a separate module gives every command handler a single source of truth
--- without threading large context objects through each public function call.
local M = {
  -- annotations[bufnr] = { { bufnr, extmark_id, path, text, seq, group_name }, ... }
  --
  -- Association invariant:
  -- - `item.extmark_id` is the extmark key inside `namespace_id` for the same `bufnr` bucket.
  -- - The tuple (bufnr, namespace_id, item.extmark_id) uniquely identifies one live extmark.
  annotations = {},
  -- Numeric id returned by `nvim_create_namespace("anno")`.
  -- The string name is constant; this id is what all extmark APIs consume.
  namespace_id = vim.api.nvim_create_namespace("anno"),
  show_virtuals = true,
  -- Monotonic insertion counter for deterministic global ordering.
  next_seq = 1,
  -- Active group used by AnnoAdd.
  active_group = "default",
  -- groups[name] = { color = "#RRGGBB"|nil }
  groups = {
    default = { color = nil },
  },
  config = {
    highlight = "Todo",
    prefix = "↳ ",
    yank_format = nil,
  },
}

--- Track an annotation item under its buffer.
---
--- Invariant: `item.extmark_id` points to an extmark in `M.namespace_id` for `bufnr`.
--- Ordering invariant: every tracked item gets a strictly increasing `item.seq`.
---
--- @param bufnr integer
--- @param item table
function M.ensure_group(name)
  local group_name = name
  if type(group_name) ~= "string" or group_name == "" then
    group_name = "default"
  end
  if M.groups[group_name] == nil then
    M.groups[group_name] = { color = nil }
  end
  return group_name
end

function M.add(bufnr, item)
  if item.seq == nil then
    item.seq = M.next_seq
    M.next_seq = M.next_seq + 1
  elseif item.seq >= M.next_seq then
    -- Keep counter ahead when tests/manual state injection provide explicit seq values.
    M.next_seq = item.seq + 1
  end

  item.group_name = M.ensure_group(item.group_name)

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

  vim.api.nvim_buf_clear_namespace(bufnr, M.namespace_id, 0, -1)
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
  M.next_seq = 1
  M.active_group = "default"
  M.groups = {
    default = { color = nil },
  }
  if not opts.keep_config then
    M.config.highlight = "Todo"
    M.config.prefix = "↳ "
    M.config.yank_format = nil
  end
end

return M
