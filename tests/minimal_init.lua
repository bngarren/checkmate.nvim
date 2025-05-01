-- Set up isolated test environment
local test_dir = vim.fn.expand("%:p:h:h") -- Get the parent directory of the test directory
local test_data_dir = test_dir .. "/.testdata"

-- Override Neovim's data, state, and cache directories to keep tests isolated
for _, dir_name in ipairs({ "data", "state", "cache" }) do
  local path = test_data_dir .. "/" .. dir_name
  vim.fn.mkdir(path, "p")
  vim.env[("XDG_%s_HOME"):format(dir_name:upper())] = path
end

-- Add this plugin to the runtimepath
vim.opt.runtimepath:append(test_dir)

-- Add test dependencies to the runtimepath

-- Disable random plugins that might affect testing
vim.g.loaded_matchparen = 1
vim.g.loaded_matchit = 1
vim.g.loaded_logiPat = 1
vim.g.loaded_rrhelper = 1
vim.g.loaded_netrwPlugin = 1

-- This function can be called by tests to reset the state between test runs
_G.reset_state = function()
  -- Reset any plugin state as needed
  -- Example:
  package.loaded["checkmate.config"] = nil
  package.loaded["checkmate.parser"] = nil
  package.loaded["checkmate.util"] = nil
  package.loaded["checkmate.log"] = nil
  package.loaded["checkmate.api"] = nil

  -- Re-require the main module to reset its state
  return require("checkmate").setup()
end
