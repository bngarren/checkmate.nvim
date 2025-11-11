---@class Checkmate
local M = {}
local H = {}

-- ================================================================================
-- ------------ CHECKMATE PUBLIC API --------------
-- ================================================================================

---@class checkmate.Todo
---@field bufnr integer Source buffer of Todo
---@field row integer 0-based row of the todo (the line containing the list marker and todo marker)
---@field state string Todo state, e.g. "checked", "unchecked", or custom state like "pending". See config `todo_states`
---@field text string First line of the todo
---@field indent number Number of spaces before the list marker
---@field list_marker string List item marker, e.g. `-`, `*`, `+`
---@field todo_marker string Todo marker, e.g. `□`, `✔`
---@field is_checked fun(): boolean Whether todo state is explicitly "checked". If custom states are used, you may want to use `is_complete()`.
---@field is_unchecked fun(): boolean Whether todo state is explicitly "unchecked". If custom states are used, you may want to use `is_incomplete()`.
---@field is_complete fun(): boolean Whether todo state type is "complete" (this includes "checked" state, by default)
---@field is_incomplete fun(): boolean Whether todo state type is "incomplete" (this includes "unchecked" state, by default)
---@field is_inactive fun(): boolean Whether todo state type is "inactive" (may be used by custom todo states)
---@field metadata string[][] Table of {tag, value} tuples
---@field get_metadata fun(name: string): string?, string? Returns 1. tag, 2. value, if exists
---@field get_parent fun(): checkmate.Todo|nil Returns the parent todo item, or nil
---@field _get_todo_item fun(): checkmate.TodoItem Returns the todo_item internal representation (use at your own risk, not guaranteed to be stable)

---@class checkmate.MetadataContext
---@field name string Metadata tag name
---@field value string Current metadata value
---@field todo checkmate.Todo Access to todo item data
---@field buffer integer Buffer number

---@enum checkmate.Picker
M.PICKERS = {
  TELESCOPE = "telescope",
  SNACKS = "snacks",
  MINI = "mini",
  NATIVE = "native",
}

---Configures a per-call picker backend and customization
---
---A "picker" is resolved in the following order (highest to lowest priority):
---  1. `picker` field - forces a specific picker backend for this call
---  2. global `config.ui.picker` preference
---  3. auto-detection - tries telescope -> snacks -> mini -> native
---
---Checkmate uses reasonable defaults for each builtin picker implementation. You can
---merge your own opts (overriding these specific fields via deep extend) by using a generic `opts` table, or
---a backend-specific table keyed by the picker name.
---
---Note: A backend-specific table field will override the same key in the `opts` table if both are passed.
---
---**Example**:
---```lua
---  picker_opts = {
---    picker = "snacks",  -- Force snacks.picker
---    snacks = {
---      layout = { preset = "sidebar" }  -- Only override preset, keep other checkmate defaults
---    }
---  }
---```
---
---@class checkmate.PickerOpts
---@field picker? checkmate.Picker Force a specific picker backend
---@field opts? table<string, any> Generic table that will be merged with current backend
---@field telescope? table<string, any> Telescope.pickers.new opts
---@field snacks? table<string, any> Snacks.pickers.pick opts
---@field mini? table<string, any> mini.pick.start opts
---@field native? table<string, any> vim.ui.select opts

-- Globally disables/deactivates Checkmate for all buffers
---@return nil
function M.disable()
  local cfg = require("checkmate.config")
  cfg.options.enabled = false
  M.stop()
end

-- Starts/activates Checkmate
---@return nil
function M.enable()
  local cfg = require("checkmate.config")
  cfg.options.enabled = true
  M.setup(H.state.user_opts)
end

--- Toggle todo item(s) state under cursor or per todo in visual selection
---
--- - If a `target_state` isn't passed, it will toggle between "unchecked" and "checked" states.
--- - If `smart_toggle` is enabled in the config, changed state will be propagated to nearby siblings and parent.
--- - To switch to states other than the default unchecked/checked, you can pass a {target_state} or use the `cycle()` API.
--- - To set a _specific_ todo to a target state (rather than locating todo by cursor/selection as is done here), use `set_todo_state`.
---   - To get a `checkmate.Todo` from the buffer, use `get_todo()`
---
---@param target_state? string Optional target state, e.g. "checked", "unchecked", etc. See `checkmate.Config.todo_states`.
---@return boolean success True if operation was performed or queued
function M.toggle(target_state)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local log = require("checkmate.log")

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
      profiler.stop("M.toggle")
      return true
    else
      profiler.stop("M.toggle")
      return false
    end
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `toggle` on invalid buffer")
    return false
  end

  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
    profiler.stop("M.toggle")
    return false
  end

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
  end)
  profiler.stop("M.toggle")
  return true
