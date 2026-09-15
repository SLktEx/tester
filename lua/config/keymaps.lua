-- Custom keymaps are loaded on the VeryLazy event.
-- Keep this file limited to mappings that intentionally differ from LazyVim defaults.
local map = vim.keymap.set

map("n", "<leader>z", function()
  Snacks.terminal()
end, { desc = "Terminal (cwd)" })
