-- This minimal init file is used for headless testing.
-- For booting up an interactive Neovim use tests/interactive.lua

-- Disable plugins that might affect testing
vim.g.loaded_matchparen = 1
vim.g.loaded_matchit = 1
vim.g.loaded_logiPat = 1
vim.g.loaded_rrhelper = 1
vim.g.loaded_netrwPlugin = 1

-- DEBUG enable
if vim.env.DEBUG == "1" then
  local ok, res = pcall(function()
    -- blocking: will freeze the instance until a client is connected
    require("osv").launch({ host = "127.0.0.1", port = 8086, blocking = true })
  end)
  if not ok then
    vim.notify("Failed to launch debug. " .. tostring(res))
  else
    print("DAP listening on 127.0.0.1:8086 – waiting for client to attach…")
  end
end

-- This function can be called by tests to reset the state between test runs
---@param close_buffers boolean? Closes all buffers (default true)
_G.reset_state = function(close_buffers)
  if package.loaded["checkmate"] then
    pcall(function()
      local checkmate = require("checkmate")
      if checkmate.is_running() then
        checkmate.stop()
      end
    end)
  end

  -- closing buffers unless explicitly told not to
  if close_buffers ~= false then
    local buffers = vim.api.nvim_list_bufs()
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        -- force delete all buffers except the current one
        if bufnr ~= vim.api.nvim_get_current_buf() then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end

    local current = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(current)
    if name ~= "" then
      vim.cmd("enew")
      pcall(vim.api.nvim_buf_delete, current, { force = true })
    end
  end

  -- clear pending callbacks
  vim.schedule(function() end)
  vim.wait(10)

  local modules = {
    "checkmate",
    "checkmate.config",
    "checkmate.parser",
    "checkmate.util",
    "checkmate.log",
    "checkmate.api",
    "checkmate.commands",
    "checkmate.highlights",
    "checkmate.linter",
    "checkmate.theme",
    "checkmate.transaction",
    "checkmate.profiler",
    "checkmate.init",
  }

  for _, mod in ipairs(modules) do
    package.loaded[mod] = nil
  end

  if _G.checkmate then
    _G.checkmate = nil
  end

  collectgarbage("collect")

  vim.wait(10)
end
