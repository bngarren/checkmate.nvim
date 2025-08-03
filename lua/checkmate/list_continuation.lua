local util = require("checkmate.util")
local ph = require("checkmate.parser.helpers")

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

M._termcodes = {
  cr = "",
  -- stop the last undo block here
  -- see :h undo-break
  undo_break = "",
  delete_to_eol = "",
  -- ensure the cursor starts at col 0 before adding absolute indent
  -- note: otherwise `\r` will put the cursor on a new line but may auto indent
  ctrl_o0 = "",
}

-- can enable for testing
M._disable_async = false

function M._get_termcode(name)
  if not M._termcodes[name] then
    if name == "cr" then
      M._termcodes[name] = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
    elseif name == "undo_break" then
      M._termcodes[name] = vim.api.nvim_replace_termcodes("<C-g>u", true, false, true)
    elseif name == "delete_to_eol" then
      M._termcodes[name] = vim.api.nvim_replace_termcodes("<C-o>D", true, false, true)
    elseif name == "ctrl_o0" then
      M._termcodes[name] = vim.api.nvim_replace_termcodes("<C-o>0", true, false, true)
    end
  end
  return M._termcodes[name]
end

--- @param todo table
--- @param config checkmate.Config
--- @return string
function M._build_checkbox_marker(todo, config)
  if config.list_continuation.inherit_state then
    if todo.is_markdown then
      return todo.raw
    else
      return config.todo_states[todo.state].marker
    end
  else
    -- don't inherit state, use default "unchecked"
    if todo.is_markdown then
      return string.format("[%s]", config.todo_states.unchecked.markdown)
    else
      return config.todo_states.unchecked.marker
    end
  end
end

--- This function is used to provide the `:h map-expression` when creating keymaps for Insert mode
---
--- It essentially checks if the current line (in insert mode) is a todo line (either Markdown or Checkmate/unicode style) and
--- if true, returns an expression string that creates a new todo line with correct indentation and marker in an undo-friendly way
---
--- Default behavior is to only work when cursor is at end of line (this can be configured with `opts.eol_only`)
--- @param opts? {nested?: boolean, eol_only?: boolean}
--- @return string  "" to swallow the key, or "<CR>" to fall back
function M.expr_newline(opts)
  opts = opts or {}

  if opts.nested == nil then
    opts.nested = false
  end
  if opts.eol_only == nil then
    opts.eol_only = true
  end

  local config = require("checkmate.config")

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  col = col - 1 -- convert to 0-based

  local line = vim.api.nvim_get_current_line()

  local cursor_is_eol = util.is_end_of_line(line, col)

  -- only trigger if we're at EOL of a todo
  if opts.eol_only and not cursor_is_eol then
    return M._get_termcode("cr")
  end

  local todo = ph.match_todo(line)
  if not todo then
    return M._get_termcode("cr")
  end

  -- get indent: same as parent, plus 2 spaces if nested
  local child_indent = opts.nested and 2 or 0
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

  -- if <CR>/<S-CR> occurs within a line, we grab the remaining string we can append it to the new todo
  local text_after_cursor = ""
  if not cursor_is_eol then
    text_after_cursor = string.sub(line, col + 2) -- +2 because col is 0-based and sub is 1-based
    text_after_cursor = util.trim_leading(text_after_cursor)
  end

  local insert_text = indent_str .. todo.list_marker .. " " .. box .. " "
  if text_after_cursor ~= "" then
    -- the expected cursor behavior is to end up in front of the broken text from the prev row
    -- position the cursor in front of the text_after_cursor
    local target_col = #insert_text

    if not M._disable_async then
      M._vim.schedule(function()
        vim.api.nvim_win_set_cursor(0, { row + 1, target_col })
      end)
    end

    insert_text = insert_text .. text_after_cursor
  end

  return M._build_expr(insert_text, { is_eol = cursor_is_eol })
end

function M._build_expr(text, opts)
  opts = opts or {}

  local parts = {
    M._get_termcode("undo_break"),
    opts.is_eol == false and M._get_termcode("delete_to_eol") or "",
    "\r",
    M._get_termcode("ctrl_o0"),
    text,
  }
  return table.concat(parts, "")
end

return M
