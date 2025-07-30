---@class Checkmate
local M = {}

-- Helper module
local H = {}

--- internal

-- save initial user opts for later restarts
local user_opts = {}

M._state = {
  -- initialized is config setup
  initialized = false,
  -- core modules are setup (parser, highlights, linter) and autocmds registered
  running = false,
  active_buffers = {}, -- bufnr -> true
}

local state = M._state

---@param opts checkmate.Config?
---@return boolean success
M.setup = function(opts)
  local config = require("checkmate.config")

  user_opts = opts or {}

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
      error()
    end

    if #config.get_deprecations(user_opts) > 0 then
      vim.notify("Checkmate: deprecated usage. Run `checkhealth checkmate`.", vim.log.levels.WARN)
    end

    M.set_initialized(true)
  end)

  if not success then
    local msg = "Checkmate: Setup failed.\nRun `:checkhealth checkmate` to debug. "
    if err then
      msg = msg .. "\n" .. tostring(err)
    end
    vim.notify(msg, vim.log.levels.ERROR)
    M.reset()
    return false
  end

  if config.options.enabled then
    M.start()
  end

  return true
end

-- spin up logger, parser, highlights, linter, autocmds
function M.start()
  if M.is_running() then
    return
  end

  local config = require("checkmate.config")

  local success, err = pcall(function()
    local log = require("checkmate.log")
    log.setup()

    -- each of these should clear any caches they own
    require("checkmate.parser").setup()
    require("checkmate.highlights").setup_highlights()

    if config.options.linter and config.options.linter.enabled ~= false then
      require("checkmate.linter").setup(config.options.linter)
    end

    M.set_running(true)

    H.setup_autocommands()

    H.setup_existing_markdown_buffers()

    log.info("[main] ✔ Checkmate started successfully")
  end)
  if not success then
    vim.notify("Checkmate: Failed to start: " .. tostring(err), vim.log.levels.ERROR)
    M.stop() -- cleanup partial initialization
  end
end

function M.stop()
  if not M.is_running() then
    return
  end

  local active_buffers = M.get_active_buffer_list()
  local active_buffers_count = M.count_active_buffers()

  -- for every buffer that was active, clear extmarks, diagnostics, keymaps, and autocmds.
  for _, bufnr in ipairs(active_buffers) do
    require("checkmate.api").shutdown(bufnr)
  end

  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_global")
  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_highlights")

  local parser = require("checkmate.parser")
  parser.clear_parser_cache()

  if package.loaded["checkmate.log"] then
    pcall(function()
      local log = require("checkmate.log")
      log.fmt_info("[main] Checkmate stopped, with %d active buffers", active_buffers_count)
      log.shutdown()
    end)
  end

  M.reset()
end

-------------- PUBLIC API --------------

-- Public Types

---@class checkmate.Todo
---@field _todo_item checkmate.TodoItem internal representation
---@field state string Todo state, e.g. "checked", "unchecked", or custom state like "pending". See config `todo_states`
---@field text string First line of the todo
---@field indent number Number of spaces before the list marker
---@field list_marker string List item marker, e.g. `-`, `*`, `+`
---@field todo_marker string Todo marker, e.g. `□`, `✔`
---@field is_checked fun(): boolean Whether todo is checked
---@field metadata string[][] Table of {tag, value} tuples
---@field get_metadata fun(name: string): string?, string? Returns 1. tag, 2. value, if exists
---@field get_parent fun(): checkmate.Todo|nil Returns the parent todo item, or nil

---@class checkmate.MetadataContext
---@field name string Metadata tag name
---@field value string Current metadata value
---@field todo checkmate.Todo Access to todo item data
---@field buffer integer Buffer number

-- Globally disables/deactivates Checkmate for all buffers
function M.disable()
  local cfg = require("checkmate.config")
  cfg.options.enabled = false
  M.stop()
end

-- Starts/activates Checkmate
function M.enable()
  local cfg = require("checkmate.config")
  cfg.options.enabled = true
  M.setup(user_opts)
end

