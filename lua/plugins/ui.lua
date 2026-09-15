return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.preset = opts.dashboard.preset or {}
      opts.dashboard.preset.header = [[

              ୨୧  LazyVim  ୨୧

          ╭──────────────────────╮
          │   good code  ♡       │
          │   calmer days        │
          ╰──────────────────────╯

]]

      opts.notifier = opts.notifier or {}
      opts.notifier.style = "compact"
      opts.notifier.top_down = true

      opts.indent = opts.indent or {}
      opts.indent.indent = vim.tbl_deep_extend("force", opts.indent.indent or {}, { char = "│" })
      opts.indent.scope = vim.tbl_deep_extend("force", opts.indent.scope or {}, { char = "│" })

      opts.input = opts.input or {}
      opts.input.icon = "󰅙 "

      opts.styles = opts.styles or {}
      opts.styles.notification = opts.styles.notification or {}
      opts.styles.notification.border = true
      opts.styles.notification.wo = vim.tbl_deep_extend("force", opts.styles.notification.wo or {}, {
        winblend = 3,
        wrap = false,
      })

      return opts
    end,
  },

  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.always_show_bufferline = true
      opts.options.separator_style = "slant"
      opts.options.show_buffer_close_icons = false
      opts.options.show_close_icon = false
      opts.options.indicator = vim.tbl_deep_extend("force", opts.options.indicator or {}, {
        icon = "▎",
        style = "icon",
      })
      return opts
    end,
  },

  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.component_separators = { left = "·", right = "·" }
      opts.options.section_separators = { left = "", right = "" }

      local function decorate(component, extra)
        local decorated = type(component) == "table" and vim.deepcopy(component) or { component }
        for key, value in pairs(extra) do
          decorated[key] = value
        end
        return decorated
      end

      local left = opts.sections and opts.sections.lualine_a
      if left and left[1] then
        left[1] = decorate(left[1], {
          icon = "♥",
          separator = { left = "", right = "" },
          padding = { left = 1, right = 1 },
        })
      end

      local right = opts.sections and opts.sections.lualine_z
      if right and #right > 0 then
        right[#right] = decorate(right[#right], {
          separator = { left = "", right = "" },
          padding = { left = 1, right = 1 },
        })
      end

      return opts
    end,
  },

  {
    "folke/noice.nvim",
    opts = {
      presets = {
        bottom_search = false,
        lsp_doc_border = true,
      },
      views = {
        cmdline_popup = {
          border = { style = "rounded" },
          position = { row = "38%", col = "50%" },
          size = { width = 60, height = "auto" },
        },
        popupmenu = {
          relative = "editor",
          position = { row = "52%", col = "50%" },
          size = { width = 60, height = 10 },
          border = { style = "rounded" },
        },
      },
    },
  },

  {
    "folke/trouble.nvim",
    opts = function(_, opts)
      opts.modes = opts.modes or {}
      opts.modes.diagnostics = vim.tbl_deep_extend("force", opts.modes.diagnostics or {}, {
        focus = false,
        win = { position = "right", size = 0.28 },
      })
      opts.modes.symbols = vim.tbl_deep_extend("force", opts.modes.symbols or {}, {
        focus = false,
        win = { position = "right", size = 0.28 },
      })
      return opts
    end,
  },
}
