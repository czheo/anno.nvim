local state = require("anno.state")

local M = {}

vim.api.nvim_set_hl(0, "AnnoText", { link = "Todo", default = true })

local function is_file_buffer(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name ~= ""
end

function M.add_anno()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_file_buffer(bufnr) then
    vim.notify("AnnoAdd: not a file-backed buffer", vim.log.levels.WARN)
    return
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local text = vim.fn.input("Annotation: ")
  if text == "" then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local id = vim.api.nvim_buf_set_extmark(
    bufnr, -- target buffer
    state.namespace, -- plugin namespace
    pos[1] - 1, -- line (0-based for extmark API)
    pos[2], -- col (0-based for extmark API)
    {
      virt_lines = { { { "↳ " .. text, "AnnoText" } } },
      virt_lines_above = false,
    } -- extmark options
  )

  state.add(bufnr, {
    bufnr = bufnr,
    id = id,
    path = path,
    text = text,
  })

  vim.notify("Annotation added", vim.log.levels.INFO)
end

function M.remove_all()
  for bufnr, _ in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, state.namespace, 0, -1)
    end
  end
  state.annotations = {}
  vim.notify("All annotations removed", vim.log.levels.INFO)
end

function M.list_annos()
  local lines = {}
  local missing = 0

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.id, {})
        if pos and pos[1] then
          local lnum = pos[1] + 1
          table.insert(lines, string.format("%s:%d %s", item.path, lnum, item.text))
        else
          missing = missing + 1
        end
      end
    else
      missing = missing + #annos
    end
  end

  if #lines == 0 then
    vim.notify("No annotations", vim.log.levels.INFO)
    return
  end

  vim.notify(string.format("Annotations: %d (missing: %d)", #lines, missing), vim.log.levels.INFO)
  vim.print(lines)
end

return M