end

--- Set a todo to a specific state
---
--- To toggle state of todos under cursor or in linewise selection, use `toggle()`
---
---@param todo checkmate.Todo Todo to modify
---@param target_state string Todo state, e.g. "checked", "unchecked", or a custom state like "pending". See `checkmate.Config.todo_states`.
---@return boolean success True if operation was performed or queued, false if todo/state is invalid
function M.set_todo_state(todo, target_state)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")

  if not todo then
    log.fmt_error("[main] bad `todo` received in `set_todo_state`:\n %s", vim.inspect(todo))
    return false
  end

  local state_def = config.options.todo_states[target_state]
  if not state_def then
    log.fmt_warn(
      "[main] invalid todo state (`target_state`) received in `set_todo_state()` for\n todo on row %d.\n'%s' does not exist in config.",
      todo.row,
      target_state
    )
    return false
  end

  local todo_id = todo._get_todo_item().id
  local smart_toggle_enabled = config.options.smart_toggle and config.options.smart_toggle.enabled

  local ctx = transaction.current_context()
  if ctx then
    if smart_toggle_enabled then
      local todo_map = ctx.get_todo_map()
      api.propagate_toggle(ctx, { todo._get_todo_item() }, todo_map, target_state)
    else
      ctx.add_op(api.toggle_state, { {
        id = todo_id,
        target_state = target_state,
      } })
    end
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `set_todo_state` on invalid buffer")
    return false
  end

  -- if smart toggle is enabled, we need the todo_map
  local todo_map = smart_toggle_enabled and parser.get_todo_map(bufnr) or nil

  transaction.run(bufnr, function(_ctx)
    if smart_toggle_enabled and todo_map then
      api.propagate_toggle(_ctx, { todo._get_todo_item() }, todo_map, target_state)
    else
      _ctx.add_op(api.toggle_state, { {
        id = todo_id,
        target_state = target_state,
      } })
    end
  end)

  return true
end

---@deprecated since v0.12 Use `set_todo_state` instead.
--- Set a specific todo item to a specific state
---
--- To toggle state of todos under cursor or in linewise selection, use `toggle()`
---
---@param todo_item checkmate.TodoItem|checkmate.Todo Todo item to set state
---@param target_state string Todo state, e.g. "checked", "unchecked", or a custom state like "pending". See `checkmate.Config.todo_states`.
---@return boolean success True if operation was performed or queued, false if todo_item is invalid
function M.set_todo_item(todo_item, target_state)
  vim.notify_once(
    "Checkmate: 'set_todo_item' is deprecated since v0.12.0,\nuse `set_todo_state` instead.",
    vim.log.levels.WARN
  )

  local util = require("checkmate.util")
  local todo
  if todo_item.id then
    local ok, res = pcall(util.build_todo, todo_item --[[@as checkmate.TodoItem]])
    if ok then
      todo = res
    else
      vim.notify("Checkmate: Invalid `todo_item` provided to 'set_todo_item: %s'", res)
      return false
    end
  else
    todo = todo_item --[[@as checkmate.Todo]]
  end

  return M.set_todo_state(todo, target_state)
end

--- Set todo item(s) to checked state
---
--- See `toggle()`
---@return boolean success True if operation was performed or queued
function M.check()
  return M.toggle("checked")
end

--- Set todo item(s) to unchecked state
---
--- See `toggle()`
---@return boolean success True if operation was performed or queued
function M.uncheck()
  return M.toggle("unchecked")
end

--- Change todo item(s) state to the next or previous state
---
--- - Will act on the todo item under the cursor or all todo items within a visual selection
--- - Refer to docs for `checkmate.Config.todo_states`. If no custom states are defined, this will act similar to `toggle()`, i.e., changing state between "unchecked" and "checked". However, unlike `toggle`, `cycle` will not propagate state changes to nearby todos ("smart toggle") unless `checkmate.Config.smart_toggle.include_cycle` is true.
---
--- {opts}
---   - backward: (boolean) If true, will cycle in reverse
---@param opts? {backward?: boolean}
---@return boolean success True if operation was performed or queued, false if no todos found at position/selection
function M.cycle(opts)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local log = require("checkmate.log")

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
      return true
    else
      return false
    end
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `cycle` on invalid buffer")
    return false
  end

  local todo_items, todo_map = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
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
  end)

  return true
end

