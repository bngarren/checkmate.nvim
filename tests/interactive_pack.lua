#!/usr/bin/env -S nvim -l

-- Manual interactive testing using Neovim 0.12+ vim.pack
--
-- Expected launch:
--   make test-interactive-pack TEST_ENV=demo
--
-- The Makefile should set XDG_* paths and NVIM_APPNAME from TEST_ENV before Nvim starts
-- so each test environment has isolated config/data/state/cache.

if vim.fn.has("nvim-0.12") == 0 then
  error("interactive_pack.lua requires Neovim 0.12+ for vim.pack")
end

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
local cwd = vim.fn.getcwd()

package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

local function require_env(name)
  local mod = "fixtures.environments.pack." .. name
  local ok, env = pcall(require, mod)

  if ok then
    return env, name
  end

  if name == "default" then
    error(("Failed to load default environment:\n%s"):format(env))
  end

  vim.print(("Failed to load environment '%s', loading 'default'"):format(name))
  vim.print(env)

  local ok_default, default_env = pcall(require, "fixtures.environments.pack.default")
  if not ok_default then
    error("Failed to load default environment:\n" .. tostring(default_env))
  end

  return default_env, "default"
end

local base = require("fixtures.environments.pack.base")
local env
env, env_name = require_env(env_name)

-- get user config on the runtimepath so setup editor with defaults
local my_config_path = vim.fs.abspath(vim.env.USER_NVIM_CONFIG or "~/.config/nvim")
vim.opt.runtimepath:prepend(my_config_path)
package.path = table.concat({
  my_config_path .. "/lua/?.lua",
  my_config_path .. "/lua/?/init.lua",
  package.path,
}, ";")
dofile(vim.fs.abspath("~/.config/nvim/lua/bngarren/core/init.lua"))

-- Shared test setup
if type(base.setup) == "function" then
  base.setup()
end

-- Environment-specific setup
if type(env.setup) == "function" then
  env.setup()
end

-- local root = vim.fs.root(0, ".git") or cwd
-- vim.opt.runtimepath:prepend(root)
--
-- local checkmate_opts = vim.tbl_deep_extend("force", base.checkmate or {}, env.checkmate or {})
--
-- local ok_checkmate, checkmate = pcall(require, "checkmate")
-- if not ok_checkmate then
--   error("Failed to require local checkmate.nvim: " .. tostring(checkmate))
-- end
--
-- checkmate.setup(checkmate_opts)

-- Post-setup hooks
if type(base.config) == "function" then
  vim.schedule(base.config)
end

if type(env.config) == "function" then
  vim.schedule(env.config)
end

if vim.env.FILE then
  vim.cmd.edit(vim.fn.fnameescape(vim.env.FILE))
elseif env_name == "demo" then
  vim.cmd.edit("tests/fixtures/demo.todo.md")
else
  vim.cmd.edit("tests/fixtures/test.todo.md")
end
