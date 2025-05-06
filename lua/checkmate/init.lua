-- main module entry point
-- should handle configuration/setup, define the public API

---@class Checkmate
local M = {}

-- Internal plugin state
local _state = {
  initialized = false, -- Has setup been called?
}

---Configure formatters to play nicely with .todo files (which should be parsed as markdown)
local function setup_formatters()
  -- Setup formatters (currently only for conform.nvim) to use prettier's 'markdown' parser
  -- for the .todo extension
  local has_conform, conform = pcall(require, "conform")
  if has_conform then
    conform.formatters_by_ft.markdown = { "todo_prettier" }

    conform.formatters.todo_prettier = {
      command = "prettier",
      args = function(self, ctx)
        return { "--parser", "markdown" }
      end,
      stdin = true,
      condition = function(self, ctx)
        -- Only apply to files ending in `.todo`
        return ctx.filename and ctx.filename:match("%.todo$")
      end,
    }
  end
end

-- Helper function to check if file matches patterns
-- Note: All pattern matching is case-sensitive.
-- Users should include multiple patterns for case-insensitive matching.
function M.should_activate_for_buffer(bufnr, patterns)
  if not patterns or #patterns == 0 then
    return false -- Don't activate Checkmate if no pattern specified
  end

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)

  -- No filename, can't check pattern
  if not filename or filename == "" then
    return false
  end

  -- Normalize path for consistent matching
  local norm_path = filename:gsub("\\", "/")
  local basename = vim.fn.fnamemodify(norm_path, ":t")

  for _, pattern in ipairs(patterns) do
    -- 1: Exact basename match
    if pattern == basename then
      return true
    end

    -- 2: If pattern has no extension and file has .md extension,
    -- check if pattern matches filename without extension
    if not pattern:match("%.%w+$") and basename:match("%.md$") then
      local basename_no_ext = vim.fn.fnamemodify(basename, ":r")
      if pattern == basename_no_ext then
        return true
      end
    end

    -- 3: For directory patterns - exact path ending match
    if pattern:find("/") then
      -- Check if the path ends with the pattern
      if norm_path:match("/" .. vim.pesc(pattern) .. "$") then
        return true
      end

      -- Special case: If pattern doesn't end with .md and the file has .md extension,
      -- check if adding .md to the pattern would match
      if not pattern:match("%.md$") and norm_path:match("%.md$") then
        if norm_path:match("/" .. vim.pesc(pattern) .. "%.md$") then
          return true
        end
      end
    end

    -- 4: Wildcard matching
    if pattern:find("*") then
      local lua_pattern = vim.pesc(pattern):gsub("%%%*", ".*")

      -- For path patterns with wildcards
      if pattern:find("/") then
        if norm_path:match(lua_pattern .. "$") then
          return true
        end

        -- Try with .md appended if pattern doesn't have extension and file does
        if not pattern:match("%.%w+$") and norm_path:match("%.md$") then
          if norm_path:match(lua_pattern .. "%.md$") then
            return true
          end
        end
      else
        -- For simple filename patterns with wildcards
        if basename:match("^" .. lua_pattern .. "$") then
          return true
        end

        -- If pattern doesn't have extension and file has .md extension,
        -- try to match pattern against filename without extension
        if not pattern:match("%.%w+$") and basename:match("%.md$") then
          local basename_no_ext = vim.fn.fnamemodify(basename, ":r")
          if basename_no_ext:match("^" .. lua_pattern .. "$") then
            return true
          end
        end
      end
    end
  end

  return false
end

---@param opts checkmate.Config?
M.setup = function(opts)
  local config = require("checkmate.config")
  opts = opts or {}

  if _state.initialized then
    M.stop()
  end

  config.setup(opts)

  _state.initialized = true

  -- Setup filetype autocommand
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("checkmate_ft", { clear = true }),
    pattern = "markdown",
    callback = function(event)
      -- Check if this markdown file should activate Checkmate
      if M.should_activate_for_buffer(event.buf, config.options.files) then
        -- Schedule the activation to avoid blocking
        vim.schedule(function()
          -- Load the plugin
          M.start()
          -- Setup this buffer
          require("checkmate.api").setup(event.buf)
        end)
      end
    end,
  })

  return config.options
