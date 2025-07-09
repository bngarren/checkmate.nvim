local M = {}

---@alias checkmate.TodoItemState "checked" | "unchecked"
--@alias checkmate.TodoItemState "checked" | "unchecked"

--- @class TodoMarkerInfo
--- @field position {row: integer, col: integer} Position of the marker (0-indexed)
--- @field text string The marker text (e.g., "□" or "✓")

--- @class checkmate.ListMarkerInfo
--- @field node TSNode Treesitter node of the list marker (uses 0-indexed row/col coordinates)
--- @field type "ordered"|"unordered" Type of list marker
--- @field text string e.g. -, *, +, or 1. or 1)

--- @class ContentNodeInfo
--- @field node TSNode Treesitter node containing content (uses 0-indexed row/col coordinates)
--- @field type string Type of content node (e.g., "paragraph")

---@class checkmate.MetadataEntry
---@field tag string The tag name
---@field value string The value
---@field range checkmate.Range Position range (0-indexed), end_col is end_exclusive
---@field value_range checkmate.Range Position range (0-indexed), end_col is end exclusive
---@field alias_for? string The canonical tag name if this is an alias

---@class checkmate.TodoMetadata
---@field entries checkmate.MetadataEntry[] List of metadata entries
---@field by_tag table<string, checkmate.MetadataEntry> Quick access by tag name

--- @class checkmate.TodoItem
--- Stable key. Uses extmark id positioned just prior to the todo marker.
--- This allows tracking the same todo item across buffer modifications.
--- @field id integer
--- @field state checkmate.TodoItemState The todo state
--- @field node TSNode The Treesitter node
--- Todo item's buffer range
--- This range is adjusted from the raw TS node range via *get_semantic_range*:
---   - The start col is adjusted to the indentation level
---   - The end col is adjusted so that it accurately reflects the end of the content
--- @field range checkmate.Range
--- @field ts_range checkmate.Range
--- This is the range of the first inline node of the first paragraph which is (currently) the best representation
--- of the todo item's main content. This allows the first todo line to be hard-wrapped but still
--- allow the broken subsequent lines to work, e.g. have metadata extracted.
--- @field first_inline_range checkmate.Range
--- @field todo_marker TodoMarkerInfo Information about the todo marker (0-indexed position)
--- @field list_marker checkmate.ListMarkerInfo Information about the list marker (0-indexed position)
--- @field metadata checkmate.TodoMetadata | {} Metadata for this todo item
--- @field todo_text string Text content of the todo item line (first line)
--- @field children integer[] IDs of child todo items
--- @field parent_id integer? ID of parent todo item

M.FULL_TODO_QUERY = vim.treesitter.query.parse(
  "markdown",
  [[
  (list_item) @list_item
  (list_marker_minus) @list_marker
  (list_marker_plus) @list_marker  
  (list_marker_star) @list_marker
  (list_marker_dot) @list_marker_ordered
  (list_marker_parenthesis) @list_marker_ordered
  (paragraph
    (inline) @first_inline) @paragraph
]]
)

-- match the @tag and then a balanced sequence %b(), which is everything in the outer parentheses
local METADATA_PATTERN = "@([%a][%w_%-]*)(%b())"

M.list_item_markers = { "-", "+", "*" }
M.markdown_checked_checkbox = "%[[xX]%]"
M.markdown_unchecked_checkbox = "%[ %]"

local PATTERN_CACHE = {
  list_item_with_captures = nil,
  list_item_without_captures = nil,
  unicode_checked_todo_with_captures = nil,
  unicode_checked_todo_without_captures = nil,
  unicode_unchecked_todo_with_captures = nil,
  unicode_unchecked_todo_without_captures = nil,
  markdown_checked_checkbox_with_captures = nil,
  markdown_unchecked_checkbox_with_captures = nil,
}

function M.clear_pattern_cache()
  PATTERN_CACHE = {
    list_item_with_captures = nil,
    list_item_without_captures = nil,
    unicode_checked_todo_with_captures = nil,
    unicode_checked_todo_without_captures = nil,
    unicode_unchecked_todo_with_captures = nil,
    unicode_unchecked_todo_without_captures = nil,
    markdown_checked_checkbox_with_captures = nil,
    markdown_unchecked_checkbox_with_captures = nil,
  }
