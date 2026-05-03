---@class checkmate.Range
---@field start {row: integer, col: integer}
---@field ["end"] {row: integer, col: integer}
local M = {}
M.__index = M

---@param start_pos {row: integer, col: integer}
---@param end_pos {row: integer, col: integer}
---@return checkmate.Range
function M.new(start_pos, end_pos)
  return setmetatable({ start = start_pos, ["end"] = end_pos }, M)
end

---Returns a checkmate.Range from a TSNode:range
---@param node TSNode
---@return checkmate.Range
function M.range_from_tsnode(node)
  local sr, sc, er, ec = node:range()
  return M.new({ row = sr, col = sc }, { row = er, col = ec })
end

-- Returns a checkmate.Range from a vim cursor position which is (1,0)-indexed
-- i.e. from |vim.api.nvim_win_get_cursor|
---@param cursor_pos integer[] A [[row, col]] tuple where row is 1-indexed
---@return checkmate.Range
function M.range_from_cursor_tuple(cursor_pos)
  local row, col = unpack(cursor_pos)
  row = row - 1 -- convert from 1-indexed row to 0-indexed
  return M.new({ row = row, col = col }, { row = row + 1, col = 0 })
end

---Returns true if (row, col) is within [start, end], inclusive.
---May pass either (row, col) or a position table {row=…, col=…}.
---@param self checkmate.Range
---@param row_or_pos integer|{row: integer, col: integer}
---@param col integer?
---@return boolean
function M:contains(row_or_pos, col)
  local row
  if type(row_or_pos) == "table" then
    row, col = row_or_pos.row, row_or_pos.col
  else
    row = row_or_pos
  end

  local sr, sc = self.start.row, self.start.col
  local er, ec = self["end"].row, self["end"].col

  if row < sr or row > er then
    return false
  end

  if row == sr and col < sc then
    return false
  end

  if row == er and col > ec then
    return false
  end

  return true
end

return M
