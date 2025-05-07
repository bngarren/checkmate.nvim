local M = {}

---@alias checkmate.TodoItemState "checked" | "unchecked"

--- @class TodoMarkerInfo
--- @field position {row: integer, col: integer} Position of the marker (0-indexed)
--- @field text string The marker text (e.g., "□" or "✓")

--- @class ListMarkerInfo
--- @field node TSNode Treesitter node of the list marker (uses 0-indexed row/col coordinates)
--- @field type "ordered"|"unordered" Type of list marker

--- @class ContentNodeInfo
--- @field node TSNode Treesitter node containing content (uses 0-indexed row/col coordinates)
--- @field type string Type of content node (e.g., "paragraph")

---@class checkmate.MetadataEntry
---@field tag string The tag name
---@field value string The value
---@field range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Position range (0-indexed)
---@field alias_for? string The canonical tag name if this is an alias
---@field position_in_line integer (1-indexed)

---@class checkmate.TodoMetadata
---@field entries checkmate.MetadataEntry[] List of metadata entries
---@field by_tag table<string, checkmate.MetadataEntry> Quick access by tag name

--- @class checkmate.TodoItem
--- @field state checkmate.TodoItemState The todo state
--- @field node TSNode The Treesitter node
--- Todo item's buffer range
--- The end col is expected to be adjusted (get_semantic_range) so that it accurately reflects the end of the content
--- @field range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}}
--- @field content_nodes ContentNodeInfo[] List of content nodes
--- @field todo_marker TodoMarkerInfo Information about the todo marker (0-indexed position)
--- @field list_marker ListMarkerInfo? Information about the list marker (0-indexed position)
--- @field metadata checkmate.TodoMetadata | {} Metadata for this todo item
--- @field todo_text string Text content of the todo item line (first line), may be truncated. Only for debugging.
--- @field children string[] IDs of child todo items
--- @field parent_id string? ID of parent todo item

M.list_item_markers = { "-", "+", "*" }

---@param todo_marker string The todo marker character to be used to build 'todo item' patterns
M.withDefaultListItemMarkers = function(todo_marker)
  local util = require("checkmate.util")
  local log = require("checkmate.log")

  -- Use the new build_todo_pattern to get a pattern-building function
  local build_patterns = util.build_todo_patterns({
    simple_markers = M.list_item_markers,
    use_numbered_list_markers = true,
  })

  local patterns = build_patterns(todo_marker)

  -- Optional debug logging of all patterns
  -- log.debug("Generated todo patterns for marker '" .. todo_marker .. "': " .. vim.inspect(patterns), { module = "parser" })

  return patterns
end

function M.getCheckedTodoPatterns()
  local checked_marker = require("checkmate.config").options.todo_markers.checked
  return M.withDefaultListItemMarkers(checked_marker)
end

function M.getUncheckedTodoPatterns()
  local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
  return M.withDefaultListItemMarkers(unchecked_marker)
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

-- Setup Treesitter queries for todo items
function M.setup()
  local config = require("checkmate.config")
  local highlights = require("checkmate.highlights")
  local log = require("checkmate.log")
  log.debug("Checked pattern is: " .. table.concat(M.getCheckedTodoPatterns(), " , "))
  log.debug("Unchecked pattern is: " .. table.concat(M.getUncheckedTodoPatterns(), " , "))

  local todo_query = [[
; Capture list items and their content for structure understanding
(list_item) @list_item
(paragraph) @paragraph

; Capture list markers for structure understanding
((list_marker_minus) @list_marker_minus)
((list_marker_plus) @list_marker_plus)
((list_marker_star) @list_marker_star)
]]
  -- Register the query
  vim.treesitter.query.set("markdown", "todo_items", todo_query)

  -- Define and set up highlight groups
  highlights.setup_highlights()

  -- Set up an autocmd to re-apply highlighting when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CheckmateHighlighting", { clear = true }),
    callback = function()
      -- Re-apply highlight groups after a small delay
      vim.defer_fn(function()
        highlights.setup_highlights()

        -- Clear the dynamic highlight cache to ensure they're recreated with the new colorscheme
        highlights.clear_highlight_cache()
      end, 10)
    end,
  })