---@class checkmate.CreateOptions
---
--- Text content for new todo
--- In visual mode, replaces existing line content if a `position` opt is nil. If a `position` is passed,
--- then this will be the content of the new todo line.
--- Default: ""
---@field content? string
---
--- Where to place new todo relative to the current line
--- Default: "below"
---@field position? "above"|"below"
---
--- Explicit todo state, e.g. "checked", "unchecked", or custom state
--- This will override `inherit_state`, i.e. `target_state` will be used instead of the state derived from origin/parent todo
--- Default: "unchecked"
---@field target_state? string
---
--- Whether to inherit state from parent/current todo
--- The "parent" todo is is the todo on the cursor line when `create` is called,
--- or, in visual mode, the start or end of the selection when a `position` is used to create a new
--- todo above or below the selection.
--- Default: false (target_state is used)
---@field inherit_state? boolean
---
--- Override list marker, e.g. "-", "*", "+", "1."
--- Default: will use parent's type or fallback to config `default_list_marker`
---@field list_marker? string
---
--- Indentation (whitespace before list marker)
---  - `false` (default): sibling - same indent as parent/origin
---  - `true` or `"nested"`: child - indented greater than parent/origin
---  - `integer`: explicit indent in spaces
--- Default: false
---@field indent? boolean|integer|"nested"

--- Creates or converts lines to todo items based on context and mode
---
--- # Mode-Specific Behavior
---
--- ## Normal Mode
--- - **On non-todo line**: Converts line to todo (preserves text as content)
---   - With `position`: Creates new todo above/below, preserves original line
--- - **On todo line**: Creates sibling todo below by default
---   - With `position="above"`: Creates sibling above
---   - With `indent=true`: Creates nested todo (indented greater than parent/origin todo)
---
--- ## Visual Mode
--- - Converts each non-todo line in selection to a todo
--- - Ignores lines that are already todos
--- - If a `position` opt is also used, then will behave like normal mode, using the
--- start or end of the selection when creating a new todo above or below.
--- - Option `content` replaces existing line text, unless `position` is used, in which
--- it behaves like normal mode, setting the text of the new todo
---
--- ## Insert Mode
--- - Creates new todo below (or above with `position="above"`)
--- - If cursor is mid-line, splits line at cursor (text after cursor moves to new todo)
--- - Maintains insert mode after creation
--- - When `create` is called from handlers in `list_continuation.keys`, this enables a keymap like `<CR>` to create a new todo item in Insert mode
---
--- # Option Precedence
---
--- **State precedence** (highest to lowest):
--- 1. `target_state` - explicit state
--- 2. `inherit_state` - copies from parent/current todo
--- 3. "unchecked" - default
---
--- **List marker precedence**:
--- 1. `list_marker` - explicit marker
--- 2. Inherited from parent/sibling with auto-numbering
--- 3. Config `default_list_marker`
--- 4. "-" is fallback
---
--- # Examples
--- ```lua
--- -- Convert current line to todo or create a new todo on current line
--- require("checkmate").create()
---
--- -- Create nested child todo
--- require("checkmate").create({ indent = true })
---
--- -- Create todo above with custom state
--- require("checkmate").create({ position = "above", target_state = "pending" })
---
--- -- Create with specific content and marker
--- require("checkmate").create({ content = "New task", list_marker = "1." })
--- ```
---
---@param opts? checkmate.CreateOptions
---@return boolean success True if operation was performed, queued, or scheduled
function M.create(opts)
  opts = opts or {}

  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")
  local log = require("checkmate.log")

  local mode = util.get_mode()
  local is_insert = mode == "i"
  local is_visual = mode == "v"

  -- if we’re already inside a transaction, queue a create_todo for the current cursor row using normal mode behavior
  local ctx = transaction.current_context()
  if ctx then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1

    ctx.add_op(api.create_todo_normal, row, {
      position = opts.position or "below",
      target_state = opts.target_state,
      inherit_state = opts.inherit_state,
      list_marker = opts.list_marker,
      indent = opts.indent or false,
      content = opts.content,
      cursor_pos = { row = row, col = cursor[2] },
    })
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `create` on invalid buffer")
    return false
  end

  -- determine which api function to use based on current mode:

  if is_insert then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]

    -- since the buffer can change between now and when we run the below create_todo_insert, we use
    -- an extmark to store the cursor position
    -- For example, if the todo line is markdown like `- [ ] Test` this will be converted to unicode during
    -- then plugin's TextChange autocmd handling, which could throw off the cursor position
    local ns = vim.api.nvim_create_namespace("checkmate_create_temp")
    local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
      right_gravity = true,
    })

    -- we use transaction for insert mode to maintain consistency
    -- but schedule it to avoid issues with insert mode
    vim.schedule(function()
      local mark_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, extmark_id, {})
      if not mark_pos or #mark_pos < 2 then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        return
      end

      local new_row = mark_pos[1]
      local new_col = mark_pos[2]

      transaction.run(bufnr, function(tx_ctx)
        tx_ctx.add_op(api.create_todo_insert, row, {
          position = opts.position or "below",
          target_state = opts.target_state,
          inherit_state = opts.inherit_state,
          list_marker = opts.list_marker,
          indent = opts.indent or false,
          content = opts.content,
          cursor_pos = { row = new_row, col = new_col },
        })
      end, function()
        -- ensure we stay in insert mode
        if not util.is_insert_mode() then
          vim.cmd("startinsert")
        end

        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end)
    end)

    return true
  end

  if is_visual then
    -- exit visual mode first
    vim.cmd([[execute "normal! \<Esc>"]])

    local mark_start = vim.api.nvim_buf_get_mark(bufnr, "<")
    local mark_end = vim.api.nvim_buf_get_mark(bufnr, ">")
    local start_row = mark_start[1] - 1
    local end_row = mark_end[1] - 1

    if end_row < start_row then
      start_row, end_row = end_row, start_row
    end

    transaction.run(bufnr, function(tx_ctx)
      tx_ctx.add_op(api.create_todos_visual, start_row, end_row, {
        target_state = opts.target_state,
        list_marker = opts.list_marker,
        content = opts.content,
        position = opts.position,
        inherit_state = opts.inherit_state or false,
        indent = opts.indent or false,
      })
    end)

    return true
  end

  -- normal mode (default)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1

  transaction.run(bufnr, function(tx_ctx)
    tx_ctx.add_op(api.create_todo_normal, row, {
      position = opts.position,
      target_state = opts.target_state,
      inherit_state = opts.inherit_state or false,
      list_marker = opts.list_marker,
      indent = opts.indent or false,
      content = opts.content,
    })
  end)

  return true