end

---@param with_captures? boolean (default false) Whether to include capture groups in the pattern. See `create_list_item_patterns`
---@return string[] patterns
function M.get_list_item_patterns(with_captures)
  if with_captures and not PATTERN_CACHE.list_item_with_captures then
    PATTERN_CACHE.list_item_with_captures =
      require("checkmate.parser.helpers").create_list_item_patterns({ with_captures = true })
  end
  if not with_captures and not PATTERN_CACHE.list_item_without_captures then
    PATTERN_CACHE.list_item_without_captures =
      require("checkmate.parser.helpers").create_list_item_patterns({ with_captures = false })
  end

  if with_captures then
    return PATTERN_CACHE.list_item_with_captures
  else
    return PATTERN_CACHE.list_item_without_captures
  end
end

---@param with_captures? boolean (default false) Whether to include capture groups in the pattern. See `create_unicode_todo_patterns`
---@return string[] patterns
function M.get_unicode_checked_todo_patterns(with_captures)
  if with_captures and not PATTERN_CACHE.unicode_checked_todo_with_captures then
    local checked = require("checkmate.config").options.todo_markers.checked
    PATTERN_CACHE.unicode_checked_todo_with_captures =
      require("checkmate.parser.helpers").create_unicode_todo_patterns(checked, { with_captures = true })
  end
  if not with_captures and not PATTERN_CACHE.unicode_checked_todo_without_captures then
    local checked = require("checkmate.config").options.todo_markers.checked
    PATTERN_CACHE.unicode_checked_todo_without_captures =
      require("checkmate.parser.helpers").create_unicode_todo_patterns(checked, { with_captures = false })
  end
  if with_captures then
    return PATTERN_CACHE.unicode_checked_todo_with_captures
  else
    return PATTERN_CACHE.unicode_checked_todo_without_captures
  end
end

---@param with_captures? boolean (default false) Whether to include capture groups in the pattern. See `create_unicode_todo_patterns`
---@return string[] patterns
function M.get_unicode_unchecked_todo_patterns(with_captures)
  if with_captures and not PATTERN_CACHE.unicode_unchecked_todo_with_captures then
    local unchecked = require("checkmate.config").options.todo_markers.unchecked
    PATTERN_CACHE.unicode_unchecked_todo_with_captures =
      require("checkmate.parser.helpers").create_unicode_todo_patterns(unchecked, { with_captures = true })
  end
  if not with_captures and not PATTERN_CACHE.unicode_unchecked_todo_without_captures then
    local unchecked = require("checkmate.config").options.todo_markers.unchecked
    PATTERN_CACHE.unicode_unchecked_todo_without_captures =
      require("checkmate.parser.helpers").create_unicode_todo_patterns(unchecked, { with_captures = false })
  end
  if with_captures then
    return PATTERN_CACHE.unicode_unchecked_todo_with_captures
  else
    return PATTERN_CACHE.unicode_unchecked_todo_without_captures
  end
end

---@return string[] patterns
function M.get_markdown_checked_checkbox_patterns()
  if not PATTERN_CACHE.markdown_checked_checkbox_with_captures then
    PATTERN_CACHE.markdown_checked_checkbox_with_captures =
      require("checkmate.parser.helpers").create_markdown_checkbox_patterns(M.markdown_checked_checkbox)
  end
  return PATTERN_CACHE.markdown_checked_checkbox_with_captures
end

---@return string[] patterns
function M.get_markdown_unchecked_checkbox_patterns()
  if not PATTERN_CACHE.markdown_unchecked_checkbox_with_captures then
    PATTERN_CACHE.markdown_unchecked_checkbox_with_captures =
      require("checkmate.parser.helpers").create_markdown_checkbox_patterns(M.markdown_unchecked_checkbox)
  end
  return PATTERN_CACHE.markdown_unchecked_checkbox_with_captures
