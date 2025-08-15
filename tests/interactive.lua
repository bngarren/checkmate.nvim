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

-- add base config to the path so we can reuse
local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path
local base = require("fixtures.environments.base")

local ok, env = pcall(require, "fixtures.environments." .. env_name)
if not ok then
  vim.print(string.format("Failed to load environment '%s', loading 'base'", env_name))
  env = {
    spec = {},
    checkmate = {},
    config = {},
  }
  env_name = "base"
end

vim.env.LAZY_STDPATH = ".testdata"
vim.env.NVIM_APPNAME = env_name

-- base specs for all environments
local spec = base.spec

-- Include nvim-dap and related tooling
if vim.env.DEBUG == "1" then
  local debug_spec = require("bngarren.plugins.debug")
  vim.list_extend(spec, { debug_spec })
end

-- Environment-specific specs
vim.list_extend(spec, env.spec or {})

-- Checkmate config
local root = vim.fs.root(0, ".git")
vim.list_extend(
  spec,
  { { dir = root, opts = vim.tbl_deep_extend("force", base.checkmate, env.checkmate) or {}, ft = "markdown" } }
)

assert(loadfile("tests/lazy_bootstrap.lua"))()

-- setup vim
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/options.lua"))
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/keymaps.lua"))

require("lazy.minit").repro({
  spec = spec,
})

-- Post setup
if base.config and type(base.config) == "function" then
  vim.schedule(function()
    base.config()
  end)
end

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
