local M = {}

---@alias checkmate.TodoItemState "checked" | "unchecked"

--- @class TodoMarkerInfo
--- @field position {row: integer, col: integer} Position of the marker
--- @field text string The marker text (e.g., "□" or "✓")

--- @class ListMarkerInfo
--- @field node TSNode Treesitter node of the list marker
--- @field type "ordered"|"unordered" Type of list marker

--- @class ContentNodeInfo
--- @field node TSNode Treesitter node containing content
--- @field type string Type of content node (e.g., "paragraph")

---@class checkmate.TodoMetadata
---@field start_date string
---@field end_date string

--- @class checkmate.TodoItem
--- @field state checkmate.TodoItemState The todo state
--- @field node TSNode The Treesitter node
--- @field range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Item range
--- @field content_nodes ContentNodeInfo[] List of content nodes
--- @field todo_marker TodoMarkerInfo Information about the todo marker
--- @field list_marker ListMarkerInfo? Information about the list marker
--- @field metadata checkmate.TodoMetadata | {} Meta tags for the todo item
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
      end, 10)
    end,
  })
end

-- Convert standard markdown 'task list marker' syntax to Unicode symbols
function M.convert_markdown_to_unicode(bufnr)
  local log = require("checkmate.log")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get all lines in the buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = false
  -- Store current modified state to restore it later
  local was_modified = vim.api.nvim_get_option_value("modified", { buf = bufnr })

  local util = require("checkmate.util")
  local config = require("checkmate.config")

  local unchecked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[%s%]")
  local checked_patterns = util.build_markdown_checkbox_patterns(M.list_item_markers, "%[[xX]%]")
  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked

  -- Replace markdown syntax with Unicode
  for i, line in ipairs(lines) do
    local new_line = line
    local original_line = line

    -- Apply all unchecked replacements
    for _, pat in ipairs(unchecked_patterns) do
      new_line = new_line:gsub(pat, "%1" .. unchecked)
    end

    -- Apply all checked replacements
    for _, pat in ipairs(checked_patterns) do
      new_line = new_line:gsub(pat, "%1" .. checked)
    end

    -- Update line if changed
    if new_line ~= original_line then
      lines[i] = new_line
      modified = true
    end
  end

  -- Update buffer if changes were made
  if modified then
    -- Disable undo and modification tracking temporarily
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! undojoin") -- Avoid breaking undo sequence
      local old_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modified", was_modified, { buf = bufnr }) -- Reset modified flag
      vim.api.nvim_set_option_value("modifiable", old_modifiable, { buf = bufnr })
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
  -- Store current modified state to restore it later
  local was_modified = vim.api.nvim_get_option_value("modified", { buf = bufnr })

  local unchecked = config.options.todo_markers.unchecked
  local checked = config.options.todo_markers.checked

  local unchecked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, unchecked)
  local checked_patterns = util.build_unicode_todo_patterns(M.list_item_markers, checked)

  -- Replace Unicode with markdown syntax
  for i, line in ipairs(lines) do
    local new_line = line
    local original_line = line

    -- Replace unchecked Unicode markers (e.g., "□") with "[ ]"
    for _, pattern in ipairs(unchecked_patterns) do
      new_line = new_line:gsub(pattern, "%1[ ]")
    end

    -- Replace checked Unicode markers (e.g., "✔") with "[x]"
    for _, pattern in ipairs(checked_patterns) do
      new_line = new_line:gsub(pattern, "%1[x]")
    end

    if new_line ~= original_line then
      lines[i] = new_line
      modified = true
    end
  end

  -- Update buffer if changes were made
  if modified then
    -- Disable undo and modification tracking temporarily
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! undojoin") -- Avoid breaking undo sequence
      local old_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modified", was_modified, { buf = bufnr }) -- Reset modified flag
      vim.api.nvim_set_option_value("modifiable", old_modifiable, { buf = bufnr })
    end)

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

  log.debug(
    string.format("Looking for todo item at position [%d,%d] with max_depth=%d", row, col, max_depth),
    { module = "parser" }
  )

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
    -- Get node information
    local start_row, start_col, end_row, end_col = node:range()
    local node_id = node:id()

    -- Get the first line to check if it's a todo item
    local first_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
    local todo_state = M.get_todo_item_state(first_line)

    if todo_state then
      -- This is a todo item, add it to the map
      log.trace("Found todo item at line " .. (start_row + 1) .. ", type: " .. todo_state, { module = "parser" })

      -- Find the todo marker position
      local todo_marker = todo_state == "checked" and config.options.todo_markers.checked
        or config.options.todo_markers.unchecked
      local todo_marker_pos = first_line:find(todo_marker, 1, true)

      local metadata = M.extract_metadata(first_line)

      -- Initialize the todo item entry
      todo_map[node_id] = {
        state = todo_state,
        node = node,
        range = {
          start = { row = start_row, col = start_col },
          ["end"] = { row = end_row, col = end_col },
        },
        todo_text = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1],
        content_nodes = {},
        todo_marker = {
          position = {
            row = start_row,
            col = todo_marker_pos and todo_marker_pos - 1 or -1,
          },
          text = todo_marker,
        },
        list_marker = nil, -- Will be set by find_list_marker_info
        metadata = metadata,
        children = {},
        parent_id = nil, -- Will be set in second pass
      }

      -- Find and store list marker information
      M.find_list_marker_info(node, bufnr, todo_map[node_id])

      -- Find and store content nodes
      M.find_content_nodes(node, bufnr, todo_map[node_id])
    end
  end

  -- Second pass: Build parent-child relationships
  M.build_todo_hierarchy(todo_map)

  return todo_map
