#!/usr/bin/env -S nvim -l

-- This file is for manual interactive testing
-- Headless test suite uses busted.lua and minimal_init.lua
--
-- Custom configs for an interactive test are defined in `fixtures/environments/` (not tracked)
-- A environment exposes:
-- - `specs` - LazySpec
-- - `checkmate` - checkmate config
-- - `config` - a function to run additional config after plugins are loaded

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

local env_name = vim.env.TEST_ENV or "default"
vim.env.LAZY_STDPATH = ".testdata"
vim.env.NVIM_APPNAME = env_name

load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"))()

-- setup vim
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/options.lua"))
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/keymaps.lua"))

package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/fixtures/?/init.lua"
local environments = require("environments")
local env = environments[env_name]

-- base specs for all environments
local spec = {
  { dir = vim.uv.cwd(), opts = env.checkmate or {}, ft = "markdown" },
  {
    "mason-org/mason.nvim",
    opts = {},
  },
  -- Menu
  { "nvzone/volt", lazy = true },
  { "nvzone/menu", lazy = true },
}

-- environment-specific specs
vim.list_extend(spec, env.spec or {})

require("lazy.minit").repro({
  spec = spec,
})

if env.config and type(env.config) == "function" then
  vim.schedule(function()
    env.config()
  end)
end

if env_name == "demo" then
  vim.cmd("edit tests/fixtures/demo.todo.md")
else
  vim.cmd("edit tests/fixtures/test.todo.md")
end
vim.notify("Loaded environment: " .. env_name, vim.log.levels.INFO)
-- vim.notify("data: " .. vim.fn.stdpath("data"))
