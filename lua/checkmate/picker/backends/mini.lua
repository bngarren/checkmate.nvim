-- mini.pick
-- https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-pick.md
-- NOTE: tested with v0.16.0

---@class checkmate.picker.MiniAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local make_choose = picker_util.make_choose

local function load_minipick()
  local ok, minipick = pcall(require, "mini.pick")
  if not ok then
    -- picker.init fallback path will handle this
    error("mini.pick not available")
  end
  return minipick
end

local centered_win_config = function()
  local height = math.floor(0.618 * vim.o.lines)
  local width = math.floor(0.618 * vim.o.columns)
  return {
    anchor = "NW",
    height = height,
    width = width,
    row = math.floor(0.5 * (vim.o.lines - height)),
    col = math.floor(0.5 * (vim.o.columns - width)),
  }
end

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local Pick = load_minipick()

  local items = ctx.items or {}

  local entry_maker = function(i)
    return {
      __cm_item = i,
      text = i.text or "",
    }
  end

  local choose = make_choose(ctx, {
    schedule = true,
  })

  local start_opts = vim.tbl_deep_extend("force", {
    source = {
      name = ctx.prompt or "Select",
      items = vim.tbl_map(entry_maker, items),
      choose = choose,
    },
    window = { config = centered_win_config },
  }, ctx.backend_opts or {})

  Pick.start(start_opts)
end

function M.pick_todo(ctx)
  local Pick = load_minipick()

  local items = ctx.items or {}

  -- see MiniPick-source.items-stritems: it will use the `text` field of the proxy to serve as the string representation
  -- for matching, i.e. the `stritem`

  local entry_maker = function(i)
    ---@type checkmate.Todo|any
    local todo = i.value

    local e = {
      __cm_item = i,
      text = i.text or "",
    }

    if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
      -- mini uses `buf` + `pos = {lnum, col}`
      e.buf = todo.bufnr
      e.pos = { todo.row + 1, 0 }
    end

    return e
  end

  ---@type checkmate.picker.after_select
  local function after_select(_, entry)
    local bufnr = entry.buf
    local row = entry.pos[1]

    if bufnr and type(row) == "number" then
      if vim.api.nvim_buf_is_valid(bufnr) then
        if not vim.api.nvim_buf_is_loaded(bufnr) then
          pcall(vim.fn.bufload, bufnr)
        end
        pcall(vim.api.nvim_set_current_buf, bufnr)
        pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
      end
    end
    -- implicit nil return will close mini.pick
  end

  local choose = make_choose(ctx, { schedule = true, after_select = after_select })

  local start_opts = vim.tbl_deep_extend("force", {
    source = {
      items = vim.tbl_map(entry_maker, items),
      name = ctx.prompt or "Todos",
      choose = choose,
    },
    window = { config = centered_win_config },
  }, ctx.backend_opts or {})

  Pick.start(start_opts)
end

return M