end

-- [buffer] -> {version: integer, current: table<integer, checkmate.TodoItem> }
M.todo_map_cache = {}

---Returns a todo map of the current buffer
---Will hit cache if buffer has not changed since last full parse,
---according to :changedtick
---@param bufnr integer Buffer number
---@return table<integer, checkmate.TodoItem>
function M.get_todo_map(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Checkmate: Invalid buffer", vim.log.levels.ERROR)
    return {}
  end

  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cache = M.todo_map_cache[bufnr]

  -- Cache hit - no changes since last parse
  if cache and changedtick == cache.version then
    return cache.current or {}
  end

  -- Buffer changed - need fresh parse
  local fresh_todo_map = M.discover_todos(bufnr)
  M.todo_map_cache[bufnr] = {
    version = changedtick,
    current = fresh_todo_map,
  }

  return fresh_todo_map
end

--- Given a line (string), returns the todo item type either "checked" or "unchecked"
---@param line string Line to extract Todo item state
---@return checkmate.TodoItemState? state Todo item state, or nil if todo item wasn't found
function M.get_todo_item_state(line)
  local ph = require("checkmate.parser.helpers")

  ---@type checkmate.TodoItemState
  local todo_state = nil
  local unchecked_patterns = M.get_unicode_unchecked_todo_patterns(false)
  local checked_patterns = M.get_unicode_checked_todo_patterns(false)

  if ph.match_any(unchecked_patterns, line) then
    todo_state = "unchecked"
  elseif ph.match_any(checked_patterns, line) then
    todo_state = "checked"
  end

  return todo_state
end

--- Returns true if the given line is a Checkmate todo item
--- This will only match on the configured todo markers, not Markdown task items
--- i.e. Does the line start with `- □` or `- ✔` ?
--- Will also match ordered list items such as `1. □`
---@param line string
---@return boolean
function M.is_todo_item(line)
  return M.get_todo_item_state(line) ~= nil
end

function M.setup()
  local highlights = require("checkmate.highlights")
  local log = require("checkmate.log")

  -- clear pattern cache in case config changed
  M.clear_pattern_cache()

  M.todo_map_cache = {}

  log.debug("Checked pattern is: " .. table.concat(M.get_unicode_checked_todo_patterns(false) or {}, " , "))
  log.debug("Unchecked pattern is: " .. table.concat(M.get_unicode_unchecked_todo_patterns(false) or {}, " , "))

  highlights.setup_highlights()
end

-- Convert standard markdown 'task list marker' syntax to Unicode symbols
function M.convert_markdown_to_unicode(bufnr)
  local log = require("checkmate.log")
  local config = require("checkmate.config")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false
  local original_modified = vim.bo[bufnr].modified

  local md_unchecked_patterns = M.get_markdown_unchecked_checkbox_patterns()
  local md_checked_patterns = M.get_markdown_checked_checkbox_patterns()
  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked

  local new_lines = {}

  for _, line in ipairs(lines) do
    local new_line = line

    -- important! slighty hacky code that isn't immediately obvious incoming:
    --
    -- The markdown checkbox patterns built above include 2 variants:
    -- 1. Patterns ending with "$" for checkboxes at end of line (e.g., "- [ ]")
    -- 2. Patterns ending with " " for checkboxes followed by text (e.g., "- [ ] text")
    --
    -- For variant 2, the space is consumed by the pattern match but NOT captured,
    -- so we must add it back explicitly in the replacement to preserve formatting.
    --
    -- Why do we need to do this?
    -- this was the best way I could find to match `- [ ]` but not `- [ ]this`
    -- i.e., if the [ ] is not at EOL, there must be a space, otherwise no space is needed

    -- capture groups: 1. indent 2. list marker + 1st whitespace 3. checkbox

    -- unchecked replacements
    for _, pat in ipairs(md_unchecked_patterns) do
      if pat:sub(-1) == " " then
        -- pattern ends with space (variant 2), so add it back in replacement
        new_line = new_line:gsub(pat, "%1%2" .. unchecked .. " ")
      else
        -- pattern ends with $, no space needed
        new_line = new_line:gsub(pat, "%1%2" .. unchecked)
      end
    end

    -- checked replacements
    for _, pat in ipairs(md_checked_patterns) do
      if pat:sub(-1) == " " then
        -- same as unchecked, above
        new_line = new_line:gsub(pat, "%1%2" .. checked .. " ")
      else
        new_line = new_line:gsub(pat, "%1%2" .. checked)
      end
    end

    if new_line ~= line then
      modified = true
    end

    table.insert(new_lines, new_line)
  end

  if modified then
    -- Disable undo to avoid breaking undo sequence
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! undojoin")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      vim.bo[bufnr].modified = original_modified
    end)

    log.debug("Converted Markdown todo symbols to Unicode", { module = "parser" })
    return true
  end

  return false
