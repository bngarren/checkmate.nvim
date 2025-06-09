local M = {}

M.configs = {
  default = {
    spec = {
      --
    },
  },
  snacks = {
    spec = {
      "folke/snacks.nvim",
      priority = 1000,
      lazy = false,
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
        statuscolumn = { enabled = true },
        words = { enabled = true },
      },
    },
  },
}

function M.get(name)
  return M.configs[name] or M.configs.default
end

return M
