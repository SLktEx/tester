return {
  {
    "Bekaboo/dropbar.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      {
        "<leader>;",
        function()
          require("dropbar.api").pick()
        end,
        desc = "Pick breadcrumb symbol",
      },
      {
        "[;",
        function()
          require("dropbar.api").goto_context_start()
        end,
        desc = "Breadcrumb context start",
      },
      {
        "];",
        function()
          require("dropbar.api").select_next_context()
        end,
        desc = "Next breadcrumb context",
      },
    },
  },
}
