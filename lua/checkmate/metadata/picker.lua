local parser = require("checkmate.parser")
local meta_module = require("checkmate.metadata")
local picker = require("checkmate.picker")
local util = require("checkmate.util")
local log = require("checkmate.log")

local M = {}

--- Gets the todo item and metadata for a picker implementation
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
---@generic T
---@param on_select fun(choice: T, metadata: checkmate.MetadataEntry)
function M.open_picker(on_select)
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

  -- Callback that passes items from `choices` table or function return
  local function handle_completions(items)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      log.fmt_warn("[metadata/picker] `handle_completions` called but bufnr %d is not valid", bufnr)
      return
    end

    if not items or #items == 0 then
      vim.notify(string.format("No choices available for @%s", selected_metadata.tag), vim.log.levels.INFO)
      return
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
        on_choice = function(choice)
          if choice and choice ~= selected_metadata.value then
            local str_choice = tostring(choice)
            on_select(str_choice, selected_metadata)
          end
          -- if choice is nil, user cancelled
        end,
      })
    end)
  end

  local success, result = pcall(function()
    return meta_module.get_choices(selected_metadata.tag, handle_completions, todo_item, bufnr)
  end)

  if not success then
    local err_msg =
      string.format("Checkmate: Error getting completions for @%s: %s", selected_metadata.tag, tostring(result))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(result, "[metadata/picker] " .. err_msg)
    return
  end
end

---Execute custom picker with managed UI (spinner, highlighting)
---Calls on_select with the chosen value, or nil if cancelled
---@param picker_fn fun(context: checkmate.MetadataPickerContext, complete: fun(value: string?))
---@param on_select fun(value: string?, metadata: checkmate.MetadataEntry)
function M.with_custom_picker(picker_fn, on_select)
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
  local todo = util.build_todo(todo_item)
  ---@type checkmate.MetadataPickerContext
  local context = {
    metadata = selected_metadata,
    todo = todo,
    buffer = bufnr,
  }

  local completed = false

  ---Completion callback for user to invoke with selected value
  ---@param value string? Selected value, or nil if cancelled
  local function complete(value)
    if completed then
      log.fmt_warn("[metadata/picker] `complete` called multiple times for bufnr %d", bufnr)
      return
    end
    completed = true

    vim.schedule(function()
      on_select(value, selected_metadata)
    end)
  end

  local success, err = pcall(picker_fn, context, complete)

  if not success then
    local err_msg =
      string.format("Checkmate: Error in the picker function passed to `with_custom_picker`: %s", tostring(err))
    vim.notify(err_msg, vim.log.levels.ERROR)
    log.log_error(err, "[metadata/picker] " .. err_msg)
    return false
  end

  return true
end

return M
