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

  -- For metadata tags, we only set up the base highlight groups from static styles
  -- Dynamic styles (functions) will be handled during the actual highlighting process
  for meta_name, meta_props in pairs(config.options.metadata) do
    -- Only add static styles directly to highlights table
    -- Function-based styles will be processed during actual highlighting
    if type(meta_props.style) ~= "function" then
      ---@diagnostic disable-next-line: assign-type-mismatch
      highlights["CheckmateMeta_" .. meta_name] = meta_props.style
    end
  end

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
  -- local non_todo_list_items = M.identify_non_todo_list_items(bufnr)

  -- Process todo items in hierarchical order (top-down)
  for _, todo_item in pairs(todo_map) do
    if not todo_item.parent_id then
      -- Only process top-level todo items (children handled recursively)
      M.highlight_todo_item_and_children(bufnr, todo_item, todo_map, config)
    end
  end

  log.debug("Highlighting applied", { module = "highlights" })

  -- Clear the line cache to free memory
  M.clear_line_cache(bufnr)
end

-- Process a todo item and all its children
function M.highlight_todo_item_and_children(bufnr, todo_item, todo_map, config)
  local log = require("checkmate.log")

  -- 1. Highlight the todo marker
  M.highlight_todo_marker(bufnr, todo_item, config)

  -- 2. Highlight the list marker
  M.highlight_list_marker(bufnr, todo_item, config)

  -- 3. Highlight content directly in this todo item
  M.highlight_content(bufnr, todo_item, config)

  -- 5. Process child todo items
  for _, child_id in ipairs(todo_item.children) do
    local child = todo_map[child_id]
    if child then
      M.highlight_todo_item_and_children(bufnr, child, todo_map, config)
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

---Applies highlight groups to metadata entries
---@param bufnr integer Buffer number
---@param config checkmate.Config.mod Configuration module
---@param metadata checkmate.TodoMetadata The metadata for this todo item
function M.highlight_metadata(bufnr, config, metadata)
  local log = require("checkmate.log")

  -- Skip if no metadata
  if not metadata or not metadata.entries or #metadata.entries == 0 then
    return
  end

  -- Process each metadata entry
  for _, entry in ipairs(metadata.entries) do
    local tag = entry.tag
    local value = entry.value
    local canonical_name = entry.alias_for or tag

    -- Find the metadata configuration
    local meta_config = config.options.metadata[canonical_name]
    if meta_config then
      local highlight_group = "CheckmateMeta_" .. canonical_name

      -- If style is a function, calculate the dynamic highlight
      if type(meta_config.style) == "function" then
        local dynamic_style = meta_config.style(value)

        -- Create a dynamic highlight group for this specific value
        local dynamic_group = highlight_group .. "_" .. value:gsub("[^%w]", "_")
        vim.api.nvim_set_hl(0, dynamic_group, dynamic_style)
        highlight_group = dynamic_group
      end

      -- Apply the highlight
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, entry.range.start.row, entry.range.start.col, {
        end_row = entry.range["end"].row,
        end_col = entry.range["end"].col,
        hl_group = highlight_group,
        priority = M.PRIORITY.TODO_MARKER, -- High priority for metadata
      })

      log.trace(
        string.format(
          "Applied highlight %s to metadata %s at [%d,%d]-[%d,%d]",
          highlight_group,
          tag,
          entry.range.start.row,
          entry.range.start.col,
          entry.range["end"].row,
          entry.range["end"].col
        ),
        { module = "highlights" }
      )
    end
  end
end

-- Highlight content directly attached to the todo item
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param config checkmate.Config.mod
function M.highlight_content(bufnr, todo_item, config)
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

    -- Process each line of the paragraph individually
    for row = para_start_row, para_end_row do
      local line = M.get_buffer_line(bufnr, row)
      local content_start = nil

      if is_first_para and row == para_start_row then
        -- Special handling for first line of first paragraph
        -- because content starts AFTER the list marker and todo marker
        local marker_pos = todo_item.todo_marker.position.col
        local marker_len = #todo_item.todo_marker.text

        -- Find first non-whitespace character after the marker
        content_start = line:find("[^%s]", marker_pos + marker_len + 1)
      else
        -- For all other lines, find first non-whitespace
        content_start = line:find("[^%s]")
      end

      -- Only highlight if we found non-whitespace content
      if content_start then
        -- Adjust to 0-based indexing
        content_start = content_start - 1

        -- Calculate end column for this line
        local end_col = (row == para_end_row) and para_end_col or #line

        -- Apply highlighting for this line
        vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
          end_row = row,
          end_col = end_col,
          hl_group = highlight_group,
          priority = M.PRIORITY.CONTENT,
        })
      end

      M.highlight_metadata(bufnr, config, todo_item.metadata)
    end

    first_para_processed = true
  end

  -- If no paragraphs were found or processed, log a warning
  if not first_para_processed then
    log.debug("No paragraphs found in todo item at line " .. (todo_item.range.start.row + 1), { module = "highlights" })
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
