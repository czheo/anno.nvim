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

local function sanitize_group_name(group_name)
  return tostring(group_name or "default"):gsub("[^%w_]", "_")
end

local function group_hl_name(group_name)
  return "AnnoTextGroup_" .. sanitize_group_name(group_name)
end

local function parse_hex_color(color)
  if type(color) ~= "string" then
    return nil
  end
  local hex = color:match("^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
  if not hex then
    return nil
  end
  return "#" .. string.lower(hex)
end


local function hsl_to_hex(h, s, l)
  local c = (1 - math.abs(2 * l - 1)) * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = l - c / 2
  local r1, g1, b1 = 0, 0, 0

  if h < 60 then
    r1, g1, b1 = c, x, 0
  elseif h < 120 then
    r1, g1, b1 = x, c, 0
  elseif h < 180 then
    r1, g1, b1 = 0, c, x
  elseif h < 240 then
    r1, g1, b1 = 0, x, c
  elseif h < 300 then
    r1, g1, b1 = x, 0, c
  else
    r1, g1, b1 = c, 0, x
  end

  local r = math.floor((r1 + m) * 255 + 0.5)
  local g = math.floor((g1 + m) * 255 + 0.5)
  local b = math.floor((b1 + m) * 255 + 0.5)
  return string.format("#%02x%02x%02x", r, g, b)
end

local function hash_group_name(group_name)
  local hash = 0
  for i = 1, #group_name do
    hash = (hash * 131 + string.byte(group_name, i)) % 360
  end
  return hash
end

local GROUP_COLOR_BUCKETS = 16

local function generate_group_color(group_name)
  -- Deterministic bucketed generation: same group name -> same palette bucket.
  -- Bucketing keeps colors visually separated better than unconstrained random hues.
  local bucket = hash_group_name(group_name) % GROUP_COLOR_BUCKETS
  local hue_step = 360 / GROUP_COLOR_BUCKETS
  local hue = (17 + bucket * hue_step) % 360
  local is_dark_bg = vim.o.background ~= "light"
  local sat = is_dark_bg and 0.72 or 0.68
  local light = is_dark_bg and 0.64 or 0.42
  return hsl_to_hex(hue, sat, light)
end

local function ensure_group(group_name, color)
  local normalized = state.ensure_group(group_name)
  local group = state.groups[normalized]

  -- Group color precedence:
  -- 1) Explicit user color (import/command) wins.
  -- 2) If explicit color is invalid, warn and fall back to generated color.
  -- 3) Any group without color (including "default") gets a deterministic color from group name.
  if color ~= nil then
    local parsed = parse_hex_color(color)
    if parsed ~= nil then
      group.color = parsed
    else
      vim.notify(
        string.format("AnnoGroup: invalid color for '%s' (expected #RRGGBB), using fallback", normalized),
        vim.log.levels.WARN
      )
      if group.color == nil then
        group.color = generate_group_color(normalized)
      end
    end
  elseif group.color == nil then
    group.color = generate_group_color(normalized)
  end
  return normalized
end

local function get_normal_fg()
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = true })
  if not ok or type(normal) ~= "table" then
    return nil
  end
  return normal.fg
end

local function hex_to_rgb(hex)
  local parsed = parse_hex_color(hex)
  if not parsed then
    return nil
  end
  return tonumber(parsed:sub(2, 3), 16), tonumber(parsed:sub(4, 5), 16), tonumber(parsed:sub(6, 7), 16)
end

local function choose_bw_fg_for_bg(hex_bg)
  local r, g, b = hex_to_rgb(hex_bg)
  if not r then
    return nil
  end

  -- Perceived luminance heuristic: choose black text on bright backgrounds,
  -- white text on dark backgrounds.
  local luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
  if luminance > 150 then
    return "#000000"
  end
  return "#ffffff"
end

local function ensure_group_highlight(group_name)
  local normalized = ensure_group(group_name)
  local hl_name = group_hl_name(normalized)
  local group = state.groups[normalized]

  if group and group.color then
    -- `group.color` is treated as a background color to keep annotations visible in
    -- themes where a custom foreground may blend into the editor background.
    local fg = choose_bw_fg_for_bg(group.color)
    if fg == nil then
      fg = get_normal_fg()
    end
    vim.api.nvim_set_hl(0, hl_name, { bg = group.color, fg = fg })
  else
    vim.api.nvim_set_hl(0, hl_name, { link = "AnnoText" })
  end
  return hl_name
end

local function refresh_all_group_highlights()
  -- Rebuild every group highlight from current theme state.
  -- Required after setup() and :colorscheme because linked base groups may change.
  set_highlight(false)
  for group_name, _ in pairs(state.groups) do
    ensure_group_highlight(group_name)
  end
