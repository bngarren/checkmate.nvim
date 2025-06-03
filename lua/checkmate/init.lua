---@class Checkmate
local M = {}

local state = {
  initialized = false,
  running = false,
  setup_callbacks = {},
  active_buffers = {}, -- bufnr -> true
}

function M.is_initialized()
  return state.initialized
end

function M.set_initialized(value)
  state.initialized = value

  -- run cb's after setup done
  if value and #state.setup_callbacks > 0 then
    local callbacks = state.setup_callbacks
    state.setup_callbacks = {}
    for _, callback in ipairs(callbacks) do
      vim.schedule(callback)
    end
  end
end

function M.is_running()
  return state.running
end

function M.set_running(value)
  state.running = value
end

function M.on_initialized(callback)
  if state.initialized then
    callback()
  else
    -- queue it
    table.insert(state.setup_callbacks, callback)
  end
end

function M.register_buffer(bufnr)
  state.active_buffers[bufnr] = true
end

function M.unregister_buffer(bufnr)
  state.active_buffers[bufnr] = nil
end

function M.is_buffer_active(bufnr)
  return state.active_buffers[bufnr] == true
end

-- Returns array of buffer numbers
function M.get_active_buffer_list()
  local buffers = {}
  for bufnr in pairs(state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(buffers, bufnr)
    else
      state.active_buffers[bufnr] = nil
    end
  end
  return buffers
end

-- Returns hash table of bufnr -> true
function M.get_active_buffer_map()
  local buffers = {}
  for bufnr in pairs(state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      buffers[bufnr] = true
    else
      state.active_buffers[bufnr] = nil
    end
  end
  return buffers
end

-- Convenience function that returns count
function M.count_active_buffers()
  local count = 0
  for bufnr in pairs(state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      count = count + 1
    else
      state.active_buffers[bufnr] = nil
    end
  end
  return count
end

function M.reset()
  state.initialized = false
  state.running = false
  state.setup_callbacks = {}
  state.active_buffers = {}
end

-- Checks if the file matches the given pattern(s)
-- Note: All pattern matching is case-sensitive.
-- Users should include multiple patterns for case-insensitive matching.
function M.should_activate_for_buffer(bufnr, patterns)
  if not patterns or #patterns == 0 then
    return false
  end

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local filename = vim.api.nvim_buf_get_name(bufnr)
  if not filename or filename == "" then
    return false
  end

  -- Normalize path for consistent matching
  local norm_filepath = filename:gsub("\\", "/")
  local basename = vim.fn.fnamemodify(norm_filepath, ":t")

  for _, pattern in ipairs(patterns) do
    -- pattern matches exactly ,easy
    if pattern == basename then
      return true
    end

    -- pattern has no extension, but matches .md files
    if not pattern:match("%.%w+$") and basename:match("%.md$") then
      local basename_no_ext = vim.fn.fnamemodify(basename, ":r")
      if pattern == basename_no_ext then
        return true
      end
    end

    -- for directory patterns
    if pattern:find("/") then
      if norm_filepath:match("/" .. vim.pesc(pattern) .. "$") then
        return true
      end

      -- directory pattern has no extension, but matches .md files
      if not pattern:match("%.md$") and norm_filepath:match("%.md$") then
        if norm_filepath:match("/" .. vim.pesc(pattern) .. "%.md$") then
          return true
        end
      end
    end

    -- Wildcard matching
    if pattern:find("*") then
      local lua_pattern = vim.pesc(pattern):gsub("%%%*", ".*")

      if pattern:find("/") then
        if norm_filepath:match(lua_pattern .. "$") then
          return true
        end

        -- try with .md added if pattern doesn't have extension and file does
        if not pattern:match("%.%w+$") and norm_filepath:match("%.md$") then
          if norm_filepath:match(lua_pattern .. "%.md$") then
            return true
          end
        end
      else
        -- simple filename patterns with wildcards
        if basename:match("^" .. lua_pattern .. "$") then
          return true
        end

        -- if pattern doesn't have extension and file has .md extension,
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
---@return boolean success
M.setup = function(opts)
  local config = require("checkmate.config")

  -- reload if config has changed
  if M.is_initialized() then
    local current_config = config.options

    if opts and not vim.deep_equal(opts, current_config) then
      M.stop()
    else
      return true
    end
  end

  local success, err = pcall(function()
    if M.is_running() then
      M.stop()
    end

    local cfg = config.setup(opts or {})
    if vim.tbl_isempty(cfg) then
      error("config setup failed")
    end

    M.set_initialized(true)

    if cfg.enabled then
      M.start()
    end
  end)

  if not success then
    vim.notify("Checkmate: Setup failed: " .. tostring(err), vim.log.levels.ERROR)
    M.reset()
    return false
  end

  return true
end

-- spin up parser, highlights, commands, linter, autocmds
function M.start()
  if M.is_running() then
    return
  end

  local config = require("checkmate.config")
  if not config.options.enabled then
    return
  end

  local success, err = pcall(function()
    local log = require("checkmate.log")
    log.setup()

    -- each of these should clear any caches they own
    require("checkmate.parser").setup()
    require("checkmate.highlights").setup_highlights()
    if config.options.linter and config.options.linter.enabled ~= false then
      require("checkmate.linter").setup(config.options.linter)
    end

    M._setup_autocommands()

    M.set_running(true)

    M._setup_existing_markdown_buffers()

    log.info("Checkmate plugin started", { module = "init" })
  end)
  if not success then
    vim.notify("Checkmate: Failed to start: " .. tostring(err), vim.log.levels.ERROR)
    M.stop() -- cleanup partial initialization
  end
end

function M._setup_autocommands()
  local augroup = vim.api.nvim_create_augroup("checkmate_global", { clear = true })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop()
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "markdown",
    callback = function(event)
      local cfg = require("checkmate.config").options
      if not (cfg and cfg.enabled) then
        return
      end

      if require("checkmate").should_activate_for_buffer(event.buf, cfg.files) then
        require("checkmate.commands").setup(event.buf)
        require("checkmate.api").setup_buffer(event.buf)
      end
    end,
  })
end

function M.stop()
  if not M.is_running() then
    return
  end

  local config = require("checkmate.config")

  local active_buffers = M.get_active_buffer_list()

  -- for every buffer that was active, clear extmarks, diagnostics, keymaps, and autocmds.
  for bufnr, _ in pairs(active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- clear extmarks
      vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, config.ns_todos, 0, -1)

      if package.loaded["checkmate.linter"] then
        pcall(function()
          require("checkmate.linter").disable(bufnr)
        end)
      end

      local group_name = "CheckmateApiGroup_" .. bufnr
      pcall(function()
        vim.api.nvim_del_augroup_by_name(group_name)
      end)

      vim.b[bufnr].checkmate_setup_complete = nil
      vim.b[bufnr].checkmate_autocmds_setup = nil

      local api = require("checkmate.api")
      if api._debounced_process_buffer_fns and api._debounced_process_buffer_fns[bufnr] then
        api._debounced_process_buffer_fns[bufnr] = nil
      end
    end
  end

  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_ft")
  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_global")
  pcall(vim.api.nvim_del_augroup_by_name, "CheckmateHighlighting")

  require("checkmate.parser").todo_map_cache = {}

  if package.loaded["checkmate.log"] then
    pcall(function()
      require("checkmate.log").shutdown()
    end)
  end

  M.reset()
end

function M._setup_existing_markdown_buffers()
  local config = require("checkmate.config")

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].filetype == "markdown"
      and M.should_activate_for_buffer(bufnr, config.options.files)
    then
      require("checkmate.api").setup_buffer(bufnr)
    end
  end
