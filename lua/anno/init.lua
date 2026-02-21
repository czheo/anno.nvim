--- anno.nvim core module.
---
--- Architecture overview:
--- - Each annotation is represented by one extmark in `state.namespace`.
--- - `state.annotations[bufnr]` stores plugin metadata for every extmark we create.
--- - The extmark position/range remains source-of-truth for line numbers; metadata stores
---   user text and file path used for yanking and JSON serialization.
---
--- Key constraints/invariants:
--- - We only create annotations in file-backed buffers.
--- - Stored annotation line numbers are always 1-based for UI/JSON, while extmark APIs are 0-based.
--- - Range annotations always satisfy `start_line <= end_line`.
--- - Operations must gracefully skip stale extmarks/buffers (e.g. file deleted, buffer wiped).
local state = require("anno.state")

local M = {}

--- Link the plugin highlight group to user-configurable highlight.
---
--- @param use_default boolean If true, only define the link when AnnoText is not already set.
local function set_highlight(use_default)
  vim.api.nvim_set_hl(0, "AnnoText", { link = state.config.highlight, default = use_default })
end

set_highlight(true)

--- Build a human-readable suffix shown for range annotations.
---
--- @param start_line integer 1-based start line
--- @param end_line integer 1-based end line
--- @return string
local function build_suffix(start_line, end_line)
  if end_line > start_line then
    return string.format(" [%d-%d]", start_line, end_line)
  end
  return ""
end

--- Build extmark virtual lines payload for annotation text.
---
--- @param text string
--- @param start_line integer 1-based start line
--- @param end_line integer 1-based end line
--- @return table
local function build_virt_lines(text, start_line, end_line)
  local suffix = build_suffix(start_line, end_line)
  return { { { state.config.prefix .. text .. suffix, "AnnoText" } } }
end

--- Default formatter used by :AnnoYank.
---
--- @param item table { bufnr, extmark_id, path, text }
--- @param ctx table { bufnr, start_line, end_line, filetype, code }
--- @return string
local function default_yank_format(item, ctx)
  local header = string.format("@%s#%d-%d", item.path, ctx.start_line, ctx.end_line)
  local comment = string.format("Comment: %s", item.text)
  local fence = string.format("```%s", ctx.filetype or "")
  return table.concat({ header, comment, "", fence, ctx.code, "```" }, "\n")
end

