---@class checkmate.TestEnvironment
---@field spec LazySpec[]
---@field checkmate? checkmate.Config
---@field config? function

local M = {}

package.path = vim.fn.getcwd() .. "/tests/fixtures/?.lua" .. ";" .. package.path

local function merge_env(...)
  ---@type checkmate.TestEnvironment
  local new_env = {
    spec = {},
    ---@diagnostic disable-next-line: missing-fields
    checkmate = {},
    config = function() end,
  }

  local envs = { ... }

  local config_fns = {}

  for _, env in ipairs(envs) do
    new_env.spec = vim.tbl_extend("force", new_env.spec, env.spec or {})
    new_env.checkmate = vim.tbl_deep_extend("force", new_env.checkmate, env.checkmate or {})

    if env.config and type(env.config) == "function" then
      table.insert(config_fns, env.config)
    end
  end

  if not vim.tbl_isempty(config_fns) then
    new_env.config = function()
      for _, fn in ipairs(config_fns) do
        fn()
      end
    end
  end

  return new_env
end

M.default = require("environments.default")
M.snacks = require("environments.snacks")
M.fzf_lua = require("environments.fzf_lua")
M.lua_snip = merge_env(M.snacks, require("environments.lua_snip"))
M.demo = merge_env(M.snacks, require("environments.demo"))
M.try_it = require("environments.try_it")

return M
