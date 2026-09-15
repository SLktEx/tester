-- Custom keymaps are loaded on the VeryLazy event.
local map = vim.keymap.set

map("n", "<leader>tt", function()
  Snacks.terminal()
end, { desc = "Terminal" })

map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle focus=false win.position=right<cr>", {
  desc = "Diagnostics (right)",
})

map("n", "<leader>xX", "<cmd>Trouble diagnostics toggle focus=false filter.buf=0 win.position=right<cr>", {
  desc = "Buffer diagnostics (right)",
})

map("n", "<leader>cs", "<cmd>Trouble symbols toggle focus=false win.position=right<cr>", {
  desc = "Symbols (right)",
})

map("n", "<leader>gg", function()
  Snacks.lazygit()
end, { desc = "Lazygit" })
