local M = {}

function M.check()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error = health.error or health.report_error

  start("Checkmate health check")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10.2") == 1 then
    ok("Using Neovim >= 0.10.2")
  else
    error("Checkmate requires Neovim >= 0.10.2")
  end

  -- Check markdown parser
  local ts_parsers = require("nvim-treesitter.parsers")
  if ts_parsers.has_parser("markdown") then
    ok("Treesitter markdown parser is installed")
  else
    error("Treesitter markdown parser is not installed.")
  end
end

return M
