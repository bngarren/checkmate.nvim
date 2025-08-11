local M = {}

---@class checkmate.TextDiffHunk
---@field start_row integer 0-based row
---@field start_col integer 0-based col
---@field end_row integer 0-based row
---@field end_col integer 0-based col
---@field insert string[] Lines to insert
---@field _type? "line_insert" | "line_replace" | "text_replace" | "text_insert" Internal type hint
local TextDiffHunk = {}
TextDiffHunk.__index = TextDiffHunk

--- Create a new TextDiffHunk
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@param insert string[]
---@return checkmate.TextDiffHunk
function TextDiffHunk:new(start_row, start_col, end_row, end_col, insert)
  self = setmetatable({
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
    insert = insert or {},
  }, TextDiffHunk)

  self:_detect_type()
  return self
end

function TextDiffHunk:_detect_type()
  local is_line_boundary = self.start_col == 0 and self.end_col == 0
  local is_same_pos = self.start_row == self.end_row and self.start_col == self.end_col

  if is_line_boundary and is_same_pos and #self.insert > 0 then
    self._type = "line_insert"
  elseif is_line_boundary and self.start_row ~= self.end_row then
    self._type = "line_replace"
  elseif is_same_pos then
    self._type = "text_insert"
  else
    self._type = "text_replace"
  end
end

--- Apply this hunk to a buffer
---@param bufnr integer
---@param opts? {undojoin?: boolean}
function TextDiffHunk:apply(bufnr, opts)
  opts = opts or {}

  if opts.undojoin then
    vim.cmd("silent! undojoin")
  end

  if self._type == "line_insert" then
    -- pure line insertion - use nvim_buf_set_lines for efficiency
    vim.api.nvim_buf_set_lines(bufnr, self.start_row, self.start_row, false, self.insert)
  elseif self._type == "line_replace" and self.start_col == 0 and self.end_col == 0 then
    -- full line replacement without preserving extmarks
    vim.api.nvim_buf_set_lines(bufnr, self.start_row, self.end_row, false, self.insert)
  else
    -- text operation - preserves extmarks
    vim.api.nvim_buf_set_text(bufnr, self.start_row, self.start_col, self.end_row, self.end_col, self.insert)
  end
end

----------------------------------
-- Hunk factory methods

--- Create a hunk for replacing an entire line
---@param row integer 0-based row
---@param text string New line text
---@return checkmate.TextDiffHunk
function M.make_line_replace(row, text)
  return TextDiffHunk:new(row, 0, row + 1, 0, { text })
end

--- Create a hunk for inserting new lines
---@param row integer 0-based row to insert at
---@param lines string[] Lines to insert
---@return checkmate.TextDiffHunk
function M.make_line_insert(row, lines)
  return TextDiffHunk:new(row, 0, row, 0, lines)
end

--- Create a hunk for replacing text within a line (preserves extmarks)
---@param row integer 0-based row
---@param start_col integer 0-based byte column
---@param end_col integer 0-based byte column (exclusive)
---@param text string Replacement text
---@return checkmate.TextDiffHunk
function M.make_text_replace(row, start_col, end_col, text)
  return TextDiffHunk:new(row, start_col, row, end_col, { text })
end

--- Create a hunk for inserting text at a position
---@param row integer 0-based row
---@param col integer 0-based byte column
---@param text string Text to insert
---@return checkmate.TextDiffHunk
function M.make_text_insert(row, col, text)
  return TextDiffHunk:new(row, col, row, col, { text })
end

--- Create a hunk for deleting text
---@param row integer 0-based row
---@param start_col integer 0-based byte column
---@param end_col integer 0-based byte column (exclusive)
---@return checkmate.TextDiffHunk
function M.make_text_delete(row, start_col, end_col)
  return TextDiffHunk:new(row, start_col, row, end_col, {})
end

--- Create a hunk for replacing a specific marker in a todo item
---@param todo_item checkmate.TodoItem
---@param new_marker string
---@return checkmate.TextDiffHunk
function M.make_marker_replace(todo_item, new_marker)
  local row = todo_item.todo_marker.position.row
  local col = todo_item.todo_marker.position.col
  local old_marker_len = #todo_item.todo_marker.text

  return M.make_text_replace(row, col, col + old_marker_len, new_marker)
end

--- Create a hunk for appending text to the end of a line
---@param row integer 0-based row
---@param text string Text to append
---@param bufnr integer Buffer number
---@return checkmate.TextDiffHunk
function M.make_line_append(row, text, bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col = #line
  return M.make_text_insert(row, col, text)
end

-----------------------------------

--[[
Apply diff hunks to buffer 

Line insertion vs text replacement
- nvim_buf_set_text: used for replacements and insertions WITHIN a line
  this is important because it preserves extmarks that are not directly in the replaced range
  i.e. the extmarks that track todo location
- nvim_buf_set_lines: used for inserting NEW LINES
  when used with same start/end positions, it inserts new lines without affecting
  existing lines or their extmarks.

We use nvim_buf_set_lines for whole line insertions (when start_col = end_col = 0)
because it's cleaner and doesn't risk affecting extmarks on adjacent lines.
For all other operations (replacements, partial line edits), we use nvim_buf_set_text
to preserve extmarks as much as possible.
--]]
---@param bufnr integer Buffer number
---@param hunks checkmate.TextDiffHunk[]
function M.apply_diff(bufnr, hunks)
  if vim.tbl_isempty(hunks) then
    return
  end

  -- backwards comptability (convert to TextHunkDiff)
  local converted_hunks = {}
  ---@cast converted_hunks checkmate.TextDiffHunk[]
  for _, hunk in ipairs(hunks) do
    if getmetatable(hunk) == TextDiffHunk then
      table.insert(converted_hunks, hunk)
    else
      -- Old format - convert
      local new_hunk = TextDiffHunk:new(hunk.start_row, hunk.start_col, hunk.end_row, hunk.end_col, hunk.insert)
      table.insert(converted_hunks, new_hunk)
    end
  end

  -- Sort hunks bottom to top so that row numbers don't change as we apply hunks
  table.sort(converted_hunks, function(a, b)
    if a.start_row ~= b.start_row then
      return a.start_row > b.start_row
    end
    return a.start_col > b.start_col
  end)

  -- apply hunks (first one creates undo entry, rest join)
  for i, hunk in ipairs(converted_hunks) do
    local undojoin = i > 1 -- join all operations after the first
    hunk:apply(bufnr, { undojoin = undojoin })
  end
end

M.TextDiffHunk = TextDiffHunk

return M