end

-- Convert standard markdown 'task list marker' syntax to Unicode symbols
function M.convert_markdown_to_unicode(bufnr)
  local log = require("checkmate.log")
  local util = require("checkmate.util")
  local config = require("checkmate.config")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get all lines in the buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false
  local original_modified = vim.bo[bufnr].modified

  -- Build patterns only once
  local unchecked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[%s%]")
  local checked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[[xX]%]")
  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked

  -- Create new_lines table to avoid modifying while iterating
  local new_lines = {}

  -- Replace markdown syntax with Unicode
  for i, line in ipairs(lines) do
    local new_line = line

    -- Apply all unchecked replacements
    for _, pat in ipairs(unchecked_patterns) do
      new_line = new_line:gsub(pat, "%1" .. unchecked)
    end

    -- Apply all checked replacements
    for _, pat in ipairs(checked_patterns) do
      new_line = new_line:gsub(pat, "%1" .. checked)
    end

    -- Check if line was modified
    if new_line ~= line then
      modified = true
    end

    table.insert(new_lines, new_line)
  end

  -- Update buffer if changes were made
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

  -- Get all lines in the buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false

  -- Build patterns
  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked
  local unchecked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, unchecked)
  local checked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, checked)

  -- Create new_lines table
  local new_lines = {}

  -- Replace Unicode with markdown syntax
  for _, line in ipairs(lines) do
    local new_line = line

    -- Replace unchecked Unicode markers with "[ ]"
    for _, pattern in ipairs(unchecked_patterns) do
      new_line = new_line:gsub(pattern, "%1[ ]")
    end

    -- Replace checked Unicode markers with "[x]"
    for _, pattern in ipairs(checked_patterns) do
      new_line = new_line:gsub(pattern, "%1[x]")
    end

    if new_line ~= line then
      modified = true
    end

    table.insert(new_lines, new_line)
  end

  -- Update buffer if changes were made
  if modified then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    log.debug("Converted Unicode todo symbols to Markdown", { module = "parser" })
    return true
  end

  return false
end

