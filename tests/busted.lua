#!/usr/bin/env -S nvim -l

vim.env.LAZY_STDPATH = ".testdata"
vim.env.NVIM_APPNAME = "headless"

load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

require("lazy.minit").busted({
  spec = {
    -- Plugin dependencies for testing
  },
  headless = {
    process = false,
    log = false,
    task = false,
  },
})
