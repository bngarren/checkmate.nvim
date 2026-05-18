--- Todo picker module (internal)
--- a "domain-picker bridge" as we refer to it in internal docs
--- links the public todo-selection API to the generic picker engine
local M = {}

local picker = require("checkmate.picker")
local picker_util = require("checkmate.picker.util")
local todo_util = require("checkmate.todo.util")

--- Normalize a feature-level custom picker result into a picker item
---
--- select_todo custom pickers are domain-level, so they may call
--- complete(todo) with a raw checkmate.Todo. Internally we still complete through
--- the picker engine's Item-based shape
---@param choice checkmate.Todo|checkmate.picker.Item|nil
---@return checkmate.picker.Item|nil|any
local function normalize_custom_choice(choice)
  if choice == nil then
    return nil
  end

  local item = picker_util.resolve_item(choice)
  if item then
    return item
  end

  if type(choice) == "table" and choice.bufnr and type(choice.row) == "number" then
    return {
      text = tostring(choice.text or ""),
      value = choice,
    }
  end

  return choice
end

--- Open the default todo picker
---@param todos checkmate.Todo[]
---@param picker_opts? checkmate.PickerOpts
---@return boolean success
function M.open_picker(todos, picker_opts)
  local items = picker.map_items(todos, "text")

  return picker.pick(items, {
    method = "pick_todo",
    picker_opts = picker_opts,
  })
end

--- Execute a user-provided todo custom picker
---@param todos checkmate.Todo[]
---@param custom_picker fun(todos: checkmate.Todo[], complete: fun(choice: checkmate.Todo|checkmate.picker.Item|nil))
---@return boolean success
function M.with_custom_picker(todos, custom_picker)
  local items = picker.map_items(todos, "text")
  local choose = picker_util.make_item_completion({
    items = items,
    backend_opts = {},
    format_item_text = function(item)
      return item.text or ""
    end,
    on_select_item = function(item)
      todo_util.jump_to_todo(item.value)
    end,
  })

  local function complete(choice)
    choose(normalize_custom_choice(choice))
  end

  local custom_ok, custom_err = pcall(custom_picker, todos, complete)
  if not custom_ok then
    vim.notify(string.format("Checkmate: error in `custom_picker` for `select_todo`:\n%s", custom_err))
    return false
  end

  return true
end

return M
