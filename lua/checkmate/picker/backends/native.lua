-- Native adapter: vim.ui.select

---@class checkmate.picker.NativeAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local proxy = picker_util.proxy
local make_choose = picker_util.make_choose

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local items = ctx.items or {}

  local proxies, resolve = proxy.build(items)

  local choose = make_choose(ctx, resolve, {
    schedule = true,
  })

  ---vim.ui.select cb has signature:
  ---`on_choice fun(item: T|nil, idx: integer|nil)`
  vim.ui.select(
    proxies,
    vim.tbl_deep_extend("force", {
      prompt = ctx.prompt or "Select",
      kind = ctx.kind,
      format_item = function(p)
        return p.text or ""
      end,
    }, ctx.backend_opts),
    choose
  )
end

---**Callbacks**:
--- - will call ctx.on_select_item(Todo) (user callback) then
--- perform a basic jump
---@param ctx checkmate.picker.AdapterContext
function M.pick_todo(ctx)
  local items = ctx.items or {}
  local proxies, resolve = proxy.build(items)

  ---@type checkmate.picker.after_select
  local function after_select(orig)
    local todo = orig and orig.value
    if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
      if vim.api.nvim_buf_is_valid(todo.bufnr) then
        if not vim.api.nvim_buf_is_loaded(todo.bufnr) then
          pcall(vim.fn.bufload, todo.bufnr)
        end
        pcall(vim.api.nvim_set_current_buf, todo.bufnr)
        pcall(vim.api.nvim_win_set_cursor, 0, { todo.row + 1, 0 })
      end
    end
  end

  vim.ui.select(
    proxies,
    vim.tbl_deep_extend("force", {
      prompt = ctx.prompt or "Todos",
      kind = ctx.kind,
      format_item = function(p)
        return p.text or ""
      end,
    }, ctx.backend_opts),
    make_choose(ctx, resolve, { schedule = true, after_select = after_select })
  )
end

return M