end

-- PUBLIC API --

---Toggle todo item(s) state under cursor or in visual selection
---
---To set a specific todo item to a target state, use `set_todo_item`
---@param target_state? checkmate.TodoItemState Optional target state ("checked" or "unchecked")
---@return boolean success
function M.toggle(target_state)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local highlights = require("checkmate.highlights")
  local config = require("checkmate.config")

  local profiler = require("checkmate.profiler")
  profiler.start("M.toggle")

  local smart_toggle_enabled = config.options.smart_toggle and config.options.smart_toggle.enabled

  local ctx = transaction.current_context()
  if ctx then
    -- queue the operation in the current transaction
    -- If toggle() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item = parser.get_todo_item_at_position(
      ctx.get_buf(),
      cursor[1] - 1,
      cursor[2],
      { todo_map = transaction._state.todo_map }
    )
    if todo_item then
      if smart_toggle_enabled then
        api.propagate_toggle(ctx, { todo_item }, transaction._state.todo_map, target_state)
      else
        ctx.add_op(api.toggle_state, {
          {
            id = todo_item.id,
            target_state = target_state or (todo_item.state == "unchecked" and "checked" or "unchecked"),
          },
        })
      end
    end
    profiler.stop("M.toggle")
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  transaction.run(bufnr, function(_ctx)
    if smart_toggle_enabled then
      api.propagate_toggle(_ctx, todo_items, todo_map, target_state)
    else
      local operations = {}

      for _, item in ipairs(todo_items) do
        table.insert(operations, {
          id = item.id,
          target_state = target_state or (item.state == "unchecked" and "checked" or "unchecked"),
        })
      end

      if #operations > 0 then
        _ctx.add_op(api.toggle_state, operations)
      end
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
---@return boolean success
function M.set_todo_item(todo_item, target_state)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")

  if not todo_item then
    return false
  end

  local todo_id = todo_item.id
  local smart_toggle_enabled = config.options.smart_toggle and config.options.smart_toggle.enabled

  local ctx = transaction.current_context()
  if ctx then
    if smart_toggle_enabled then
      local todo_map = transaction._state.todo_map
      api.propagate_toggle(ctx, { todo_item }, todo_map, target_state)
    else
      ctx.add_op(api.toggle_state, { {
        id = todo_id,
        target_state = target_state,
      } })
    end
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- if smart toggle is enabled, we need the todo_map
  local todo_map = smart_toggle_enabled and parser.get_todo_map(bufnr) or nil

  transaction.run(bufnr, function(_ctx)
    if smart_toggle_enabled and todo_map then
      api.propagate_toggle(_ctx, { todo_item }, todo_map, target_state)
    else
      _ctx.add_op(api.toggle_state, { {
        id = todo_id,
        target_state = target_state,
      } })
    end
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)

  return true
end

--- Set todo item to checked state
---
--- See `toggle()`
---@return boolean success
function M.check()
  return M.toggle("checked")
end

--- Set todo item to unchecked state
---
--- See `toggle()`
---@return boolean success
function M.uncheck()
  return M.toggle("unchecked")
end

--- Create a new todo item
---@returns boolean success
function M.create()
  require("checkmate.api").create_todo()
  return true
end

--- Insert a metadata tag into a todo item(s) under the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string? Value contained in the tag
---@return boolean success
function M.add_metadata(metadata_name, value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local meta_props = config.options.metadata[metadata_name]
  if not meta_props then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return false
  end

  local ctx = transaction.current_context()
  if ctx then
    -- if add_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item = parser.get_todo_item_at_position(
      ctx.get_buf(),
      cursor[1] - 1,
      cursor[2],
      { todo_map = transaction._state.todo_map }
    )
    if todo_item then
      ctx.add_op(api.add_metadata, { { id = todo_item.id, meta_name = metadata_name, meta_value = value } })
    end
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  local operations = {}
  for _, item in ipairs(todo_items) do
    table.insert(operations, {
      id = item.id,
      meta_name = metadata_name,
      meta_value = value,
    })
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.add_metadata, operations)
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

--- Remove a metadata tag from a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@return boolean success
function M.remove_metadata(metadata_name)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- if remove_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item = parser.get_todo_item_at_position(
      ctx.get_buf(),
      cursor[1] - 1,
      cursor[2],
      { todo_map = transaction._state.todo_map }
    )
    if todo_item then
      ctx.add_op(api.remove_metadata, { { id = todo_item.id, meta_name = metadata_name } })
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  local operations = {}
  for _, item in ipairs(todo_items) do
    table.insert(operations, {
      id = item.id,
      meta_name = metadata_name,
    })
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.remove_metadata, operations)
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