end

---@class checkmate.RemoveOptions
---
---If true, keep the list marker (e.g. "- Text"); if false, remove list marker also ("Text")
---Default: true
---@field preserve_list_marker? boolean
---
---Removes all metadata associated with the todo
---Default: true
---@field remove_metadata? boolean

--- Remove todo from the current line (or all todos in a visual selection)
--- In other words, this converts a todo line back to a non-todo line
--- Can use `opts` to specify keeping/removing list marker and metadata
--- @param opts? checkmate.RemoveOptions
---@return boolean success True if operation was performed or queued, false if no todos found
function M.remove(opts)
  opts = opts or {}
  local preserve_list_marker = opts.preserve_list_marker ~= false
  local strip_meta = opts.remove_metadata ~= false

  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")

  -- a gotcha of this code is that when you remove metadata first that spans multiple lines, this will
  -- perform a line replace (instead of text replace), losing the stable todo id extmark. So we cover this
  -- by also linking on the todo's start_row. I'm not sure how fragile this will be, but working for now...

  local ctx = transaction.current_context()
  if ctx then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if not item then
      util.notify("No todo items found at cursor position", vim.log.levels.INFO)
      return false
    end

    local start_row = item.range.start.row
    if strip_meta then
      ctx.add_op(api.remove_metadata, { { id = item.id, meta_names = true } })
      ctx.add_cb(function(c)
        local refreshed = c.get_todo_by_id(item.id) or c.get_todo_by_row(start_row, true)
        if refreshed then
          c.add_op(api.remove_todo, { { id = refreshed.id, remove_list_marker = not preserve_list_marker } })
        end
      end)
    else
      ctx.add_op(api.remove_todo, { { id = item.id, remove_list_marker = not preserve_list_marker } })
    end
    return true
  end

  -- normal/visual path: collect once, then run both phases in a single transaction
  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `remove` on invalid buffer")
    return false
  end

  local items = api.collect_todo_items_from_selection(is_visual)

  if #items == 0 then
    local mode_msg = is_visual and "within selection" or "at cursor position"
    util.notify(string.format("No todo items found %s", mode_msg), vim.log.levels.INFO)
    return false
  end

  -- capture stable targets (IDs may change after multi-line metadata edits)
  local targets = {}
  for _, it in ipairs(items) do
    targets[#targets + 1] = { id = it.id, start_row = it.range.start.row }
  end

  local meta_ops = {}
  if strip_meta then
    for _, t in ipairs(targets) do
      meta_ops[#meta_ops + 1] = { id = t.id, meta_names = true } -- true = remove all
    end
  end

  transaction.run(bufnr, function(_ctx)
    if strip_meta and #meta_ops > 0 then
      _ctx.add_op(api.remove_metadata, meta_ops)
      _ctx.add_cb(function(c)
        local rm_ops = {}
        for _, t in ipairs(targets) do
          local found = c.get_todo_by_id(t.id) or c.get_todo_by_row(t.start_row, true)
          if found then
            rm_ops[#rm_ops + 1] = { id = found.id, remove_list_marker = not preserve_list_marker }
          end
        end
        if #rm_ops > 0 then
          c.add_op(api.remove_todo, rm_ops)
        end
      end)
    else
      -- no metadata stripping: remove prefixes immediately
      local rm_ops = {}
      for _, t in ipairs(targets) do
        rm_ops[#rm_ops + 1] = {
          id = t.id,
          remove_list_marker = not preserve_list_marker,
        }
      end
      _ctx.add_op(api.remove_todo, rm_ops)
    end
  end)
  return true
end

--- Insert metadata into todo item(s) under the cursor or per todo in the visual selection
---
--- If the metadata already exists on the todo, this will update the value to match the new value (upsert behavior).
---
--- If you desire update-only behavior, see `update_metadata()`.
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string? (Optional) New metadata value. If nil, will attempt to get default value from the metadata's `get_value` field.
---@return boolean success True if operation was performed or queued, false if no todos found
function M.add_metadata(metadata_name, value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local util = require("checkmate.util")
  local log = require("checkmate.log")

  H.metadata_is_defined(metadata_name)

  local ctx = transaction.current_context()
  if ctx then
    -- if add_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.add_metadata, { { id = todo_item.id, meta_name = metadata_name, meta_value = value } })
      return true
    else
      return false
    end
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `add_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
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
  end)
  return true
end

--- Remove metadata from todo item(s) under the cursor or per todo in the visual selection
---
--- To remove **all** metadata from todo(s), use `remove_all_metadata()`
---@param metadata_name string Name of the metadata tag (defined in the config)
---@return boolean success True if operation was performed or queued, false if no todos found
function M.remove_metadata(metadata_name)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  H.metadata_is_defined(metadata_name)

  local ctx = transaction.current_context()
  if ctx then
    -- if remove_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.remove_metadata, { { id = todo_item.id, meta_names = { metadata_name } } })
      return true
    else
      return false
    end
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `remove_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
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
  end)
  return true
end

--- Remove all metadata from todo item(s) under the cursor or per todo in visual selection
---
--- To remove _specific_ metadata from todo(s), see `remove_metadata()`
---@return boolean success True if operation was performed or queued, false if no todos found
function M.remove_all_metadata()
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  local ctx = transaction.current_context()
  if ctx then
    -- if remove_all_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.remove_metadata, { { id = todo_item.id, meta_names = true } })
      return true
    else
      return false
    end
  end

  local is_visual = require("checkmate.util").is_visual_mode()

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `remove_all_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
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
  end)
  return true
end

--- Update existing metadata value for todo item(s) under the cursor or per todo in visual selection.
---
--- If the metadata doesn't exist on a todo item, no change is made to that item.
---
--- If you want to ensure a metadata tag/value is updated **OR** added (upsert behavior), use `add_metadata()`.
---
---@param metadata_name string The metadata tag name
---@param new_value? string (Optional) New metadata value. If nil, will attempt to get default value from the metadata's `get_value` field.
---@return boolean success True if operation was performed or queued, false if no todos with the metadata were found
function M.update_metadata(metadata_name, new_value)
  local api = require("checkmate.api")
  local util = require("checkmate.util")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  H.metadata_is_defined(metadata_name)

  local ctx = transaction.current_context()
  if ctx then
    -- within existing transaction
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local bufnr = ctx.get_buf()
    local todo_item =
      parser.get_todo_item_at_position(bufnr, cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })

    if todo_item then
      local has_metadata = todo_item.metadata.by_tag[metadata_name] ~= nil
      if has_metadata then
        ctx.add_op(api.add_metadata, {
          { id = todo_item.id, meta_name = metadata_name, meta_value = new_value },
        })
        return true
      end
    end
    return false
  end

  local is_visual = util.is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `update_metadata` on invalid buffer")
    return false
  end

  local todo_items, _ = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
    return false
  end

  -- filter only items that have the metadata
  local operations = {}

  for _, item in ipairs(todo_items) do
    local has_metadata = item.metadata.by_tag[metadata_name] ~= nil
    if has_metadata then
      table.insert(operations, {
        id = item.id,
        meta_name = metadata_name,
        meta_value = new_value,
      })
    end
  end

  if #operations == 0 then
    util.notify(string.format("No todo items found with metadata '%s'", metadata_name), vim.log.levels.WARN)
    return false
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.add_metadata, operations)
  end)

  return true
end

--- Toggle metadata for todo item(s) under the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string? (Optional) New metadata value. If nil, will attempt to get default value from the metadata's `get_value` field.
---@return boolean success True if operation was performed or queued, false if no todos found
function M.toggle_metadata(metadata_name, value)
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local profiler = require("checkmate.profiler")
  local log = require("checkmate.log")

  H.metadata_is_defined(metadata_name)

  profiler.start("M.toggle_metadata")

  local ctx = transaction.current_context()
  if ctx then
    -- if toggle_metadata() is run within an existing transaction, we will use the cursor position
    local parser = require("checkmate.parser")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local todo_item =
      parser.get_todo_item_at_position(ctx.get_buf(), cursor[1] - 1, cursor[2], { todo_map = ctx.get_todo_map() })
    if todo_item then
      ctx.add_op(api.toggle_metadata, { { id = todo_item.id, meta_name = metadata_name, custom_value = value } })
      profiler.stop("M.toggle_metadata")
      return true
    else
      profiler.stop("M.toggle_metadata")
      return false
    end
  end

  local is_visual = require("checkmate.util").is_visual_mode()
  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `toggle_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(is_visual)

  if #todo_items == 0 then
    H.notify_no_todos_found(is_visual)
    profiler.stop("M.toggle_metadata")
    return false
  end

  local operations = {}
  for _, item in ipairs(todo_items) do
    table.insert(operations, {
      id = item.id,
      meta_name = metadata_name,
      custom_value = value,
    })
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.toggle_metadata, operations)
  end)

  profiler.stop("M.toggle_metadata")
  return true
