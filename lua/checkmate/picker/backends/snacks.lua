---@class checkmate.picker.SnacksAdapter : checkmate.picker.Adapter
local M = {}

---@param ctx checkmate.picker.AdapterContext
function M.select(ctx)
  local snacks = require("snacks")

  ---@type snacks.picker.ui_select.Opts
  local opts = vim.tbl_extend("force", ctx.backend_opts or {}, {
    prompt = ctx.prompt or "Select",
    kind = ctx.kind,
    format_item = function(item)
      -- item is checkmate.picker.Item
      return ctx.format_item(item)
    end,
  })

  snacks.picker.select(ctx.items, opts, function(chosen, idx)
    if not idx or not chosen then
      if ctx.on_cancel then
        ctx.on_cancel()
      end
      return
    end
    -- chosen is our original item (checkmate.picker.Item)
    if ctx.on_accept then
      ctx.on_accept(chosen)
    end
  end)
end

return M
