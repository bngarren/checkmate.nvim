--- Metadata picker module (internal)
--- Handles both default (choices-based) and custom picker implementations
--- for updating metadata values
local M = {}

local meta_module = require("checkmate.metadata")
local picker_util = require("checkmate.picker.util")
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
function M.open_picker(context, apply_value_with_transaction, picker_opts)
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
      require("checkmate.picker").pick(items, {
        prompt = "Select value for @" .. context.name,
        kind = "checkmate_metadata_value",
        format_item_text = function(item)
          if item.text == context.value then
            return item.text .. " (current)"
          end
          return item.text
        end,
        on_select = receive_selection_from_ui,
        picker_opts = picker_opts,
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

--- Execute a user-provided custom picker function.
---
--- This path is domain-level rather than picker-engine-level: the user receives
--- metadata context and calls complete(value), where value is the metadata value
--- to apply.
---
--- Callback flow:
---   1. Receives metadata context (todo, selected metadata) from caller
---   2. Builds user-facing context object
---   3. Creates `complete` (the function user calls)
---   4. Invokes user's `custom_picker(context, complete)`
---   5. User's picker eventually calls `complete(value)` or `complete(nil)`
---   6. `complete(value)` calls `apply_value_with_transaction`
---
---@param context checkmate.MetadataContext
---@param custom_picker fun(context: checkmate.MetadataContext, complete: fun(value: string?))
---@param apply_value_with_transaction fun(value: string?)
function M.with_custom_picker(context, custom_picker, apply_value_with_transaction)
  local bufnr = context.buffer
  local complete = picker_util.make_value_completion(apply_value_with_transaction, {
    source = string.format("[metadata/picker] bufnr %d", bufnr),
  })

  -- step 1 for the with_custom_picker path:
  -- Call the user's custom_picker fn, giving it metadata context and a `complete` callback to use
  local success, err = pcall(custom_picker, context, complete)

  if not success then
    local err_msg =
      string.format("Checkmate: Error in the user's `custom_picker` passed to `with_custom_picker`: %s", tostring(err))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(err, "[metadata/picker] " .. err_msg)
    return false
  end

  return true
end

return M
