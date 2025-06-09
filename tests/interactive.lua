#!/usr/bin/env -S nvim -l

-- disable built-ins that might interfere
for _, m in ipairs({
  "matchparen",
  "matchit",
  "logiPat",
  "rrhelper",
  "netrwPlugin",
}) do
  vim.g["loaded_" .. m] = 1
end

load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

local env_name = _G.arg[1] or vim.env.TEST_ENV or "default"
vim.env.LAZY_STDPATH = ".testdata/interactive/"
vim.env.NVIM_APPNAME = env_name

-- Add tests directory to path for environments
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/?.lua"
local environments = require("environments")
local env = environments.get(env_name)

local spec = {
  { dir = vim.uv.cwd(), ft = "markdown" },
}

-- Add environment-specific specs
vim.list_extend(spec, env.spec or {})

-- Setup for interactive mode
require("lazy.minit").setup({
  spec = spec,
})

-- Apply environment config
if env.config then
  vim.schedule(function()
    env.config()
    vim.notify("Loaded environment: " .. env_name, vim.log.levels.INFO)
  end)
end
