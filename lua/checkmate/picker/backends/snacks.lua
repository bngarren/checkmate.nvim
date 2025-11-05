---@class checkmate.picker.SnacksAdapter : checkmate.picker.Adapter
local M = {}

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local Snacks = require("snacks")

  ---@type snacks.picker.Config
  local base = {
    title = (ctx.prompt or "Select"):gsub("^%s*", ""):gsub("[%s:]*$", ""),
    finder = function()
      ---@type snacks.picker.finder.Item[]
      local ret = {}
      for idx, item in ipairs(ctx.items) do
        local text = ctx.format_item and ctx.format_item(item) or item.text
        ---@type snacks.picker.finder.Item
        local it = { text = text, item = item, idx = idx, preview = { text = vim.inspect(item.value) } }
        ret[#ret + 1] = it
      end
      return ret
    end,
    -- preview = "preview",
    format = "text",
    actions = {
      confirm = function(picker, it)
        picker:close()
        if it and ctx.on_accept then
          ctx.on_accept(it.item) -- return the original checkmate.picker.Item
        end
      end,
      cancel = function(picker)
        picker:close()
        if ctx.on_cancel then
          ctx.on_cancel()
        end
      end,
    },
    layout = ctx.preview and "dropdown" or "select",
  }

  -- Merge user backend_opts (they can provide preview, layout, sorts, etc.)
  ---@type snacks.picker.Config
  local opts = Snacks.config.merge({}, base, ctx.backend_opts or {})

  return Snacks.picker.pick(opts)
end

return M
