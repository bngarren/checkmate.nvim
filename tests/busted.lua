#!/usr/bin/env -S nvim -l

-- Set up test environment in an isolated location
vim.env.LAZY_STDPATH = ".testdata"

-- Bootstrap lazy.nvim
load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

-- Setup lazy.nvim with busted and all test dependencies
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
