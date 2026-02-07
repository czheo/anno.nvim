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

local function clear_annotations(silent)
  for bufnr, _ in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, state.namespace, 0, -1)
    end
  end
  state.annotations = {}
  if not silent then
    vim.notify("All annotations removed", vim.log.levels.INFO)
  end
end

local function find_or_load_buffer(path)
  local abs_path = vim.fn.fnamemodify(path, ":p")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == abs_path then
      return bufnr
    end
  end

  if vim.fn.filereadable(abs_path) == 0 then
    return nil
  end

  local bufnr = vim.fn.bufadd(abs_path)
  local ok = pcall(vim.fn.bufload, bufnr)
  if not ok then
    return nil
  end
  return bufnr
end

local function decode_json(input)
  if vim.json and vim.json.decode then
    return vim.json.decode(input)
  end
  return vim.fn.json_decode(input)
end

local function encode_json(input)
  if vim.json and vim.json.encode then
    return vim.json.encode(input)
  end
  return vim.fn.json_encode(input)
end

local function is_positive_int(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function parse_anno_json(path)
  local lines = vim.fn.readfile(path)
  local content = table.concat(lines, "\n")
  local ok, data = pcall(decode_json, content)
  if not ok or type(data) ~= "table" then
    return nil, "Invalid JSON"
  end

  if data.version ~= 1 then
    return nil, "Unsupported version (expected 1)"
  end

  if type(data.annotations) ~= "table" then
    return nil, "Missing or invalid annotations array"
  end

  local entries = {}
  for i, entry in ipairs(data.annotations) do
    if type(entry) ~= "table" then
      return nil, string.format("annotations[%d] must be an object", i)
    end
    if type(entry.path) ~= "string" or entry.path == "" then
      return nil, string.format("annotations[%d].path must be a non-empty string", i)
    end
    if type(entry.text) ~= "string" then
      return nil, string.format("annotations[%d].text must be a string", i)
    end
    if not is_positive_int(entry.start_line) then
      return nil, string.format("annotations[%d].start_line must be a positive integer", i)
    end
    if not is_positive_int(entry.end_line) then
      return nil, string.format("annotations[%d].end_line must be a positive integer", i)
    end
    if entry.end_line < entry.start_line then
      return nil, string.format("annotations[%d].end_line must be >= start_line", i)
    end
    table.insert(entries, {
      path = entry.path,
      start_line = entry.start_line,
      end_line = entry.end_line,
      text = entry.text,
    })
  end

  return entries, nil
end

local function build_json_annotations()
  local entries = {}
  local missing = 0

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, { details = true })
        if mark and mark[1] then
          local lnum = mark[1] + 1
          local details = mark[3] or {}
          local end_lnum = details.end_row and (details.end_row + 1) or lnum
          table.insert(entries, {
            path = item.path,
            start_line = lnum,
            end_line = end_lnum,
            text = item.text,
          })
        else
          missing = missing + 1
        end
      end
    else
      missing = missing + #annos
    end
  end

  return entries, missing
end

function M.remove_all()
  clear_annotations(false)
end

function M.load_from_file(file_path)
  local path = vim.fn.expand(file_path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify(string.format("AnnoLoad: file not found: %s", file_path), vim.log.levels.ERROR)
    return
  end

  local entries, err = parse_anno_json(path)
  if not entries then
    vim.notify("AnnoLoad parse error: " .. err, vim.log.levels.ERROR)
    return
  end

  local loaded = 0
  local skipped = 0
  local first_loaded_bufnr = nil
  for _, entry in ipairs(entries) do
    local bufnr = find_or_load_buffer(entry.path)
    if not bufnr then
      skipped = skipped + 1
    else
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if line_count <= 0 then
        skipped = skipped + 1
      else
        vim.bo[bufnr].buflisted = true
        local start_line = math.max(1, math.min(entry.start_line, line_count))
        local end_line = math.max(start_line, math.min(entry.end_line, line_count))
        local id = vim.api.nvim_buf_set_extmark(
          bufnr,
          state.namespace,
          start_line - 1,
          0,
          {
            end_row = end_line - 1,
            end_col = 0,
            virt_lines = state.show_virtuals and build_virt_lines(entry.text, start_line, end_line) or {},
            virt_lines_above = false,
          }
        )

        state.add(bufnr, {
          bufnr = bufnr,
          extmark_id = id,
          path = vim.api.nvim_buf_get_name(bufnr),
          text = entry.text,
        })
        if not first_loaded_bufnr then
          first_loaded_bufnr = bufnr
        end
        loaded = loaded + 1
      end
    end
  end

  if first_loaded_bufnr and vim.api.nvim_buf_is_valid(first_loaded_bufnr) then
    pcall(vim.cmd, "silent keepalt buffer " .. first_loaded_bufnr)
  end

  if skipped > 0 then
    vim.notify(string.format("Annotations loaded: %d (skipped: %d)", loaded, skipped), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations loaded: %d", loaded), vim.log.levels.INFO)
  end
end

function M.save_to_file(file_path)
  local path = vim.fn.expand(file_path)
  local entries, missing = build_json_annotations()
  local payload = {
    version = 1,
    annotations = entries,
  }

  local ok_encode, encoded = pcall(encode_json, payload)
  if not ok_encode then
    vim.notify("AnnoSave error: failed to encode JSON", vim.log.levels.ERROR)
    return
  end

  local ok_write = pcall(vim.fn.writefile, { encoded }, path)
  if not ok_write then
    vim.notify(string.format("AnnoSave error: cannot write file: %s", path), vim.log.levels.ERROR)
    return
  end

  if missing > 0 then
    vim.notify(string.format("Annotations saved: %d (missing: %d)", #entries, missing), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations saved: %d", #entries), vim.log.levels.INFO)
  end
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
