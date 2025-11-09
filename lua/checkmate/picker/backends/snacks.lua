-- snacks.nvim
-- https://github.com/folke/snacks.nvim/blob/main/docs/picker.md
-- NOTE: tested with v2.26.0

---@class checkmate.picker.SnacksAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local proxy = picker_util.proxy
local make_choose = picker_util.make_choose

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    -- core fallback path will handle this (adapter is wrapped with pcall & fallback)
    error("snacks.nvim not available")
  end

  local items = ctx.items or {}
  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
  })

  local choose = make_choose(ctx, resolve, {
    schedule = true,
  })

  ---@type snacks.picker.Config
  local base = {
    title = (ctx.prompt or "Select"):gsub("^%s*", ""):gsub("[%s:]*$", ""),
    layout = "select",
    format = "text",
    finder = function()
      -- Snacks finder expects a list of items
      -- Each proxy is: { idx = number, text = string, ... }
      return proxies
    end,
    actions = {
      confirm = function(picker, it, action)
        choose(it, { action = action })
        picker:close()
      end,
    },
  }

  ---@type snacks.picker.Config
  local opts = Snacks.config.merge({}, base, ctx.backend_opts or {}) -- deep merge

  return Snacks.picker.pick(opts)
end

function M.pick_todo(ctx)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    error("snacks.nvim not available")
  end

  local items = ctx.items or {}

  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
    decorate = function(p, item)
      ---@type checkmate.Todo
      local todo = item.value
      if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
        -- Snacks preview and jump expect buf/pos fields
        p.buf = todo.bufnr
        p.pos = { todo.row + 1, 0 }
      end
    end,
  })

  ---@type checkmate.picker.after_select
  local function after_select(_, item, extra)
    -- must match how we decorated the proxy item
    local bufnr = item.buf
    local pos = item.pos

    if bufnr and pos then
      require("snacks.picker.actions").jump(extra.picker, extra.item, extra.action)
    end
  end

  local choose = make_choose(ctx, resolve, {
    schedule = true,
    after_select = after_select,
  })

  ---@type snacks.picker.Config
  local base = {
    title = (ctx.prompt or "Todos"):gsub("^%s*", ""):gsub("[%s:]*$", ""),
    layout = "dropdown",
    format = "text",
    finder = function()
      return proxies -- {__cm_idx, text, ...}
    end,
    actions = {
      confirm = function(picker, item, action)
        -- item = proxy item fields + snack's finder.Item fields {idx, score, ...}
        choose(item, { picker = picker, item = item, action = action })
        picker:close()
      end,
    },
  }

  local opts = Snacks.config.merge({}, base, ctx.backend_opts or {})

  return Snacks.picker.pick(opts)
end

return M
