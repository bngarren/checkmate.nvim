local parser = require("checkmate.parser")
local meta_module = require("checkmate.metadata")
local picker = require("checkmate.picker")
local util = require("checkmate.util")
local log = require("checkmate.log")

local M = {}

--- Opens a picker for the metadata under the cursor
---@generic T
---@param on_select fun(choice: T, metadata: checkmate.MetadataEntry)
function M.open_picker(on_select)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- to 0-index

  local todo_item = parser.get_todo_item_at_position(bufnr, row, col)

  if not todo_item then
    util.notify("No todo item at cursor", vim.log.levels.INFO)
    return
  end

  local selected_metadata = meta_module.find_metadata_at_pos(todo_item, row, col)

  if not selected_metadata then
    util.notify("No metadata tag at cursor", vim.log.levels.INFO)
    return
  end

  -- Callback that passes items from `choices` table or function return
  local function handle_completions(items)
    -- local active_op = active_pickers[bufnr]
    -- if not active_op then
    --   log.fmt_warn("[metadata/picker] `handle_completions` called but picker is no longer active for bufnr %d", bufnr)
    --   return
    -- end

    -- cleanup_spinner(bufnr)

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
            on_select(choice, selected_metadata)
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

return M
