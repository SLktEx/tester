-- These options are loaded before lazy.nvim starts.

-- Snacks is the primary picker in this setup.
vim.g.lazyvim_picker = "snacks"

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.signcolumn = "yes"
vim.opt.scrolloff = 6
vim.opt.sidescrolloff = 8
vim.opt.splitkeep = "screen"
vim.opt.showmode = false
vim.opt.cmdheight = 0
vim.opt.laststatus = 3
vim.opt.pumblend = 4
vim.opt.winblend = 0
vim.opt.wrap = false
vim.opt.smoothscroll = true

-- Let modern floating windows share one rounded visual language.
vim.o.winborder = "rounded"

vim.opt.fillchars:append({
  eob = " ",
  foldopen = "",
  foldclose = "",
  fold = " ",
  foldsep = " ",
  diff = "╱",
})

vim.opt.listchars = {
  tab = "  ",
  trail = "·",
  nbsp = "␣",
  extends = "…",
  precedes = "…",
}
