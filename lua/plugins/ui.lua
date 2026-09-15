return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.dashboard = vim.tbl_deep_extend("force", opts.dashboard or {}, {
        preset = {
          header = [[

              ୨୧  LazyVim  ୨୧

          ╭──────────────────────╮
          │   good code  ♡       │
          │   calmer days        │
          ╰──────────────────────╯

]],
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
            { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            { icon = " ", key = "s", desc = "Restore Session", section = "session" },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
      })

      opts.notifier = vim.tbl_deep_extend("force", opts.notifier or {}, {
        enabled = true,
        style = "compact",
        top_down = true,
      })

      opts.indent = vim.tbl_deep_extend("force", opts.indent or {}, {
        enabled = true,
        indent = { char = "│" },
        scope = { char = "│" },
      })

      opts.input = vim.tbl_deep_extend("force", opts.input or {}, {
        enabled = true,
        icon = "󰅙 ",
      })

      opts.styles = opts.styles or {}
      opts.styles.notification = vim.tbl_deep_extend("force", opts.styles.notification or {}, {
        border = true,
        wo = {
          winblend = 3,
          wrap = false,
        },
      })

      return opts
    end,
  },

  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      opts.options = vim.tbl_deep_extend("force", opts.options or {}, {
        always_show_bufferline = true,
        separator_style = "slant",
        show_buffer_close_icons = false,
        show_close_icon = false,
        diagnostics = "nvim_lsp",
        indicator = {
          icon = "▎",
          style = "icon",
        },
      })
      return opts
    end,
  },

  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      opts.options = vim.tbl_deep_extend("force", opts.options or {}, {
        component_separators = { left = "·", right = "·" },
        section_separators = { left = "", right = "" },
      })

      opts.sections = opts.sections or {}
      opts.sections.lualine_a = {
        {
          "mode",
          icon = "♥",
          separator = { left = "", right = "" },
          padding = { left = 1, right = 1 },
        },
      }
      opts.sections.lualine_z = {
        {
          function()
            return " " .. os.date("%R")
          end,
          separator = { left = "", right = "" },
          padding = { left = 1, right = 1 },
        },
      }
      return opts
    end,
  },

  {
    "folke/noice.nvim",
    opts = {
      presets = {
        bottom_search = false,
        command_palette = true,
        long_message_to_split = true,
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
