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

    M.set_initialized(true)
  end)

  if not success then
    local msg = "Checkmate: Setup failed"
    if err then
      msg = msg .. ": " .. tostring(err)
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

-- spin up parser, highlights, linter, autocmds
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

    log.info("Checkmate plugin started", { module = "init" })
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

  -- for every buffer that was active, clear extmarks, diagnostics, keymaps, and autocmds.
  for _, bufnr in ipairs(active_buffers) do
    require("checkmate.api").shutdown(bufnr)
  end

  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_global")
  pcall(vim.api.nvim_del_augroup_by_name, "checkmate_highlights")

  local parser = require("checkmate.parser")
  parser.todo_map_cache = {}
  parser.clear_pattern_cache()

  if package.loaded["checkmate.log"] then
    pcall(function()
      require("checkmate.log").shutdown()
    end)
  end

  M.reset()
end

-------------- PUBLIC API --------------

-- Public Types

---@class checkmate.Todo
---@field _todo_item checkmate.TodoItem internal representation
---@field state checkmate.TodoItemState
---@field text string First line of the todo
---@field metadata string[][] Table of {tag, value} tuples
---@field is_checked fun(): boolean Whether todo is checked (vs unchecked)
---@field get_metadata fun(name: string): string?, string? Returns 1. tag, 2. value, if exists

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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      if smart_toggle_enabled then
        api.propagate_toggle(ctx, { todo_item }, ctx.get_todo_map(), target_state)
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

--- Creates a new todo item
---
--- # Behavior
--- - In normal mode:
---   - Will convert a line under the cursor to a todo item if it is not one
---   - Will append a new todo item below the current line, making a sibling todo item, that attempts to match the list marker and indentation
--- - In visual mode:
---   - Will convert each line in the selection to a new todo item with the default list marker
---   - Will ignore existing todo items (first line only). If the todo item spans more than one line, the
---   additional lines will be converted to individual todos
---   - Will not append any new todo items even if all lines in the selection are already todo items
---@return boolean success
function M.create()
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")

  -- if we’re already inside a transaction, queue a "create_todos" for the current cursor row
  local ctx = transaction.current_context()
  if ctx then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1

    ctx.add_op(api.create_todos, row, row, false)

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
  else
    local cur = vim.api.nvim_win_get_cursor(0)
    start_row = cur[1] - 1
    end_row = start_row
  end

  if start_row == nil or end_row == nil then
    return false
  end

  transaction.run(bufnr, function(tx_ctx)
    tx_ctx.add_op(api.create_todos, start_row, end_row, is_visual)
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
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
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

---------- DEBUGGING API ----------------

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

  -- Use native vim.notify here as we want to show this regardless of config.options.notify
  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  vim.api.nvim_set_hl(0, "CheckmateDebugHighlight", { bg = "#3b3b3b" })

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, item.range.start.row, item.range.start.col, {
    id = extmark_id,
    end_row = item.range["end"].row,
    end_col = item.range["end"].col,
    hl_group = "CheckmateDebugHighlight",
    priority = 9999,
  })

  -- remove hl after x seconds
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)
  end, 10000)
end

--- Print todo map
function M.debug_print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  vim.notify(vim.inspect(sorted_list), vim.log.levels.DEBUG)
end

