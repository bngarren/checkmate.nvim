-- parser/helpers.lua
-- Helper functions for parsing Markdown list items and GFM task checkboxes

local M = {}

--- Returns the line's leading whitespace (indentation)
---@return string indent
function M.get_line_indent(line)
  return line:match("^(%s*)") or ""
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

-- @param patterns string[]: List of Lua patterns
-- @param str string: Input string to test
function M.match_first(patterns, str)
  for _, pat in ipairs(patterns) do
    local match = { str:match(pat) }
    if match[1] then
      return unpack(match)
    end
  end
  return nil
end

---@class CreateListItemPatternsOpts
---@field bullet_markers? string[]
---@field include_ordered_markers? boolean
---@field with_captures? boolean

--- Create patterns to match list items with captures for indent, list marker, and content.
---
--- Note:
---  - The list marker capture will include 1 trailing whitespace (" ", tab, line break), so the caller must trim this accordingly to get the _only_ the marker
---@param opts? CreateListItemPatternsOpts
---@return string[] patterns If captures are included, each pattern will return:
--  1. indent (spaces/tabs)
--  2. marker (bullet or ordered marker + the first trailing whitespace)
--  3. content (rest of the line, including additional initial whitespace not captured by marker)
function M.create_list_item_patterns(opts)
  local parser = require("checkmate.parser")
  opts = opts or {}

  local default_bullet_markers = table.concat(parser.list_item_markers, "")

  local bullet_markers
  local include_ordered_markers = opts.include_ordered_markers ~= false

  if not opts.bullet_markers then
    bullet_markers = default_bullet_markers
  else
    bullet_markers = table.concat(bullet_markers, "")
  end

  local cls = escape_for_char_class(bullet_markers)

  local patterns = {}

  if opts.with_captures == false then
    table.insert(patterns, "^%s*[" .. cls .. "]%s")
    if include_ordered_markers then
      table.insert(patterns, "^%s*%d+[%.)]%s")
    end
  else
    table.insert(patterns, "^(%s*)([" .. cls .. "]%s)(.*)")
    if include_ordered_markers then
      table.insert(patterns, "^(%s*)(%d+[%.)]%s)(.*)")
    end
  end

  return patterns
end

--- Attempts to match the given line against the parser's list item patterns
--- If found, will return a structured result with the following behavior:
---   - indent is the length of whitespace up to the list marker
---   - marker is the trimmed list marker string
---   - content is the string from the list marker to EOL with trailing trim only
--- Returns nil if no list item was matched
---@param line string Line to match
---@return {indent: integer, marker: string, content: string}|nil
function M.match_list_item(line)
  line = line or ""
  local parser = require("checkmate.parser")
  local list_item_patterns = parser.get_list_item_patterns(true)

  -- HACK: add whitespace to end so that we can always catch empty list items
  --
  -- i.e. `-` won't match but `- ` will
  line = line .. " "

  local matched = { M.match_first(list_item_patterns, line) }
  if #matched == 0 then
    return nil
  end

  local indent = #matched[1]
  local lm_raw = matched[2]
  local lm = vim.trim(lm_raw)
  local lm_trailing_ws = lm_raw:match("^" .. lm .. "(%s*)")
  local content = lm_trailing_ws .. matched[3]
  content = require("checkmate.util").trim_trailing(content)

  return {
    indent = indent,
    marker = lm,
    content = content,
  }
end

---@class CreateUnicodeTodoPatternsOpts : CreateListItemPatternsOpts

--- Create patterns to match unicode todo items with or without captures
---
---@param todo_marker string Unicode todo marker
---@param opts? CreateUnicodeTodoPatternsOpts
---@return string[] patterns If captures are included, each pattern will return:
--- 1. list marker - includes indentation + marker + the first trailing whitespace
--- 2. todo marker
--- 3. content (rest of the line after the todo marker)
function M.create_unicode_todo_patterns(todo_marker, opts)
  opts = opts or {}
  local result = {}

  local list_item_patterns = M.create_list_item_patterns({
    with_captures = false,
    bullet_markers = opts.bullet_markers,
    include_ordered_markers = opts.include_ordered_markers,
  })
  if opts.with_captures == false then
    -- without capture groups
    for _, li_pattern in ipairs(list_item_patterns) do
      table.insert(result, li_pattern .. vim.pesc(todo_marker) .. "%s+")
    end
  else
    for _, li_pattern in ipairs(list_item_patterns) do
      li_pattern = li_pattern:gsub("^(%^)", "")
      table.insert(result, "^(" .. li_pattern .. ")" .. "(" .. vim.pesc(todo_marker) .. ")" .. "(%s+.*)")
    end
  end
  return result
end

return M