end

---@class checkmate.SelectMetadataValueOpts
---@field position? {row: integer, col?: integer} Position to use to locate metadata rather than cursor (0-indexed)
---For advanced customization
---@field picker_opts? checkmate.PickerOpts
---Call exactly once with:
---  - Selected value (string) to apply the change
---  - nil to cancel (no changes)
---@field custom_picker? fun(context: checkmate.MetadataContext, complete: fun(value: string?))

---Opens a picker to select a new value for the metadata under the cursor
---
---A `position` opt can be used to specify a metadata rather than use cursor. It must resolve to within the metadata tag/value range.
---
---**Default Behavior:**
---Uses the metadata's `choices` field to populate items and opens a picker.
---The global picker can be customized via the `ui.picker` option in the config, or
---a picker-specific config can be passed via `picker_opts`.
---
---
---**Custom Picker:**
---Pass a `opts.custom_picker` for complete control (BYOP). You handle everything: generating choices, UI, calling complete(value).
---Your function will receive:
---  - `context`: Contains metadata details, todo item, and buffer number
---  - `complete`: Callback function to finalize the selection
---Why? If you want a custom picker (e.g., items that aren't generated by the `choices` field,
---such as an optimized picker from a dedicated picker plugin)
---
---**Important Notes:**
---  - The cursor must be positioned on a metadata region (e.g., @priority(high)), or a `position` opt passed
---  - If metadata value hasn't changed, no operation is performed
---
---@example
---Example: custom picker function:
---
---```lua
--- -- Update metadata from a snacks.nvim picker
--- require("checkmate").select_metadata_value({
---  custom_picker = function(ctx, complete)
---    require("snacks").picker.files({
---      confirm = function(picker, item)
---        if item then
---          vim.schedule(function()
---            complete(item.text)
---          end)
---        end
---        picker:close()
---      end,
---    })
---  end,
--- })
---```
---
---@param opts? checkmate.SelectMetadataValueOpts
---@return boolean success False if validation failed (no todo/metadata at position), true if picker was opened successfully
function M.select_metadata_value(opts)
  opts = opts or {}
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local picker = require("checkmate.metadata.picker")
  local log = require("checkmate.log")
  local util = require("checkmate.util")
  local parser = require("checkmate.parser")
  local meta_module = require("checkmate.metadata")

  local custom_picker = opts.custom_picker
  if custom_picker and not vim.is_callable(custom_picker) then
    require("checkmate.util").notify("`custom_picker` must be a function", vim.log.levels.WARN)
    log.fmt_warn("[main] attempted to call `select_metadata_value` with `custom_picker` not a function")
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `select_metadata_value` on invalid buffer")
    return false
  end

  -- resolve the `position` opt or default to cursor position
  local position = opts.position
  local row, col, pos_str = H.resolve_position(position and position.row or nil, position and position.col or nil)

  -- create the metadata context that we pass to the picker implementation
  local todo_item = parser.get_todo_item_at_position(bufnr, row, col)
  if not todo_item then
    util.notify(string.format("No todo at %s (0-indexed)", pos_str), vim.log.levels.INFO)
    return false
  end

  local selected_metadata = meta_module.find_metadata_at_pos(todo_item, row, col)
  if not selected_metadata then
    util.notify(string.format("No metadata at %s (0-indexed)", pos_str), vim.log.levels.INFO)
    return false
  end

  ---@type checkmate.MetadataContext
  local context = {
    name = selected_metadata.tag,
    value = selected_metadata.value,
    buffer = bufnr,
    todo = util.build_todo(todo_item),
  }

  --- apply (set) the new metadata value via transaction (similar to all APIs)
  --- this is called by both picker paths (1. default `choices` path via |open_picker| and, 2. user's |custom_picke|)
  ---@param value string? Selected value, or nil if cancelled
  local function apply_value_with_transaction(value)
    if value == nil then
      return
    end

    -- resolve the metadata entry we are updating
    -- TODO: do we need to re-find the todo/metadata again or use the closed selected_metadata?
    local metadata = selected_metadata

    -- no change
    if value == metadata.value then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      require("checkmate.util").notify("Buffer no longer valid during `select_metadata_value`", vim.log.levels.WARN)
      return
    end

    local ctx = transaction.current_context()
    if ctx then
      ctx.add_op(api.set_metadata_value, metadata, value)
      return
    end

    transaction.run(bufnr, function(_ctx)
      _ctx.add_op(api.set_metadata_value, metadata, value)
    end)
  end

  -- custom picker pathway: user provides their own `custom_picker` that handles generating the choices, UI, etc.
  if custom_picker then
    picker.with_custom_picker(context, custom_picker, apply_value_with_transaction)
    return true
  end

  -- default pathway using config's `choices` value (table or function return) inside checkmate's picker (see `config.ui.picker`)
  picker.open_picker(context, apply_value_with_transaction, opts.picker_opts)
  return true
end

--- Move the cursor to the next metadata tag for the todo item under the cursor, if present
---@return nil
function M.jump_next_metadata()
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  local ctx = transaction.current_context()
  if ctx then
    ctx.add_cb(function()
      local bufnr = ctx.get_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local todo_item = ctx.get_todo_by_row(cursor[1] - 1)
      if todo_item then
        api.move_cursor_to_metadata(bufnr, todo_item, false)
      end
    end)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `jump_next_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(false)
  if #todo_items > 0 then
    api.move_cursor_to_metadata(bufnr, todo_items[1], false)
  end
end

--- Move the cursor to the previous metadata tag for the todo item under the cursor, if present
---@return nil
function M.jump_previous_metadata()
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  local ctx = transaction.current_context()
  if ctx then
    ctx.add_cb(function()
      local bufnr = ctx.get_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local todo_item = ctx.get_todo_by_row(cursor[1] - 1)
      if todo_item then
        api.move_cursor_to_metadata(bufnr, todo_item, true)
      end
    end)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `jump_previous_metadata` on invalid buffer")
    return false
  end

  local todo_items = api.collect_todo_items_from_selection(false)
  if #todo_items > 0 then
    api.move_cursor_to_metadata(bufnr, todo_items[1], true)
  end
end

--- Get the todo under the cursor (or the first line of a visual selection)
---
--- Behavior:
--- - Uses current buffer and cursor row by default
--- - In visual mode, resolves the todo at the *first* line of the selection (`'<`)
--- - If `root_only=true`, only returns a todo when the resolved row is the todo's first line (i.e., with list item and todo marker)
--- - If the buffer is not an active Checkmate buffer, returns nil
---
--- Options:
---   - bufnr?: integer            Buffer to inspect (default: current)
---   - row?:   integer (0-based)  Explicit row to inspect (overrides cursor/visual)
---   - root_only?: boolean        Only match if row is the todo’s first line
---
--- @param opts? {bufnr?: integer, row?: integer, root_only?: boolean}
--- @return checkmate.Todo? todo The todo item at the specified position, or nil if not found
function M.get_todo(opts)
  local api = require("checkmate.api")
  local log = require("checkmate.log")
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `get_todo` on invalid buffer")
    return nil
  end

  local util = require("checkmate.util")
  local parser = require("checkmate.parser")
  local transaction = require("checkmate.transaction")

  local row
  if type(opts.row) == "number" then
    row = opts.row
  else
    if util.is_visual_mode() then
      vim.cmd([[execute "normal! \<Esc>"]])
      local mark = vim.api.nvim_buf_get_mark(bufnr, "<") -- 1-based
      row = (mark and mark[1] or vim.api.nvim_win_get_cursor(0)[1]) - 1
    else
      row = vim.api.nvim_win_get_cursor(0)[1] - 1
    end
  end

  local ctx = transaction.current_context(bufnr)
  local parse_opts = { root_only = opts.root_only == true }
  if ctx then
    parse_opts.todo_map = ctx.get_todo_map()
  end

  local item = parser.get_todo_item_at_position(bufnr, row, 0, parse_opts)
  if not item then
    return nil
  end
  return util.build_todo(item)
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
---@return boolean success True if lint operation completed
---@return table|nil diagnostics Array of diagnostic objects, or nil if lint failed
function M.lint(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local api = require("checkmate.api")
  local log = require("checkmate.log")

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `lint` on invalid buffer")
    return false, nil
  end

  local linter = require("checkmate.linter")
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
---@return boolean success True if operation was performed or queued
function M.archive(opts)
  opts = opts or {}
  local api = require("checkmate.api")
  local transaction = require("checkmate.transaction")
  local log = require("checkmate.log")

  local ctx = transaction.current_context()
  if ctx then
    -- already in a transaction, queue the operation
    ctx.add_op(api.archive_todos, opts)
    return true
  end

  local bufnr = vim.api.nvim_get_current_buf()

  if not api.is_valid_buffer(bufnr) then
    log.warn("[main] Attempted to call `archive` on invalid buffer")
    return false
  end

  transaction.run(bufnr, function(_ctx)
    _ctx.add_op(api.archive_todos, opts)
  end)
  return true
end

----------------------------------------------------------------------

---@param opts checkmate.Config?
---@return boolean success True if setup completed successfully
M.setup = function(opts)
  local config = require("checkmate.config")

  H.state.user_opts = opts or {}

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

    -- if config.setup() returns {}, it already notified the validation error
    ---@type checkmate.Config
    local cfg = config.setup(opts or {})
    if type(cfg) ~= "table" or vim.tbl_isempty(cfg) then
      return
    end

    if #config.get_deprecations(H.state.user_opts) > 0 then
      vim.notify("Checkmate: deprecated usage detected. Run `checkhealth checkmate`.", vim.log.levels.WARN)
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

  -- got here but not initialized, ?config error, do graceful cleanup
  if not M.is_initialized() then
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

function M.get_user_opts()
  return vim.deepcopy(H.state.user_opts)
end

function M.is_initialized()
  return H.state.initialized
end

function M.set_initialized(value)
  H.state.initialized = value
end

function M.is_running()
  return H.state.running
end

function M.set_running(value)
  H.state.running = value
end

function M.register_buffer(bufnr)
  H.state.active_buffers[bufnr] = true
end

function M.unregister_buffer(bufnr)
  H.state.active_buffers[bufnr] = nil
end

function M.is_buffer_active(bufnr)
  return H.state.active_buffers[bufnr] == true
end

-- Returns array of buffer numbers
function M.get_active_buffer_list()
  local buffers = {}
  for bufnr in pairs(H.state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(buffers, bufnr)
    else
      H.state.active_buffers[bufnr] = nil
    end
  end
  return buffers
end

-- Returns hash table of bufnr -> true
function M.get_active_buffer_map()
  local buffers = {}
  for bufnr in pairs(H.state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      buffers[bufnr] = true
    else
      H.state.active_buffers[bufnr] = nil
    end
  end
  return buffers
end

-- Convenience function that returns count
function M.count_active_buffers()
  local count = 0
  for bufnr in pairs(H.state.active_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      count = count + 1
    else
      H.state.active_buffers[bufnr] = nil
    end
  end
  return count
end

function M.reset()
  H.state.initialized = false
  H.state.running = false
  H.state.active_buffers = {}
end

-- ================================================================================
-- ------------ HELPERS --------------
-- ================================================================================

H.state = {
  -- initialized is config setup
  initialized = false,
  -- core modules are setup (parser, highlights, linter) and autocmds registered
  running = false,
  active_buffers = {}, -- bufnr -> true
  -- save initial user opts for later restarts
  user_opts = {},
}

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

--- Checks that is metadata tag name (internally using it's canonical name)
--- exists in the config.metadata
---@return boolean exists
function H.metadata_is_defined(metadata_name)
  local meta_mod = require("checkmate.metadata")
  local log = require("checkmate.log")

  local canonical = meta_mod.get_canonical_name(metadata_name)
  if not canonical then
    log.fmt_warn(
      "[main] Metadata with name '%s' does not exist. Is it defined in the `config.metadata`?",
      metadata_name
    )
    return false
  end

  return true
end

---Returns the given row/col position or defaults to cursor pos (converting to 0-based row)
---@param row? integer 0-based
---@param col? integer 0-based
---@return integer row
---@return integer col
---@return string pos_str string for notifications/logging
function H.resolve_position(row, col)
  local resolved_row, resolved_col
  if row then
    resolved_row = row -- 0 indexed
    resolved_col = col or 0
  else
    resolved_row, resolved_col = unpack(vim.api.nvim_win_get_cursor(0))
    resolved_row = resolved_row - 1
  end
  local pos_str = string.format("%s [%d,%d]", row ~= nil and "position" or "cursor pos", resolved_row, resolved_col)
  return resolved_row, resolved_col, pos_str
end

function H.notify_no_todos_found(is_visual)
  local mode_msg = is_visual and "within selection" or "at cursor position"
  require("checkmate.util").notify(string.format("No todo items found %s", mode_msg), vim.log.levels.INFO)
end

return M
