-- Native adapter: vim.ui.select

---@class checkmate.picker.NativeAdapter : checkmate.picker.Adapter
local M = {}

---@param ctx checkmate.picker.AdapterContext
function M.select(ctx)
  local items = ctx.items or {}
  local display = {}
  for i = 1, #items do
    display[i] = ctx.format_item(items[i])
  end

  vim.ui.select(display, { prompt = ctx.prompt or "Select", kind = ctx.kind }, function(_, idx)
    if not idx then
      if ctx.on_cancel then
        ctx.on_cancel()
      end
      return
    end
    local it = items[idx]
    if it and ctx.on_accept then
      ctx.on_accept(it)
    end
  end)
end

return M
