# Lavender LazyVim

A real LazyVim config that recreates the lavender / dusty-pink editor mockup using actual Neovim plugins.

## What is included

- LazyVim + lazy.nvim
- custom Rosé Pine Moon palette (lavender + dusty pink)
- Snacks picker and explorer
- Snacks dashboard / notifier / terminal
- rounded floating windows
- Bufferline with a softer tab style
- Lualine with pill-like separators
- Noice command / popup UI
- Trouble diagnostics and symbols on the right
- Java extra enabled

## Requirements

- Neovim >= 0.11.2
- Git >= 2.19
- Nerd Font v3+
- `ripgrep`, `fd`, `curl`
- `tree-sitter-cli` + a C compiler
- `lazygit` (optional, for `<leader>gg`)
- a JDK for Java development

## Install

Back up your current config first:

```bash
mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null || true
mv ~/.local/share/nvim ~/.local/share/nvim.bak 2>/dev/null || true
mv ~/.local/state/nvim ~/.local/state/nvim.bak 2>/dev/null || true
mv ~/.cache/nvim ~/.cache/nvim.bak 2>/dev/null || true
```

Clone this repository as your Neovim config:

```bash
git clone https://github.com/SLktEx/tester.git ~/.config/nvim
nvim
```

On first launch, lazy.nvim will install the plugins. Then run:

```vim
:LazyHealth
```

## Useful keys

| Key | Action |
| --- | --- |
| `<leader>e` | Explorer |
| `<leader><space>` | Find files |
| `<leader>/` | Grep |
| `<leader>tt` | Bottom terminal |
| `<leader>xx` | Diagnostics on the right |
| `<leader>xX` | Current-buffer diagnostics on the right |
| `<leader>cs` | Symbols on the right |
| `<leader>gg` | Lazygit |

## Main customization files

- `lua/plugins/colorscheme.lua` — lavender / pink palette
- `lua/plugins/ui.lua` — dashboard, notifications, tabs, statusline, Noice, Trouble
- `lua/config/options.lua` — rounded borders and editor presentation
- `lua/config/keymaps.lua` — layout shortcuts

The setup deliberately keeps the official LazyVim starter structure so future LazyVim updates are easier to absorb.
