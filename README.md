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
- `lazygit` (optional, for the Lazygit shortcuts)
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
| `<leader>z` | Floating terminal (cwd) |
| `<leader>xx` | Diagnostics on the right |
| `<leader>xX` | Current-buffer diagnostics on the right |
| `<leader>cs` | Symbols on the right |
| `<leader>gg` | Lazygit at the Git root |
| `<leader>gG` | Lazygit at the current working directory |

The Java extra owns `<leader>tt` in Java buffers for running the current test class, so the custom terminal shortcut intentionally lives on `<leader>z`.

## Main customization files

- `lua/plugins/colorscheme.lua` — lavender / pink palette
- `lua/plugins/ui.lua` — dashboard, notifications, tabs, statusline, Noice, Trouble
- `lua/config/options.lua` — only editor options that intentionally differ from LazyVim defaults
- `lua/config/keymaps.lua` — only custom shortcuts that intentionally differ from LazyVim defaults

The setup keeps the core LazyVim starter layout and minimizes overrides so future LazyVim updates are easier to absorb.