end

-- Convert Unicode symbols back to standard markdown 'task list marker' syntax
function M.convert_unicode_to_markdown(bufnr)
  local log = require("checkmate.log")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false

  local unchecked_patterns, checked_patterns
  local ok, err = pcall(function()
    -- capture groups: 1=list prefix, 2=todo marker, 3=content
    unchecked_patterns = M.get_unicode_unchecked_todo_patterns(true)
    checked_patterns = M.get_unicode_checked_todo_patterns(true)
    return true
  end)

  if not ok then
    log.error("Error building patterns: " .. tostring(err), { module = "parser" })
    return false
  end

  local new_lines = {}

  -- Replace Unicode with markdown syntax
  for i, line in ipairs(lines) do
    local new_line = line
    local had_error = false

    for _, pattern in ipairs(unchecked_patterns) do
      ok, err = pcall(function()
        new_line = new_line:gsub(pattern, "%1[ ]%3")
        return true
      end)

      if not ok then
        log.error(string.format("Error on line %d with unchecked pattern: %s", i, tostring(err)), { module = "parser" })
        had_error = true
        break
      end
    end

    if had_error then
      break
    end

    for _, pattern in ipairs(checked_patterns) do
      ok, err = pcall(function()
        new_line = new_line:gsub(pattern, "%1[x]%3")
        return true
      end)

      if not ok then
        log.error(string.format("Error on line %d with checked pattern: %s", i, tostring(err)), { module = "parser" })
        had_error = true
        break
      end
    end

    if had_error then
      return false
    end

    if new_line ~= line then
      modified = true
    end

    table.insert(new_lines, new_line)
  end

  if modified then
    ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      return true
    end)

    if not ok then
      log.error("Error setting buffer lines: " .. tostring(err), { module = "parser" })
      return false
    end

    log.debug("Converted Unicode todo symbols to Markdown", { module = "parser" })
    return true
  end

  return true
end

---@class GetTodoItemAtPositionOpts
---@field todo_map? table<integer, checkmate.TodoItem> Pre-parsed todo item map to use instead of performing within function
---@field root_only? boolean If true, only matches to the todo item's first line