-- Function to find a todo item at a given buffer position
--  - If on a blank line, will return nil
--  - If on the same line as a todo item, will return the todo item
--  - If on a line that is contained within a parent todo item, may return the todo item depending on the allowed max_depth
--  - Otherwise if no todo item is found, will return nil
---@param bufnr integer? Buffer number
---@param row integer? 0-indexed row
---@param col integer? 0-indexed column
---@param opts? { max_depth?: integer } What depth should still register as a parent todo item (0 = only direct, 1 = include children, etc.)
---@return checkmate.TodoItem? todo_item
function M.get_todo_item_at_position(bufnr, row, col, opts)
  local log = require("checkmate.log")

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

  local todo_map = M.discover_todos(bufnr)
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

  -- If we found a list_item node
  if list_item_node then
    -- Get the node ID
    local node_id = list_item_node:id()
    -- Check if this list_item is itself a todo item
    local todo_item = todo_map[node_id]

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
          local parent_todo = todo_map[current:id()]
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
---@return table<string, checkmate.TodoItem>  Map of all todo items with their relationships
function M.discover_todos(bufnr)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Initialize the node map
  ---@type table <string, checkmate.TodoItem>
  local todo_map = {}

  -- Get the Treesitter parser for markdown
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  if not parser then
    log.debug("No parser available for markdown", { module = "parser" })
    return todo_map
  end

  -- Parse the buffer
  local tree = parser:parse()[1]
  if not tree then
    log.debug("Failed to parse buffer", { module = "parser" })
    return todo_map
  end

  local root = tree:root()

  -- Create a query to find all list_item nodes
  local list_item_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_item) @list_item
  ]]
  )

  -- First pass: Discover all todo items
  for _, node, _ in list_item_query:iter_captures(root, bufnr, 0, -1) do
    -- Get node information (TS ranges are 0-indexed and end-exclusive)
    local start_row, start_col, end_row, end_col = node:range()
    local node_id = node:id()

    -- Get the first line to check if it's a todo item
    local first_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
    local todo_state = M.get_todo_item_state(first_line)

    if todo_state then
      -- This is a todo item, add it to the map
      log.trace("Found todo item at line " .. (start_row + 1) .. ", type: " .. todo_state, { module = "parser" })

      -- Create the raw range first
      local raw_range = {
        start = { row = start_row, col = start_col },
        ["end"] = { row = end_row, col = end_col },
      }

      -- Get the adjusted range with proper semantic boundaries
      -- This more meaningful range encompasses the todo content better than the quirky Treesitter technical range for a node
      local semantic_range = util.get_semantic_range(raw_range, bufnr)

      -- Find the todo marker position
      local todo_marker = todo_state == "checked" and config.options.todo_markers.checked
        or config.options.todo_markers.unchecked

      -- Find marker position, defaulting to -1 if not found
      local marker_col = -1
      local todo_marker_pos = first_line:find(todo_marker, 1, true)
      if todo_marker_pos then
        marker_col = todo_marker_pos - 1 -- Adjust for 0-indexing
      end

      local metadata = M.extract_metadata(first_line, start_row)

      -- Initialize the todo item entry
      todo_map[node_id] = {
        state = todo_state,
        node = node,
        range = semantic_range,
        todo_text = first_line,
        content_nodes = {},
        todo_marker = {
          position = {
            row = start_row,
            col = marker_col,
          },
          text = todo_marker,
        },
        list_marker = nil, -- Will be set by find_list_marker_info
        metadata = metadata,
        children = {}, -- Will be set in second pass, if applicable
        parent_id = nil, -- Will be set in second pass, if applicable
      }

      -- Find and store list marker information
      M.update_list_marker_info(node, bufnr, todo_map[node_id])

      -- Find and store content nodes
      M.update_content_nodes(node, bufnr, todo_map[node_id])
    end
  end

  -- Second pass: Build parent-child relationships
  M.build_todo_hierarchy(todo_map)

  return todo_map
end

---Returns a TS query for finding markdown list_markers
---@return vim.treesitter.Query
function M.get_list_marker_query()
  return vim.treesitter.query.parse(
    "markdown",
    [[
    (list_marker_minus) @list_marker_minus
    (list_marker_plus) @list_marker_plus
    (list_marker_star) @list_marker_star
    (list_marker_dot) @list_marker_ordered
    (list_marker_parenthesis) @list_marker_ordered
    ]]
  )
end

---Returns the list_marker type as "unordered" or "ordered"
---@param capture_name string A capture name returned from a TS query
---@return string: "ordered" or "unordered"
function M.get_marker_type_from_capture_name(capture_name)
  local is_ordered = capture_name:match("ordered") ~= nil
  return is_ordered and "ordered" or "unordered"
end

---Finds the markdown list_marker associated with the given node and updates the todo_item's
---list_marker field
---@param node TSNode The list_item node of a todo item
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
function M.update_list_marker_info(node, bufnr, todo_item)
  -- Find all child nodes that could be list markers
  local list_marker_query = M.get_list_marker_query()

  for id, marker_node, _ in list_marker_query:iter_captures(node, bufnr, 0, -1) do
    local name = list_marker_query.captures[id]
    local marker_type = M.get_marker_type_from_capture_name(name)

    -- Verify this marker is a direct child of this list_item
    local parent = marker_node:parent()
    while parent and parent ~= node do
      parent = parent:parent()
    end

    if parent == node then
      todo_item.list_marker = {
        node = marker_node,
        type = marker_type,
      }
      break
    end
  end
end

-- Find content nodes (paragraphs, etc.)
function M.update_content_nodes(node, bufnr, todo_item)
  -- Find child nodes containing content
  local content_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_item (paragraph) @paragraph)
  ]]
  )

  for _, content_node, _ in content_query:iter_captures(node, bufnr, 0, -1) do
    -- Verify this paragraph is a direct child of this list_item
    local parent = content_node:parent()
    if parent == node then
      table.insert(todo_item.content_nodes, {
        node = content_node,
        type = "paragraph",
      })
    end
  end
