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
function M.notify(msg, log_level, once)
  local config = require("checkmate.config")
  local prefix = "Checkmate: "
  if config.options.notify then
    if once ~= false then
      vim.notify_once(prefix .. msg, log_level)
    else
      vim.notify(prefix .. msg, log_level)
    end
  else
    --[[ local hl_group = "Normal"
    if log_level == vim.log.levels.WARN then
      hl_group = "WarningMsg"
    elseif log_level == vim.log.levels.ERROR then
      hl_group = "ErrorMsg"
    end
    vim.api.nvim_echo({ msg, hl_group }, true, {}) ]]
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

  for _, g in ipairs(hl_group) do
    -- First try to get attributes with link = false
    ---@cast g string
    local hl = vim.api.nvim_get_hl(0, { name = g, link = false })

    if hl[prop] then
      return string.format("#%06x", hl[prop])
    end

    -- If no direct attribute, try following the link
    if hl.link then
      local linked_hl = vim.api.nvim_get_hl(0, { name = hl.link, link = false })
      if linked_hl[prop] then
        return string.format("#%06x", linked_hl[prop])
      end
    end
  end

  return default
end

---@return string trimmed
---@return number count
function M.trim_trailing(line)
  if not line or #line == 0 then
    return "", 0
  end
  return line:gsub("(%s+)$", "")
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
---@deprecated
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
---@deprecated
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
    return with_capture and "^(" .. p .. ")" or p
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
---@deprecated
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
---@deprecated
function M.build_todo_patterns(opts)
  opts = opts or {}

  local prefix_patterns = M.create_list_prefix_patterns({
    simple_markers = opts.simple_markers,
    use_numbered_list_markers = opts.use_numbered_list_markers,
    with_capture = false,
  })

  ---Build multiple full-patterns from todo_marker
  ---@param todo_marker string: The todo marker to look for
  ---@return string[] patterns List of full Lua patterns to match
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
---@deprecated
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

--- Builds patterns to match GitHub Flavored Markdown checkboxes like `- [x]` or `1. [ ]`
---
--- For each list marker type we create 2 pattern variants:
--- 1. One for checkboxes at end of line
--- 2. One for checkboxes followed by space
---
--- Below are the patterns for an unchecked markdown task marker:
--- { "^(%s*[%-+*]%s+)%[ %]$", "^(%s*%d+[%.)]%s+)%[ %]$", "^(%s*[%-+*]%s+)%[ %] ", "^(%s*%d+[%.)]%s+)%[ %] " }
--- 2 patterns are matching type bullet markers with the 2 variants
--- 2 patterns are matching ordered list markers with the 2 variants
---
--- IMPORTANT: the patterns returned have different behaviors:
--- - EOL patterns (variant 1): Match list prefix + checkbox, captured in group 1
--- - Space patterns (varian 2): Match list prefix + checkbox + space, but only capture prefix in group 1
---   The trailing space is matched but NOT captured, requiring special handling in gsub replacements
---
---@param list_item_markers table List item markers to use, e.g. {"-", "*", "+"}
---@param checkbox_pattern string Must be a Lua pattern, e.g. "%[[xX]%]" or "%[ %]"
---@return string[] patterns List of full Lua patterns with capture group for list prefix
function M.build_markdown_checkbox_patterns(list_item_markers, checkbox_pattern)
  if not checkbox_pattern or checkbox_pattern == "" then
    error("checkbox_pattern cannot be nil or empty")
  end

  local patterns = {}

  -- Variant 1: Checkbox at end of line (e.g., "- [ ]" with no trailing content)
  local eol_patterns = M.build_list_pattern({
    simple_markers = list_item_markers,
    right_pattern = checkbox_pattern .. "$",
  })
  vim.list_extend(patterns, eol_patterns)

  -- Variant 2: Checkbox followed by space - include space in the pattern but not the replacement
  local space_patterns = M.build_list_pattern({
    simple_markers = list_item_markers,
    right_pattern = checkbox_pattern .. " ", -- space not captured, just matched!!!
  })
  vim.list_extend(patterns, space_patterns)

  return patterns
end

---Returns a todo_map table sorted by start row
---@generic T: table<integer, checkmate.TodoItem>
---@param todo_map T
---@return {id: integer, item: checkmate.TodoItem}
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

