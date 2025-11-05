---@class checkmate.picker.MiniAdapter : checkmate.picker.Adapter
local M = {}

---@param ctx checkmate.picker.AdapterContext
function M.select(ctx)
  local pick = require("mini.pick")
  local items = ctx.items or {}

  local lines = {}
  for i = 1, #items do
    lines[i] = ctx.format_item(items[i])
  end

  pick.start({
    source = {
      items = lines,
      name = ctx.prompt or "Select",
    },
    options = ctx.backend_opts or {},
    on_choose = function(_, idx)
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
    end,
  })
end

return M
