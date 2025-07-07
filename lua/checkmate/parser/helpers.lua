-- parser/helpers.lua
-- Helper functions for parsing Markdown list items and GFM task checkboxes

local M = {}

--- Returns a structured result on the first pattern match
---  - Check the `result.matched` to see if a pattern matched
---  - The `result.captures` will hold the captures (if capture groups were present), otherwise the matched string
---  - Can use `result.unpack` to get the captures, such as:
---    `local indent, marker, content = result:unpack()`
---@param patterns string[]: list of Lua patterns
---@param str string: input string to test
---@return {matched: boolean, captures: string[], pattern: string, unpack: function} result
function M.match_first(patterns, str)
  for _, pat in ipairs(patterns) do
    local captures = { str:match(pat) }
    if #captures > 0 then
      return {
        matched = true,
        captures = captures,
        pattern = pat,
        unpack = function(self)
          return unpack(self.captures)
        end,
      }
    end
  end
  return { matched = false, captures = {} }
end

--- Returns true if any pattern matches the string
---@param patterns string[]: list of Lua patterns
---@param str string: input string to test
function M.match_any(patterns, str)
  return M.match_first(patterns, str).matched
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

  local cls = require("checkmate.util").escape_for_char_class(bullet_markers)

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

  local result = M.match_first(list_item_patterns, line)
  if not result.matched then
    return nil
  end

  local indent = #result.captures[1]
  local lm_raw = result.captures[2]
  local lm = vim.trim(lm_raw)
  local lm_trailing_ws = lm_raw:match("^" .. lm .. "(%s*)")
  local content = lm_trailing_ws .. result.captures[3]
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
      table.insert(result, li_pattern .. vim.pesc(todo_marker) .. "%s+.*$")
      -- allow empty content
      table.insert(result, li_pattern .. vim.pesc(todo_marker) .. "$")
    end
  else
    for _, li_pattern in ipairs(list_item_patterns) do
      li_pattern = li_pattern:gsub("^(%^)", "")
      table.insert(result, "^(" .. li_pattern .. ")" .. "(" .. vim.pesc(todo_marker) .. ")" .. "(%s+.*)$")
      -- allow empty content
      table.insert(result, "^(" .. li_pattern .. ")" .. "(" .. vim.pesc(todo_marker) .. ")" .. "$")
    end
  end
  return result
end

--- Builds patterns to match GitHub Flavored Markdown checkboxes like `- [x]` or `1. [ ]`
---
--- For each list marker type we create 2 pattern variants:
--- 1. One for checkboxes at end of line
--- 2. One for checkboxes followed by space
---
--- IMPORTANT: the patterns returned have different behaviors:
--- - EOL patterns (variant 1): Match list prefix + checkbox, captured in group 1
--- - Space patterns (variant 2): Match list prefix + checkbox + space, but only capture prefix in group 1
---   The trailing space is matched but NOT captured, requiring special handling in gsub replacements
---
---@param checkbox_pattern string Must be a Lua pattern, e.g. "%[[xX]%]" or "%[ %]"
---@return string[] patterns List of full Lua patterns with capture group for:
---  - 1. indentation
---  - 2. list marker + first trailing whitespace
---  - 3. checkbox
function M.create_markdown_checkbox_patterns(checkbox_pattern)
  if not checkbox_pattern or checkbox_pattern == "" then
    error("checkbox_pattern cannot be nil or empty")
  end

  local patterns = {}

  local list_patterns = M.create_list_item_patterns({
    with_captures = true,
  })

  for _, list_pattern in ipairs(list_patterns) do
    -- original: "^(%s*)([%-+*]%s)(.*)"
    -- we need: "^(%s*[%-+*]%s+)" for the list prefix
    local prefix_pattern = list_pattern:gsub("%(%.%*%)$", "") -- Remove content capture

    -- variant 1: checkbox at EOL
    table.insert(patterns, prefix_pattern .. "(" .. checkbox_pattern .. ")" .. "$")

    -- variant 2: checkbox followed by space (space not captured)
    table.insert(patterns, prefix_pattern .. "(" .. checkbox_pattern .. ")" .. " ")
  end

  return patterns
end

--- Attempts to match a GitHub-style task list checkbox (e.g. "- [ ] foo" or "1. [x] bar")
--- @param line string
--- @param state? checkmate.TodoItemState
--- @return { indent: integer, marker: string, checked: boolean, content: string, raw_checkbox: string }? result
function M.match_markdown_checkbox(line, state)
  line = line or ""
  local parser = require("checkmate.parser")
  local patterns = {}

  if state == nil or state == "checked" then
    for _, p in ipairs(parser.get_markdown_checked_checkbox_patterns()) do
      table.insert(patterns, p)
    end
  end
  if state == nil or state == "unchecked" then
    for _, p in ipairs(parser.get_markdown_unchecked_checkbox_patterns()) do
      table.insert(patterns, p)
    end
  end

  local result = M.match_first(patterns, line)
  if not result.matched then
    return nil
  end

  -- captures are:
  --   1) indent, 2) raw list-marker + first whitespace, 3) the "[ ]" or "[x]" token
  local indent = #result.captures[1]
  local lm_raw = result.captures[2]
  local lm = vim.trim(lm_raw)
  local raw_box = result.captures[3]

  local mark_char = raw_box:match("%[([xX ])%]")
  local checked = (mark_char or ""):lower() == "x"

  local prefix_len = #result.captures[1] + #lm_raw + #raw_box
  local next_char = line:sub(prefix_len + 1, prefix_len + 1)
  local content = (next_char == " ") and line:sub(prefix_len + 2) or line:sub(prefix_len + 1)

  content = require("checkmate.util").trim_trailing(content)

  return {
    indent = indent,
    marker = lm,
    checked = checked,
    content = content,
    raw_checkbox = raw_box,
  }
end

return M
