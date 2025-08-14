--[[
Buffer manipulation via diff hunks

 - Creates "diff hunks" (discrete change operations) that can be collected and applied to the buffer.
 - Uses `nvim_buf_set_lines` for whole-line operations (better performance) and `nvim_buf_set_text` for partial edits (to preserve extmarks outside the range). Notably, a todo's stable `id` is based on the extmark located on its todo marker. We try to preserve this so that todos can be tracked across buffer changes.
 - All positions are 0-based
 - All end positions are exclusive, following `nvim_buf_set_text` convention
 - Full line operations use col=0 for line start, col=0 on next row for line end

]]
local M = {}

---@class checkmate.TextDiffHunk
---@field start_row integer 0-based row
---@field start_col integer 0-based col
---@field end_row integer 0-based row
---@field end_col integer 0-based col (exclusive - char at end_col is not included)
---@field insert string[] Lines/text to insert
---@field _type? "line_insert" | "line_replace" | "text_replace" | "text_insert" | "text_delete" Internal type hint
local TextDiffHunk = {}
TextDiffHunk.__index = TextDiffHunk

--- Create a new TextDiffHunk
---@private
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer (exclusive)
---@param insert string[]
---@return checkmate.TextDiffHunk
function TextDiffHunk:_new(start_row, start_col, end_row, end_col, insert)
  self = setmetatable({
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    insert = insert or {},
  }, TextDiffHunk)

  return self
end

