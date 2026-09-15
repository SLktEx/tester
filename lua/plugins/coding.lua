return {
  {
    "saghen/blink.cmp",
    opts = function(_, opts)
      opts.completion = opts.completion or {}

      opts.completion.menu = vim.tbl_deep_extend("force", opts.completion.menu or {}, {
        border = "rounded",
        min_width = 22,
        max_height = 12,
        scrollbar = false,
        winblend = 2,
      })

      opts.completion.documentation = vim.tbl_deep_extend("force", opts.completion.documentation or {}, {
        auto_show = true,
        auto_show_delay_ms = 150,
        window = {
          border = "rounded",
          winblend = 2,
        },
      })

      opts.signature = vim.tbl_deep_extend("force", opts.signature or {}, {
        enabled = true,
        window = {
          border = "rounded",
          winblend = 2,
        },
      })

      return opts
    end,
  },
}