end

-- Find list marker information
function M.find_list_marker_info(node, bufnr, todo_item)
  -- Find all child nodes that could be list markers
  local list_marker_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_marker_minus) @list_marker_minus
    (list_marker_plus) @list_marker_plus
    (list_marker_star) @list_marker_star
    (list_marker_dot) @list_marker_ordered
    (list_marker_parenthesis) @list_marker_ordered
  ]]
  )

  for id, marker_node, _ in list_marker_query:iter_captures(node, bufnr, 0, -1) do
    local name = list_marker_query.captures[id]
    local is_ordered = name:match("ordered") ~= nil
    local marker_type = is_ordered and "ordered" or "unordered"

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
function M.find_content_nodes(node, bufnr, todo_item)
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

-- Build the hierarchy of todo items
---@param todo_map table<string, checkmate.TodoItem>
function M.build_todo_hierarchy(todo_map)
  local log = require("checkmate.log")

  -- For each todo item, find its true parent (if any)
  for child_id, child_item in pairs(todo_map) do
    local child_node = child_item.node

    -- Get the direct parent node
    local parent_node = child_node:parent()

    -- If the parent is a 'list', we need to check if it's part of another list_item
    -- This helps us determine if this is a nested list or a top-level list
    if parent_node and parent_node:type() == "list" then
      local grandparent = parent_node:parent()

      -- If the grandparent is a list_item, this might be a nested list
      if grandparent and grandparent:type() == "list_item" then
        -- Get the grandparent's ID
        local gp_row, gp_col = grandparent:range()
        local gp_id = grandparent:id()
        -- Check if grandparent is in our todo map
        if todo_map[gp_id] then
          -- This is a nested todo item
          child_item.parent_id = gp_id
          table.insert(todo_map[gp_id].children, child_id)
        end
      end
    end
  end
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

---Returns the todo item metadata for a given line, or empty table
---@param line any
---@return checkmate.TodoMetadata | {}
function M.extract_metadata(line)
  local log = require("checkmate.log")
  ---@type checkmate.TodoMetadata | {}
  local metadata = {}

  -- Match all @key(value) patterns
  for key, value in line:gmatch("@(%w+)%((.-)%)") do
    log.debug(("metadata found: %s=%s"):format(key, value), { module = "parser" })
    metadata[key] = value
  end

  return metadata
end

return M
