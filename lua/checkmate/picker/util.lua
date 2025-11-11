local M = {}

local log = require("checkmate.log")

---@class checkmate.picker.MakeChooseOpts
---@field schedule? boolean
---@field after_select? fun(item: checkmate.picker.Item, entry: any)

---@alias checkmate.picker.after_select fun(item: checkmate.picker.Item, entry: any)

--- Create a selection handler:
--- - accepts a backend "entry" (created in the adapter code, fed to the picker as its internal representation)
--- - resolves to the original checkmate.picker.Item
--- - calls ctx.on_select_item(item) once
--- - optionally runs after_select(item, entry) for adapter specific code to run after the caller's on_select
--- - can run via vim.schedule() if `schedule=true`
---
---@param ctx checkmate.picker.AdapterContext
---@param opts? checkmate.picker.MakeChooseOpts
---@return fun(entry: any) choose
function M.make_choose(ctx, opts)
  opts = opts or {}
  local schedule = opts.schedule
  local after_select = opts.after_select
  local completed = false

  local function run(fn)
    if schedule then
      vim.schedule(fn)
    else
      fn()
    end
  end

  return function(entry)
    if completed or entry == nil then
      return
    end
    completed = true

    ---@type checkmate.picker.Item|nil
    local item

    if type(entry) == "table" and entry.__cm_item ~= nil then
      item = entry.__cm_item
    else
      -- allow native or other adapters to pass the item directly
      item = entry
    end

    if not item then
      return
    end

    run(function()
      if ctx.on_select_item then
        local ok_sel, err_sel = pcall(ctx.on_select_item, item)
        if not ok_sel then
          log.fmt_error("[picker] on_select_item failed: %s", tostring(err_sel))
        end
      end

      if after_select then
        local ok_after, err_after = pcall(after_select, item, entry)
        if not ok_after then
          log.fmt_error("[picker] after_select failed: %s", tostring(err_after))
        end
      end
    end)
  end
end

return M
