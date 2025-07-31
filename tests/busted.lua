#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = ".testdata"
vim.env.NVIM_APPNAME = "headless"

load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

local env = require("tests.fixtures.environments.headless")

local spec = env.spec

if vim.env.DEBUG == "1" then
  table.insert(spec, {
    "mfussenegger/nvim-dap",
    dependencies = { "jbyuki/one-small-step-for-vimkind" },
    lazy = false,
    config = function()
      local dap = require("dap")

      dap.configurations.lua = {
        {
          type = "nlua",
          request = "attach",
          name = "Attach to running Neovim instance",
        },
      }

      dap.adapters.nlua = function(callback, config)
        callback({ type = "server", host = config.host or "127.0.0.1", port = config.port or 8086 })
      end
    end,
  })
end

require("lazy.minit").busted({
  spec = spec,
  headless = {
    process = false,
    log = false,
    task = false,
  },
})
