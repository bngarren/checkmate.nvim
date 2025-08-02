local util = require("checkmate.util")
local ph = require("checkmate.parser.helpers")
local config = require("checkmate.config")

--[[
This module provides an `expr` mapping for `<CR>` and `<S-CR>` in Insert mode to
automatically create a new todo item below the current line:

  - `<CR>`   – insert a sibling todo (same indent)  
  - `<S-CR>` – insert a nested (child) todo (+2 spaces)

Notes:
  - Uses parser.helpers module to detects GitHub-style or Unicode checkbox lines 
  - `inherit_state` allows "reusing" the original line state, otherwise defaults to "unchecked"
  - Falls back to a normal newline when not on a todo  
  - Returns a single string so the entire operation stays in one undo step
--]]

local M = {}

--- @param nested boolean
--- @return string  "" to swallow the key, or "<CR>" to fall back
function M.expr_newline(nested)
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  col = col - 1 -- convert to 0-based

  local line = vim.api.nvim_get_current_line()

  -- only trigger if we're at EOL of a todo
  if not util.is_end_of_line(line, col) then
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end
  local todo = ph.match_todo(line)
  if not todo then
    return vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end

  -- get indent: same as parent, plus 2 spaces if nested
  local child_indent = nested and 2 or 0
  local indent = todo.indent + child_indent
  local indent_str = string.rep(" ", indent)

  -- todo marker
  --  - for markdown, use raw checkbox, e.g "[ ]"
  --  - for unicode, use the marker for that state
  local box
  if config.options.list_continuation.inherit_state then
    if todo.is_markdown then
      box = todo.raw
    else
      box = config.options.todo_states[todo.state].marker
    end
  else
    -- don't inherit state, use default "unchecked"
    if todo.is_markdown then
      box = string.format("[%s]", config.options.todo_states.unchecked.markdown)
    else
      box = config.options.todo_states.unchecked.marker
    end
  end

  -- stop the last undo block here
  -- see :h undo-break
  local undo_break = vim.api.nvim_replace_termcodes("<C-g>u", true, false, true)

  -- ensure the cursor starts at col 0 before adding absolute indent
  -- note: otherwise `\r` will put the cursor on a new line but may auto indent
  local ctrl_o0 = vim.api.nvim_replace_termcodes("<C-o>0", true, false, true)

  local insert_text = indent_str .. todo.list_marker .. " " .. box .. " "

  local prefix = undo_break .. "\r" .. ctrl_o0

  return prefix .. insert_text
end

return M