-- Function to find a todo item at a given buffer position
--  - If on a blank line, will return nil
--  - If on the same line as a todo item, will return the todo item
--  - If on a line that is contained within a parent todo item, may return the todo item depending on the allowed max_depth
--  - Otherwise if no todo item is found, will return nil
---@param bufnr integer? Buffer number
---@param row integer? 0-indexed row
---@param col integer? 0-indexed column
---@param opts GetTodoItemAtPositionOpts?
---@return checkmate.TodoItem? todo_item
function M.get_todo_item_at_position(bufnr, row, col, opts)
  local log = require("checkmate.log")
  local config = require("checkmate.config")

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  row = row or vim.api.nvim_win_get_cursor(0)[1] - 1
  col = col or vim.api.nvim_win_get_cursor(0)[2]

  opts = opts or {}

  local todo_map = opts.todo_map or M.get_todo_map(bufnr)

  -- first check: exact position match via extmarks
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns_todos, { row, 0 }, { row, -1 }, {})

  for _, extmark in ipairs(extmarks) do
    local extmark_id = extmark[1]
    local todo_item = todo_map[extmark_id]
    if todo_item then
      return todo_item
    end
  end

  -- we are here because the row did not match a todo's first row (tracked by the extmark)...but we could still be within a todo's scope
  -- use TS to find the smallest list_item containing this position
  local root = M.get_markdown_tree_root(bufnr)
  local node = root:named_descendant_for_range(row, col, row, col)

  -- reverse lookup: node -> todo_item
  local node_to_todo = {}
  for _, todo_item in pairs(todo_map) do
    node_to_todo[todo_item.node:id()] = todo_item
  end

  -- walk up from the current node to find the closest list_item that's a todo
  while node do
    if node:type() == "list_item" then
      local todo_item = node_to_todo[node:id()]
      -- limit to the semantic end row (TS range's will include a blank line at the end of the node as part of the node)
      if todo_item and row <= todo_item.range["end"].row then
        if opts.root_only ~= true then
          return todo_item
        end
        -- if root_only, we only match if on the exact first row
        if todo_item.range.start.row == row then
          return todo_item
        end
      end
    end
    node = node:parent()
  end

  log.debug("No matching todo item found at position", { module = "parser" })
  return nil
end

--- Finds the first inline node within a list_item
---
--- This is more robust than simply finding the first paragraph node and its inline node.
--- For example, when a list item's content is converted to a sextext heading due to a bare `-` on the next line,
--- the first inline node is actually within sextext_heading -> paragraph -> inline.
---
--- PERFORMANCE: I don't think this should be too performance heavy unless todo items very deeply nested or
--- in really big documents.
---
---@param list_item_node TSNode list_item node to search within
---@return TSNode|nil result the first inline node found, or nil
function M.find_first_inline_in_list_item(list_item_node)
  -- BFS to find the first paragraph --> first inline child
  local queue = { list_item_node }
  local first_paragraph = nil

  while #queue > 0 do
    local node = table.remove(queue, 1)

    if node:type() == "paragraph" then
      first_paragraph = node
      break
    end

    for child in node:iter_children() do
      if child:type() ~= "list_item" then
        table.insert(queue, child)
      end
    end
  end

  if first_paragraph then
    for child in first_paragraph:iter_children() do
      if child:type() == "inline" then
        return child
      end
    end
  end

  return nil
end

--- Discovers all todo items in a buffer and builds a node map
---@param bufnr number Buffer number
---@return table<integer, checkmate.TodoItem>  Map of all todo items with their relationships
function M.discover_todos(bufnr)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("parser.discover_todos")

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local todo_map = {}

  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  if not parser then
    log.debug("No parser available for markdown", { module = "parser" })
    return todo_map
  end

  local tree = parser:parse()[1]
  if not tree then
    log.debug("Failed to parse buffer", { module = "parser" })
    vim.notify("Checkmate: Failed to parse buffer", vim.log.levels.ERROR)
    return todo_map
  end

  local existing_extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns_todos, 0, -1, {})
  local extmark_by_pos = {}
  for _, extmark in ipairs(existing_extmarks) do
    local id, row, col = extmark[1], extmark[2], extmark[3]
    extmark_by_pos[row .. ":" .. col] = id
  end

  local root = tree:root()

  -- grab all nodes we need in a single pass
  local node_info = {
    list_items = {},
    markers_by_list_item = {}, -- list_item node id -> marker node
    first_inlines_by_list_item = {}, -- list_item node id -> first inline node
  }

  local current_list_item = nil

  for id, node, _ in M.FULL_TODO_QUERY:iter_captures(root, bufnr, 0, -1) do
    local capture_name = M.FULL_TODO_QUERY.captures[id]

    if capture_name == "list_item" then
      current_list_item = node

      local start_row, start_col, end_row, end_col = node:range()
      table.insert(node_info.list_items, {
        node = node,
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
      })
    elseif capture_name == "list_marker" or capture_name == "list_marker_ordered" then
      local parent = node:parent()
      if parent then
        local parent_id = parent:id()
        node_info.markers_by_list_item[parent_id] = node_info.markers_by_list_item[parent_id] or {}
        table.insert(node_info.markers_by_list_item[parent_id], {
          node = node,
          type = M.get_marker_type_from_capture_name(capture_name),
        })
      end
    elseif capture_name == "first_inline" and current_list_item then
      -- The "first inline" node of a list item node is almost always within a enclosing paragraph node
      -- There are some non-paragraph nodes that will break this assumption, such as ATX headings, thematic breaks, HTML blocks, etc
      -- However, since we only care about inline nodes on lines with todo markers, these are always parsed as paragraph and inline nodes
      -- because the todo marker (or GFM task marker) after the list marker makes the list item content parse as a paragraph
      local parent = node:parent() -- should be paragraph
      if parent then
        parent = parent:parent() -- should be list_item or something between
        -- walk up to find the containing list_item
        local enclosing_list_item = parent
        while enclosing_list_item and enclosing_list_item:type() ~= "list_item" do
          enclosing_list_item = enclosing_list_item:parent()
        end

        if enclosing_list_item == current_list_item then
          local list_item_id = current_list_item:id()
          if not node_info.first_inlines_by_list_item[list_item_id] then
            node_info.first_inlines_by_list_item[list_item_id] = node
          end
        end
      end
    end
  end

  -- batch read all needed lines
  local rows_needed = {}
  for _, item in ipairs(node_info.list_items) do
    table.insert(rows_needed, item.start_row)
  end
  local first_lines = util.batch_get_lines(bufnr, rows_needed)

  for _, item in ipairs(node_info.list_items) do
    local first_line = first_lines[item.start_row] or ""
    local todo_state = M.get_todo_item_state(first_line)

    if todo_state then
      local start_row = item.start_row

      -- get marker position
      local todo_marker = todo_state == "checked" and config.options.todo_markers.checked
        or config.options.todo_markers.unchecked
      local marker_col = 0
      local todo_marker_byte_pos = first_line:find(todo_marker, 1, true)
      if todo_marker_byte_pos then
        marker_col = todo_marker_byte_pos - 1
      end

      local extmark_col = marker_col
      local pos_key = start_row .. ":" .. extmark_col
      local extmark_id = extmark_by_pos[pos_key]

      if not extmark_id then
        extmark_id = vim.api.nvim_buf_set_extmark(bufnr, config.ns_todos, start_row, extmark_col, {
          right_gravity = false,
        })
      end
      extmark_by_pos[pos_key] = nil

      local raw_range = {
        start = { row = start_row, col = item.start_col },
        ["end"] = { row = item.end_row, col = item.end_col },
      }
      local semantic_range = util.get_semantic_range(raw_range, bufnr)

      ---@type checkmate.ListMarkerInfo
      local list_marker = nil
      local node_id = item.node:id()
      -- TODO: verify this is the list mark for the todo item?
      local markers = node_info.markers_by_list_item[node_id]

      if markers and #markers > 0 then
        local line_from_marker = first_line:gsub("^%s+", "")
        local marker_text = line_from_marker:match("^[%-%*%+]") or line_from_marker:match("^%d+[%.%)]")
        list_marker = {
          node = markers[1].node,
          type = markers[1].type,
          text = marker_text,
        }
      end

      local first_inline_node = node_info.first_inlines_by_list_item[item.node:id()]
      local first_inline_range = nil

      if first_inline_node then
        local inline_start_row, inline_start_col, inline_end_row, inline_end_col = first_inline_node:range()
        first_inline_range = {
          start = { row = inline_start_row, col = inline_start_col },
          ["end"] = { row = inline_end_row, col = inline_end_col },
        }
      else
        -- fallback to semantic range
        first_inline_range = semantic_range
      end

      todo_map[extmark_id] = {
        id = extmark_id,
        state = todo_state,
        node = item.node,
        range = semantic_range,
        ts_range = raw_range,
        first_inline_range = first_inline_range,
        todo_text = first_line,
        todo_marker = {
          position = { row = start_row, col = marker_col },
          text = todo_marker,
        },
        list_marker = list_marker,
        metadata = {},
        children = {},
        parent_id = nil,
      }
    end
  end

  -- extract metadata using the inline range
  for _, todo_item in pairs(todo_map) do
    todo_item.metadata = M.extract_metadata(bufnr, todo_item.first_inline_range)
  end

  -- Clean up orphaned extmarks
  for _, orphaned_id in pairs(extmark_by_pos) do
    vim.api.nvim_buf_del_extmark(bufnr, config.ns_todos, orphaned_id)
  end

  M.build_todo_hierarchy(todo_map)

  profiler.stop("parser.discover_todos")
  return todo_map
