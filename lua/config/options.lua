-- These options are loaded before lazy.nvim starts.
-- Keep only values that intentionally differ from LazyVim defaults.

-- Snacks is the primary picker in this setup.
vim.g.lazyvim_picker = "snacks"

vim.opt.scrolloff = 6
vim.opt.cmdheight = 0
vim.opt.pumblend = 4

-- Let modern floating windows share one rounded visual language.
vim.o.winborder = "rounded"

vim.opt.listchars = {
  tab = "  ",
  trail = "·",
  nbsp = "␣",
  extends = "…",
  precedes = "…",
}