--- see if this hunk is effectively a no-op
---@return boolean
function TextDiffHunk:is_empty()
  -- delete nothing = no-op
  if self._type == "text_delete" and self.start_row == self.end_row and self.start_col == self.end_col then
    return true
  end

  -- insert nothing at same position = no-op
  if self._type == "text_insert" and #self.insert == 1 and self.insert[1] == "" then
    return true
  end

  -- replace with identical position and no content = no-op
  if
    self._type == "text_replace"
    and #self.insert == 0
    and self.start_row == self.end_row
    and self.start_col == self.end_col
    and (#self.insert == 0 or (#self.insert == 1 and self.insert[1] == ""))
  then
    return true
  end
  return false
end

--- Apply this hunk to a buffer
---@param bufnr integer
---@param opts? {undojoin?: boolean}
function TextDiffHunk:apply(bufnr, opts)
  opts = opts or {}

  -- skip no-op
  if self:is_empty() then
    return
  end

  if opts.undojoin ~= false then
    pcall(function()
      vim.cmd("silent! undojoin")
    end)
  end

  if self._type == "line_insert" then
    -- pure line insertion at row boundary
    vim.api.nvim_buf_set_lines(bufnr, self.start_row, self.start_row, false, self.insert)
  elseif self._type == "line_replace" then
    -- full line replacement - end_row is exclusive for lines
    vim.api.nvim_buf_set_lines(bufnr, self.start_row, self.end_row, false, self.insert)
  else
    -- preserves extmarks outside the modified range
    -- end_row is exclusive
    vim.api.nvim_buf_set_text(bufnr, self.start_row, self.start_col, self.end_row, self.end_col, self.insert)
  end
end

--- Transform input text to string array format
---@private
---@param text any
---@return string[] transformed
local function to_string_array(text)
  if type(text) == "string" then
    return vim.split(text, "\n", { plain = true })
  elseif type(text) == "table" then
    return text
  else
    return { tostring(text) }
  end
end

--- Validate row/col parameters
---@private
---@param row integer
---@param col integer?
---@return boolean valid
local function validate_position(row, col)
  if type(row) ~= "number" or row < 0 then
    return false
  end
  if col ~= nil and (type(col) ~= "number" or col < 0) then
    return false
  end
  return true
end

----------------------------------
-- Factory methods for creating hunks
----------------------------------

--- Create a hunk for replacing entire line(s)
---@param row integer|integer[] 0-based start row or [start, end] row tuple (end inclusive)
---@param text string|string[]? New line content (nil for deletion)
---@return checkmate.TextDiffHunk
function M.make_line_replace(row, text)
  local start_row, end_row
  if type(row) == "table" then
    start_row, end_row = row[1], row[2]
  else
    start_row, end_row = row, row
  end

  local content = text and to_string_array(text) or {}

  -- for line operations, we use exclusive end (end_row + 1)
  local hunk = TextDiffHunk:_new(start_row, 0, end_row + 1, 0, content)
  hunk._type = "line_replace"
  return hunk
end

--- Create a hunk for inserting new line(s)
---@param row integer 0-based row to insert before
---@param text string|string[] Line(s) to insert
---@return checkmate.TextDiffHunk
function M.make_line_insert(row, text)
  local content = to_string_array(text)
  local hunk = TextDiffHunk:_new(row, 0, row, 0, content)
  hunk._type = "line_insert"
  return hunk
end

--- Create a hunk for deleting entire line(s)
---@param row integer|integer[] 0-based row or [start, end] row tuple (end inclusive)
---@return checkmate.TextDiffHunk
function M.make_line_delete(row)
  return M.make_line_replace(row, nil)
end

--- Create a hunk for replacing text within a line
--- The character at end_col is NOT included in the replacement
---@param row integer 0-based row
---@param start_col integer 0-based byte column
---@param end_col integer 0-based byte column (exclusive)
---@param text string Replacement text
---@return checkmate.TextDiffHunk
function M.make_text_replace(row, start_col, end_col, text)
  if not validate_position(row, start_col) or not validate_position(row, end_col) then
    error("Invalid position parameters")
  end
  local hunk = TextDiffHunk:_new(row, start_col, row, end_col, { text })
  hunk._type = "text_replace"
  return hunk
end

--- Create a hunk for inserting text at a position
---@param row integer 0-based row
---@param col integer 0-based byte column
---@param text string Text to insert
---@return checkmate.TextDiffHunk
function M.make_text_insert(row, col, text)
  if not validate_position(row, col) then
    error("Invalid position parameters")
  end
  local hunk = TextDiffHunk:_new(row, col, row, col, { text })
  hunk._type = "text_insert"
  return hunk
end

--- Create a hunk for deleting text within a line
--- The character at end_col is NOT deleted
---@param row integer 0-based row
---@param start_col integer 0-based byte column
---@param end_col integer 0-based byte column (exclusive)
---@return checkmate.TextDiffHunk
function M.make_text_delete(row, start_col, end_col)
  if not validate_position(row, start_col) or not validate_position(row, end_col) then
    error("Invalid position parameters")
  end
  local hunk = TextDiffHunk:_new(row, start_col, row, end_col, {})
  hunk._type = "text_delete"
  return hunk
end

--- Create a hunk for appending text to the end of a line
---@param row integer 0-based row
---@param text string Text to append
---@param bufnr integer
---@return checkmate.TextDiffHunk
function M.make_line_append(row, text, bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return M.make_text_insert(row, #line, text)
end

----------------------------------
-- Convenience methods
----------------------------------

--- Create a hunk for replacing a specific marker in a todo item
---
--- Just a convenience wrapper around `make_text_replace()`
---@param todo_item checkmate.TodoItem
---@param new_marker string
---@return checkmate.TextDiffHunk
function M.make_marker_replace(todo_item, new_marker)
  local row = todo_item.todo_marker.position.row
  local col = todo_item.todo_marker.position.col
  local old_marker_len = #todo_item.todo_marker.text
  -- end_col is exclusive, so we add the length to get the position after the marker
  return M.make_text_replace(row, col, col + old_marker_len, new_marker)
end

----------------------------------
-- Batch operations
----------------------------------

---@param hunk table
---@return boolean valid
function M.is_valid_hunk(hunk)
  if not hunk or not type(hunk) == "table" then
    return false
  end

  return type(hunk.start_row) == "number"
    and type(hunk.start_col) == "number"
    and type(hunk.end_row) == "number"
    and type(hunk.end_col) == "number"
    and type(hunk.insert) == "table"
end

--- Apply multiple diff hunks to buffer
--- - Hunks are automatically sorted and applied bottom-to-top to handle row offsets.
--- - All operations are joined in a single undo entry for atomic undo/redo.
---@param bufnr integer
---@param hunks checkmate.TextDiffHunk[]
function M.apply_diff(bufnr, hunks)
  if not hunks or #hunks == 0 then
    return
  end

  local valid_hunks = {}
  for _, hunk in ipairs(hunks) do
    if M.is_valid_hunk(hunk) and not hunk:is_empty() then
      table.insert(valid_hunks, hunk)
    end
  end

  -- sort hunks bottom to top so that row numbers don't change as we apply hunks
  table.sort(valid_hunks, function(a, b)
    if a.start_row ~= b.start_row then
      return a.start_row > b.start_row
    end
    return a.start_col > b.start_col
  end)

  vim.api.nvim_buf_call(bufnr, function()
    -- apply hunks (first one creates undo entry, rest join)
    for i, hunk in ipairs(valid_hunks) do
      local undojoin = i > 1 -- join all operations after the first
      if not vim.tbl_isempty(hunk) then
        hunk:apply(bufnr, { undojoin = undojoin })
      end
    end
  end)
end

M.TextDiffHunk = TextDiffHunk

return M
