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

-- This function is called by tests to reset the state between test runs
---@param close_buffers boolean? Closes all buffers (default true)
_G.reset_state = function(close_buffers)
  if package.loaded["checkmate"] then
    pcall(function()
      local checkmate = require("checkmate")
      if checkmate._is_running() then
        checkmate._stop()
      end
    end)
  end

  -- closing buffers unless explicitly told not to
  if close_buffers ~= false then
    -- delete all buffers except current
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if bufnr ~= vim.api.nvim_get_current_buf() and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end

    -- replace current buffer with empty one if it has a name
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

  -- clear all checkmate modules from cache
  for key in pairs(package.loaded) do
    if key:match("^checkmate") then
      package.loaded[key] = nil
    end
  end

  _G.checkmate = nil
end
