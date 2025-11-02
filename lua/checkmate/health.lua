local validate = require("checkmate.config.validate")
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local info = health.info or warn
local error = health.error or health.report_error

local M = {}

function M.check()
  start("checkmate.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.10.2") == 1 then
    ok("Using Neovim >= 0.10.2")
  else
    error("Checkmate requires Neovim >= 0.10.2")
  end

  -- check markdown parser
  -- though neovim includes Markdown by default
  local has_md_parser, _ = vim.treesitter.language.add("markdown")
  if has_md_parser then
    ok("Markdown parser present")
  else
    error("Missing Markdown parser")
  end

  local config = require("checkmate.config")
  local checkmate = require("checkmate")
  local user_opts = checkmate.get_user_opts()

  local validation_ok, validation_errors
  if user_opts and not vim.tbl_isempty(user_opts) then
    validation_ok, validation_errors = validate.validate_options(user_opts)
    if validation_ok then
      ok("Configuration is valid")
    else
      error("Configuration validation failed:", validation_errors)
    end
  end

  if validation_ok then
    -- is checkmate enabled via config
    if config.options.enabled then
      ok("Checkmate is enabled")
    else
      warn("Checkmate is disabled", {
        "Set `enabled = true` in your config to enable",
      })
    end

    if user_opts.style == false then
      warn("Checkmate highlights are disabled (`style` is false)\nIf this is intentional, this is okay.")
    end
  end

  -- WHICH BUFFERS MEET ACTIVATION CRITERIA
  M._buffer_activation_check(user_opts.files or config.get_defaults().files)

  -- DEPRECATIONS
  M._deprecations_check()

  -- COMPATBILITY AND INTEGRATIONS
  M._compatibility_check()
end

function M._deprecations_check()
  local checkmate = require("checkmate")
  local deprecations = require("checkmate.config").get_deprecations(checkmate.get_user_opts())

  if #deprecations > 0 then
    warn("Deprecation warnings:\n" .. table.concat(deprecations, "\n"))
  end
end

---@param files string[] `opts.files` patterns
function M._buffer_activation_check(files)
  local fm = require("checkmate.file_matcher")

  local bufs = vim.api.nvim_list_bufs()
  local matched, unmatched = {}, {}

  local function is_candidate(buf)
    -- listed & loaded buffers
    if not vim.api.nvim_buf_is_loaded(buf) then
      return false
    end
    if vim.fn.buflisted(buf) ~= 1 then
      return false
    end
    if vim.api.nvim_get_current_buf() == buf then
      return false
    end
    -- skip these
    local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
    if vim.list_contains({ "help", "quickfix", "terminal", "prompt" }, bt) then
      return false
    end
    return true
  end

  local function short_name(buf)
    return vim.fn.pathshorten(vim.fn.bufname(buf), 5)
  end

  for _, b in ipairs(bufs) do
    if is_candidate(b) then
      local ok_should, should = pcall(fm.should_activate_for_buffer, b, files)
      local name = short_name(b)
      local line
      if ok_should then
        line = string.format("'%s' (bufnr %d)", name, b)
        if should then
          table.insert(matched, line)
        else
          table.insert(unmatched, line)
        end
      else
        line = string.format("'%s' (bufnr %d) -> error during match check", name, b)
        table.insert(unmatched, line)
      end
    end
  end

  local total = #matched + #unmatched
  if total == 0 then
    health.info("No open valid buffers to evaluate filename match (skipped help/checkhealth/term/quickfix)")
  else
    start("checkmate.nvim [buffer activation check] (ft = 'markdown' and `opts.files` pattern match):")
    for _, m in ipairs(matched) do
      ok(m)
    end
    for _, m in ipairs(unmatched) do
      health.info("[not activated] " .. m)
    end
    if #matched == 0 then
      warn("No buffers active", {
        "Ensure that filetype = 'markdown'",
        "Check that buffer name matches the `opts.files` patterns:\n" .. vim.inspect(files),
      })
    end
  end
end

function M._compatibility_check()
  local function module_loaded(mod)
    return package.loaded[mod] ~= nil
  end

  local checks = {
    {
      name = "render-markdown.nvim",
      module = "render-markdown",
      level = "info",
      lines = {
        "Should not conflict.",
        "If you see issues with checkbox styling, consider:",
        "In `render-markdown` config, setting { checkbox = { enabled = false }}`",
        "More info at https://github.com/bngarren/checkmate.nvim/wiki",
      },
    },
    {
      name = "markview.nvim",
      module = "markview",
      level = "info",
      lines = {
        "Should not conflict.",
        "If you see issues with checkbox styling, consider:",
        "In `markview` config: setting the `markdown_inline.checkboxes` to `{ enabled = false }`",
        "More info at https://github.com/bngarren/checkmate.nvim/wiki",
      },
    },
  }

  local any = false
  for _, spec in pairs(checks) do
    local loaded = module_loaded(spec.module)

    if loaded then
      if not any then
        start("checkmate.nvim [compatibility]")
        any = true
      end

      local header = string.format("[%s] detected", spec.name)

      local level = spec.level or "info"
      local lines = vim
        .iter(spec.lines)
        :map(function(l)
          return "  - " .. l
        end)
        :join("\n")
      if level == "warn" then
        warn(header, spec.lines)
      elseif level == "ok" then
        ok(header .. "\n" .. lines)
      else
        health.info(header .. "\n" .. lines)
      end
    end
  end
end

return M
