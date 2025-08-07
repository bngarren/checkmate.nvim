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
  - `eol_only` (default true), when false allows breaking a line and creating new todo with remainder
  - Falls back to a normal newline when not on a todo  
  - Each operation is a single undo step
--]]

local M = {}

-- can enable for testing
M._test_mode = false

function M._is_valid_cursor_position(col, todo)
  local config = require("checkmate.config")
  local box = todo.is_markdown and todo.raw or config.options.todo_states[todo.state].marker
  -- where the checkbox + space ends in "insert" mode positioning
  -- this is the insert pos 1 space after the box
  local threshold = todo.indent + #todo.list_marker + 1 + #box

  return col >= threshold
end

--- @param todo table See `parser.helpers.match_todo()`
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
--- if true, modifies the buffer using vim.schedule
---
--- Default behavior is to only work when cursor is at end of line (this can be configured with `opts.eol_only`)
--- @param opts? {cursor?: {row: integer, col: integer}, nested?: boolean, eol_only?: boolean}
--- @return string  "" to swallow the key, or "<CR>" to fall back
function M.expr_newline(opts)
  opts = vim.tbl_extend("force", { nested = false, eol_only = true }, opts or {})
  local config = require("checkmate.config").options

  local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)

  local row = vim.tbl_get(opts, "cursor", "row")
  local col = vim.tbl_get(opts, "cursor", "col")
  if not row or not col then
    row, col = unpack(vim.api.nvim_win_get_cursor(0))
  end

  local line = vim.api.nvim_get_current_line()
  local todo = ph.match_todo(line)

  -- not a todo or cursor before checkbox?  fall back
  if not todo or not M._is_valid_cursor_position(col, todo) then
    return cr
  end

  -- are we mid-line but eol_only disallows splitting?
  -- note: in insert mode, col == #line means cursor is after all text
  local at_eol = col >= #line
  if opts.eol_only and not at_eol then
    return cr
  end

  local box = M._build_checkbox_marker(todo, config)

  local li_marker_str = todo.list_marker

  -- handle ordered list auto-increment
  local next_ordered_marker = util.get_next_ordered_marker(li_marker_str, opts.nested)

  if next_ordered_marker ~= nil then
    li_marker_str = next_ordered_marker
  end

  -- nested indent is relative to the parent's list marker length
  local indent = todo.indent + (opts.nested and (#todo.list_marker + 1) or 0)
  local indent_str = string.rep(" ", indent)

  local prefix = indent_str .. li_marker_str .. " " .. box .. " "

  local function callback()
    -- start new undo‐break
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>u", true, false, true), "n", false)

    if not at_eol then
      -- split
      local after = line:sub(col + 1)
      vim.api.nvim_set_current_line(line:sub(1, col))
      vim.api.nvim_buf_set_lines(0, row + 1, row + 1, false, { prefix .. after })
      vim.api.nvim_win_set_cursor(0, { row + 2, #prefix }) -- row is 1-index so +2
    else
      -- new line below
      vim.api.nvim_buf_set_lines(0, row + 1, row + 1, false, { prefix })
      vim.api.nvim_win_set_cursor(0, { row + 2, #prefix })
    end
  end

  if M._test_mode then
    callback()
  else
    vim.schedule(callback)
  end

  -- swallow the <CR> so Vim doesn't do its native newline
  return ""
end

return M
