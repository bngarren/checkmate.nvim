---@class checkmate.Util
local M = {}

local uv = vim.uv or vim.loop

---Returns true is current mode is VISUAL, false otherwise
---@return boolean
function M.is_visual_mode()
  local mode = vim.fn.mode()
  return mode:match("^[vV]") or mode == "\22"
end

---Calls vim.notify with the given message and log_level depending on if config.options.notify enabled
---@param msg any
---@param log_level any
function M.notify(msg, log_level)
  local config = require("checkmate.config")
  if config.options.notify then
    vim.notify(msg, log_level)
  else
    local hl_group = "Normal"
    if log_level == vim.log.levels.WARN then
      hl_group = "WarningMsg"
    elseif log_level == vim.log.levels.ERROR then
      hl_group = "ErrorMsg"
    end
    vim.api.nvim_echo({ msg, hl_group }, true, {})
  end
end

---@generic T
---@param fn T
---@param opts? {ms?:number}
---@return T
function M.debounce(fn, opts)
  local timer = assert(uv.new_timer())
  local ms = opts and opts.ms or 20
  return function()
    timer:start(ms, 0, vim.schedule_wrap(fn))
  end
end

---Blends the foreground color with the background color
---
---Credit to github.com/folke/snacks.nvim
---@param fg string|nil Foreground color (default #ffffff)
---@param bg string|nil Background color (default #000000)
---@param alpha number Number between 0 and 1. 0 results in bg, 1 results in fg.
---@return string: Color in hex format
function M.blend(fg, bg, alpha)
  -- Default colors if nil
  fg = fg or "#ffffff"
  bg = bg or "#000000"

  -- Validate inputs are hex colors
  if not (fg:match("^#%x%x%x%x%x%x$") and bg:match("^#%x%x%x%x%x%x$")) then
    -- Return a safe default if the colors aren't valid
    return "#888888"
  end

  local bg_rgb = { tonumber(bg:sub(2, 3), 16), tonumber(bg:sub(4, 5), 16), tonumber(bg:sub(6, 7), 16) }
  local fg_rgb = { tonumber(fg:sub(2, 3), 16), tonumber(fg:sub(4, 5), 16), tonumber(fg:sub(6, 7), 16) }
  local blend = function(i)
    local ret = (alpha * fg_rgb[i] + ((1 - alpha) * bg_rgb[i]))
    return math.floor(math.min(math.max(0, ret), 255) + 0.5)
  end
  return string.format("#%02x%02x%02x", blend(1), blend(2), blend(3))
end

---Gets a color from an existing highlight group (see :highlight-groups)
---
---Credit to github.com/folke/snacks.nvim
---@param hl_group string|string[] Highlight group(s) to get prop's color
---@param prop? string Property to get color from (default "fg")
---@param default? string Fallback color if not found (in hex format)
---@return string?: Color in hex format or nil
function M.get_hl_color(hl_group, prop, default)
  prop = prop or "fg"
  hl_group = type(hl_group) == "table" and hl_group or { hl_group }
  ---@cast hl_group string[]
  for _, g in ipairs(hl_group) do
    local hl = vim.api.nvim_get_hl(0, { name = g, link = false })
    if hl[prop] then
      return string.format("#%06x", hl[prop])
    end
  end
  return default
end

--- Escapes special characters in a string for safe use in a Lua pattern character class.
--
-- Use this when dynamically constructing a pattern like `[%s]` or `[-+*]`,
-- since characters like `-`, `]`, `^`, and `%` have special meaning inside `[]`.
--
-- Example:
--   escape_for_char_class("-^]") → "%-%^%]"
--
-- @param s string: Input string to escape
-- @return string: Escaped string safe for use inside a Lua character class
local function escape_for_char_class(s)
  if not s or s == "" then
    return ""
  end
  return s:gsub("([%%%^%]%-])", "%%%1")
end

--- Escapes special characters in a string for safe use in a Lua pattern as a literal.
--
-- This allows literal matching of characters like `(`, `[`, `.`, etc.,
-- which otherwise have special meaning in Lua patterns.
--
-- Example:
--   escape_literal(".*[abc]") → "%.%*%[abc%]"
--
---@param s string: Input string to escape
---@return string: Escaped string safe for literal matching in Lua patterns
local function escape_literal(s)
  if not s or s == "" then
    return ""
  end
  ---@diagnostic disable-next-line: redundant-return-value
  return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

--- Creates a pattern that matches list item prefixes, supporting:
-- 1. Simple markers (e.g., "-", "+", "*")
-- 2. Optional numbered formats (e.g., "1.", "1)")
--
---@param opts table: Options
--   - simple_markers: string | table of characters (default "-+*")
--   - use_numbered_list_markers: boolean (default true)
--   - with_capture: boolean - whether to wrap the pattern in a capturing group (default true)
---@return string[]: A Lua pattern for matching list prefixes
function M.create_list_prefix_patterns(opts)
  opts = opts or {}
  local simple_markers = opts.simple_markers or "-+*"
  local use_numbered = opts.use_numbered_list_markers ~= false
  local with_capture = opts.with_capture ~= false

  if type(simple_markers) == "table" then
    simple_markers = table.concat(simple_markers, "")
  end

  local escaped_simple = escape_for_char_class(simple_markers)

  local function wrap(p)
    return with_capture and "(" .. p .. ")" or p
  end

  local patterns = {
    wrap("%s*[" .. escaped_simple .. "]%s+"),
  }

  if use_numbered then
    table.insert(patterns, wrap("%s*%d+[%.)]%s+"))
  end

  return patterns
end

--- Tries each pattern in order and returns the first successful match.
--
-- @param patterns string[]: List of Lua patterns
-- @param str string: Input string to test
-- @return string|nil: The first match found, or nil if none match
function M.match_first(patterns, str)
  for _, pat in ipairs(patterns) do
    local match = str:match(pat)
    if match then
      return match
    end
  end
  return nil
end

--- Builds an array of Lua patterns to check if a line is a todo item.
-- Each call returns a list of full-match patterns that:
--   1. Start with a list prefix (simple or numbered)
--   2. Are followed by a specific todo marker (e.g., "□", "✔")
--
---@param opts table:
--   - simple_markers: string | table (e.g., "-+*")
--   - use_numbered_list_markers: boolean (default true)
---@return function(todo_marker): string[] pattern
function M.build_todo_patterns(opts)
  opts = opts or {}

  local prefix_patterns = M.create_list_prefix_patterns({
    simple_markers = opts.simple_markers,
    use_numbered_list_markers = opts.use_numbered_list_markers,
    with_capture = false,
  })

  --- Build multiple full-patterns from todo_marker
  -- @param todo_marker string: The todo marker to look for
  -- @return string[]: List of full Lua patterns to match
  local function build_patterns_with_marker(todo_marker)
    local escaped_todo = escape_literal(todo_marker)
    local patterns = {}
    for _, prefix in ipairs(prefix_patterns) do
      table.insert(patterns, "^" .. prefix .. (escaped_todo or ""))
    end
    return patterns
  end

  return build_patterns_with_marker
end

--- Builds one or more patterns with a capture group for the list prefix.
--
-- Each pattern captures the full list item prefix (whitespace + marker),
-- and appends a user-defined pattern that comes after.
--
---@param opts table:
--   - simple_markers: string|table - Characters like "-", "+", "*" (default: "-+*")
--   - use_numbered_list_markers: boolean - Whether to include "1." or "1)" (default: true)
--   - right_pattern: string - Pattern for content after list marker (default: "")
---@return string[]: A list of full patterns
function M.build_list_pattern(opts)
  opts = opts or {}

  local prefix_patterns = M.create_list_prefix_patterns({
    simple_markers = opts.simple_markers,
    use_numbered_list_markers = opts.use_numbered_list_markers,
    with_capture = true,
  })

  local right_pattern = opts.right_pattern or ""
  local full_patterns = {}

  for _, prefix in ipairs(prefix_patterns) do
    table.insert(full_patterns, prefix .. right_pattern)
  end

  return full_patterns
end

--- Builds patterns to match `- `, `* `, or other configured list markers
function M.build_empty_list_patterns(list_item_markers)
  return M.build_list_pattern({
    simple_markers = list_item_markers,
  })
end

--- Builds patterns to match a Unicode todo item like `- ✔`
function M.build_unicode_todo_patterns(list_item_markers, todo_marker)
  return M.build_list_pattern({
    simple_markers = list_item_markers,
    right_pattern = escape_literal(todo_marker),
  })
end

--- Builds patterns to match a Markdown checkbox like `- [x]` or `1. [ ]`
--
---@param list_item_markers table List item markers to use, e.g. {"-", "*", "+"}
---@param checkbox_pattern string Must be a Lua pattern, e.g. "%[[xX]%]"
---@return string[] List of full Lua patterns with capture group for list prefix
function M.build_markdown_checkbox_patterns(list_item_markers, checkbox_pattern)
  if not checkbox_pattern or checkbox_pattern == "" then
    error("checkbox_pattern cannot be nil or empty")
  end

  return M.build_list_pattern({
    simple_markers = list_item_markers,
    right_pattern = checkbox_pattern,
  })
end

---Returns a todo_map table sorted by start row
---@generic T: table<string, checkmate.TodoItem>
---@param todo_map T
---@return table T
function M.get_sorted_todo_list(todo_map)
  -- Convert map to array of {id, item} pairs
  local todo_list = {}
  for id, item in pairs(todo_map) do
    table.insert(todo_list, { id = id, item = item })
  end

  -- Sort by item.range.start.row
  table.sort(todo_list, function(a, b)
    return a.item.range.start.row < b.item.range.start.row
  end)

  return todo_list
end

--- Interprets a TS range's true end position, accounting for end_col = 0
---@param range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}}
---@param bufnr integer Buffer number
---@return {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Adjusted range
function M.get_true_range(range, bufnr)
  -- Create a new range object to avoid modifying the original
  local new_range = {
    start = { row = range.start.row, col = range.start.col },
    ["end"] = { row = range["end"].row, col = range["end"].col },
  }

  -- If end_col is 0, it means we're at the start of the next line
  -- which actually means the end of the previous line
  if new_range["end"].col == 0 then
    new_range["end"].row = new_range["end"].row - 1
  end

  -- For both cases (end_col=0 or multi-line), set end column to end of line
  if new_range["end"].col == 0 or new_range.start.row < new_range["end"].row then
    local lines = vim.api.nvim_buf_get_lines(bufnr, new_range["end"].row, new_range["end"].row + 1, false)
    if #lines > 0 then
      new_range["end"].col = #lines[1]
    end
  end

  return new_range
end

-- Cursor helper
M.Cursor = {}

---@class CursorState
---@field win integer Window handle
---@field cursor integer[] Cursor position as [row, col] (1-indexed row)
---@field bufnr integer Buffer number

---Saves the current cursor state
---@return CursorState Current cursor position information
function M.Cursor.save()
  return {
    win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    bufnr = vim.api.nvim_get_current_buf(),
  }
end

---Restores a previously saved cursor state
---@param state CursorState The cursor state returned by Cursor.save()
---@return boolean success Whether restoration was successful
function M.Cursor.restore(state)
  -- Make sure we have a valid state
  if not state or not state.win or not state.cursor or not state.bufnr then
    return false
  end

  -- Make sure the window and buffer still exist
  if not (vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.bufnr)) then
    return false
  end

  -- Ensure the cursor position is valid for the buffer
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  if state.cursor[1] > line_count then
    state.cursor[1] = line_count
  end

  -- Get the line at the cursor position
  local line = vim.api.nvim_buf_get_lines(state.bufnr, state.cursor[1] - 1, state.cursor[1], false)[1] or ""

  -- Ensure cursor column is valid for the line
  if state.cursor[2] >= #line then
    state.cursor[2] = math.max(0, #line - 1)
  end

  -- Restore cursor
  local success = pcall(vim.api.nvim_win_set_cursor, state.win, state.cursor)

  return success
end

return M
