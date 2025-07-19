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
  local has_md_parser, _ = vim.treesitter.language.add("markdown")
  if has_md_parser then
    ok("Markdown parser present")
  else
    error("Missing Markdown parser")
  end

  local has_render_markdown = pcall(require, "render-markdown")
  if has_render_markdown then
    warn("render-markdown.nvim detected. Should not conflict.", {
      "If issues arise, consider disabling its 'checkbox' styling:",
      "`require('render-markdown').setup({checkbox = { enabled = false }})`",
    })
  end

  start("Checkmate configuration")
  local config = require("checkmate.config")
  local checkmate = require("checkmate")

  local validation_ok, validation_err = config.validate_options(checkmate.get_user_opts())
  if validation_ok then
    ok("Configuration is valid")
  else
    error("Configuration validation failed: " .. validation_err)
  end

  if validation_ok then
    if config.options.enabled then
      ok("Checkmate is enabled")
    else
      warn("Checkmate is disabled", {
        "Set `enabled = true` in your config to enable",
      })
    end
  end
end

return M