--- Return true when bufnr points to a normal file-backed buffer.
---
--- @param bufnr integer
--- @return boolean
local function is_file_buffer(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name ~= ""
end

--- Normalize a possibly reversed line range into an increasing pair.
---
--- @param line1 integer
--- @param line2 integer
--- @return integer, integer
local function normalize_line_range(line1, line2)
  if line2 < line1 then
    return line2, line1
  end
  return line1, line2
end

--- Read extmark coordinates and translate to 1-based line range.
---
--- @param bufnr integer
--- @param extmark_id integer
--- @return table|nil { row0, col0, start_line, end_line, end_row0, end_col0 }
local function get_extmark_range(bufnr, extmark_id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, extmark_id, { details = true })
  if not (mark and mark[1] ~= nil) then
    return nil
  end

  local details = mark[3] or {}
  local start_line = mark[1] + 1
  local end_line = details.end_row and (details.end_row + 1) or start_line

  return {
    row0 = mark[1],
    col0 = mark[2] or 0,
    start_line = start_line,
    end_line = end_line,
    end_row0 = details.end_row,
    end_col0 = details.end_col,
  }
end

--- Create one annotation extmark and track it in state.
---
--- @param bufnr integer
--- @param path string
--- @param start_line integer 1-based
--- @param end_line integer 1-based
--- @param text string
local function create_annotation(bufnr, path, start_line, end_line, text)
  local id = vim.api.nvim_buf_set_extmark(
    bufnr,
    state.namespace,
    start_line - 1,
    0,
    {
      end_row = end_line - 1,
      end_col = 0,
      virt_lines = state.show_virtuals and build_virt_lines(text, start_line, end_line) or {},
      virt_lines_above = false,
    }
  )

  state.add(bufnr, {
    bufnr = bufnr,
    extmark_id = id,
    path = path,
    text = text,
  })
end

--- Add an annotation on the current cursor line or provided command range.
---
--- Canonical public API name: `add`.
---
--- @param opts table|nil User-command opts containing optional `line1`/`line2`.
function M.add(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_file_buffer(bufnr) then
    vim.notify("AnnoAdd: not a file-backed buffer", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line1 = opts and opts.line1 or cursor_line
  local line2 = opts and opts.line2 or cursor_line
  line1, line2 = normalize_line_range(line1, line2)

  local text = vim.fn.input("Annotation: ")
  if text == "" then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  create_annotation(bufnr, path, line1, line2, text)
  vim.notify("Annotation added", vim.log.levels.INFO)
end

--- Validate and normalize setup options.
---
--- @param opts table
--- @return table normalized
local function normalize_setup_opts(opts)
  if type(opts) ~= "table" then
    error("anno.setup: opts must be a table", 2)
  end

  if opts.highlight ~= nil and type(opts.highlight) ~= "string" then
    error("anno.setup: highlight must be a string", 2)
  end
  if opts.prefix ~= nil and type(opts.prefix) ~= "string" then
    error("anno.setup: prefix must be a string", 2)
  end
  if opts.yank_format ~= nil and type(opts.yank_format) ~= "function" then
    error("anno.setup: yank_format must be a function", 2)
  end

  return opts
end

function M.setup(opts)
  local normalized = normalize_setup_opts(opts or {})

  if normalized.highlight ~= nil then
    state.config.highlight = normalized.highlight
  end
  if normalized.prefix ~= nil then
    state.config.prefix = normalized.prefix
  end
  if normalized.yank_format ~= nil then
    state.config.yank_format = normalized.yank_format
  end
  -- setup() should win over colorscheme defaults.
  set_highlight(false)
end

--- Remove all extmarks we track and reset annotation index.
---
--- @param silent boolean Suppress success notification when true.
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

--- Find existing buffer for path or load it from disk.
---
--- @param path string
--- @return integer|nil bufnr
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

--- Parse and validate annotation JSON payload.
---
--- @param path string
--- @return table|nil entries
--- @return string|nil error_message
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

--- Iterate over tracked annotations and provide resolved extmark data.
---
--- Callback receives:
--- - item: original tracked annotation object
--- - ctx: { bufnr, start_line, end_line, row0, col0, end_row0, end_col0 }
---
--- @param fn fun(item: table, ctx: table)
--- @return integer missing_count Number of stale annotation entries skipped.
local function for_each_live_annotation(fn)
  local missing = 0

  for bufnr, annos in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, item in ipairs(annos) do
        local mark = get_extmark_range(bufnr, item.extmark_id)
        if mark then
          fn(item, {
            bufnr = bufnr,
            start_line = mark.start_line,
            end_line = mark.end_line,
            row0 = mark.row0,
            col0 = mark.col0,
            end_row0 = mark.end_row0,
            end_col0 = mark.end_col0,
          })
        else
          missing = missing + 1
        end
      end
    else
      missing = missing + #annos
    end
  end

  return missing
end

local function build_json_annotations()
  local entries = {}
  local missing = for_each_live_annotation(function(item, ctx)
    table.insert(entries, {
      path = item.path,
      start_line = ctx.start_line,
      end_line = ctx.end_line,
      text = item.text,
    })
  end)

  return entries, missing
end

function M.remove_all()
  clear_annotations(false)
end

--- Load annotations from a JSON file and append them to in-memory state.
---
--- Canonical public API name: `load`.
---
--- @param file_path string
function M.load(file_path)
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
        -- Clamp ranges so out-of-date JSON still loads safely for shorter files.
        local start_line = math.max(1, math.min(entry.start_line, line_count))
        local end_line = math.max(start_line, math.min(entry.end_line, line_count))

        vim.bo[bufnr].buflisted = true
        create_annotation(bufnr, vim.api.nvim_buf_get_name(bufnr), start_line, end_line, entry.text)

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

--- Save all live annotations into a JSON file.
---
--- Canonical public API name: `save`.
---
--- @param file_path string
function M.save(file_path)
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

--- Toggle inline virtual annotation visibility.
---
--- Canonical public API name: `toggle`.
function M.toggle()
  state.show_virtuals = not state.show_virtuals

  for_each_live_annotation(function(item, ctx)
    vim.api.nvim_buf_set_extmark(
      ctx.bufnr,
      state.namespace,
      ctx.row0,
      ctx.col0,
      {
        id = item.extmark_id,
        -- Preserve explicit end coordinates when present; otherwise keep a single-line mark.
        end_row = (ctx.end_row0 ~= nil) and ctx.end_row0 or (ctx.start_line - 1),
        end_col = (ctx.end_col0 ~= nil) and ctx.end_col0 or 0,
        virt_lines = state.show_virtuals and build_virt_lines(item.text, ctx.start_line, ctx.end_line) or {},
        virt_lines_above = false,
      }
    )
  end)

  local status = state.show_virtuals and "shown" or "hidden"
  vim.notify("Annotations " .. status, vim.log.levels.INFO)
end

--- Remove an annotation anchored at the current cursor line.
---
--- Canonical public API name: `remove`.
function M.remove()
  local bufnr = vim.api.nvim_get_current_buf()
  local annos = state.annotations[bufnr]
  if not annos or #annos == 0 then
    vim.notify("No annotations in current buffer", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]

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

--- Jump to next/previous annotation line, wrapping around file boundaries.
---
--- @param forward boolean True jumps to next, false jumps to previous.
local function jump_to_annotation(forward)
  local bufnr = vim.api.nvim_get_current_buf()
  local annos = state.annotations[bufnr]
  if not annos or #annos == 0 then
    vim.notify("No annotations in current buffer", vim.log.levels.INFO)
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = {}
  local seen = {}

  for _, item in ipairs(annos) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, {})
    if mark and mark[1] then
      local line = mark[1] + 1
      if not seen[line] then
        table.insert(lines, line)
        seen[line] = true
      end
    end
  end

  if #lines == 0 then
    vim.notify("No annotations in current buffer", vim.log.levels.INFO)
    return
  end

  table.sort(lines)

  local target = nil
  if forward then
    for _, line in ipairs(lines) do
      if line > current_line then
        target = line
        break
      end
    end
    if not target then
      target = lines[1]
    end
  else
    for i = #lines, 1, -1 do
      if lines[i] < current_line then
        target = lines[i]
        break
      end
    end
    if not target then
      target = lines[#lines]
    end
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

--- Jump to the next annotation in the current buffer.
---
--- Canonical public API name: `next`.
function M.next()
  jump_to_annotation(true)
end

--- Jump to the previous annotation in the current buffer.
---
--- Canonical public API name: `prev`.
function M.prev()
  jump_to_annotation(false)
end

--- Format and copy annotations to the unnamed register.
---
--- Canonical public API name: `yank`.
function M.yank()
  local blocks = {}
  local missing = for_each_live_annotation(function(item, ctx)
    local ft = vim.bo[ctx.bufnr].filetype
    local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.start_line - 1, ctx.end_line, false)
    local code = table.concat(lines, "\n")
    local formatter = state.config.yank_format or default_yank_format

    table.insert(blocks, formatter(item, {
      bufnr = ctx.bufnr,
      start_line = ctx.start_line,
      end_line = ctx.end_line,
      filetype = ft,
      code = code,
    }))
  end)

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
