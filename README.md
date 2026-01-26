# anno.nvim

Add annotations in Neovim.

## Features
- Add annotations tied to line ranges
- Print annotations in an LLM-friendly format

## Installation (LazyVim)

```lua
{
  "czheo/anno.nvim",
  keys = {
    { "<leader>aa", "<cmd>AnnoAdd<cr>", desc = "Add annotation" },
    { "<leader>aa", ":AnnoAdd<cr>", desc = "Add range annotation", mode = "v" },
    { "<leader>ad", "<cmd>AnnoRemove<cr>", desc = "Delete annotation" },
    { "<leader>al", "<cmd>AnnoList<cr>", desc = "List annotations" },
    { "<leader>aD", "<cmd>AnnoRemoveAll<cr>", desc = "Delete all annotations" },
  },
}
```
