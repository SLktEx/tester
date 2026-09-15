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
- `tree-sitter-cli >= 0.26.1` + a C compiler
- `lazygit` (optional, for the Lazygit shortcuts)
- a JDK for Java development

`nvim-treesitter` requires `tree-sitter-cli >= 0.26.1`, including the compatibility commit LazyVim currently uses on Neovim 0.11. Distribution packages can lag behind that version, so check `tree-sitter --version` if parser installation or `:checkhealth` reports a problem.

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

On first launch, lazy.nvim installs the plugins. Then run:

```vim
:LazyHealth
```

## Plugin versions and updates

`lazy-lock.json` records the resolved plugin commits so an existing known-good set can be restored. It does not make a first install completely self-contained: Git/remotes, Neovim, external tools, Mason packages, parsers, compilers, and language runtimes still come from outside the lockfile.

Useful lazy.nvim commands:

```vim
:Lazy restore
:Lazy update
```

- `:Lazy restore` restores plugins to the commits recorded in `lazy-lock.json`.
- `:Lazy update` updates plugins and refreshes the lockfile.
- LazyVim extras are tracked in `lazyvim.json` and can be managed with `:LazyExtras`.

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

The Java extra does not unconditionally own `<leader>tt`. LazyVim registers its Java buffer-local `<leader>tt` (`Run All Test`) only after `jdtls` attaches and the DAP / Java debug / Java test pieces it depends on are available. This config enables the Java extra but does not enable LazyVim's DAP core extra, so a fresh install does not reserve `<leader>tt` for Java tests. The custom terminal shortcut intentionally remains on `<leader>z`.

## Main customization files

- `lazyvim.json` — LazyVim extras managed through the same mechanism as `:LazyExtras`
- `lua/plugins/colorscheme.lua` — lavender / pink palette
- `lua/plugins/ui.lua` — dashboard, notifications, tabs, statusline, Noice, Trouble
- `lua/config/options.lua` — only editor options that intentionally differ from LazyVim defaults
- `lua/config/keymaps.lua` — only custom shortcuts that intentionally differ from LazyVim defaults

The setup keeps the core LazyVim starter layout and minimizes overrides so future LazyVim updates are easier to absorb.
