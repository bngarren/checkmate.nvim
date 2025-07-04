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
---@field value_col integer Start col (0-indexed) of value
---@field alias_for? string The canonical tag name if this is an alias
---@field position_in_line integer (1-indexed)

---@class checkmate.TodoMetadata
---@field entries checkmate.MetadataEntry[] List of metadata entries
---@field by_tag table<string, checkmate.MetadataEntry> Quick access by tag name

---@class checkmate.Range
---@field start {row: integer, col: integer}
---@field ["end"] {row: integer, col: integer}

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
--- @field content_nodes ContentNodeInfo[] List of content nodes
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
  (paragraph) @paragraph
]]
)

-- match the @tag and then a balanced sequence %b(), which is everything in the outer parentheses
local METADATA_PATTERN = "@([%a][%w_%-]*)(%b())"

M.list_item_markers = { "-", "+", "*" }

local PATTERN_CACHE = {
  checked_todo = nil,
  unchecked_todo = nil,
}

function M.clear_pattern_cache()
  PATTERN_CACHE = {
    checked_todo = nil,
    unchecked_todo = nil,
  }
end

function M.getCheckedTodoPatterns()
  if not PATTERN_CACHE.checked_todo then
    local checked_marker = require("checkmate.config").options.todo_markers.checked
    local util = require("checkmate.util")
    ---@type fun(marker: string): string[]
    local build_patterns = util.build_todo_patterns({
      simple_markers = M.list_item_markers,
      use_numbered_list_markers = true,
    })
    PATTERN_CACHE.checked_todo = build_patterns(checked_marker)
  end
  return PATTERN_CACHE.checked_todo
end

function M.getUncheckedTodoPatterns()
  if not PATTERN_CACHE.unchecked_todo then
    local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
    local util = require("checkmate.util")
    ---@type fun(marker: string): string[]
    local build_patterns = util.build_todo_patterns({
      simple_markers = M.list_item_markers,
      use_numbered_list_markers = true,
    })
    PATTERN_CACHE.unchecked_todo = build_patterns(unchecked_marker)
  end
  return PATTERN_CACHE.unchecked_todo
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
--- Returns nil if no todo item was found on the line
---@param line string Line to extract Todo item state
---@return checkmate.TodoItemState?
function M.get_todo_item_state(line)
  local log = require("checkmate.log")
  local util = require("checkmate.util")

  ---@type checkmate.TodoItemState
  local todo_state = nil
  local unchecked_patterns = M.getUncheckedTodoPatterns()
  local checked_patterns = M.getCheckedTodoPatterns()

  if util.match_first(unchecked_patterns, line) then
    todo_state = "unchecked"
    log.trace("Matched unchecked pattern", { module = "parser" })
  elseif util.match_first(checked_patterns, line) then
    todo_state = "checked"
    log.trace("Matched checked pattern", { module = "parser" })
  end

  log.trace("Todo type: " .. (todo_state or "nil"), { module = "parser" })
  return todo_state
end

function M.setup()
  local highlights = require("checkmate.highlights")
  local log = require("checkmate.log")

  -- clear pattern cache in case config changed
  M.clear_pattern_cache()

  M.todo_map_cache = {}

  log.debug("Checked pattern is: " .. table.concat(M.getCheckedTodoPatterns() or {}, " , "))
  log.debug("Unchecked pattern is: " .. table.concat(M.getUncheckedTodoPatterns() or {}, " , "))

  highlights.setup_highlights()
end

