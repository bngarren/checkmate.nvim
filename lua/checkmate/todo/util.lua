local M = {}

local api = vim.api

--- Jump to a todo's source buffer and row
---
--- `checkmate.Todo.row` is 0 because it comes from parser positions
--- Nvim window cursors are 1-based
---@param todo checkmate.Todo|any
---@return boolean success
function M.jump_to_todo(todo)
  if type(todo) ~= "table" then
    return false
  end

  local bufnr = todo.bufnr
  local row = todo.row
  local col = type(todo.col) == "number" and todo.col or 0

  if not (bufnr and type(row) == "number") then
    return false
  end

  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if not api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.fn.bufload, bufnr)
  end

  local ok_buf = pcall(api.nvim_set_current_buf, bufnr)
  if not ok_buf then
    return false
  end

  local ok_cursor = pcall(api.nvim_win_set_cursor, 0, { row + 1, col })
  return ok_cursor
end

return M
