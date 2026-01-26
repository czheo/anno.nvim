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

function M.add_anno(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_file_buffer(bufnr) then
    vim.notify("AnnoAdd: not a file-backed buffer", vim.log.levels.WARN)
    return
  end

  local pos = vim.api.nvim_win_get_cursor(0)
  local line1 = opts and opts.line1 or pos[1]
  local line2 = opts and opts.line2 or pos[1]
  if line2 < line1 then
    line1, line2 = line2, line1
  end
  local text = vim.fn.input("Annotation: ")
  if text == "" then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local span = line2 - line1 + 1
  local suffix = span > 1 and string.format(" [%d-%d]", line1, line2) or ""
  local id = vim.api.nvim_buf_set_extmark(
    bufnr, -- target buffer
    state.namespace, -- plugin namespace
    line1 - 1, -- line (0-based for extmark API)
    0, -- col (0-based for extmark API)
    {
      end_row = line2 - 1,
      end_col = 0,
      virt_lines = { { { "↳ " .. text .. suffix, "AnnoText" } } },
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

function M.remove_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local annos = state.annotations[bufnr]
  if not annos or #annos == 0 then
    vim.notify("No annotations in current buffer", vim.log.levels.INFO)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]

  for i = #annos, 1, -1 do
    local item = annos[i]
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.id, {})
    if mark and mark[1] and (mark[1] + 1) == line then
      vim.api.nvim_buf_del_extmark(bufnr, state.namespace, item.id)
      table.remove(annos, i)
      if #annos == 0 then
        state.annotations[bufnr] = nil
      end
      vim.notify("Annotation removed", vim.log.levels.INFO)
      return
    end
  end

  vim.notify("No annotation found at cursor line", vim.log.levels.INFO)
end

function M.list_annos()
  local blocks = {}
  local missing = 0

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.id, { details = true })
        if mark and mark[1] then
          local lnum = mark[1] + 1
          local details = mark[3] or {}
          local end_lnum = details.end_row and (details.end_row + 1) or lnum
          local ft = vim.bo[bufnr].filetype
          local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, end_lnum, false)
          local header = string.format("@%s#%d-%d", item.path, lnum, end_lnum)
          local comment = string.format("Comment: %s", item.text)
          local code = table.concat(lines, "\n")
          local fence = string.format("```%s", ft or "")
          local block = table.concat({ header, comment, "", fence, code, "```" }, "\n")
          table.insert(blocks, block)
        else
          missing = missing + 1
        end
      end
    else
      missing = missing + #annos
    end
  end

  if #blocks == 0 then
    vim.notify("No annotations", vim.log.levels.INFO)
    return
  end

  if missing > 0 then
    vim.notify(string.format("Annotations: %d (missing: %d)", #blocks, missing), vim.log.levels.WARN)
  end
  vim.print(table.concat(blocks, "\n\n"))
end

return M
