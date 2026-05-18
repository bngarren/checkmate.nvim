-- Native adapter: vim.ui.select

---@class checkmate.picker.NativeAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local todo_util = require("checkmate.todo.util")
local make_item_completion = picker_util.make_item_completion

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local items = ctx.items or {}
  if #items == 0 then
    return
  end

  local labels = vim.tbl_map(function(item)
    return item.text or ""
  end, items)

  local choose = make_item_completion(ctx)

  vim.ui.select(
    labels,
    vim.tbl_deep_extend("force", {
      prompt = ctx.prompt or "Select Todo",
      kind = ctx.kind,
      format_item = function(label)
        return label
      end,
    }, ctx.backend_opts or {}),
    function(_, idx)
      if not idx then
        return
      end

      local item = items[idx]
      if not item then
        return
      end

      -- pass the Item directly; item completion treats it as the resolved item
      choose(item)
    end
  )
end

---@param ctx checkmate.picker.AdapterContext
function M.pick_todo(ctx)
  local items = ctx.items or {}
  if #items == 0 then
    return
  end

  local labels = vim.tbl_map(function(item)
    return item.text or ""
  end, items)

  --- Jump to the todo's buffer/row after user callback
  local function after_item_select(item)
    todo_util.jump_to_todo(item.value)
  end

  local choose = make_item_completion(ctx, {
    after_item_select = after_item_select,
  })

  vim.ui.select(
    labels,
    vim.tbl_deep_extend("force", {
      prompt = ctx.prompt or "Todos",
      kind = ctx.kind,
      format_item = function(label)
        return label
      end,
    }, ctx.backend_opts or {}),
    function(_, idx)
      if not idx then
        return
      end

      local item = items[idx]
      if not item then
        return
      end

      choose(item)
    end
  )
end

return M
