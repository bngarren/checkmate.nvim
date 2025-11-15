---@class checkmate.Util.string
local M = {}

---@param line string
function M.trim_leading(line)
  line = line or ""
  return line:match("^%s*(.*)$")
end

---@param line string
function M.trim_trailing(line)
  line = line or ""
  return line:match("^(.-)%s*$")
end

---Convert a snake_case string to CamelCase
---@param input string input in snake_case (underscores)
---@return string result converted to CamelCase
function M.snake_to_camel(input)
  local s = tostring(input)
  -- uppercase the letter/digit after each underscore, and remove the underscore
  s = s:gsub("_([%w])", function(c)
    return c:upper()
  end)
  -- uppercase first character if it's a lowercase letter
  s = s:gsub("^([a-z])", function(c)
    return c:upper()
  end)
  return s
end

--- Returns the line's leading whitespace (indentation)
---@param line string
---@return string indent
function M.get_line_indent(line)
  return line:match("^(%s*)") or ""
end

--- Returns true if the col (0-based) is at the end of the trimmed line
--- The 'end' is the position of the last character of the line
---@param line string
---@param col integer (0-based)
---@param opts? {include_whitespace?: boolean}
--- - include_whitespace: Default is true
---@return boolean
function M.is_end_of_line(line, col, opts)
  assert(type(line) == "string")
  opts = opts or {}
  local line_length = opts.include_whitespace ~= false and #line or #M.trim_trailing(line)
  return col + 1 == line_length
end

--- Returns the next ordered marker (incremented)
--- e.g. if `1.` is passed, will return `2.`
--- If the passed string does not match an ordered list marker, will return nil
--- Pass `restart = true` if the numbering should start at 1, i.e. for a nested list item
---@param li_marker_str string Current marker like "1." or "2)"
---@param restart? boolean If true, reset to "1.", e.g., for nested items
---@return string|nil
function M.get_next_ordered_marker(li_marker_str, restart)
  local num, delimiter = li_marker_str:match("^%s*(%d+)([%.%)])")
  local result = nil
  if num then
    if not restart then
      -- same level: increment
      result = tostring(tonumber(num) + 1) .. delimiter
    else
      -- nested: start from 1
      result = "1" .. delimiter
    end
  end
  return result
end

return M
