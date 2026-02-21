local anno = require("anno")
local state = require("anno.state")

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

local function reset_state()
  for bufnr, _ in pairs(state.annotations) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, state.namespace, 0, -1)
    end
  end
  state.annotations = {}
  state.show_virtuals = true
  state.config.highlight = "Todo"
  state.config.prefix = "↳ "
  state.config.yank_format = nil
end

describe("anno.nvim", function()
  before_each(function()
    reset_state()
  end)

  it("saves annotation ranges to JSON", function()
    local src = vim.fn.tempname() .. ".lua"
    local out = vim.fn.tempname() .. ".json"
    write_file(src, { "line1", "line2", "line3" })

    vim.cmd("edit " .. vim.fn.fnameescape(src))
    local bufnr = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)

    local id = vim.api.nvim_buf_set_extmark(bufnr, state.namespace, 0, 0, {
      end_row = 1,
      end_col = 0,
    })
    state.add(bufnr, {
      bufnr = bufnr,
      extmark_id = id,
      path = path,
      text = "Refactor this",
    })

    anno.save(out)

    local payload = vim.fn.json_decode(table.concat(vim.fn.readfile(out), "\n"))
    assert.are.same(1, payload.version)
    assert.are.same(1, #payload.annotations)

    local entry = payload.annotations[1]
    assert.are.same(path, entry.path)
    assert.are.same(1, entry.start_line)
    assert.are.same(2, entry.end_line)
    assert.are.same("Refactor this", entry.text)
  end)

  it("loads annotations and clamps line range to buffer size", function()
    local src = vim.fn.tempname() .. ".lua"
    local input = vim.fn.tempname() .. ".json"
    write_file(src, { "a", "b", "c" })

    local payload = {
      version = 1,
      annotations = {
        {
          path = src,
          start_line = 2,
          end_line = 999,
          text = "Check this block",
        },
      },
    }
    write_file(input, { vim.fn.json_encode(payload) })

    anno.load(input)

    local bufnr = vim.fn.bufnr(vim.fn.fnamemodify(src, ":p"))
    assert.is_true(bufnr > 0)
    assert.is_truthy(state.annotations[bufnr])
    assert.are.same(1, #state.annotations[bufnr])

    local item = state.annotations[bufnr][1]
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.namespace, item.extmark_id, { details = true })

    assert.are.same("Check this block", item.text)
    assert.are.same(1, mark[1]) -- start line 2 (0-based)
    assert.are.same(2, mark[3].end_row) -- clamped to line 3 (0-based)
  end)

  it("remove_all clears tracked annotations", function()
    local src = vim.fn.tempname() .. ".lua"
    write_file(src, { "line" })
    vim.cmd("edit " .. vim.fn.fnameescape(src))

    local bufnr = vim.api.nvim_get_current_buf()
    local id = vim.api.nvim_buf_set_extmark(bufnr, state.namespace, 0, 0, { end_row = 0, end_col = 0 })
    state.add(bufnr, {
      bufnr = bufnr,
      extmark_id = id,
      path = vim.api.nvim_buf_get_name(bufnr),
      text = "x",
    })

    anno.remove_all()

    assert.are.same(nil, state.annotations[bufnr])
  end)

  it("setup validates option types", function()
    assert.has_error(function()
      anno.setup({ prefix = 123 })
    end, "anno.setup: prefix must be a string")

    assert.has_error(function()
      anno.setup({ yank_format = "bad" })
    end, "anno.setup: yank_format must be a function")

    assert.has_error(function()
      anno.setup("bad")
    end, "anno.setup: opts must be a table")
  end)

  it("yank_format receives one annotation object", function()
    local src = vim.fn.tempname() .. ".lua"
    write_file(src, { "alpha", "beta" })
    vim.cmd("edit " .. vim.fn.fnameescape(src))

    local bufnr = vim.api.nvim_get_current_buf()
    local id = vim.api.nvim_buf_set_extmark(bufnr, state.namespace, 0, 0, {
      end_row = 1,
      end_col = 0,
    })
    state.add(bufnr, {
      bufnr = bufnr,
      extmark_id = id,
      path = vim.api.nvim_buf_get_name(bufnr),
      text = "note",
    })

    local captured = nil
    anno.setup({
      yank_format = function(a)
        captured = a
        return "ok"
      end,
    })

    anno.yank()

    assert.is_truthy(captured)
    assert.are.same("note", captured.text)
    assert.are.same(1, captured.start_line)
    assert.are.same(2, captured.end_line)
    assert.are.same("alpha\nbeta", captured.code)
    assert.are.same("ok", vim.fn.getreg('"'))
  end)
end)
