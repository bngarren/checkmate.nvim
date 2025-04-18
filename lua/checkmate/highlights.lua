---@class checkmate.Highlights
local M = {}

--- Highlight priority levels
---@enum HighlightPriority
M.PRIORITY = {
  CONTENT = 100,
  LIST_MARKER = 101,
  TODO_MARKER = 102,
}

--- Get highlight group for todo content based on state and relation
---@param todo_state checkmate.TodoItemState The todo state
---@param is_main_content boolean Whether this is main content or additional content
---@return string highlight_group The highlight group to use
function M.get_todo_content_highlight(todo_state, is_main_content)
  if todo_state == "checked" then
    return is_main_content and "CheckmateCheckedMainContent" or "CheckmateCheckedAdditionalContent"
  else
    return is_main_content and "CheckmateUncheckedMainContent" or "CheckmateUncheckedAdditionalContent"
  end
end

-- Caching
-- To avoid redundant nvim_buf_get_lines calls during highlighting passes
M._line_cache = {}

function M.get_buffer_line(bufnr, row)
  -- Initialize cache if needed
  M._line_cache[bufnr] = M._line_cache[bufnr] or {}

  -- Return cached line if available
  if M._line_cache[bufnr][row] then
    return M._line_cache[bufnr][row]
  end

  -- Get and cache the line
  local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
  local line = lines[1] or ""
  M._line_cache[bufnr][row] = line

  return line
end

function M.clear_line_cache(bufnr)
  M._line_cache[bufnr] = {}
end

function M.setup_highlights()
  local config = require("checkmate.config")
  local log = require("checkmate.log")

  -- Define highlight groups from config
  local highlights = {
    -- List markers
    CheckmateListMarkerUnordered = config.options.style.list_marker_unordered,
    CheckmateListMarkerOrdered = config.options.style.list_marker_ordered,

    -- Unchecked todos
    CheckmateUncheckedMarker = config.options.style.unchecked_marker,
    CheckmateUncheckedMainContent = config.options.style.unchecked_main_content,
    CheckmateUncheckedAdditionalContent = config.options.style.unchecked_additional_content,

    -- Checked todos
    CheckmateCheckedMarker = config.options.style.checked_marker,
    CheckmateCheckedMainContent = config.options.style.checked_main_content,
    CheckmateCheckedAdditionalContent = config.options.style.checked_additional_content,
  }

  -- Apply highlight groups
  for group_name, group_settings in pairs(highlights) do
    vim.api.nvim_set_hl(0, group_name, group_settings)
    log.debug("Applied highlight group: " .. group_name, { module = "parser" })
  end
end

--- TODO: This redraws all highlights and can be expensive for large files.
--- For future optimization, consider implementing incremental updates.
function M.apply_highlighting(bufnr)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

  -- Clear the line cache
  M.clear_line_cache(bufnr)

  -- Discover all todo items
  ---@type table<string, checkmate.TodoItem>
  local todo_map = parser.discover_todos(bufnr)

  -- First, find and mark non-todo list items to know their scope
  local non_todo_list_items = M.identify_non_todo_list_items(bufnr)

  -- Process todo items in hierarchical order (top-down)
  for _, todo_item in pairs(todo_map) do
    if not todo_item.parent_id then
      -- Only process top-level todo items (children handled recursively)
      M.highlight_todo_item_and_children(bufnr, todo_item, todo_map, non_todo_list_items, config)
    end
  end

  log.debug("Highlighting applied", { module = "highlights" })

  -- Clear the line cache to free memory
  M.clear_line_cache(bufnr)
end

-- Identify non-todo list items for later processing
function M.identify_non_todo_list_items(bufnr)
  local non_todo_items = {}

  -- Create a query to get all list items
  local list_item_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (list_item) @list_item
  ]]
  )

  -- Get parser for this buffer
  local ts_parser = vim.treesitter.get_parser(bufnr, "markdown")
  if not ts_parser then
    return non_todo_items
  end

  local tree = ts_parser:parse()[1]
  if not tree then
    return non_todo_items
  end

  local root = tree:root()

  -- Process all list items to find ones that aren't todos
  for id, node, _ in list_item_query:iter_captures(root, bufnr, 0, -1) do
    local start_row, start_col = node:range()

    -- Check if this is a todo item by examining its first line
    local first_line = M.get_buffer_line(bufnr, start_row)
    local is_todo = require("checkmate.parser").get_todo_item_state(first_line) ~= nil

    if not is_todo then
      -- This is a regular list item, not a todo
      local node_id = string.format("%d:%d", start_row, start_col)
      non_todo_items[node_id] = {
        node = node,
        parent_todo = nil, -- Will be set later when processing hierarchies
      }
    end
  end

  return non_todo_items