end

---Returns the list_marker type as "unordered" or "ordered"
---@param capture_name string A capture name returned from a TS query
---@return string: "ordered" or "unordered"
function M.get_marker_type_from_capture_name(capture_name)
  local is_ordered = capture_name:match("ordered") ~= nil
  return is_ordered and "ordered" or "unordered"
end

---Build the hierarchy of todo items based on Treesitter's parsing of markdown structure
---@param todo_map table<integer, checkmate.TodoItem>
---@return table<integer, checkmate.TodoItem> result The updated todo map with hierarchy information
function M.build_todo_hierarchy(todo_map)
  -- Build node->todo lookup table once
  local node_to_todo = {}
  for id, todo in pairs(todo_map) do
    node_to_todo[todo.node:id()] = id
    todo.children = {}
    todo.parent_id = nil
  end

  for id, todo in pairs(todo_map) do
    local parent_node = M.find_parent_list_item(todo.node)
    if parent_node then
      local parent_id = node_to_todo[parent_node:id()]
      if parent_id then
        todo.parent_id = parent_id
        table.insert(todo_map[parent_id].children, id)
      end
    end
  end

  return todo_map
end

--- Get current position of a todo item via its extmark
---@param bufnr integer
---@param extmark_id integer
---@return {row: integer, col: integer}|nil
function M.get_todo_position(bufnr, extmark_id)
  local config = require("checkmate.config")
  local extmark = vim.api.nvim_buf_get_extmark_by_id(bufnr, config.ns_todos, extmark_id, {})
  if extmark then
    return { row = extmark[1], col = extmark[2] }
  end
  return nil