end

-- Main loading function - loads all plugin components
function M.start()
  local config = require("checkmate.config")

  -- Don't reload if already running
  if config._state.running then
    return
  end

  -- If not enabled in config, don't proceed
  if not config.options.enabled then
    return
  end

  -- Step 1: Initialize logger (independent of all other modules)
  local log = require("checkmate.log")
  log.setup()
  log.debug("Beginning plugin initialization", { module = "init" })

  -- Step 2: Start the configuration module
  config.start()

  -- Step 3: Initialize parser (core functionality, no UI dependencies)
  -- This handles the TS queries that other modules need
  require("checkmate.parser").setup()

  -- Step 4: Set up highlights module (depends on parser)
  require("checkmate.highlights").setup_highlights()

  -- Step 5: Register commands (user-facing features)
  require("checkmate.commands").setup()

  -- Step 6: Setup formatters
  setup_formatters()

  -- Step 7: Set up the linter if enabled (depends on parser)
  if config.options.linter and config.options.linter.enabled ~= false then
    require("checkmate.linter").setup(config.options.linter)
  end

  -- Step 8: Setup module-specific autocommands
  M._setup_autocommands()

  -- Mark as fully loaded
  config._state.running = true

  -- Log successful initialization
  log.info("Checkmate plugin loaded successfully", { module = "init" })
end

-- Sets up all plugin autocommands (beyond the lazy detection ones)
function M._setup_autocommands()
  local augroup = vim.api.nvim_create_augroup("checkmate", { clear = true })

  -- Track active buffers for cleanup
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      local bufnr = args.buf
      require("checkmate.config").unregister_buffer(bufnr)
      -- Reset any API state for this buffer
      require("checkmate.api")._debounced_process_buffer_fns[bufnr] = nil
    end,
  })

  -- Clean up on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop()
    end,
  })
end

-- Shutdown the plugin and clean up
function M.stop()
  local config = require("checkmate.config")
  if not config.is_running() then
    return
  end

  config.stop()

  config._state.running = false

  require("checkmate.log").shutdown()
end

-- PUBLIC API --

---Toggle todo item state at cursor or in visual selection
---
---To set a specific todo item to a target state, use `set_todo_item`
---@param target_state? checkmate.TodoItemState Optional target state ("checked" or "unchecked")
function M.toggle(target_state)
  local api = require("checkmate.api")
  local is_visual = require("checkmate.util").is_visual_mode()

  return api.apply_todo_operation({
    operation = api.toggle_todo_item,
    is_visual = is_visual,
    action_name = "toggle",
    params = { target_state = target_state },
  })
end

---Sets a given todo item to a specific state
---@param todo_item checkmate.TodoItem
---@param target_state checkmate.TodoItemState
function M.set_todo_item(todo_item, target_state)
  local api = require("checkmate.api")
  return api.toggle_todo_item(todo_item, { target_state = target_state })
end

--- Set todo item to checked state
function M.check()
  M.toggle("checked")
end

--- Set todo item to unchecked state
function M.uncheck()
  M.toggle("unchecked")
end

--- Create a new todo item
function M.create()
  require("checkmate.api").create_todo()
end

--- Insert a metadata tag into a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string Value contained in the tag
function M.add_metadata(metadata_name, value)
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local api = require("checkmate.api")
  local meta_config = config.options.metadata[metadata_name]

  if not meta_config then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return
  end

  local is_visual = util.is_visual_mode()

  api.apply_todo_operation({
    operation = api.apply_metadata,
    is_visual = is_visual,
    action_name = "add metadata",
    params = { meta_name = metadata_name, custom_value = value },
  })
end

--- Remove a metadata tag from a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
function M.remove_metadata(metadata_name)
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  api.apply_todo_operation({
    operation = api.remove_metadata,
    is_visual = is_visual,
    action_name = "remove metadata",
    params = { meta_name = metadata_name },
  })
end