end

-- Process a todo item and all its children
function M.highlight_todo_item_and_children(bufnr, todo_item, todo_map, non_todo_list_items, config)
  local log = require("checkmate.log")

  -- 1. Highlight the todo marker
  M.highlight_todo_marker(bufnr, todo_item, config)

  -- 2. Highlight the list marker
  M.highlight_list_marker(bufnr, todo_item, config)

  -- 3. Highlight main content directly in this todo item
  M.highlight_main_content(bufnr, todo_item, config)

  -- 5. Process child todo items
  for _, child_id in ipairs(todo_item.children) do
    local child = todo_map[child_id]
    if child then
      M.highlight_todo_item_and_children(bufnr, child, todo_map, non_todo_list_items, config)
    end
  end
end

-- Highlight the todo marker (✓ or □)
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param config checkmate.Config.mod
function M.highlight_todo_marker(bufnr, todo_item, config)
  local marker_pos = todo_item.todo_marker.position
  local marker_text = todo_item.todo_marker.text

  -- Only highlight if we have a valid position
  if marker_pos.col >= 0 then
    local hl_group = todo_item.state == "checked" and "CheckmateCheckedMarker" or "CheckmateUncheckedMarker"

    vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_pos.row, marker_pos.col, {
      end_row = marker_pos.row,
      end_col = marker_pos.col + #marker_text,
      hl_group = hl_group,
      priority = M.PRIORITY.TODO_MARKER, -- Highest priority for todo markers
    })
  end
end

-- Highlight the list marker (-, +, *, 1., etc.)
function M.highlight_list_marker(bufnr, todo_item, config)
  -- Skip if no list marker found
  if not todo_item.list_marker or not todo_item.list_marker.node then
    return
  end

  local list_marker = todo_item.list_marker
  local start_row, start_col, end_row, end_col = list_marker.node:range()

  local hl_group = list_marker.type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, start_row, start_col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = hl_group,
    priority = M.PRIORITY.LIST_MARKER, -- Medium priority for list markers
  })
end

-- Highlight main content directly attached to the todo item
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param config checkmate.Config.mod
function M.highlight_main_content(bufnr, todo_item, config)
  local log = require("checkmate.log")

  -- Select highlight groups based on todo state
  local main_content_hl = M.get_todo_content_highlight(todo_item.state, true)
  local additional_content_hl = M.get_todo_content_highlight(todo_item.state, false)

  if #todo_item.content_nodes == 0 then
    return
  end

  -- Query to find all paragraphs within this todo item
  local paragraph_query = vim.treesitter.query.parse("markdown", [[(paragraph) @paragraph]])

  -- Track if we've processed the first paragraph
  local first_para_processed = false

  for _, para_node, _ in paragraph_query:iter_captures(todo_item.node, bufnr, 0, -1) do
    local para_start_row, para_start_col, para_end_row, para_end_col = para_node:range()
    local is_first_para = para_start_row == todo_item.range.start.row

    -- Choose highlight group based on whether this is the main paragraph or a child paragraph
    local highlight_group = is_first_para and main_content_hl or additional_content_hl

    log.trace(
      string.format(
        "Processing paragraph at [%d,%d]-[%d,%d], first_para=%s",
        para_start_row,
        para_start_col,
        para_end_row,
        para_end_col,
        tostring(is_first_para)
      ),
      { module = "highlights" }
    )

    if is_first_para then
      -- For the first paragraph (containing the todo marker)
      -- Find the position right after the todo marker
      local marker_pos = todo_item.todo_marker.position
      local marker_len = #todo_item.todo_marker.text
      local content_start = marker_pos.col + marker_len + 1

      -- Make sure content_start is valid
      local line = M.get_buffer_line(bufnr, para_start_row)
      content_start = math.min(content_start, #line)

      -- Apply highlighting from after the marker to the end of paragraph
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, para_start_row, content_start, {
        end_row = para_end_row,
        end_col = para_end_col,
        hl_group = highlight_group,
        priority = M.PRIORITY.CONTENT,
      })

      first_para_processed = true
    else
      -- For other paragraphs, highlight the entire content
      -- We need to process it line by line to handle indentation properly
      for row = para_start_row, para_end_row do
        local line = M.get_buffer_line(bufnr, row)

        -- Find first non-whitespace character on this line
        local content_start = line:find("[^%s]")
        if content_start then
          -- Adjust to 0-based indexing
          content_start = content_start - 1

          -- Calculate end column for this line
          local end_col = (row == para_end_row) and para_end_col or #line

          -- Apply highlighting
          vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
            end_row = row,
            end_col = end_col,
            hl_group = highlight_group,
            priority = M.PRIORITY.CONTENT,
          })
        end
      end
    end
  end

  -- If no paragraphs were found or processed, log a warning
  if not first_para_processed then
    log.debug("No paragraphs found in todo item at line " .. (todo_item.range.start.row + 1), { module = "highlights" })
  end