-- Convert standard markdown 'task list marker' syntax to Unicode symbols
function M.convert_markdown_to_unicode(bufnr)
  local log = require("checkmate.log")
  local util = require("checkmate.util")
  local config = require("checkmate.config")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false
  local original_modified = vim.bo[bufnr].modified

  -- build patterns once
  local unchecked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[ %]")
  local checked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[[xX]%]")
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

    -- unchecked replacements
    for _, pat in ipairs(unchecked_patterns) do
      if pat:sub(-1) == " " then
        -- pattern ends with space (variant 2), so add it back in replacement
        new_line = new_line:gsub(pat, "%1" .. unchecked .. " ")
      else
        -- pattern ends with $, no space needed
        new_line = new_line:gsub(pat, "%1" .. unchecked)
      end
    end

    -- checked replacements
    for _, pat in ipairs(checked_patterns) do
      if pat:sub(-1) == " " then
        -- same as unchecked, above
        new_line = new_line:gsub(pat, "%1" .. checked .. " ")
      else
        new_line = new_line:gsub(pat, "%1" .. checked)
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
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false

  -- Build patterns
  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked

  local unchecked_patterns, checked_patterns
  local ok, err = pcall(function()
    unchecked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, unchecked)
    checked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, checked)
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
        new_line = new_line:gsub(pattern, "%1[ ]")
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
        new_line = new_line:gsub(pattern, "%1[x]")
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
---@field todo_map table<integer, checkmate.TodoItem>? Pre-parsed todo item map to use instead of performing within function
---@field max_depth integer? What depth should still register as a parent todo item (0 = only direct, 1 = include children, etc.)

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

  -- Check if the current line is blank - if so, don't return any todo item
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  if line:match("^%s*$") then
    log.debug("Line is blank, not returning any todo item", { module = "parser" })
    return nil
  end

  opts = opts or {}
  local max_depth = opts.max_depth or 0

  local todo_map = opts.todo_map or M.get_todo_map(bufnr)

  -- First check: exact position match via extmarks
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns_todos, { row, 0 }, { row, -1 }, {})

  for _, extmark in ipairs(extmarks) do
    local extmark_id = extmark[1]
    local todo_item = todo_map[extmark_id]
    if todo_item then
      return todo_item
    end
  end

  -- we are here because the row did not match a todo's first row (tracked by the extmark)...but we could still be within a todo's scope
  -- now use Treesitter-based logic

  local root = M.get_markdown_tree_root(bufnr)
  local node = root:named_descendant_for_range(row, col, row, col)

  -- First, check if any todo items exist on this row
  -- This handles the case where the cursor is not in the todo item's Treesitter node's range, but
  -- should still act as if this todo item was selected (same row)
  for _, todo_item in pairs(todo_map) do
    if todo_item.range.start.row == row then
      log.debug("Found todo item starting on current row", { module = "parser" })
      return todo_item
    end
  end

  -- Otherwise, we see if this row position is within a list_item node (potential todo item hierarchy)
  -- Find the list_item node at or containing our position (if any)
  local list_item_node = nil
  while node do
    if node:type() == "list_item" then
      list_item_node = node
      break
    end
    node = node:parent()
  end

  if list_item_node then
    local function find_todo_by_node(target_node)
      for _, todo_item in pairs(todo_map) do
        if todo_item.node == target_node then
          return todo_item
        end
      end
      return nil
    end

    -- Check if this list_item is itself a todo item
    local todo_item = find_todo_by_node(list_item_node)

    if todo_item then
      -- It's a todo item - check if we're on its first line
      if row == todo_item.range.start.row then
        log.debug("Matched todo item directly on its first line", { module = "parser" })
        return todo_item
      elseif max_depth >= 1 then
        -- Within the todo item but not on first line - return if depth allows
        log.debug("Matched todo item via inner content (not first line) with depth=1", { module = "parser" })
        return todo_item
      end
    else
      -- It's a regular list item - check if it's a child of any todo item
      local current = list_item_node:parent()
      local depth = 1

      -- max_depth: how many levels we are allowed to look up for a todo item parent
      while current and depth <= max_depth do
        if current:type() == "list_item" then
          local parent_todo = find_todo_by_node(current)
          if parent_todo then
            log.debug(string.format("Matched parent todo item at depth=%d", depth), { module = "parser" })
            return parent_todo
          end
          depth = depth + 1
        end
        current = current:parent()
      end
    end
  end

  log.debug("No matching todo item found at position", { module = "parser" })
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

  -- Get existing extmarks
  local existing_extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns_todos, 0, -1, {})
  local extmark_by_pos = {}
  for _, extmark in ipairs(existing_extmarks) do
    local id, row, col = extmark[1], extmark[2], extmark[3]
    extmark_by_pos[row .. ":" .. col] = id
  end

  local root = tree:root()

  -- collect all nodes in a single pass
  local node_info = {
    list_items = {},
    markers_by_parent = {}, -- parent node id -> marker nodes
    paragraphs_by_parent = {}, -- parent node id -> paragraph nodes
  }

  for id, node, _ in M.FULL_TODO_QUERY:iter_captures(root, bufnr, 0, -1) do
    local capture_name = M.FULL_TODO_QUERY.captures[id]

    if capture_name == "list_item" then
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
        node_info.markers_by_parent[parent_id] = node_info.markers_by_parent[parent_id] or {}
        table.insert(node_info.markers_by_parent[parent_id], {
          node = node,
          type = M.get_marker_type_from_capture_name(capture_name),
        })
      end
    elseif capture_name == "paragraph" then
      local parent = node:parent()
      if parent then
        local parent_id = parent:id()
        node_info.paragraphs_by_parent[parent_id] = node_info.paragraphs_by_parent[parent_id] or {}
        table.insert(node_info.paragraphs_by_parent[parent_id], node)
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
      local markers = node_info.markers_by_parent[node_id]

      if markers and #markers > 0 then
        local line_from_marker = first_line:gsub("^%s+", "")
        local marker_text = line_from_marker:match("^[%-%*%+]") or line_from_marker:match("^%d+[%.%)]")
        list_marker = {
          node = markers[1].node,
          type = markers[1].type,
          text = marker_text,
        }
      end

      local content_nodes = {}
      local paragraphs = node_info.paragraphs_by_parent[node_id]
      if paragraphs then
        for _, p_node in ipairs(paragraphs) do
          table.insert(content_nodes, {
            node = p_node,
            type = "paragraph",
          })
        end
      end

      todo_map[extmark_id] = {
        id = extmark_id,
        state = todo_state,
        node = item.node,
        range = semantic_range,
        ts_range = raw_range,
        todo_text = first_line,
        content_nodes = content_nodes,
        todo_marker = {
          position = { row = start_row, col = marker_col },
          text = todo_marker,
        },
        list_marker = list_marker,
        metadata = M.extract_metadata(first_line, start_row),
        children = {},
        parent_id = nil,
      }
    end
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

