-- Helper functions for parsing Markdown list items and GFM task checkboxes

local config = require("checkmate.config")

local M = {}

---@class checkmate.ListItemPrefix
---@field indent integer
---@field list_marker string

---@class checkmate.TodoPrefix : checkmate.ListItemPrefix
---@field state string Todo state
---@field is_markdown boolean If true, todo is represented as raw Markdown rather than unicode or other
---@field todo_marker string
---Byte length of the prefix, i.e., indent + list_marker + 1 space + todo_marker.
---Thus, `string:sub(length + 1)` will return the substring of the todo line immediately after the todo_marker
---@field length integer

-- return the number of bytes of (indent + list marker + 1 space + todo marker)
function M.calc_todo_prefix_length(indent, list_marker, todo_marker)
  indent = type(indent) == "string" and #indent or indent or 0
  list_marker = type(list_marker) == "string" and #list_marker or list_marker
  todo_marker = type(todo_marker) == "string" and #todo_marker or todo_marker
  return indent + list_marker + 1 + todo_marker
end

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

  local cls = vim.pesc(bullet_markers)

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
  local parser = require("checkmate.parser")
  line = line or ""
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
  content = require("checkmate.util").string.trim_trailing(content)

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
--- @param chars string | string[]  A single character or list of characters to allow inside the brackets
--- @return string[] patterns  List of full Lua patterns with capture groups:
---   1. indentation
---   2. list marker + first trailing whitespace
---   3. the checkbox token itself
function M.create_markdown_checkbox_patterns(chars)
  vim.validate({
    chars = { chars, { "string", "table" }, false },
  })
  local arr = type(chars) == "string" and { chars } or chars
  ---@cast arr string[]

  for i, c in ipairs(arr) do
    assert(
      type(c) == "string" and #c == 1,
      ("create_markdown_checkbox_patterns: element #%d must be a 1-char string, got %q"):format(i, c)
    )
  end

  local esc = vim.tbl_map(vim.pesc, arr)
  local inner = (#esc == 1) and esc[1] or ("[" .. table.concat(esc) .. "]")

  local checkbox = "%[" .. inner .. "%]"

  local pats = {}
  for _, lp in ipairs(M.create_list_item_patterns({ with_captures = true })) do
    local prefix = lp:gsub("%(%.%*%)$", "")
    pats[#pats + 1] = prefix .. "(" .. checkbox .. ")" .. "$"
    pats[#pats + 1] = prefix .. "(" .. checkbox .. ")" .. " "
  end

  return pats
end

--- Attempts to match a GitHub-style task list checkbox (e.g. `- [ ] foo` or `1. [x] bar`)
--- - It will also match custom states, if defined in the config `todo_states`
--- - Returns nil if the line does not match a Markdown checkbox
--- - Pass `opts.state` to only match a checkbox with specific todo state
--- @param line string
--- @param opts? {state?: string}
--- @return checkmate.TodoPrefix? match
function M.match_markdown_checkbox(line, opts)
  opts = opts or {}
  local parser = require("checkmate.parser")

  if not line or #line == 0 then
    return nil
  end

  for state_name, _ in pairs(config.options.todo_states) do
    if not opts.state or opts.state == state_name then
      local state_patterns = parser.get_markdown_checkbox_patterns_by_state(state_name)
      local result = M.match_first(state_patterns, line)
      if result.matched then
        -- see `M.create_markdown_checkbox_patterns`
        --   1) indent, 2) raw list-marker + first whitespace, 3) the "[ ]" or "[x]" token
        local indent_str, marker, raw = result:unpack()
        local prefix_length = M.calc_todo_prefix_length(indent_str, vim.trim(marker), raw)
        return {
          indent = #indent_str,
          list_marker = vim.trim(marker),
          state = state_name,
          is_markdown = true,
          todo_marker = raw,
          length = prefix_length,
        }
      end
    end
  end
  return nil
end

--- Checks if a line matches a todo (either Markdown or unicode)
---@param line string
---@return checkmate.TodoPrefix? match
function M.match_todo(line)
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  -- 1. try to match unicode/Checkmate style todo
  for _, pat in ipairs(parser.get_all_checkmate_todo_patterns(true)) do
    local list_seg, todo_marker, _ = line:match(pat)
    if list_seg then
      local indent_ws = list_seg:match("^(%s*)") or ""
      local list_marker = util.string.trim_leading(util.string.trim_trailing(list_seg))

      for state_name, state in pairs(config.options.todo_states) do
        if state.marker == todo_marker then
          local prefix_length = M.calc_todo_prefix_length(indent_ws, list_marker, todo_marker)
          return {
            indent = #indent_ws,
            list_marker = list_marker,
            state = state_name,
            is_markdown = false,
            todo_marker = todo_marker,
            length = prefix_length,
          }
        end
      end
    end
  end

  -- 2. try to match Markdown style todo
  local md_todo = M.match_markdown_checkbox(line)
  if md_todo then
    local prefix_length = M.calc_todo_prefix_length(md_todo.indent, md_todo.list_marker, md_todo.todo_marker)
    return {
      indent = md_todo.indent,
      list_marker = md_todo.list_marker,
      state = md_todo.state,
      is_markdown = true,
      todo_marker = md_todo.todo_marker,
      length = prefix_length,
    }
  end
  return nil
end

--- Convert a TodoItem to TodoPrefix
---@private
---@param item checkmate.TodoItem
---@return checkmate.TodoPrefix
function M._item_to_prefix(item)
  local state_config = config.options.todo_states[item.state]
  local todo_marker = state_config and state_config.marker or item.todo_marker.text
  local prefix_length = M.calc_todo_prefix_length(item.range.start.col, item.list_marker.text, todo_marker)

  return {
    indent = item.range.start.col,
    list_marker = item.list_marker.text,
    state = item.state,
    is_markdown = false,
    todo_marker = todo_marker,
    length = prefix_length,
  }
end

return M
