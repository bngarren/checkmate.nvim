local parser = require("checkmate.parser")
local meta_module = require("checkmate.metadata")
local picker = require("checkmate.picker")
local animation = require("checkmate.ui.animation")
local util = require("checkmate.util")

local M = {}

local ns_id = vim.api.nvim_create_namespace("checkmate_metadata_picker")

--- bufnr -> {spinner}
---@type table<integer, {spinner: AnimationState}>
local active_pickers = {}

-- separate from cleanup_ui so that we can stop the spinner but keep other highlight
local function cleanup_spinner(bufnr)
  local active_picker = active_pickers[bufnr]
  if active_picker and active_picker.spinner then
    active_picker.spinner:stop()
    active_picker.spinner = nil
  end
end

function M.cleanup_ui(bufnr)
  cleanup_spinner(bufnr)

  if active_pickers[bufnr] then
    active_pickers[bufnr] = nil
  end

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

--- open a picker for the metadata under the cursor.
function M.open_picker(on_select)
  local bufnr = vim.api.nvim_get_current_buf()

  if active_pickers[bufnr] then
    return
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- to 0-index

  -- cleanup any prior
  M.cleanup_ui(bufnr)

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
  ---@cast selected_metadata checkmate.MetadataEntry

  -- highlight the metadata being updated
  vim.api.nvim_buf_set_extmark(bufnr, ns_id, selected_metadata.range.start.row, selected_metadata.range.start.col, {
    hl_group = "DiagnosticVirtualTextInfo",
    end_row = selected_metadata.range["end"].row,
    end_col = selected_metadata.range["end"].col,
    priority = 250,
  })

  local spinner = animation.inline({
    bufnr = bufnr,
    range = vim.tbl_deep_extend("force", selected_metadata.range, {
      start = {
        col = selected_metadata.value_range.start.col,
      },
    }),
    interval = 50,
    hl_group = "Comment",
    text = "",
  })

  active_pickers[bufnr] = {
    spinner = spinner,
  }

  -- this is the cb that is passed as paraemter in the 'choices' function
  -- i.e., the user should call the cb when they have obtained the async results
  local function handle_completions(items)
    local active_op = active_pickers[bufnr]
    if not active_op then
      return
    end

    cleanup_spinner(bufnr)

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if not items or vim.tbl_count(items) == 0 then
      vim.notify(string.format("Checkmate: No choices available for @%s", selected_metadata.tag), vim.log.levels.INFO)
      M.cleanup_ui(bufnr)
      return
    end

    vim.schedule(function()
      picker.select(items, {
        prompt = "Select value for @" .. selected_metadata.tag,
        format_item = function(item)
          if item == selected_metadata.value then
            return item .. " (current)"
          end
          return item
        end,
        on_choice = function(choice)
          vim.schedule(function()
            M.cleanup_ui(bufnr)
          end)
          if choice and choice ~= selected_metadata.value then
            on_select(choice, selected_metadata)
          end
        end,
      })
    end)
  end

  local success, result = pcall(function()
    return meta_module.get_choices(selected_metadata.tag, handle_completions, todo_item, bufnr)
  end)

  if not success then
    M.cleanup_ui(bufnr)
    vim.notify(
      string.format("Checkmate: Error getting completions for @%s: %s", selected_metadata.tag, tostring(result)),
      vim.log.levels.ERROR
    )
    return
  end
end

return M