end

function M.get_markdown_tree_root(bufnr)
  local ts_parser = vim.treesitter.get_parser(bufnr, "markdown")
  if not ts_parser then
    error("No Treesitter parser found for markdown")
  end

  local tree = ts_parser:parse()[1]
  if not tree then
    error("No parse tree found")
  end

  local root = tree:root()
  return root
end

--- Extract all @tag(value) metadata from the first‐inline range of a todo.
--- @param bufnr number
--- @param range checkmate.Range
--- @return table{entries:checkmate.MetadataEntry[], by_tag:table<string,checkmate.MetadataEntry>}
function M.extract_metadata(bufnr, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, range.start.row, range["end"].row + 1, false)
  local raw = table.concat(lines, "\n")

  -- map a byte‐offset of the joined string back to (row,col) in the original lines
  -- precompute cumulative byte‐lengths for each line
  -- i.e. each line contributes `#ln + 1` bytes to the offset
  local cum = { 0 }
  for i, ln in ipairs(lines) do
    cum[i + 1] = cum[i] + #ln + 1 -- +1 for the "\n"
  end
  -- convert a 1-based raw byte-offset → 0-based {row, col}
  local offset_to_pos = function(off)
    for i = 1, #lines do
      if off <= cum[i + 1] then
        return {
          row = range.start.row + i - 1,
          col = off - cum[i] - 1,
        }
      end
    end
    -- fallback to the end of the range
    return { row = range["end"].row, col = range["end"].col }
  end

  local entries = {}
  local by_tag = {}

  -- iterate all "@tag(...)" matches
  local idx = 1
  while true do
    -- s,e are the 1-based INCLUSIVE byte‐offsets of the entire "@tag(...)" substring
    -- tag is the name; group is "(...)" including parens
    local s, e, tag, group = raw:find(METADATA_PATTERN, idx)
    if not s then
      break
    end

    -- i hate Lua string indexing + Neovim...seriously wtf

    -- find the "(" and ")" -- these are both 1-based, inclusive
    local open_off = e - #group + 1 -- byte of "("
    local close_off = e -- byte of ")"

    -- get 1-based range of the value inside
    local val_start_off = open_off + 1 -- first byte of value
    local val_end_off = close_off - 1 -- last byte of value

    -- extract and normalize the text
    local raw_value = raw:sub(val_start_off, val_end_off)
    local clean_value = raw_value:gsub("\n%s*", " ")

    -- full "@tag(value)" range:
    local tag_start_pos = offset_to_pos(s) -- at "@"
    local tag_end_incl = offset_to_pos(e) -- at ")"
    local tag_end_excl = {
      row = tag_end_incl.row,
      col = tag_end_incl.col + 1, -- one past ")"
    }

    local val_start_pos = offset_to_pos(val_start_off) -- at first byte of value
    local val_end_excl = offset_to_pos(val_end_off + 1) -- maps to the ")" byte

    local entry = {
      tag = tag,
      value = clean_value,
      range = require("checkmate.lib.range").new(tag_start_pos, tag_end_excl),
      value_range = {
        start = val_start_pos,
        ["end"] = val_end_excl,
      },
      alias_for = nil, -- will be set later
    }

    -- check if this is an alias and map to canonical name
    local meta_module = require("checkmate.metadata")
    local canonical_name = meta_module.get_canonical_name(tag)
    if canonical_name and canonical_name ~= tag then
      entry.alias_for = canonical_name
    end

    table.insert(entries, entry)
    by_tag[tag] = entry

    idx = e + 1
  end

  return { entries = entries, by_tag = by_tag }
