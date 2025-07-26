---@type checkmate.TestEnvironment
return {
  spec = {
    {
      "folke/snacks.nvim",
      priority = 1000,
      lazy = false,
      ---@module "snacks"
      ---@type snacks.Config
      opts = {
        bigfile = { enabled = true },
        dashboard = { enabled = false },
        explorer = { enabled = false },
        indent = { enabled = true },
        input = { enabled = true },
        picker = { enabled = true },
        notifier = { enabled = true },
        quickfile = { enabled = true },
        scope = { enabled = false },
        scroll = { enabled = false },
        scratch = {
          enabled = true,
        },
        statuscolumn = { enabled = true },
        words = { enabled = true },
      },
      keys = {
        {
          "<leader>T.",
          function()
            local data = vim.fn.stdpath("data")
            local root = data .. "/snacks/todo"
            vim.fn.mkdir(root, "p")
            local file = root .. "/todo.md"
            print(file)
            ---@diagnostic disable-next-line: missing-fields
            Snacks.scratch.open({
              ft = "markdown",
              file = file,
              autowrite = false,
            })
          end,
          desc = "Toggle Scratch Todo",
        },
      },
    },
  },
  checkmate = require("checkmate_config").with({}),
}
