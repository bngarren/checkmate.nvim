-- mini.pick
-- https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-pick.md
-- NOTE: tested with v0.16.0

---@class checkmate.picker.MiniAdapter : checkmate.picker.Adapter
local M = {}

local picker_util = require("checkmate.picker.util")
local proxy = picker_util.proxy
local make_choose = picker_util.make_choose

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
  local ok, Pick = pcall(require, "mini.pick")
  if not ok then
    error("mini.pick not available")
  end

  local items = ctx.items or {}

  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
  })

  local choose = make_choose(ctx, resolve, {
    schedule = true,
  })

  local start_opts = vim.tbl_deep_extend("force", {
    source = {
      items = proxies,
      name = ctx.prompt or "Select",
      choose = choose,
    },
    window = { config = centered_win_config },
  }, ctx.backend_opts or {})

  local ok_run, err = pcall(Pick.start, start_opts)
  if not ok_run then
    error("mini.pick.start failed: " .. tostring(err))
  end
end

function M.pick_todo(ctx)
  local ok, Pick = pcall(require, "mini.pick")
  if not ok then
    error("mini.pick not available")
  end

  local items = ctx.items or {}
  -- see MiniPick-source.items-stritems: it will use the `text` field of the proxy to serve as the string representation
  -- for matching, i.e. the `stritem`
  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
    decorate = function(p, item)
      local todo = item.value
      if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
        -- provide to mini.pick for e.g. preview
        p.bufnr = todo.bufnr
        p.lnum = todo.row + 1 -- mini.pick's lnum is 1-indexed
        p.col = 0
      end
    end,
  })

  ---@type checkmate.picker.after_select
  local function after_select(orig)
    local todo = orig and orig.value
    local bufnr = todo and todo.bufnr
    local row = todo and todo.row

    if bufnr and type(row) == "number" then
      if vim.api.nvim_buf_is_valid(bufnr) then
        if not vim.api.nvim_buf_is_loaded(bufnr) then
          pcall(vim.fn.bufload, bufnr)
        end
        pcall(vim.api.nvim_set_current_buf, bufnr)
        pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, 0 })
      end
    end
    -- implicit nil return will close mini.pick
  end

  local choose = make_choose(ctx, resolve, { schedule = true, after_select = after_select })

  local start_opts = vim.tbl_deep_extend("force", {
    source = {
      items = proxies,
      name = ctx.prompt or "Todos",
      choose = choose,
    },
    window = { config = centered_win_config },
  }, ctx.backend_opts or {})

  local ok_run, err = pcall(Pick.start, start_opts)
  if not ok_run then
    error("mini.pick.start failed: " .. tostring(err))
  end
end

return M