end

-- Helper function to find the parent list_item node of a given list_item node
---@param node TSNode The list_item node to find the parent for
---@return TSNode|nil parent_node The parent list_item node, if any
function M.find_parent_list_item(node)
  -- In markdown, the hierarchy is typically:
  -- list_item -> list -> list_item (parent)

  local parent = node:parent()

  -- no parent or parent is root
  if not parent or parent:type() == "document" then
    return nil
  end

  -- in CommonMark, list items are nested inside lists
  if parent:type() == "list" then
    local grandparent = parent:parent()
    if grandparent and grandparent:type() == "list_item" then
      return grandparent
    end
  end

  return nil
end

function M.get_all_list_items(bufnr)
  local list_items = {}

  local root = M.get_markdown_tree_root(bufnr)
  if not root then
    return {}
  end

  local list_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_item) @list_item
    ]]
  )

  -- collect all list items and their marker information
  for _, node, _ in list_query:iter_captures(root, bufnr, 0, -1) do
    local start_row, start_col, end_row, end_col = node:range()

    local marker_node = nil
    local marker_type = nil

    -- Find direct children that are list markers
    local marker_query = M.FULL_TODO_QUERY
    for marker_id, marker, _ in marker_query:iter_captures(node, bufnr, 0, -1) do
      local name = marker_query.captures[marker_id]
      local m_type = M.get_marker_type_from_capture_name(name)

      -- Verify this marker is a direct child
      if marker:parent() == node then
        marker_node = marker
        marker_type = m_type
        break
      end
    end

    -- Only add if we found a marker
    if marker_node then
      table.insert(list_items, {
        node = node,
        range = {
          start = { row = start_row, col = start_col },
          ["end"] = { row = end_row, col = end_col },
        },
        list_marker = {
          node = marker_node,
          type = marker_type,
        },
        text = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1],
        -- Find parent relationship
        parent_node = M.find_parent_list_item(node), -- List item's parent is usually two levels up
      })
    end
  end

  -- Build parent-child relationships
  for _, item in ipairs(list_items) do
    -- Initialize children array
    item.children = {}

    for _, other in ipairs(list_items) do
      if item.node:id() ~= other.node:id() and other.parent_node == item.node then
        table.insert(item.children, other.node:id()) -- Store index in our list
      end
    end
  end

  return list_items
end

return M
