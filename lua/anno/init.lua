--- anno.nvim core module.
---
--- Architecture overview:
--- - Each annotation is represented by one extmark in `state.namespace_id`.
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

-- Forward declaration: mutation commands call this before its implementation section.
local refresh_annotations_quickfix_if_open

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
--- @param anno table { bufnr, extmark_id, path, text, start_line, end_line, filetype, code }
--- @return string
local function default_yank_format(anno)
  local header = string.format("@%s#%d-%d", anno.path, anno.start_line, anno.end_line)
  local comment = string.format("Comment: %s", anno.text)
  local fence = string.format("```%s", anno.filetype or "")
  return table.concat({ header, comment, "", fence, anno.code, "```" }, "\n")
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
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace_id, extmark_id, { details = true })
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
    state.namespace_id,
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
  refresh_annotations_quickfix_if_open()
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
  -- Keep current setup() options while clearing runtime annotations.
  state.reset({ keep_config = true })
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

  -- Iteration contract (intentional for coding-agent workflows):
  -- - Within each buffer bucket (`annos`), `ipairs` preserves annotation insertion order.
  --   This keeps earlier (usually more important) annotations earlier in output.
  -- - Buffer buckets are traversed via `pairs(state.annotations)`, so cross-buffer order is undefined.
  --   We intentionally avoid a global timeline because annotations are consumed file-by-file.
  --
  -- Why we keep this model:
  -- - Users commonly add high-priority guidance first.
  -- - Grouping by buffer helps agents stay focused on one file context at a time.
  -- - A synthetic cross-buffer order would add complexity without improving this workflow.
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

--- Collect live annotations with deterministic global insertion ordering.
---
--- We keep storage keyed by buffer for efficient buffer-local commands, and derive a
--- globally ordered view by sorting on `item.seq` when command output needs stable order.
---
--- @return table rows { { item = table, ctx = table }, ... }
--- @return integer missing
local function collect_live_annotations()
  local rows = {}
  local missing = for_each_live_annotation(function(item, ctx)
    table.insert(rows, { item = item, ctx = ctx })
  end)

  table.sort(rows, function(a, b)
    return a.item.seq < b.item.seq
  end)

  return rows, missing
end

local function build_json_annotations()
  local entries = {}
  local rows, missing = collect_live_annotations()
  for _, row in ipairs(rows) do
    table.insert(entries, {
      path = row.item.path,
      start_line = row.ctx.start_line,
      end_line = row.ctx.end_line,
      text = row.item.text,
    })
  end

  return entries, missing
end

--- Build quickfix entries in deterministic insertion order.
---
--- @return table items
--- @return integer missing
local function build_quickfix_items()
  local items = {}
  local rows, missing = collect_live_annotations()
  for _, row in ipairs(rows) do
    local item = row.item
    local ctx = row.ctx
    local suffix = ctx.end_line > ctx.start_line and string.format(" [%d-%d]", ctx.start_line, ctx.end_line) or ""
    table.insert(items, {
      filename = item.path,
      lnum = ctx.start_line,
      col = 1,
      text = item.text .. suffix,
    })
  end
  return items, missing
end

--- Refresh the Annotations quickfix list when it is currently open.
---
--- We only touch the quickfix list if the visible quickfix window is the one created by
--- :AnnoList, so we never clobber unrelated quickfix workflows.
refresh_annotations_quickfix_if_open = function()
  -- Request quickfix window metadata only:
  -- - winid: non-zero means a quickfix window is currently open.
  -- - title: lets us refresh only the list owned by :AnnoList.
  local qf = vim.fn.getqflist({ winid = 1, title = 1 })
  if not qf or qf.winid == 0 or qf.title ~= "Annotations" then
    return
  end

  local items, _ = build_quickfix_items()
  vim.fn.setqflist({}, "r", {
    title = "Annotations",
    items = items,
  })
end

function M.remove_all()
  clear_annotations(false)
  refresh_annotations_quickfix_if_open()
end

