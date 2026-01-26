# anno.nvim

Add annotations in Neovim.

## Why?
When using coding agents such as Claude Code/Codex, I want to

- open a diff view to see the changes in the code.
- add comments to the code inline to instruct the agents.
- paste the comments back to the agents to continue the work.

In Claude Code/Codex, you can
- `ctrl-G` to call out Neovim, which opens a temp buffer.
- open a file or diff view (e.g. `diffview.nvim`)
- add inline comments `<leader>aa` using this plugin.
- copy all comments `<leader>ay` and paste `p` them back to the temp buffer of coding agents.

![screenshot](screenshot.gif)

## Installation (LazyVim)

```lua
{
  "czheo/anno.nvim",
  keys = {
    { "<leader>aa", "<cmd>AnnoAdd<cr>", desc = "Add annotation" },
    { "<leader>aa", ":AnnoAdd<cr>", desc = "Add range annotation", mode = "v" },
    { "<leader>ad", "<cmd>AnnoRemove<cr>", desc = "Delete annotation" },
    { "<leader>ay", "<cmd>AnnoYank<cr>", desc = "Yank annotations" },
    { "<leader>aD", "<cmd>AnnoRemoveAll<cr>", desc = "Delete all annotations" },
    { "<leader>at", "<cmd>AnnoToggle<cr>", desc = "Show/hide annotations" },
  },
}
```

## Commands
- `:AnnoAdd`
- `:'<,'>AnnoAdd`
- `:AnnoYank`
- `:AnnoRemove`
- `:AnnoToggle`
- `:AnnoRemoveAll`

## Setup

```lua
require("anno").setup({
  highlight = "Todo",
  prefix = "↳ ",
  -- item: { bufnr, extmark_id, path, text }
  -- ctx: { bufnr, start_line, end_line, filetype, code }
  yank_format = function(item, ctx)
    return string.format(
      "@%s#%d-%d\nComment: %s\n\n```%s\n%s\n```",
      item.path,
      ctx.start_line,
      ctx.end_line,
      item.text,
      ctx.filetype or "",
      ctx.code
    )
  end,
})
```
