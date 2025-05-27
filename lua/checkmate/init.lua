-- main module entry point
-- should handle configuration/setup, define the public API

---@class Checkmate
local M = {}

-- Internal plugin state
local _state = {
  initialized = false, -- Has setup been called?
}

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

  -- Step 6: Set up the linter if enabled (depends on parser)
  if config.options.linter and config.options.linter.enabled ~= false then
    require("checkmate.linter").setup(config.options.linter)
  end

  -- Step 7: Setup module-specific autocommands
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
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local highlights = require("checkmate.highlights")

  local profiler = require("checkmate.profiler")
  profiler.start("M.toggle")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If toggle() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.toggle_state, todo_item.id, target_state)
    end
    profiler.stop("M.toggle")
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  transaction.run(bufnr, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.toggle_state, item.id, target_state)
    end
  end, function()
    highlights.apply_highlighting(bufnr)
  end)
  profiler.stop("M.toggle")
  return true
end

---Sets a given todo item to a specific state
---@param todo_item checkmate.TodoItem Todo item to set state
---@param target_state checkmate.TodoItemState
function M.set_todo_item(todo_item, target_state)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")

  if not todo_item then
    return
  end
  local todo_id = todo_item.id

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    ctx.add_op(api.set_todo_item, todo_id, target_state)
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()
  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.set_todo_item, todo_id, target_state)
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
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
---@param value string? Value contained in the tag
function M.add_metadata(metadata_name, value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local meta_props = config.options.metadata[metadata_name]
  if not meta_props then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return
  end

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If add_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.add_metadata, todo_item.id, metadata_name, value)
    end
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return
  end

  -- Begin a transaction
  transaction.run(bufnr, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.add_metadata, item.id, metadata_name, value)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)

    -- Handle cursor jump if configured
    if #todo_items == 1 and meta_props.jump_to_on_insert then
      local item = todo_items[1]
      api._handle_metadata_cursor_jump(bufnr, item, metadata_name, meta_props)
    end
  end)
  return true
end

--- Remove a metadata tag from a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
function M.remove_metadata(metadata_name)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If remove_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.remove_metadata, todo_item.id, metadata_name)
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return
  end

  transaction.run(bufnr, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.remove_metadata, item.id, metadata_name)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

function M.remove_all_metadata()
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If remove_all_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.remove_all_metadata, todo_item.id)
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return
  end

  transaction.run(bufnr, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.remove_all_metadata, item.id)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

--- Toggle a metadata tag on/off at the cursor or for each todo in the visual selection
---@param meta_name string Name of the metadata tag (defined in the config)
---@param custom_value string? (Optional) Value contained in tag. If nil, will attempt to get default value from get_value()
function M.toggle_metadata(meta_name, custom_value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("M.toggle_metadata")

  local ctx = transaction.current_context()
  if ctx then
    -- Queue the operation in the current transaction
    -- If toggle_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.bufnr, cursor[1] - 1, cursor[2], { todo_map = transaction._state.todo_map })
    if todo_item then
      ctx.add_op(api.toggle_metadata, todo_item.id, meta_name, custom_value)
    end
    profiler.stop("M.toggle_metadata")
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return
  end

  transaction.run(bufnr, function(_ctx)
    for _, item in ipairs(todo_items) do
      _ctx.add_op(api.toggle_metadata, item.id, meta_name, custom_value)
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)

  profiler.stop("M.toggle_metadata")
  return true
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

---@class ArchiveOpts
---@field heading {title?: string, level?: integer}

--- Archive checked todo items to a special section
--- Rules:
--- - If a parent todo is checked, all its children will be archived regardless of state
--- - If a child todo is checked but its parent is not, the child will not be archived
---@param opts ArchiveOpts?
function M.archive(opts)
  opts = opts or {}
  local api = require("checkmate.api")
  return api.archive_todos(opts)
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
    ("  ID: %s"):format(item.id),
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