end

---Build the hierarchy of todo items based on indentation
---
---The Treesitter tree-based list item hierarchy doesn't always match the expected parent/child
---relationships from a user perspective. Users expect parent/child relationships based on
---indentation, so we build the todo hierarchy based on indentation differences rather than
---relying solely on the Treesitter tree structure.
---
---The rule is: "your parent is the closest todo item above you with less indentation"
---
---@param todo_map table<string, checkmate.TodoItem>
---@return table<string, checkmate.TodoItem> result The updated todo map with hierarchy information
function M.build_todo_hierarchy(todo_map)
  -- Reset all children arrays and parent_ids
  for _, item in pairs(todo_map) do
    item.children = {}
    item.parent_id = nil
  end

  -- Create a sorted list of todos by row
  local todos_by_row = {}
  for id, item in pairs(todo_map) do
    table.insert(todos_by_row, { id = id, item = item })
  end

  table.sort(todos_by_row, function(a, b)
    return a.item.range.start.row < b.item.range.start.row
  end)

  -- Process each todo to establish parent-child relationships based on indentation
  for i, entry in ipairs(todos_by_row) do
    local current_id = entry.id
    local current_item = entry.item
    local current_indent = current_item.range.start.col

    -- Only process indented items (non-root items)
    if current_indent > 0 then
      -- Find the closest previous item with less indentation
      for j = i - 1, 1, -1 do
        local prev_entry = todos_by_row[j]
        local prev_id = prev_entry.id
        local prev_item = prev_entry.item
        local prev_indent = prev_item.range.start.col

        if prev_indent < current_indent then
          -- Found a parent - it's the first item above with less indentation
          current_item.parent_id = prev_id
          table.insert(todo_map[prev_id].children, current_id)
          break
        end
      end
    end
  end

  return todo_map
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

  ---@type checkmate.TodoMetadata
  local metadata = {
    entries = {},
    by_tag = {},
  }
  ---Tags must begin with a letter, but can then contain letters, digits, underscores, or hyphens
  local tag_value_pattern = "@([%a][%w_%-]*)%(%s*(.-)%s*%)"

  -- Find all @tag(value) patterns and their positions
  local pos = 1
  while true do
    -- Will capture tag names that include underscores and hypens
    local tag_start, tag_end, tag, value = line:find(tag_value_pattern, pos)
    if not tag_start or not tag_end then
      break
    end

    -- Create metadata entry with position information
    ---@type checkmate.MetadataEntry
    local entry = {
      tag = tag,
      value = value,
      range = {
        start = { row = row, col = tag_start - 1 }, -- 0-indexed column
        ["end"] = { row = row, col = tag_end - 1 },
      },
      alias_for = nil, -- Will be set later if it's an alias
      position_in_line = tag_start, -- track original position in the line
    }

    -- Check if this is an alias and map to canonical name
    for canonical_name, meta_props in pairs(config.options.metadata) do
      if tag == canonical_name then
        -- This is a canonical name, no need to set alias_for
        break
      end

      -- Check if it's in the aliases
      for _, alias in ipairs(meta_props.aliases or {}) do
        if tag == alias then
          entry.alias_for = canonical_name
          break
        end
      end

      if entry.alias_for then
        break
      end
    end

    -- Add to entries list
    table.insert(metadata.entries, entry)

    -- Store in by_tag lookup (last one wins if multiple with same tag)
    metadata.by_tag[tag] = entry

    -- If this is an alias, also store under canonical name
    if entry.alias_for then
      metadata.by_tag[entry.alias_for] = entry
    end

    -- Move position for next search
    pos = tag_end + 1

    log.debug(
      string.format("Metadata found: %s=%s at [%d,%d]-[%d,%d]", tag, value, row, tag_start - 1, row, tag_end),
      { module = "parser" }
    )
  end

  return metadata
end

return M
