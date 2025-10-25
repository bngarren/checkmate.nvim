--- Metadata picker module (internal)
--- Handles both default (choices-based) and custom picker implementations
--- for updating metadata values
local M = {}

local parser = require("checkmate.parser")
local meta_module = require("checkmate.metadata")
local picker = require("checkmate.picker")
local util = require("checkmate.util")
local log = require("checkmate.log")

--- Gets the todo item and metadata for a picker implementation
--- **internal only**
---@param bufnr integer
---@param row? 0-indexed row (defaults to cursor line)
---@param col? 0-indexed col (default to cursor pos)
---@return {bufnr: integer, todo_item: checkmate.TodoItem, selected_metadata: checkmate.MetadataEntry}|nil ctx
local function get_picker_context(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  col = col or 0
  if not row then
    row, col = unpack(vim.api.nvim_win_get_cursor(0))
    row = row - 1 -- to 0-index
  end

  local context = {
    bufnr = bufnr,
  }

  local todo_item = parser.get_todo_item_at_position(bufnr, row, col)
  if not todo_item then
    util.notify("No todo item at cursor", vim.log.levels.INFO)
    return nil
  else
    context.todo_item = todo_item
  end

  local selected_metadata = meta_module.find_metadata_at_pos(todo_item, row, col)
  if not selected_metadata then
    util.notify("No metadata tag at cursor", vim.log.levels.INFO)
    return nil
  else
    context.selected_metadata = selected_metadata
  end

  return context
end

--- Opens a picker for the metadata under the cursor
--- Uses the metadata's `choices` field to populate items
---
--- **Callback flow**:
---   1. Gets metadata context (todo item, selected metadata)
---   2. Creates `receive_choices` callback
---   3. Calls meta_module.get_choices() which will invoke the callback with items
---   4. When items are received, creates `receive_selection_from_ui` callback
---   5. Opens picker UI with `receive_selection_from_ui` as the selection handler
---   6. When user selects, `receive_selection_from_ui` calls `apply_value_to_transaction`
---@param apply_value_with_transaction fun(value: string, metadata: checkmate.MetadataEntry)
function M.open_picker(apply_value_with_transaction)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- to 0-index

  local ctx = get_picker_context(bufnr, row, col)
  if not ctx then
    log.fmt_error("[metadata/picker] failed to get_picker_context", bufnr)
    return
  end
  local todo_item = ctx.todo_item
  local selected_metadata = ctx.selected_metadata

  --- Receive the choices items from metadata module
  --- This cb is passed to |meta_module.get_choices()| and invoked when items are ready
  --- @param items string[] available choices for this metadata tag
  local function receive_choices(items)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      log.fmt_warn("[metadata/picker] `receive_choices` called but bufnr %d is not valid", bufnr)
      return
    end

    if not items or #items == 0 then
      vim.notify(string.format("No choices available for @%s", selected_metadata.tag), vim.log.levels.INFO)
      return
    end

    --- Receive the user's selection from the picker UI
    --- This cb is passed to |picker.select()| and invoked when user selects an item
    --- @param choice string? the selected value, or nil if cancelled
    local function receive_selection_from_ui(choice)
      if choice and choice ~= selected_metadata.value then
        if not vim.api.nvim_buf_is_valid(bufnr) then
          log.fmt_warn("[metadata/picker] buffer %d no longer valid, ignoring selection", bufnr)
          return
        end
        local str_choice = tostring(choice)
        apply_value_with_transaction(str_choice, selected_metadata)
      end
      -- if choice is nil, user cancelled - do nothing
    end

    vim.schedule(function()
      picker.select(items, {
        prompt = "Select value for @" .. selected_metadata.tag,
        kind = "checkmate_metadata_value",
        format_item = function(item)
          if item == selected_metadata.value then
            return item .. " (current)"
          end
          return item
        end,
        on_choice = receive_selection_from_ui,
      })
    end)
  end

  -- this is step 1: request choices from the metadata module, i.e. resolve the `choices` table or function
  local success, result = pcall(function()
    return meta_module.get_choices(selected_metadata.tag, receive_choices, todo_item, bufnr)
  end)

  if not success then
    local err_msg =
      string.format("Checkmate: Error getting completions for @%s: %s", selected_metadata.tag, tostring(result))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(result, "[metadata/picker] " .. err_msg)
    return
  end
end

--- Execute a user-provided custom picker function
--- The user's picker must call `user_complete_callback` with the selected value
---
--- **Callback flow**:
---   1. Gets metadata context (todo item, selected metadata)
---   2. Builds user-facing context object
---   3. Creates `user_complete_callback` (the "complete" function user calls)
---   4. Invokes user's `picker_fn(context, user_complete_callback)`
---   5. User's picker eventually calls `user_complete_callback(value)`
---   6. `user_complete_callback` calls `apply_value_with_transaction`
---
---@param picker_fn fun(context: checkmate.MetadataContext, user_complete_callback: fun(value: string?))
---@param apply_value_with_transaction fun(value: string?, metadata: checkmate.MetadataEntry)
function M.with_custom_picker(picker_fn, apply_value_with_transaction)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local ctx = get_picker_context(bufnr, row, col)
  if not ctx then
    log.fmt_error("[metadata/picker] failed to get_picker_context", bufnr)
    return
  end
  local todo_item = ctx.todo_item
  local selected_metadata = ctx.selected_metadata

  -- build context for user's picker
  local context = meta_module.create_context(todo_item, selected_metadata.alias_for, selected_metadata.value, bufnr)

  local completed = false

  --- Completion callback that user invokes with their selected value
  --- This is the "complete" function passed to the user's custom picker_fn,
  --- and the user would typically call within their picker's "confirm" or "select" action/handler
  ---@param value string? Selected value, or nil if cancelled
  local function user_complete_callback(value)
    if completed then
      log.fmt_warn("[metadata/picker] `complete` called multiple times for bufnr %d", bufnr)
      return
    end
    completed = true

    vim.schedule(function()
      apply_value_with_transaction(value, selected_metadata)
    end)
  end

  -- step 1 for the with_custom_picker path:
  -- Call the user's picker_fn, giving it metadata context and a `complete` callback to use
  local success, err = pcall(picker_fn, context, user_complete_callback)

  if not success then
    local err_msg =
      string.format("Checkmate: Error in the user's `picker_fn` passed to `with_custom_picker`: %s", tostring(err))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(err, "[metadata/picker] " .. err_msg)
    return false
  end

  return true
end

return M
