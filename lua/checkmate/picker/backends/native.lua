-- Native adapter: vim.ui.select

---@class checkmate.picker.NativeAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local make_choose = picker_util.make_choose
local api = vim.api

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local items = ctx.items or {}
  if #items == 0 then
    return
  end

  local labels = vim.tbl_map(function(item)
    return item.text or ""
  end, items)

  local choose = make_choose(ctx, {
    schedule = true,
  })

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

      -- pass the Item directly...`make_choose` will treat it as the resolved item
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
  local function after_select(item)
    local todo = item.value
    if type(todo) ~= "table" then
      return
    end

    local bufnr = todo.bufnr
    local row = todo.row

    if not (bufnr and type(row) == "number") then
      return
    end

    if not api.nvim_buf_is_valid(bufnr) then
      return
    end

    if not api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.fn.bufload, bufnr)
    end

    pcall(api.nvim_set_current_buf, bufnr)
    pcall(api.nvim_win_set_cursor, 0, { row + 1, 0 })
  end

  local choose = make_choose(ctx, {
    schedule = true,
    after_select = after_select,
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