function M.remove_all_metadata()
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  api.apply_todo_operation({
    operation = api.remove_all_metadata,
    is_visual = is_visual,
    action_name = "remove all metadata",
  })
end

--- Toggle a metadata tag on/off at the cursor or for each todo in the visual selection
---@param meta_name string Name of the metadata tag (defined in the config)
---@param custom_value string Value contained in tag
function M.toggle_metadata(meta_name, custom_value)
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  return api.apply_todo_operation({
    operation = api.toggle_metadata,
    is_visual = is_visual,
    action_name = "toggle metadata",
    params = { meta_name = meta_name, custom_value = custom_value },
  })
end

--- Lints the current Checkmate buffer according to the plugin's enabled custom linting rules
---
--- This is not intended to be a comprehensive Markdown linter
--- and could interfere with other active Markdown linters.
---
--- The purpose is to catch/warn about a select number of formatting
--- errors (according to CommonMark spec) that could lead to unexpected
--- results when using this plugin.
---
---@param opts? {bufnr?: integer, fix?: boolean} Optional parameters
---@return boolean success Whether lint was successful or failed
---@return table|nil diagnostics Diagnostics table, or nil if failed
function M.lint(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local api = require("checkmate.api")

  if not api.is_valid_buffer(bufnr) then
    return false, nil
  end

  local linter = require("checkmate.linter")
  local log = require("checkmate.log")
  local util = require("checkmate.util")

  local results = linter.lint_buffer(bufnr)

  if #results == 0 then
    util.notify("Linting passed!", vim.log.levels.INFO)
  else
    local msg = string.format("Found %d formatting issues", #results)
    util.notify(msg, vim.log.levels.WARN)
    log.warn(msg, log.levels.WARN)
    for i, issue in ipairs(results) do
      log.warn(string.format("Issue %d, row %d [%s]: %s", i, issue.lnum, issue.severity, issue.message))
    end
  end

  return true, results
end

--- Archive checked todo items to a special section
--- If a parent todo is checked, all its children will be archived regardless of state
--- If a child todo is checked but its parent is not, the child will not be archived
function M.archive()
  local api = require("checkmate.api")
  return api.archive_todos()
end

--- Open debug log
function M.debug_log()
  require("checkmate.log").open()
end

--- Clear debug log
function M.debug_clear()
  require("checkmate.log").clear()
end

--- Inspect todo item at cursor
function M.debug_at_cursor()
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- normalize

  local extmark_id = 9001 -- Arbitrary unique ID for debug highlight

  -- Clear the previous debug highlight (just that one)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)

  local item = parser.get_todo_item_at_position(bufnr, row, col, {
    search = { main_content = true },
  })

  if not item then
    util.notify("No todo item found at cursor", vim.log.levels.INFO)
    return
  end

  local msg = {
    ("Debug called at (0-index): %s:%s"):format(row, col),
    "Todo item at cursor:",
    ("  State: %s"):format(item.state),
    ("  List marker: [%s]"):format(util.get_ts_node_range_string(item.list_marker.node)),
    ("  Todo marker: [%d,%d] → %s"):format(
      item.todo_marker.position.row,
      item.todo_marker.position.col,
      item.todo_marker.text
    ),
    ("  Range: [%d,%d] → [%d,%d]"):format(
      item.range.start.row,
      item.range.start.col,
      item.range["end"].row,
      item.range["end"].col
    ),
    ("  Metadata: %s"):format(vim.inspect(item.metadata)),
  }

  -- Use native vim.notify here as we want to show this regardless of config.options.notify
  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  -- Add debug highlight
  vim.api.nvim_set_hl(0, "CheckmateDebugHighlight", { bg = "#3b3b3b" })

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, item.range.start.row, item.range.start.col, {
    id = extmark_id,
    end_row = item.range["end"].row,
    end_col = item.range["end"].col,
    hl_group = "CheckmateDebugHighlight",
    priority = 9999, -- Ensure it draws on top
  })

  -- Auto-remove highlight after 3 seconds
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)
  end, 3000)
end

--- Print todo map
function M.debug_print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  vim.notify(vim.inspect(sorted_list), vim.log.levels.DEBUG)
end

return M