---Removes all metadata from a todo item(s) under the cursor or include in visual selection
---@return boolean success
function M.remove_all_metadata()
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")

  local ctx = transaction.current_context()
  if ctx then
    -- if remove_all_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item = parser.get_todo_item_at_position(
      ctx.get_buf(),
      cursor[1] - 1,
      cursor[2],
      { todo_map = transaction._state.todo_map }
    )
    if todo_item then
      ctx.add_op(api.remove_all_metadata, { todo_item.id })
    end
    return true
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  local ids = vim.tbl_map(function(item)
    return item.id
  end, todo_items)

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.remove_all_metadata, ids)
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)
  return true
end

--- Toggle a metadata tag on/off for todo item under the cursor or for each todo in the visual selection
---@param meta_name string Name of the metadata tag (defined in the config)
---@param custom_value string? (Optional) Value contained in tag. If nil, will attempt to get default value from get_value()
---@return boolean success
function M.toggle_metadata(meta_name, custom_value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("M.toggle_metadata")

  local ctx = transaction.current_context()
  if ctx then
    -- if toggle_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item = parser.get_todo_item_at_position(
      ctx.get_buf(),
      cursor[1] - 1,
      cursor[2],
      { todo_map = transaction._state.todo_map }
    )
    if todo_item then
      ctx.add_op(api.toggle_metadata, { { id = todo_item.id, meta_name = meta_name, custom_value = custom_value } })
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
    return false
  end

  local operations = {}
  for _, item in ipairs(todo_items) do
    table.insert(operations, {
      id = item.id,
      meta_name = meta_name,
      custom_value = custom_value,
    })
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.toggle_metadata, operations)
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
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- normalize

  local extmark_id = 9001 -- arbitrary unique ID for debug highlight

  -- clear previous
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