--- Toggle annotation quickfix list visibility.
---
--- Behavior:
--- - If the currently open quickfix window is the Annotations list, close it.
--- - Otherwise, rebuild Annotations quickfix entries and open quickfix.
---
--- Canonical public API name: `list`.
function M.list()
  local qf = vim.fn.getqflist({ winid = 1, title = 1 })
  if qf and qf.winid ~= 0 and qf.title == "Annotations" then
    vim.cmd("cclose")
    return
  end

  local items, missing = build_quickfix_items()
  if #items == 0 then
    vim.notify("No annotations", vim.log.levels.INFO)
    return
  end

  vim.fn.setqflist({}, "r", {
    title = "Annotations",
    items = items,
  })
  vim.cmd("copen")

  if missing > 0 then
    vim.notify(string.format("Annotations listed: %d (missing: %d)", #items, missing), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations listed: %d", #items), vim.log.levels.INFO)
  end
end

--- Import annotations from a JSON file and append them to in-memory state.
---
--- Canonical public API name: `import`.
---
--- @param file_path string
function M.import(file_path)
  local path = vim.fn.expand(file_path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify(string.format("AnnoImport: file not found: %s", file_path), vim.log.levels.ERROR)
    return
  end

  local entries, err = parse_anno_json(path)
  if not entries then
    vim.notify("AnnoImport parse error: " .. err, vim.log.levels.ERROR)
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

  refresh_annotations_quickfix_if_open()

  if skipped > 0 then
    vim.notify(string.format("Annotations imported: %d (skipped: %d)", loaded, skipped), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations imported: %d", loaded), vim.log.levels.INFO)
  end
end

--- Output all live annotations into a JSON file.
---
--- Canonical public API name: `output`.
---
--- @param file_path string
function M.output(file_path)
  local path = vim.fn.expand(file_path)
  local entries, missing = build_json_annotations()
  local payload = {
    version = 1,
    annotations = entries,
  }

  local ok_encode, encoded = pcall(encode_json, payload)
  if not ok_encode then
    vim.notify("AnnoOutput error: failed to encode JSON", vim.log.levels.ERROR)
    return
  end

  local ok_write = pcall(vim.fn.writefile, { encoded }, path)
  if not ok_write then
    vim.notify(string.format("AnnoOutput error: cannot write file: %s", path), vim.log.levels.ERROR)
    return
  end

  if missing > 0 then
    vim.notify(string.format("Annotations output: %d (missing: %d)", #entries, missing), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations output: %d", #entries), vim.log.levels.INFO)
  end
end


--- Update an existing annotation extmark in-place using current plugin display settings.
---
--- @param bufnr integer
--- @param item table
--- @param ctx table Output from get_extmark_range()
local function update_annotation_extmark(bufnr, item, ctx)
  vim.api.nvim_buf_set_extmark(
    bufnr,
    state.namespace_id,
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
end

--- Toggle inline virtual annotation visibility.
---
--- Canonical public API name: `toggle`.
function M.toggle()
  state.show_virtuals = not state.show_virtuals

  for_each_live_annotation(function(item, ctx)
    update_annotation_extmark(ctx.bufnr, item, ctx)
  end)

  local status = state.show_virtuals and "shown" or "hidden"
  vim.notify("Annotations " .. status, vim.log.levels.INFO)
end

--- Open a temporary floating editor for multi-line annotation text.
---
--- Interaction model:
--- - Window opens in Normal mode by default (users enter Insert mode manually).
--- - Annotation text is loaded as-is, including embedded newlines.
--- - Save keys (Normal mode): <CR>
--- - Cancel keys (Normal mode): q, <Esc>
---
--- @param initial_text string
--- @param on_save fun(new_text: string)
local function open_annotation_editor_float(initial_text, on_save)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"

  local lines = vim.split(initial_text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local function get_editor_size()
    local ui = vim.api.nvim_list_uis()[1]
    if ui then
      return ui.width, ui.height
    end
    return vim.o.columns, vim.o.lines
  end

  -- Size policy:
  -- - Width tracks ~75% of the editor so long lines are readable without dominating the UI.
  -- - Height tracks ~60% and also respects current content length.
  -- - Min/max clamps keep the window usable in tiny terminals and bounded in large ones.
  local function calc_float_config()
    local editor_width, editor_height = get_editor_size()

    local min_width = 40
    local max_width = math.max(min_width, editor_width - 4)
    local target_width = math.floor(editor_width * 0.75)
    local width = math.min(max_width, math.max(min_width, target_width))

    local content_height = math.max(8, #lines + 2)
    local min_height = 8
    local max_height = math.max(min_height, editor_height - 4)
    local target_height = math.floor(editor_height * 0.6)
    local height = math.min(max_height, math.max(min_height, math.max(content_height, target_height)))

    return {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      width = width,
      height = height,
      row = math.max(0, math.floor((editor_height - height) / 2)),
      col = math.max(0, math.floor((editor_width - width) / 2)),
      title = " Annotation (Enter save, q/Esc cancel) ",
      title_pos = "center",
    }
  end

  local win = vim.api.nvim_open_win(buf, true, calc_float_config())

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  -- Keep the float centered and proportionally sized while it is open.
  -- This preserves the UX invariant that :AnnoEdit remains readable across terminal resizes.
  local augroup = vim.api.nvim_create_augroup("AnnoFloatResize" .. win, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, calc_float_config())
      end
    end,
  })

  local done = false
  local function finish(save)
    if done then
      return
    end
    done = true

    if save and vim.api.nvim_buf_is_valid(buf) then
      local edited = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(edited, "\n")
      on_save(text)
    end

    -- Cleanup must always run so repeated :AnnoEdit calls do not leak resize autocmds.
    pcall(vim.api.nvim_del_augroup_by_id, augroup)

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<CR>", function()
    finish(true)
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "q", function()
    finish(false)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    finish(false)
  end, { buffer = buf, silent = true })

end

--- Edit an annotation anchored at the current cursor line.
---
--- Canonical public API name: `edit`.
function M.edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local annos = state.annotations[bufnr]
  if not annos or #annos == 0 then
    vim.notify("No annotations in current buffer", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]

  for i = #annos, 1, -1 do
    local item = annos[i]
    local ctx = get_extmark_range(bufnr, item.extmark_id)
    if ctx and ctx.start_line == line then
      open_annotation_editor_float(item.text, function(new_text)
        if new_text == "" or new_text == item.text then
          return
        end

        local fresh_ctx = get_extmark_range(bufnr, item.extmark_id)
        if not fresh_ctx then
          vim.notify("Annotation no longer exists", vim.log.levels.WARN)
          return
        end

        item.text = new_text
        update_annotation_extmark(bufnr, item, fresh_ctx)
        refresh_annotations_quickfix_if_open()
        vim.notify("Annotation edited", vim.log.levels.INFO)
      end)
      return
    end
  end

  vim.notify("No annotation found at cursor line", vim.log.levels.INFO)
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
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace_id, item.extmark_id, {})
    if mark and mark[1] and (mark[1] + 1) == line then
      vim.api.nvim_buf_del_extmark(bufnr, state.namespace_id, item.extmark_id)
      table.remove(annos, i)
      if #annos == 0 then
        state.annotations[bufnr] = nil
      end
      refresh_annotations_quickfix_if_open()
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
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace_id, item.extmark_id, {})
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
--- Ordering note:
--- - Output follows global annotation insertion order (`item.seq`) across all buffers.
---
--- Canonical public API name: `yank`.
function M.yank()
  local blocks = {}
  local rows, missing = collect_live_annotations()
  for _, row in ipairs(rows) do
    local item = row.item
    local ctx = row.ctx
    local ft = vim.bo[ctx.bufnr].filetype
    local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.start_line - 1, ctx.end_line, false)
    local code = table.concat(lines, "\n")
    local formatter = state.config.yank_format or default_yank_format
    local anno = {
      bufnr = ctx.bufnr,
      extmark_id = item.extmark_id,
      path = item.path,
      text = item.text,
      start_line = ctx.start_line,
      end_line = ctx.end_line,
      filetype = ft,
      code = code,
    }

    table.insert(blocks, formatter(anno))
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
