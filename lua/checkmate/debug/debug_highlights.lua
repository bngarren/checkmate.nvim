local config = require("checkmate.config")

local M = {}

M._active = {} -- maps bufnr -> list of extmark ids
M._color_idx = 1

local palette = {
  "#3b3b3b",
  "#5b5b5b",
  "#7b7b7b",
  "#9b9b9b",
}

function M.setup()
  for i, color in ipairs(palette) do
    vim.api.nvim_set_hl(0, ("CheckmateDebugHl%d"):format(i), { bg = color })
  end
end

---@param bufnr integer
function M.dispose(bufnr)
  M.clear_all(bufnr)
end

local function next_hl_group()
  local name = ("CheckmateDebugHl%d"):format(M._color_idx)
  M._color_idx = (M._color_idx % #palette) + 1
  return name
end

--- Highlight a single range.
---@param range checkmate.Range
---@param opts? { bufnr?: integer, timeout?: integer, persistent?: boolean }
---@return integer extmark_id
function M.add(range, opts)
  opts = vim.tbl_extend("force", {
    bufnr = vim.api.nvim_get_current_buf(),
    timeout = 10000,
    persistent = false,
  }, opts or {})

  local hl_group = next_hl_group()

  local ext_id = vim.api.nvim_buf_set_extmark(opts.bufnr, config.ns, range.start.row, range.start.col, {
    end_row = range["end"].row,
    end_col = range["end"].col,
    hl_group = hl_group,
    priority = 9999,
  })

  M._active[opts.bufnr] = M._active[opts.bufnr] or {}
  table.insert(M._active[opts.bufnr], ext_id)

  if not opts.persistent then
    vim.defer_fn(function()
      M.clear(opts.bufnr, ext_id)
    end, opts.timeout)
  end

  return ext_id
end

---Clear one highlight by extmark id in a given buffer
---@param bufnr number
---@param ext_id number
function M.clear(bufnr, ext_id)
  local ids = M._active[bufnr]
  if not ids then
    return false
  end
  for i, id in ipairs(ids) do
    if id == ext_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, id)
      table.remove(ids, i)
      if #ids == 0 then
        M._active[bufnr] = nil
      end
      return true
    end
  end
  return false
end

---Clear *all* highlights in a specific buffer
---@param bufnr integer
function M.clear_buffer(bufnr)
  local ids = M._active[bufnr]
  if not ids then
    return
  end
  for _, id in ipairs(ids) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, id)
  end
  M._active[bufnr] = nil
end

---Clear *all* highlights (or only one buffer if you pass bufnr)
---@param bufnr? integer
function M.clear_all(bufnr)
  if bufnr then
    M.clear_buffer(bufnr)
  else
    for b in pairs(M._active) do
      M.clear_buffer(b)
    end
  end
end

---List active extmark IDs
---@return table -- { bufnr, id }
function M.list()
  return vim.tbl_deep_extend("force", {}, M._active)
end

return M
