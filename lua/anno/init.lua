local state = require("anno.state")

local M = {}

-- use_default=true only sets the highlight if AnnoText doesn't already exist.
-- This lets users or colorschemes define AnnoText without us overwriting it.
-- setup() passes false so user config always takes effect.
local function set_highlight(use_default)
  vim.api.nvim_set_hl(0, "AnnoText", { link = state.config.highlight, default = use_default })
end

set_highlight(true)

local function build_suffix(start_line, end_line)
  if end_line > start_line then
    return string.format(" [%d-%d]", start_line, end_line)
  end
  return ""
end

local function build_virt_lines(text, start_line, end_line)
  local suffix = build_suffix(start_line, end_line)
  return { { { state.config.prefix .. text .. suffix, "AnnoText" } } }
end

-- item: { bufnr, extmark_id, path, text }
-- ctx: { bufnr, start_line, end_line, filetype, code }
local function default_yank_format(item, ctx)
  local header = string.format("@%s#%d-%d", item.path, ctx.start_line, ctx.end_line)
  local comment = string.format("Comment: %s", item.text)
  local fence = string.format("```%s", ctx.filetype or "")
  return table.concat({ header, comment, "", fence, ctx.code, "```" }, "\n")
end

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
  local id = vim.api.nvim_buf_set_extmark(
    bufnr, -- target buffer
    state.namespace, -- plugin namespace
    line1 - 1, -- line (0-based for extmark API)
    0, -- col (0-based for extmark API)
    {
      end_row = line2 - 1,
      end_col = 0,
      virt_lines = state.show_virtuals and build_virt_lines(text, line1, line2) or {},
      virt_lines_above = false,
    } -- extmark options
  )

  state.add(bufnr, {
    bufnr = bufnr,
    extmark_id = id,
    path = path,
    text = text,
  })

  vim.notify("Annotation added", vim.log.levels.INFO)
end

function M.setup(opts)
  opts = opts or {}
  if opts.highlight ~= nil then
    state.config.highlight = opts.highlight
  end
  if opts.prefix ~= nil then
    state.config.prefix = opts.prefix
  end
  if opts.yank_format ~= nil then
    state.config.yank_format = opts.yank_format
  end
  set_highlight(false)
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

function M.toggle_virtuals()
  state.show_virtuals = not state.show_virtuals

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, { details = true })
        if mark and mark[1] then
          local lnum = mark[1] + 1
          local details = mark[3] or {}
          local end_lnum = details.end_row and (details.end_row + 1) or lnum
          vim.api.nvim_buf_set_extmark(
            bufnr,
            state.namespace,
            mark[1],
            mark[2],
            {
              id = item.extmark_id, -- reuse extmark id instead of creating a new one
              end_row = (details.end_row ~= nil) and details.end_row or (lnum - 1), -- preserve range end
              end_col = (details.end_col ~= nil) and details.end_col or 0, -- preserve range end col
              -- toggle display by setting/unsetting virtual lines on the same extmark
              virt_lines = state.show_virtuals and build_virt_lines(item.text, lnum, end_lnum) or {},
              virt_lines_above = false, -- keep annotation below the line
            }
          )
        end
      end
    end
  end

  local status = state.show_virtuals and "shown" or "hidden"
  vim.notify("Annotations " .. status, vim.log.levels.INFO)
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
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, {})
    if mark and mark[1] and (mark[1] + 1) == line then
      vim.api.nvim_buf_del_extmark(bufnr, state.namespace, item.extmark_id)
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

function M.yank_annos()
  local blocks = {}
  local missing = 0

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, { details = true })
        if mark and mark[1] then
          local lnum = mark[1] + 1
          local details = mark[3] or {}
          local end_lnum = details.end_row and (details.end_row + 1) or lnum
          local ft = vim.bo[bufnr].filetype
          local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, end_lnum, false)
          local code = table.concat(lines, "\n")
          local ctx = {
            bufnr = bufnr,
            start_line = lnum,
            end_line = end_lnum,
            filetype = ft,
            code = code,
          }
          local formatter = state.config.yank_format or default_yank_format
          table.insert(blocks, formatter(item, ctx))
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
  -- Copy to unnamed register so `p` pastes immediately in Neovim.
  local output = table.concat(blocks, "\n\n")
  vim.fn.setreg('"', output)
  vim.notify("Annotations copied", vim.log.levels.INFO)
  vim.print(output)
end

return M
