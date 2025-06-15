#!/usr/bin/env -S nvim -l

-- This file is for manual interactive testing
-- Headless test suite used busted and uses busted.lua and minimal_init.lua
--
-- To create a custom config, edit the environments.lua and then pass it as arg or TEST_ENV

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

local env_name = vim.env.TEST_ENV or "default"
vim.env.LAZY_STDPATH = ".testdata"
vim.env.NVIM_APPNAME = env_name

-- setup vim
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/options.lua"))
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/keymaps.lua"))

package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/?.lua"
local environments = require("environments")
local env = environments.get(env_name)

-- base specs for all environments
local spec = {
  { dir = vim.uv.cwd(), opts = env.checkmate, ft = "markdown" },
}

-- environment-specific specs
vim.list_extend(spec, env.spec or {})

require("lazy.minit").repro({
  spec = spec,
})

if env.config then
  vim.schedule(function()
    env.config()
  end)
end

vim.cmd("edit tests/test.todo.md")
vim.notify("Loaded environment: " .. env_name, vim.log.levels.INFO)