function M.debug_extmarks()
  local config = require("checkmate.config")
  local ns = config.ns
  local bufnr = vim.api.nvim_get_current_buf()

  -- 1) Get cursor: {<1-based-row>, <0-based-col>}
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row1, col0 = cursor[1], cursor[2]

  -- 2) Convert to 0-based row for all extmark APIs:
  local r0, c0 = row1 - 1, col0

  -- 3) Fetch *all* extmarks on this line by spanning from col=0 → col=-1.
  --    Since we set overlap=true, we also catch any extmark whose “end_row,end_col”
  --    is on this same line, even if its start was earlier.
  local line_marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    ns,
    { r0, 0 }, -- start at (0-based row, col=0)
    { r0, -1 }, -- end   at (0-based row, “end of line”)
    {
      overlap = true,
      hl_name = true, -- so info.hl_group is returned
      details = true, -- so info.end_row, info.end_col, etc. are returned
    }
  )

  if vim.tbl_isempty(line_marks) then
    print(string.format("🚫 No extmarks found on line %d (0-based).", r0))
    return
  end

  -- 4) Manually filter only those extmarks whose 0-based range
  --    actually covers the cursor‐column c0.
  local hits = {}
  for _, mark in ipairs(line_marks) do
    local id = mark[1] -- extmark_id
    local sr0 = mark[2] -- start_row   (0-based)
    local sc0 = mark[3] -- start_col   (0-based)
    local info = mark[4] or {} -- details table

    -- If details.end_row is nil, treat it as a “point” extmark:
    local er0, ec0 = info.end_row, info.end_col
    if er0 == nil then
      er0, ec0 = sr0, sc0
    end

    -- Only consider extmarks that actually span this line (should be true)
    -- and whose start_col ≤ c0 ≤ end_col.
    if r0 >= sr0 and r0 <= er0 and c0 >= sc0 and c0 <= ec0 then
      table.insert(hits, {
        id = id,
        sr0 = sr0,
        sc0 = sc0,
        er0 = er0,
        ec0 = ec0,
        info = info,
      })
    end
  end

  if vim.tbl_isempty(hits) then
    print(string.format("🚫 No extmarks overlapping cursor (0-based: row=%d, col=%d).", r0, c0))
    return
  end

  -- 5) Print all hits in 0-based form:
  print(string.format("🔍 Extmarks overlapping cursor (0-based: row=%d, col=%d):", r0, c0))
  for _, entry in ipairs(hits) do
    local id = entry.id
    local sr0 = entry.sr0
    local sc0 = entry.sc0
    local er0 = entry.er0
    local ec0 = entry.ec0
    local info = entry.info

    -- Pull out every detail field (all are 0-based when they refer to rows/cols)
    local namespace_id = info.ns_id or nil
    local priority = info.priority or nil
    local right_grav0 = info.right_gravity -- boolean or nil
    local end_grav0 = info.end_right_gravity -- boolean or nil
    local hl_eol0 = info.hl_eol -- boolean or nil
    local group_name = info.hl_group -- string or nil
    local sign_name = info.sign_name -- string or nil

    -- Build a “key=value” list for whatever fields exist:
    local parts = {}
    if group_name then
      table.insert(parts, "hl_group=" .. group_name)
    end
    if sign_name then
      table.insert(parts, "sign_name=" .. sign_name)
    end
    if namespace_id then
      table.insert(parts, "ns_id=" .. namespace_id)
    end
    if priority then
      table.insert(parts, "priority=" .. priority)
    end
    if right_grav0 ~= nil then
      table.insert(parts, "right_gravity=" .. tostring(right_grav0))
    end
    if end_grav0 ~= nil then
      table.insert(parts, "end_right_gravity=" .. tostring(end_grav0))
    end
    if hl_eol0 ~= nil then
      table.insert(parts, "hl_eol=" .. tostring(hl_eol0))
    end

    -- Finally, print the 0-based range {sr0,sc0}→{er0,ec0}:
    table.insert(parts, string.format("range={%d,%d}→{%d,%d}", sr0, sc0, er0, ec0))

    local detail_str = "[" .. table.concat(parts, ", ") .. "]"

    print(string.format(" • extmark %d @ start=(row=%d, col=%d) (0-based) %s", id, sr0, sc0, detail_str))
  end
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

      if require("checkmate.file_matcher").should_activate_for_buffer(event.buf, cfg.files) then
        --  TODO: remove legacy in v0.10+
        require("checkmate.commands").setup(event.buf) -- legacy commands
        require("checkmate.commands_new").setup(event.buf)
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
          local buf = event.buf
          --  TODO: remove legacy in v0.10+
          require("checkmate.commands").dispose(buf) -- legacy
          require("checkmate.commands_new").dispose(buf)
          require("checkmate.api").shutdown(buf)
          M.unregister_buffer(buf)
        end
      end
    end,
  })
end

function H.setup_existing_markdown_buffers()
  local config = require("checkmate.config")
  local file_matcher = require("checkmate.file_matcher")

  local buffers = vim.api.nvim_list_bufs()

  for _, bufnr in ipairs(buffers) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].filetype == "markdown"
      and file_matcher.should_activate_for_buffer(bufnr, config.options.files)
    then
      require("checkmate.api").setup_buffer(bufnr)
    end
  end
end

return M