--- Converts TreeSitter's technical range to a semantically meaningful range for todo items
---
--- TreeSitter ranges have two quirks to address:
--- 1. End-of-line positions are represented as [next_line, 0] instead of [current_line, line_length]
--- 2. Multi-line nodes may not include the full line content in their ranges
---
--- This function transforms these ranges to better represent the semantic boundaries of todo items:
--- - When end_col=0, it means "end of previous line" rather than "start of current line"
--- - For multi-line ranges, ensures the end position captures the entire line content
---
--- @param range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Raw TreeSitter range (0-indexed, end-exclusive)
--- @param bufnr integer Buffer number
--- @return {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Adjusted range suitable for semantic operations
function M.get_semantic_range(range, bufnr)
  -- Create a new range object to avoid modifying the original
  local new_range = {
    start = { row = range.start.row, col = range.start.col },
    ["end"] = { row = range["end"].row, col = range["end"].col },
  }

  -- Standard TS range adjustment when end_col is 0
  if new_range["end"].col == 0 then
    new_range["end"].row = new_range["end"].row - 1
  end

  -- Get the first line to determine indentation level of this todo item
  local first_line = vim.api.nvim_buf_get_lines(bufnr, new_range.start.row, new_range.start.row + 1, false)[1] or ""
  local indent_match = first_line:match("^(%s+)")
  local current_indent_level = indent_match and #indent_match or 0

  -- Scan through lines to find where this todo item actually ends
  -- We're looking for the last line that:
  -- 1. Has content (not just whitespace)
  -- 2. Is indented at the same level or greater than our todo item
  -- 3. But stops when we hit another list item at the same indentation level
  -- (which would be a sibling, not a child)
  local end_row = new_range.start.row
  for row = new_range.start.row + 1, new_range["end"].row do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    -- Skip empty lines (but don't update end_row)
    if not line:match("^%s*$") then
      -- Get this line's indentation
      local line_indent_match = line:match("^(%s+)")
      local line_indent = line_indent_match and #line_indent_match or 0

      -- Check if this line is a new list item (contains a list marker)
      local is_list_item = line:match("^%s*[-+*]%s") or line:match("^%s*%d+[.)]%s")

      -- If this is a list item at same or lower indent level, it's a sibling or parent
      -- and should not be part of our current todo's range
      if is_list_item and line_indent <= current_indent_level then
        break
      end

      -- Otherwise, this line is part of our todo item's content
      end_row = row
    end
  end

  -- Update the range
  new_range["end"].row = end_row

  -- Get the end column by finding the length of the last line (minus trailing whitespace)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local trimmed_line = last_line:gsub("%s+$", "")
  new_range["end"].col = #trimmed_line

  -- Preserve the actual indentation level in col, not set to 0
  new_range.start.col = current_indent_level

  return new_range
end

---Returns a string of the node's range data
---@param node TSNode
function M.get_ts_node_range_string(node)
  if not node then
    return ""
  end
  local start_row, start_col, end_row, end_col = node:range()
  return ("[%d,%d] → [%d,%d]"):format(start_row, start_col, end_row, end_col)
end

--- Strip trailing blank (all-whitespace) lines, in-place.
---@param lines string[]
---@param max_blank integer max amount of blank lines to allow
---@return table result the same table for convenience
function M.strip_trailing_blank_lines(lines, max_blank)
  -- walk backwards until we meet a non-blank line
  local last = #lines
  while last >= 1 and lines[last]:match("^%s*$") do
    last = last - 1
  end

  for i = #lines, last + 1 + (max_blank or 0), -1 do
    lines[i] = nil
  end
  return lines
end

---Build a Markdown heading
---@param title string text after the hashes
---@param level? integer 1-6; clamped; defaults to 2
---@return string
function M.get_heading_string(title, level)
  level = tonumber(level) or 2
  level = math.min(math.max(level, 1), 6)
  return string.rep("#", level) .. " " .. title
end

--- Efficiently batch-read buffer lines for multiple row positions
--- Optimizes by reading contiguous ranges in single API calls
---@param bufnr integer Buffer number
---@param rows integer[] Array of 0-based row numbers to read
---@return table<integer, string> Map of row number to line content
function M.batch_get_lines(bufnr, rows)
  if #rows == 0 then
    return {}
  end

  -- For small requests, just read directly
  if #rows == 1 then
    local lines = vim.api.nvim_buf_get_lines(bufnr, rows[1], rows[1] + 1, false)
    return { [rows[1]] = lines[1] or "" }
  end

  -- Sort rows to find contiguous ranges
  local sorted_rows = vim.tbl_extend("error", {}, rows)
  table.sort(sorted_rows)

  local result = {}
  local range_start = sorted_rows[1]
  local range_end = sorted_rows[1]

  local function read_range()
    if range_start <= range_end then
      local lines = vim.api.nvim_buf_get_lines(bufnr, range_start, range_end + 1, false)
      for i = 0, range_end - range_start do
        result[range_start + i] = lines[i + 1] or ""
      end
    end
  end

  -- Find contiguous ranges and batch read them
  for i = 2, #sorted_rows do
    if sorted_rows[i] > range_end + 1 then
      -- Gap found, read current range
      read_range()
      range_start = sorted_rows[i]
      range_end = sorted_rows[i]
    else
      range_end = sorted_rows[i]
    end
  end

  -- Read final range
  read_range()

  return result
end

--- Simple line cache for operations that need repeated access to same lines
---@class LineCache
---@field private bufnr integer
---@field private lines table<integer, string>
---@field get fun(self: LineCache, row: integer): string
---@field get_many fun(self: LineCache, rows: integer[]): table<integer, string>
local LineCache = {}
LineCache.__index = LineCache

---@param bufnr integer
---@return LineCache
function M.create_line_cache(bufnr)
  local self = setmetatable({
    bufnr = bufnr,
    lines = {},
  }, LineCache)
  return self
end

---@param row integer 0-based row number
---@return string
function LineCache:get(row)
  if self.lines[row] == nil then
    local lines = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)
    self.lines[row] = lines[1] or ""
  end
  return self.lines[row]
end

---@param rows integer[] Array of 0-based row numbers
---@return table<integer, string>
function LineCache:get_many(rows)
  -- Find which rows we need to fetch
  local missing = {}
  for _, row in ipairs(rows) do
    if self.lines[row] == nil then
      table.insert(missing, row)
    end
  end

  -- Batch fetch missing rows
  if #missing > 0 then
    local fetched = M.batch_get_lines(self.bufnr, missing)
    for row, line in pairs(fetched) do
      self.lines[row] = line
    end
  end

  -- Return requested rows
  local result = {}
  for _, row in ipairs(rows) do
    result[row] = self.lines[row]
  end
  return result
end

--- Convert character position to byte position in a line
---
--- IMPORTANT: This function expects 0-based character position and returns 0-based byte position.
--- Neovim APIs typically use 0-based byte positions for buffer operations.
---
--- @param line string The line content (UTF-8 encoded)
--- @param char_col integer Character column (0-indexed)
--- @return integer byte_col Byte column (0-indexed)
function M.char_to_byte_col(line, char_col)
  if char_col == 0 then
    return 0
  end

  -- vim.fn.byteidx expects 0-based character index and returns 0-based byte index
  local byte_idx = vim.fn.byteidx(line, char_col)

  -- byteidx returns -1 if char_col is out of range
  if byte_idx == -1 then
    return #line
  end

  return byte_idx
end

--- Convert byte position to character position in a line
---
--- This function handles UTF-8 encoded strings where a single character may
--- occupy multiple bytes.
---
--- @param line string The line content (UTF-8 encoded)
--- @param byte_col integer Byte column (0-indexed)
--- @return integer char_col Character column (0-indexed)
function M.byte_to_char_col(line, byte_col)
  if byte_col == 0 then
    return 0
  end

  -- Clamp byte_col to valid range
  if byte_col > #line then
    byte_col = #line
  end

  -- vim.fn.charidx expects 0-based byte index and returns 0-based character index
  local char_idx = vim.fn.charidx(line, byte_col)

  -- charidx returns -1 if byte_col is out of range (shouldn't happen with our clamp)
  if char_idx == -1 then
    return vim.fn.strchars(line)
  end

  return char_idx
end

---Creates a public facing checkmate.Todo from the internal checkmate.TodoItem representation
---
---exposes a public api while still providing access to the underlying todo_item
---@param todo_item checkmate.TodoItem
---@return checkmate.Todo
function M.build_todo(todo_item)
  local metadata_array = {}
  for _, entry in ipairs(todo_item.metadata.entries) do
    table.insert(metadata_array, { entry.tag, entry.value })
  end

  local function get_metadata(name)
    local result = vim
      .iter(metadata_array)
      :filter(function(m)
        return m[1] == name
      end)()
    if not result then
      return nil, nil
    end
    return result[1], result[2]
  end

  local function is_checked()
    return todo_item.state == "checked"
  end

  ---@type checkmate.Todo
  return {
    _todo_item = todo_item,
    state = todo_item.state,
    text = todo_item.todo_text,
    metadata = metadata_array,
    is_checked = is_checked,
    get_metadata = get_metadata,
  }
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