--- Toggle todo item(s) state under cursor or in visual selection
---
--- - If a `target_state` isn't passed, it will toggle between "unchecked" and "checked" states.
--- - If `smart_toggle` is enabled in the config, changed state will be propagated to nearby siblings and parent
--- - To switch to states other than the default unchecked/checked, you can pass a {target_state} or use the `cycle()` API.
--- - To set a _specific_ todo item to a target state (rather than locating todo by cursor/selection as is done here), use `set_todo_item`.
---
---@param target_state? string Optional target state, e.g. "checked", "unchecked", etc. See `checkmate.Config.todo_states`.
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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      if smart_toggle_enabled then
        api.propagate_toggle(ctx, { todo_item }, ctx.get_todo_map(), target_state)
      else
        ctx.add_op(api.toggle_state, {
          {
            id = todo_item.id,
            target_state = target_state or (todo_item.state ~= "checked" and "checked" or "unchecked"),
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
          target_state = target_state or (item.state ~= "checked" and "checked" or "unchecked"),
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

--- Sets a specific todo item to a specific state
---
--- To toggle state of todos under cursor or in linewise selection, use `toggle()`
---
---@param todo_item checkmate.TodoItem Todo item to set state
---@param target_state string Todo state, e.g. "checked", "unchecked", or a custom state like "pending". See `checkmate.Config.todo_states`.
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
      local todo_map = ctx.get_todo_map()
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

--- Change a todo item(s) state to the next or previous state
---
--- - Will act on the todo item under the cursor or all todo items within a visual selection
--- - Refer to docs for `checkmate.Config.todo_states`. If no custom states are defined, this will act similar to `toggle()`, i.e., changing state between "unchecked" and "checked". However, unlike `toggle`, `cycle` will not propagate state changes to nearby todos ("smart toggle") unless `checkmate.Config.smart_toggle.include_cycle` is true.
---
--- {opts}
---   - backward: (boolean) If true, will cycle in reverse
---@param opts? {backward?: boolean}
---@return boolean success
function M.cycle(opts)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local parser = require("checkmate.parser")
  local highlights = require("checkmate.highlights")
  local config = require("checkmate.config")

  opts = opts or {}

  local smart_toggle_enabled = config.options.smart_toggle
    and (config.options.smart_toggle.enabled and config.options.smart_toggle.include_cycle)

  local ctx = transaction.current_context()
  if ctx then
    -- inside a transaction, use cursor position
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      local next_state = api.get_next_todo_state(todo_item.state, opts.backward)
      if smart_toggle_enabled then
        api.propagate_toggle(ctx, { todo_item }, ctx.get_todo_map(), next_state)
      else
        ctx.add_op(api.toggle_state, { {
          id = todo_item.id,
          target_state = next_state,
        } })
      end
    end
    return true
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    local mode_msg = is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  -- the next state will be based on the first item
  local sorted_todo_items = util.get_sorted_todo_list(todo_items)
  local next_state = api.get_next_todo_state(sorted_todo_items[1].item.state, opts.backward)

  transaction.run(bufnr, function(_ctx)
    if smart_toggle_enabled then
      api.propagate_toggle(_ctx, todo_items, todo_map, next_state)
    else
      local operations = {}

      for _, item in ipairs(todo_items) do
        table.insert(operations, {
          id = item.id,
          target_state = next_state,
        })
      end

      if #operations > 0 then
        _ctx.add_op(api.toggle_state, operations)
      end
    end
  end, function()
    highlights.apply_highlighting(bufnr)
  end)

  return true
end

---@class checkmate.CreateOpts
---@field nested? boolean Create as nested/child todo (default: false, normal mode only)
---@field indent? number Absolute indentation in spaces, from the start of line. Only applies when creating new todos below existing lines. When nil: inherits parent's indent for siblings, or parent's indent + 2 for nested todos.
---@field state? string Target todo state (default: "unchecked", or inherits from parent if nested). If the `state` is not defined in config `todo_states` then "unchecked" will be used.

--- Creates a new todo item
---
--- # Behavior by mode:
--- ## Normal mode:
--- - **On non-todo line**: Converts the line to a todo item
--- - **On todo line**: Inserts a new todo below current line
---   - Default: Creates sibling at same indentation level
---   - With `nested = true`: Creates child todo indented 2 spaces
---   - With custom `indent`: Creates todo at specified indentation
---
--- ## Visual mode:
--- - Converts each non-todo line in selection to a todo item
--- - Ignores lines that are already todo items
--- - Options `nested` and `indent` are ignored
---
--- # Examples:
--- ```lua
--- -- Convert current line to todo
--- require('checkmate').create()
---
--- -- Create a child todo below current todo
--- require('checkmate').create({ nested = true })
---
--- -- Create todo with custom state
--- require('checkmate').create({ state = "in_progress" })
---
--- -- Create todo at specific indentation (4 spaces)
--- require('checkmate').create({ indent = 4 })
--- ```
---@param opts? checkmate.CreateOpts
---@return boolean success
function M.create(opts)
  opts = opts or {}
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")

  -- if we’re already inside a transaction, queue a "create_todos" for the current cursor row
  local ctx = transaction.current_context()
  if ctx then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1

    ctx.add_op(api.create_todos, row, row, {
      visual = false,
      nested = opts.nested,
      indent = opts.indent,
      todo_state = opts.state,
    })

    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local is_visual = util.is_visual_mode()

  local start_row, end_row
  if is_visual then
    vim.cmd([[execute "normal! \<Esc>"]])
    -- get the sel start/end row (1-based)
    local mark_start = vim.api.nvim_buf_get_mark(bufnr, "<")
    local mark_end = vim.api.nvim_buf_get_mark(bufnr, ">")
    start_row = mark_start[1] - 1
    end_row = mark_end[1] - 1

    if end_row < start_row then
      start_row, end_row = end_row, start_row
    end

    -- don't nest in visual mode
    opts.nested = false
  else
    local cur = vim.api.nvim_win_get_cursor(0)
    start_row = cur[1] - 1
    end_row = start_row
  end

  if start_row == nil or end_row == nil then
    return false
  end

  transaction.run(bufnr, function(tx_ctx)
    tx_ctx.add_op(api.create_todos, start_row, end_row, {
      visual = is_visual,
      nested = opts.nested,
      indent = opts.indent,
      todo_state = opts.state,
    })
  end, function()
    require("checkmate.highlights").apply_highlighting(bufnr)
  end)

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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.remove_metadata, { { id = todo_item.id, meta_names = { metadata_name } } })
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
      meta_names = { metadata_name },
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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.remove_metadata, { { id = todo_item.id, meta_names = true } })
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
      meta_names = true, -- true means remove all
    })
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.remove_metadata, operations)
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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
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