-- Find content nodes (paragraphs, etc.)
function M.update_content_nodes(node, bufnr, todo_item)
  local content_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_item (paragraph) @paragraph)
  ]]
  )

  for _, content_node, _ in content_query:iter_captures(node, bufnr, 0, -1) do
    -- verify this paragraph is a direct child of this list_item
    local parent = content_node:parent()
    if parent == node then
      table.insert(todo_item.content_nodes, {
        node = content_node,
        type = "paragraph",
      })
    end
  end
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

---Extracts metadata from a line and returns structured information
---@param line string The line to extract metadata from
---@param row integer The row number (0-indexed)
---@return checkmate.TodoMetadata
function M.extract_metadata(line, row)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local meta_module = require("checkmate.metadata")

  ---@type checkmate.TodoMetadata
  local metadata = {
    entries = {},
    by_tag = {},
  }

  ---@param _line string String to search
  ---@param from_byte_pos integer start looking at this byte position
  ---@return string? tag, string? value, integer? start_byte, integer? end_byte
  local function find_metadata(_line, from_byte_pos)
    local s, e, tag, raw = _line:find(METADATA_PATTERN, from_byte_pos)
    if not s or not e then
      return nil
    end

    -- raw is "( ... )", so we gotta strip outer parens
    local inner = raw:sub(2, -2)

    -- trim whitespace
    local value = inner:match("^%s*(.-)%s*$")

    return tag, value, s, e
  end

  -- find all @tag(value) patterns and their positions
  local byte_pos = 1
  while true do
    local tag, value, start_byte, end_byte = find_metadata(line, byte_pos)
    if not tag or not start_byte or not end_byte then
      break
    end

    ---@type checkmate.MetadataEntry
    local entry = {
      tag = tag,
      value = value or "",
      range = {
        start = { row = row, col = start_byte - 1 }, -- 0-indexed column
        -- For the end col, we need 0 indexed (subtract 1) and since it is end-exclusive we add 1, cancelling out
        -- end-exclusive means the end col points to the pos after the last char
        ["end"] = { row = row, col = end_byte },
      },
      value_col = line:find("%b()", start_byte) or start_byte + #tag + 1,
      alias_for = nil, -- Will be set later if it's an alias
      position_in_line = start_byte, -- track original position in the line, use byte pos for sorting
    }

    -- check if this is an alias and map to canonical name
    local canonical_name = meta_module.get_canonical_name(tag)
    if canonical_name and canonical_name ~= tag then
      entry.alias_for = canonical_name
    end

    table.insert(metadata.entries, entry)

    -- store in by_tag lookup (last one wins if multiple with same tag)
    metadata.by_tag[tag] = entry

    -- if this is an alias, also store under canonical name
    if entry.alias_for then
      metadata.by_tag[entry.alias_for] = entry
    end

    -- move position for next search
    byte_pos = end_byte + 1

    log.debug(
      string.format("Metadata found: %s=%s at [%d,%d]-[%d,%d]", tag, value, row, start_byte - 1, row, end_byte),
      { module = "parser" }
    )
  end

  return metadata
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