end

local colorscheme_augroup = vim.api.nvim_create_augroup("AnnoColors", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = colorscheme_augroup,
  callback = function()
    refresh_all_group_highlights()
  end,
})

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
--- @param hl_group string
--- @return table
local function build_virt_lines(text, start_line, end_line, hl_group)
  local suffix = build_suffix(start_line, end_line)
  return { { { state.config.prefix .. text .. suffix, hl_group } } }
end

local function has_non_whitespace(text)
  return type(text) == "string" and text:match("%S") ~= nil
end

--- Default formatter used by :AnnoYank.
---
--- @param anno table { bufnr, extmark_id, path, text, start_line, end_line, filetype, code }
--- @return string
local function default_yank_format(anno)
  local header = string.format("@%s#%d-%d", anno.path, anno.start_line, anno.end_line)
  local comment = string.format("Comment: %s", anno.text)
  local lines = { header, comment }

  -- Skip empty/whitespace-only snippets to avoid noisy empty fences in paste output.
  if has_non_whitespace(anno.code) then
    local fence = string.format("```%s", anno.filetype or "")
    table.insert(lines, "")
    table.insert(lines, fence)
    table.insert(lines, anno.code)
    table.insert(lines, "```")
  end

  return table.concat(lines, "\n")
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
--- @param group_name string|nil
local function create_annotation(bufnr, path, start_line, end_line, text, group_name)
  local normalized_group = ensure_group(group_name or state.active_group)
  local hl_group = ensure_group_highlight(normalized_group)

  local id = vim.api.nvim_buf_set_extmark(
    bufnr,
    state.namespace_id,
    start_line - 1,
    0,
    {
      end_row = end_line - 1,
      end_col = 0,
      virt_lines = state.show_virtuals and build_virt_lines(text, start_line, end_line, hl_group) or {},
      virt_lines_above = false,
    }
  )

  state.add(bufnr, {
    bufnr = bufnr,
    extmark_id = id,
    path = path,
    text = text,
    group_name = normalized_group,
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

  local active_group = state.active_group or "default"
  local text = vim.fn.input(string.format("Annotation [%s]: ", active_group))
  if text == "" then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  create_annotation(bufnr, path, line1, line2, text)
  refresh_annotations_quickfix_if_open()
  vim.notify("Annotation added", vim.log.levels.INFO)
end

--- Select the active group for new annotations.
---
--- @param name string
--- @param color string|nil Optional #RRGGBB override
function M.group(name, color)
  -- Active group is a write-time selector: AnnoAdd stores new annotations under this group.
  -- Existing annotations keep their own group_name metadata.
  if type(name) ~= "string" or name == "" then
    vim.notify("AnnoGroup: group name is required", vim.log.levels.ERROR)
    return
  end

  local group_name = ensure_group(name, color)
  state.active_group = group_name
  ensure_group_highlight(group_name)
  vim.notify(string.format("Active annotation group: %s", group_name), vim.log.levels.INFO)
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
  -- setup() should win over colorscheme defaults and recompute group highlights.
  refresh_all_group_highlights()
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

--- Parse and validate grouped annotation JSON payload.
---
--- Schema:
--- {
---   version = 1,
---   groups = {
---     { name = "...", color = "#RRGGBB"|nil, annotations = { ... } }
---   }
--- }
---
--- @param path string
--- @return table|nil groups
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

  if type(data.groups) ~= "table" then
    return nil, "Missing or invalid groups array"
  end

  local groups = {}
  for gi, group in ipairs(data.groups) do
    if type(group) ~= "table" then
      return nil, string.format("groups[%d] must be an object", gi)
    end
    if type(group.name) ~= "string" or group.name == "" then
      return nil, string.format("groups[%d].name must be a non-empty string", gi)
    end
    local color = nil
    if group.color ~= nil then
      color = parse_hex_color(group.color)
      if not color then
        return nil, string.format("groups[%d].color must be #RRGGBB", gi)
      end
    end
    if type(group.annotations) ~= "table" then
      return nil, string.format("groups[%d].annotations must be an array", gi)
    end

    local entries = {}
    for ai, entry in ipairs(group.annotations) do
      if type(entry) ~= "table" then
        return nil, string.format("groups[%d].annotations[%d] must be an object", gi, ai)
      end
      if type(entry.path) ~= "string" or entry.path == "" then
        return nil, string.format("groups[%d].annotations[%d].path must be a non-empty string", gi, ai)
      end
      if type(entry.text) ~= "string" then
        return nil, string.format("groups[%d].annotations[%d].text must be a string", gi, ai)
      end
      if not is_positive_int(entry.start_line) then
        return nil, string.format("groups[%d].annotations[%d].start_line must be a positive integer", gi, ai)
      end
      if not is_positive_int(entry.end_line) then
        return nil, string.format("groups[%d].annotations[%d].end_line must be a positive integer", gi, ai)
      end
      if entry.end_line < entry.start_line then
        return nil, string.format("groups[%d].annotations[%d].end_line must be >= start_line", gi, ai)
      end

      table.insert(entries, {
        path = entry.path,
        start_line = entry.start_line,
        end_line = entry.end_line,
        text = entry.text,
      })
    end

    table.insert(groups, {
      name = group.name,
      color = color,
      annotations = entries,
    })
  end

  return groups, nil
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

--- Build the canonical grouped JSON payload written by :AnnoOutput.
---
--- Shape:
--- {
---   version = 1,
---   groups = {
---     { name = string, color = "#RRGGBB"|nil, annotations = { ... } }
---   }
--- }
---
--- @return table payload
--- @return integer missing_count
local function build_grouped_json_payload()
  local grouped = {}
  local rows, missing = collect_live_annotations()

  for _, row in ipairs(rows) do
    local group_name = row.item.group_name or "default"
    if grouped[group_name] == nil then
      grouped[group_name] = {
        name = group_name,
        color = state.groups[group_name] and state.groups[group_name].color or nil,
        annotations = {},
      }
    end

    table.insert(grouped[group_name].annotations, {
      path = row.item.path,
      start_line = row.ctx.start_line,
      end_line = row.ctx.end_line,
      text = row.item.text,
    })
  end

  local groups = {}
  for _, group in pairs(grouped) do
    table.insert(groups, group)
  end

  table.sort(groups, function(a, b)
    return a.name < b.name
  end)

  return {
    version = 1,
    groups = groups,
  }, missing
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
    local group_name = item.group_name or "default"
    local label = (group_name ~= "default") and ("[" .. group_name .. "] ") or ""
    table.insert(items, {
      filename = item.path,
      lnum = ctx.start_line,
      col = 1,
      text = string.format("%s%s%s", label, item.text, suffix),
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

  local groups, err = parse_anno_json(path)
  if not groups then
    vim.notify("AnnoImport parse error: " .. err, vim.log.levels.ERROR)
    return
  end

  local loaded = 0
  local skipped = 0
  local first_loaded_bufnr = nil
  local first_group_name = nil

  for _, group in ipairs(groups) do
    local group_name = ensure_group(group.name, group.color)
    if first_group_name == nil then
      first_group_name = group_name
    end
    for _, entry in ipairs(group.annotations) do
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
          create_annotation(bufnr, vim.api.nvim_buf_get_name(bufnr), start_line, end_line, entry.text, group_name)

          if not first_loaded_bufnr then
            first_loaded_bufnr = bufnr
          end
          loaded = loaded + 1
        end
      end
    end
  end

  if first_loaded_bufnr and vim.api.nvim_buf_is_valid(first_loaded_bufnr) then
    pcall(vim.cmd, "silent keepalt buffer " .. first_loaded_bufnr)
  end

  -- After import, switch active group to the first imported group so add/edit prompts
  -- reflect the imported context (including "default" when that is what the file defines).
  if first_group_name ~= nil then
    state.active_group = first_group_name
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
  local payload, missing = build_grouped_json_payload()

  local ok_encode, encoded = pcall(encode_json, payload)
  if not ok_encode then
    vim.notify("AnnoOutput error: failed to encode JSON", vim.log.levels.ERROR)
    return
  end

  local output_lines = { encoded }
  -- Keep builtin JSON encoding as the source of truth; pretty-print is best-effort only.
  -- If jq exists and succeeds, we write human-friendly multi-line JSON.
  -- If jq is missing/fails, we still emit valid compact JSON.
  if vim.fn.executable("jq") == 1 then
    local pretty = vim.fn.system({ "jq", "." }, encoded)
    if vim.v.shell_error == 0 and type(pretty) == "string" and pretty ~= "" then
      output_lines = vim.split(pretty, "\n", { plain = true })
    end
  end

  local ok_write = pcall(vim.fn.writefile, output_lines, path)
  if not ok_write then
    vim.notify(string.format("AnnoOutput error: cannot write file: %s", path), vim.log.levels.ERROR)
    return
  end

  local group_count = #payload.groups
  if missing > 0 then
    vim.notify(string.format("Annotations output groups: %d (missing: %d)", group_count, missing), vim.log.levels.WARN)
  else
    vim.notify(string.format("Annotations output groups: %d", group_count), vim.log.levels.INFO)
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
      virt_lines = state.show_virtuals
        and build_virt_lines(item.text, ctx.start_line, ctx.end_line, ensure_group_highlight(item.group_name))
        or {},
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
--- @param group_name string|nil
--- @param on_save fun(new_text: string)
local function open_annotation_editor_float(initial_text, group_name, on_save)
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
      title = string.format(" Annotation [%s] (Enter save, q/Esc cancel) ", group_name or "default"),
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

--- Find tracked annotation anchored at a specific buffer line.
---
--- @param bufnr integer
--- @param line integer 1-based line
--- @return table|nil item
--- @return table|nil ctx
--- @return integer|nil index
local function find_annotation_at_line(bufnr, line)
  local annos = state.annotations[bufnr]
  if not annos or #annos == 0 then
    return nil, nil, nil
  end

  for i = #annos, 1, -1 do
    local item = annos[i]
    local ctx = get_extmark_range(bufnr, item.extmark_id)
    if ctx and ctx.start_line == line then
      return item, ctx, i
    end
  end

  return nil, nil, nil
end

--- Resolve selected quickfix row into a tracked annotation.
---
--- We only operate on quickfix lists created by :AnnoList (title = "Annotations")
--- to avoid mutating unrelated quickfix workflows.
---
--- @return integer|nil bufnr
--- @return table|nil item
--- @return table|nil ctx
--- @return integer|nil index
local function find_selected_qf_annotation()
  local qf = vim.fn.getqflist({ title = 1, idx = 0, items = 1 })
  if not qf or qf.title ~= "Annotations" then
    vim.notify("Anno: current quickfix is not the Annotations list", vim.log.levels.WARN)
    return nil, nil, nil, nil
  end

  local item = qf.items and qf.items[qf.idx]
  if not item then
    vim.notify("Anno: no quickfix item selected", vim.log.levels.INFO)
    return nil, nil, nil, nil
  end

  local bufnr = item.bufnr
  if (not bufnr or bufnr == 0) and item.filename and item.filename ~= "" then
    bufnr = find_or_load_buffer(item.filename)
  end
  if not bufnr or bufnr == 0 then
    vim.notify("Anno: quickfix item has no valid buffer", vim.log.levels.WARN)
    return nil, nil, nil, nil
  end

  return bufnr, find_annotation_at_line(bufnr, item.lnum)
end

--- Edit an annotation anchored at the current cursor line.
---
--- Dual-mode behavior:
--- - In normal file buffers, edits annotation at cursor line.
--- - In quickfix buffers, edits selected entry from the Annotations quickfix list.
---
--- Canonical public API name: `edit`.
function M.edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local item

  if vim.bo[bufnr].buftype == "quickfix" then
    local qf_bufnr
    qf_bufnr, item = find_selected_qf_annotation()
    if not qf_bufnr or not item then
      return
    end
    bufnr = qf_bufnr
  else
    local line = vim.api.nvim_win_get_cursor(0)[1]
    item = find_annotation_at_line(bufnr, line)
    if not item then
      vim.notify("No annotation found at cursor line", vim.log.levels.INFO)
      return
    end
  end

  open_annotation_editor_float(item.text, item.group_name, function(new_text)
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
end

--- Remove an annotation anchored at the current cursor line.
---
--- Dual-mode behavior:
--- - In normal file buffers, removes annotation at cursor line.
--- - In quickfix buffers, removes selected entry from the Annotations quickfix list.
---
--- Canonical public API name: `remove`.
function M.remove()
  local bufnr = vim.api.nvim_get_current_buf()
  local item
  local index

  if vim.bo[bufnr].buftype == "quickfix" then
    local qf_bufnr
    qf_bufnr, item, _, index = find_selected_qf_annotation()
    if not qf_bufnr or not item or not index then
      return
    end
    bufnr = qf_bufnr
  else
    local line = vim.api.nvim_win_get_cursor(0)[1]
    item, _, index = find_annotation_at_line(bufnr, line)
    if not item then
      vim.notify("No annotation found at cursor line", vim.log.levels.INFO)
      return
    end
  end

  vim.api.nvim_buf_del_extmark(bufnr, state.namespace_id, item.extmark_id)
  table.remove(state.annotations[bufnr], index)
  if #state.annotations[bufnr] == 0 then
    state.annotations[bufnr] = nil
  end
  refresh_annotations_quickfix_if_open()
  vim.notify("Annotation removed", vim.log.levels.INFO)
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