---Opens a picker to select a new value for the metadata under the cursor
---
---Set `config.ui.preferred_picker` to designate a specific picker implementation
---Otherwise, will attempt to use an installed picker UI plugin, or fallback to native vim.ui.select
function M.select_metadata_value()
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local picker = require("checkmate.metadata.picker")

  picker.open_picker(function(choice, metadata)
    local ctx = transaction.current_context()
    if ctx then
      ctx.add_op(api.set_metadata_value, metadata, choice)
      return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    transaction.run(bufnr, function(_ctx)
      _ctx.add_op(api.set_metadata_value, metadata, choice)
    end, function()
      require("checkmate.highlights").apply_highlighting(bufnr)
    end)
  end)
end

--- Move the cursor to the next metadata tag for the todo item under the cursor, if present
function M.jump_next_metadata()
  local api = require("checkmate.api")
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(false)

  api.move_cursor_to_metadata(bufnr, todo_items[1], false)
end

--- Move the cursor to the previous metadata tag for the todo item under the cursor, if present
function M.jump_previous_metadata()
  local api = require("checkmate.api")
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_items = api.collect_todo_items_from_selection(false)

  api.move_cursor_to_metadata(bufnr, todo_items[1], true)
end

---Returns a `checkmate.Todo` or nil
---Will use the current buffer and cursor pos unless overriden in `opts`
--- - `row` is 0-based
---@param opts? {bufnr?: integer, row?: integer}
---@return checkmate.Todo? todo
function M.get_todo(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local row = opts.row or vim.api.nvim_win_get_cursor(0)[1]

  local todo = require("checkmate.parser").get_todo_item_at_position(bufnr, row, 0)
  if not todo then
    return nil
  end
  return require("checkmate.util").build_todo(todo)
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
    for i, issue in ipairs(results) do
      -- log.warn(string.format("Issue %d, row %d [%s]: %s", i, issue.lnum, issue.severity, issue.message))
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

---------- DEBUGGING API ----------------

local debug_hl = require("checkmate.debug.debug_highlights")
M.debug = {
  ---Add a new highlight
  ---@param range checkmate.Range
  ---@param opts? {timeout?: integer, permanent?: boolean}
  ---@return integer id extmark id
  highlight = function(range, opts)
    return debug_hl.add(range, opts)
  end,
  clear_all_highlights = function()
    debug_hl.clear_all()
  end,
  list_highlights = function()
    return debug_hl.list()
  end,
  ---@param opts? {type?: "floating" | "split"}
  log = function(opts)
    opts = opts or {}
    require("checkmate.log").open({ scratch = opts.type or "floating" })
  end,
  clear_log = function()
    require("checkmate.log").clear()
  end,
}

-- Clears a debug highlight under the cursor
function M.debug.clear_highlight()
  local config = require("checkmate.config")
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, m in ipairs(marks) do
    local id, _, start_col, details = m[1], m[2], m[3], m[4]
    local end_col = details and details.end_col or start_col
    if col - 1 >= start_col and col - 1 < end_col then
      debug_hl.clear(bufnr, id)
      vim.notify("Cleared debug highlight " .. id, vim.log.levels.INFO)
      return
    end
  end
  vim.notify("No debug highlight under cursor", vim.log.levels.WARN)
end

--- Inspect todo item at cursor
function M.debug.at_cursor()
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local item = parser.get_todo_item_at_position(bufnr, row, col)

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

  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  M.debug.highlight(item.range)
end

--- Print todo map (in Snacks scratch buffer or vim.print)
function M.debug.print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  require("checkmate.util").scratch_buf_or_print(sorted_list, { name = "checkmate.nvim todo_map" })
end

-- Print current config (in Snacks scratch buffer or vim.print)
function M.debug.print_config()
  local config = require("checkmate.config")
  require("checkmate.util").scratch_buf_or_print(config.options, { name = "checkmate.nvim config" })
end

----- END API -----

function M.get_user_opts()
  return vim.deepcopy(user_opts)
end

function M.is_initialized()
  return state.initialized
end

function M.set_initialized(value)
  state.initialized = value
end

function M.is_running()
  return state.running
end

function M.set_running(value)
  state.running = value
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
  state.active_buffers = {}
end

---- Helpers ----

function H.setup_autocommands()
  local log = require("checkmate.log")
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
      log.fmt_debug("[autocmd] Filetype = '%s' Bufnr = %d'", event.match, event.buf)
      local cfg = require("checkmate.config").options
      if not (cfg and cfg.enabled) then
        return
      end

      if require("checkmate.file_matcher").should_activate_for_buffer(event.buf, cfg.files) then
        require("checkmate.commands").setup(event.buf)
        require("checkmate.api").setup_buffer(event.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    callback = function(event)
      if event.match ~= "markdown" then
        local bufs = M.get_active_buffer_map()

        if bufs[event.buf] then
          log.fmt_info("[autocmd] Filetype = '%s', turning off Checkmate for bufnr %d", event.match, event.buf)

          local buf = event.buf
          require("checkmate.commands").dispose(buf)
          require("checkmate.api").shutdown(buf)
          M.unregister_buffer(buf)
        end
      end
    end,
  })
end

function H.setup_existing_markdown_buffers()
  local config = require("checkmate.config")
  local log = require("checkmate.log")
  local file_matcher = require("checkmate.file_matcher")

  local buffers = vim.api.nvim_list_bufs()

  local existing_buffers = {}
  for _, bufnr in ipairs(buffers) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].filetype == "markdown"
      and file_matcher.should_activate_for_buffer(bufnr, config.options.files)
    then
      table.insert(existing_buffers, bufnr)
      require("checkmate.api").setup_buffer(bufnr)
    end
  end

  local count = vim.tbl_count(existing_buffers)
  if count > 0 then
    log.fmt_info("[main] %d existing Checkmate buffers found during startup: %s", count, existing_buffers)
  end
end

return M
