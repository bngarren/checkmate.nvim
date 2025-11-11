-- snacks.nvim
-- https://github.com/folke/snacks.nvim/blob/main/docs/picker.md
-- NOTE: tested with v2.26.0

---@class checkmate.picker.SnacksAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local make_choose = picker_util.make_choose

local function load_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    -- picker.init fallback path will handle this
    error("snacks.nvim not available")
  end
  return snacks
end

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local snacks = load_snacks()

  local items = ctx.items or {}

  local entry_maker = function(i)
    return {
      __cm_item = i,
      --
      -- used by snacks
      text = i.text or "",
    }
  end

  local choose = make_choose(ctx, {
    schedule = true,
  })

  ---@type snacks.picker.Config
  local base = {
    title = (ctx.prompt or "Select"):gsub("^%s*", ""):gsub("[%s:]*$", ""),
    layout = "select",
    format = "text",
    items = vim.tbl_map(entry_maker, items),
    actions = {
      confirm = function(picker, it)
        picker:close()
        choose(it)
      end,
    },
  }

  ---@type snacks.picker.Config
  local opts = snacks.config.merge({}, base, ctx.backend_opts or {}) -- deep merge

  return snacks.picker.pick(opts)
end

function M.pick_todo(ctx)
  local snacks = load_snacks()

  local items = ctx.items or {}

  local entry_maker = function(i)
    local e = {
      __cm_item = i,
      --
      -- used by snacks
      text = i.text,
    }
    ---@type checkmate.Todo
    local todo = i.value
    if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
      -- Snacks preview and jump expect buf/pos fields
      e.buf = todo.bufnr
      e.pos = { todo.row + 1, 0 }
    end
    return e
  end

  local choose = make_choose(ctx, {
    schedule = true,
  })

  ---@type snacks.picker.Config
  local base = {
    title = (ctx.prompt or "Todos"):gsub("^%s*", ""):gsub("[%s:]*$", ""),
    layout = "dropdown",
    format = function(entry)
      local ret = {} ---@type snacks.picker.Highlight
      local display = vim.trim(entry.text)
      ret[#ret + 1] = { display }
      return ret
    end,
    items = vim.tbl_map(entry_maker, items),
    actions = {
      confirm = function(picker, item, action)
        picker:close()
        choose(item)
        snacks.picker.actions.jump(picker, item, action)
      end,
    },
  }

  local opts = snacks.config.merge({}, base, ctx.backend_opts or {})

  return snacks.picker.pick(opts)
end

return M