end

--- Highlight a range of content lines
---@param bufnr integer Buffer number
---@param config checkmate.Config.mod Configuration
---@param start_row integer Starting row (0-indexed)
---@param end_row integer Ending row (0-indexed)
---@param content_hl string Highlight group
---@param last_line_end_col? integer Optional end column for last line
function M.highlight_content_lines(bufnr, config, start_row, end_row, content_hl, last_line_end_col)
  for row = start_row, end_row do
    local line = M.get_buffer_line(bufnr, row)
    if #line > 0 then
      local end_col = (row == end_row and last_line_end_col) or #line
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, 0, {
        end_row = row,
        end_col = end_col,
        hl_group = content_hl,
        priority = M.PRIORITY.CONTENT,
      })
    end
  end
end

--- Highlight paragraph content including inline nodes
---@param bufnr number Buffer number
---@param para_node TSNode Paragraph node
---@param todo_item checkmate.TodoItem Todo item containing this paragraph
---@param content_hl string Highlight group to use
---@param config checkmate.Config.mod Configuration
function M.highlight_paragraph_content(bufnr, para_node, todo_item, content_hl, config)
  local start_row, start_col, end_row, end_col = para_node:range()
  local is_first_paragraph = start_row == todo_item.range.start.row

  -- 1. Handle the paragraph's main content
  if is_first_paragraph then
    -- Special handling for first line (where todo marker is)
    local line = M.get_buffer_line(bufnr, start_row)
    local marker_pos = todo_item.todo_marker.position.col
    local marker_text = todo_item.todo_marker.text

    -- Find where content starts after the todo marker
    local content_start = nil

    -- Try to find first non-whitespace after the marker
    if marker_pos and marker_text then
      content_start = line:find("[^%s]", marker_pos + #marker_text + 1)
    end

    if content_start then
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, start_row, content_start - 1, {
        end_row = start_row,
        end_col = #line,
        hl_group = content_hl,
        priority = M.PRIORITY.CONTENT,
      })
    end

    -- Handle subsequent paragraph lines
    if end_row > start_row then
      M.highlight_content_lines(bufnr, config, start_row + 1, end_row, content_hl, end_col)
    end
  else
    -- Handle regular paragraph (not first line of todo)
    M.highlight_content_lines(bufnr, config, start_row, end_row, content_hl, end_col)
  end

  -- 2. Handle inline nodes within the paragraph
  local inline_query = vim.treesitter.query.parse(
    "markdown",
    [[
    (inline) @inline
    ]]
  )

  for _, inline_node, _ in inline_query:iter_captures(para_node, bufnr, 0, -1) do
    local i_start_row, i_start_col, i_end_row, i_end_col = inline_node:range()

    -- Skip the first line as it's already been handled
    if i_start_row == todo_item.range.start.row and i_end_row == i_start_row then
      goto continue
    end

    if i_start_row == todo_item.range.start.row then
      -- Inline that starts on first line but continues to other lines
      M.highlight_content_lines(
        bufnr,
        config,
        i_start_row + 1,
        i_end_row,
        content_hl,
        i_end_row == i_end_row and i_end_col or nil
      )
    else
      -- For inline nodes that don't start on the first line
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, i_start_row, i_start_col, {
        end_row = i_end_row,
        end_col = i_end_col,
        hl_group = content_hl,
        priority = M.PRIORITY.CONTENT,
      })
    end

    ::continue::
  end
end

-- Check if a node is a child of another node
function M.is_child_of_node(child_node, parent_node)
  -- Check that the parent is in the ancestor chain of the child
  local current = child_node:parent()
  while current do
    if current == parent_node then
      return true
    end
    current = current:parent()
  end
  return false
end

return M
