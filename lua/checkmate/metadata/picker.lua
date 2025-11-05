--- Metadata picker module (internal)
--- Handles both default (choices-based) and custom picker implementations
--- for updating metadata values
local M = {}

local parser = require("checkmate.parser")
local meta_module = require("checkmate.metadata")
local picker = require("checkmate.picker")
local util = require("checkmate.util")
local log = require("checkmate.log")

--- Opens a picker for the metadata provided in context
--- Uses the metadata's `choices` field to populate items
---
--- **Callback flow**:
---   1. Receives metadata context (todo, selected metadata) from caller
---   2. Creates `receive_choices` callback
---   3. Calls meta_module.get_choices() which will invoke the callback with items
---   4. When items are received, creates `receive_selection_from_ui` callback
---   5. Opens picker UI with `receive_selection_from_ui` as the selection handler
---   6. When user selects, `receive_selection_from_ui` calls `apply_value_to_transaction`
---
---@param context checkmate.MetadataContext
---@param apply_value_with_transaction fun(value: string)
function M.open_picker(context, apply_value_with_transaction)
  local bufnr = context.buffer
  --- Receive the choices items from metadata module
  --- This cb is passed to |meta_module.get_choices()| and invoked when items are ready
  --- @param items string[] available choices for this metadata tag
  local function receive_choices(items)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      log.fmt_warn("[metadata/picker] `receive_choices` called but bufnr %d is not valid", bufnr)
      return
    end

    if not items or #items == 0 then
      vim.notify(string.format("No choices available for @%s", context.name), vim.log.levels.INFO)
      return
    end

    --- Receive the user's selection from the picker UI
    --- This cb is passed to |picker.select()| and invoked when user selects an item
    --- @param choice string? the selected value, or nil if cancelled
    local function receive_selection_from_ui(choice)
      if choice and choice ~= context.value then
        if not vim.api.nvim_buf_is_valid(bufnr) then
          log.fmt_warn("[metadata/picker] buffer %d no longer valid, ignoring selection", bufnr)
          return
        end
        local str_choice = tostring(choice)
        apply_value_with_transaction(str_choice)
      end
      -- if choice is nil, user cancelled - do nothing
    end

    vim.schedule(function()
      require("checkmate.picker.init").pick(items, {
        prompt = "Select value for @" .. context.name,
        kind = "checkmate_metadata_value",
        format_item = function(item)
          if item.text == context.value then
            return item.text .. " (current)"
          end
          return item.text
        end,
        on_choice = receive_selection_from_ui,
        preview = true,
      })
    end)
  end

  -- this is step 1: request choices from the metadata module, i.e. resolve the `choices` table or function
  local success, result = pcall(function()
    return meta_module.get_choices(context.name, receive_choices, context.todo._get_todo_item(), bufnr)
  end)

  if not success then
    local err_msg = string.format("Checkmate: Error getting completions for @%s: %s", context.name, tostring(result))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(result, "[metadata/picker] " .. err_msg)
    return
  end
end

--- Execute a user-provided custom picker function
--- The user's picker must call `user_complete_callback` with the selected value
---
--- **Callback flow**:
---   1. Receives metadata context (todo, selected metadata) from caller
---   2. Builds user-facing context object
---   3. Creates `user_complete_callback` (the "complete" function user calls)
---   4. Invokes user's `picker_fn(context, user_complete_callback)`
---   5. User's picker eventually calls `user_complete_callback(value)`
---   6. `user_complete_callback` calls `apply_value_with_transaction`
---
---@param context checkmate.MetadataContext
---@param picker_fn fun(context: checkmate.MetadataContext, user_complete_callback: fun(value: string?))
---@param apply_value_with_transaction fun(value: string?)
function M.with_custom_picker(context, picker_fn, apply_value_with_transaction)
  local bufnr = context.buffer
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
      apply_value_with_transaction(value)
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
