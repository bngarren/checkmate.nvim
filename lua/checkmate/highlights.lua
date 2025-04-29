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

---Some highlights are created from factory functions via the config module. Instead of re-running these every time
---highlights are re-applied, we cache the results of the highlight generating functions
M._dynamic_highlight_cache = {
  metadata = {},
}

-- Generic function to get or create a dynamic highlight group
---@param category string The category of highlight (e.g., 'metadata', etc.)
---@param key string A unique identifier within the category
---@param base_name string The base name for the highlight group
---@param style_fn function|table A function that returns style options or a style table directly
---@return string highlight_group The name of the highlight group
function M.get_or_create_dynamic_highlight(category, key, base_name, style_fn)
  -- Initialize category if needed
  M._dynamic_highlight_cache[category] = M._dynamic_highlight_cache[category] or {}

  -- Check if already cached
  if M._dynamic_highlight_cache[category][key] then
    return M._dynamic_highlight_cache[category][key]
  end

  -- Create highlight group name
  local highlight_group = base_name .. "_" .. key:gsub("[^%w]", "_")

  -- Apply style - handle both functions and direct style tables
  local style = type(style_fn) == "function" and style_fn(key) or style_fn

  -- Create the highlight group
  ---@diagnostic disable-next-line: param-type-mismatch
  vim.api.nvim_set_hl(0, highlight_group, style)

  -- Cache it
  M._dynamic_highlight_cache[category][key] = highlight_group

  return highlight_group
end

-- Clear cache for a specific category or all categories
---@param category? string Optional category to clear (nil clears all)
function M.clear_highlight_cache(category)
  if category then
    M._dynamic_highlight_cache[category] = {}
  else
    M._dynamic_highlight_cache = {}
  end
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

    -- Todo count
    CheckmateTodoCountIndicator = config.options.style.todo_count_indicator,
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

---@class ApplyHighlightingOpts
---@field debug_reason string? Reason for call (to help debug why highlighting update was called)

--- TODO: This redraws all highlights and can be expensive for large files.
--- For future optimization, consider implementing incremental updates.
---
---@param bufnr integer Buffer number
---@param opts ApplyHighlightingOpts? Options
function M.apply_highlighting(bufnr, opts)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  opts = opts or {}

  if opts.debug_reason then
    log.debug(("apply_highlighting called for: %s"):format(opts.debug_reason), { module = "highlights" })
  end

  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

  -- Clear the line cache
  M.clear_line_cache(bufnr)

  -- Discover all todo items
  ---@type table<string, checkmate.TodoItem>
  local todo_map = parser.discover_todos(bufnr)

  -- Process todo items in hierarchical order (top-down)
  for _, todo_item in pairs(todo_map) do
    if not todo_item.parent_id then
      -- Only process top-level todo items (children handled recursively)
      M.highlight_todo_item(bufnr, todo_item, todo_map, { recursive = true })
    end
  end

  log.debug("Highlighting applied", { module = "highlights" })

  -- Clear the line cache to free memory
  M.clear_line_cache(bufnr)
end

---@class HighlightTodoOpts
---@field recursive boolean? If `true`, also highlight all descendant todos.

---Process a todo item (and, if requested via `opts.recursive`, its descendants).
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem The todo item to highlight.
---@param todo_map table<string, checkmate.TodoItem> Todo map from `discover_todos`
---@param opts HighlightTodoOpts? Optional settings.
---@return nil
function M.highlight_todo_item(bufnr, todo_item, todo_map, opts)
  opts = opts or {}

  -- 1. Highlight the todo marker
  M.highlight_todo_marker(bufnr, todo_item)

  -- 2. Highlight the list marker of the todo item
  M.highlight_list_marker(bufnr, todo_item)

  -- 3. Highlight the child list markers within this todo item
  M.highlight_child_list_markers(bufnr, todo_item)

  -- 4. Highlight content directly in this todo item
  M.highlight_content(bufnr, todo_item)

  -- 5. Show child count indicator
  M.show_todo_count_indicator(bufnr, todo_item, todo_map)

  -- 5. If recursive option is enabled, also highlight all children
  if opts.recursive then
    for _, child_id in ipairs(todo_item.children or {}) do
      local child = todo_map[child_id]
      if child then
        -- pass the same opts so grandchildren respect `recursive`
        M.highlight_todo_item(bufnr, child, todo_map, opts)
      end
    end
  end
end

-- Highlight the todo marker (✓ or □)
---@param bufnr integer
---@param todo_item checkmate.TodoItem
function M.highlight_todo_marker(bufnr, todo_item)
  local config = require("checkmate.config")
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

---Highlight the list marker (-, +, *, 1., etc.)
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
function M.highlight_list_marker(bufnr, todo_item)
  local config = require("checkmate.config")
  local list_marker = todo_item.list_marker

  -- Skip if no list marker found
  if not list_marker or not todo_item.list_marker.node then
    return
  end

  local start_row, start_col, end_row, end_col = list_marker.node:range()

  local hl_group = list_marker.type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, start_row, start_col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = hl_group,
    priority = M.PRIORITY.LIST_MARKER, -- Medium priority for list markers
  })
end

---Finds and highlights all markdown list_markers within the todo item, excluding the
---list_marker for the todo item itself (i.e. the first list_marker in the todo item's list_item node)
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
function M.highlight_child_list_markers(bufnr, todo_item)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")

  -- Skip if no node
  if not todo_item.node then
    return
  end

  -- Get all list markers using the parser's query helper
  local list_marker_query = parser.get_list_marker_query()

  for id, marker_node, _ in list_marker_query:iter_captures(todo_item.node, bufnr, 0, -1) do
    local name = list_marker_query.captures[id]
    local marker_type = parser.get_marker_type_from_capture_name(name)

    -- Skip the todo item's own list marker
    -- Its highlighting is handled separately by `highlight_list_marker`
    if todo_item.list_marker and todo_item.list_marker.node == marker_node then
      goto continue
    end

    -- Get the marker range
    local marker_start_row, marker_start_col, marker_end_row, marker_end_col = marker_node:range()

    -- Only highlight markers within the todo item's range
    if marker_start_row >= todo_item.range.start.row and marker_end_row <= todo_item.range["end"].row then
      local hl_group = marker_type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

      vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_start_row, marker_start_col, {
        end_row = marker_end_row,
        end_col = marker_end_col,
        hl_group = hl_group,
        priority = M.PRIORITY.LIST_MARKER,
      })

      log.trace(
        string.format(
          "Highlighted child list marker at [%d,%d]-[%d,%d] with %s",
          marker_start_row,
          marker_start_col,
          marker_end_row,
          marker_end_col,
          hl_group
        ),
        { module = "highlights" }
      )
    end

    ::continue::
  end
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
      local highlight_group

      -- Get or create the highlight group
      if type(meta_config.style) == "function" then
        -- For dynamic styles
        local cache_key = canonical_name .. "_" .. value
        highlight_group = M.get_or_create_dynamic_highlight("metadata", cache_key, "CheckmateMeta", function()
          return meta_config.style(value)
        end)
      else
        -- For static styles
        highlight_group = "CheckmateMeta_" .. canonical_name
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
function M.highlight_content(bufnr, todo_item)
  local config = require("checkmate.config")
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

---Show todo count indicator
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
---@param todo_map table<string, checkmate.TodoItem>
function M.show_todo_count_indicator(bufnr, todo_item, todo_map)
  local config = require("checkmate.config")

  if not config.options.show_todo_count then
    return
  end

  -- Skip if no children
  if not todo_item.children or #todo_item.children == 0 then
    return
  end

  local use_recursive = config.options.todo_count_recursive ~= false
  local counts = require("checkmate.api").count_child_todos(todo_item, todo_map, { recursive = use_recursive })

  if counts.total == 0 then
    return
  end

  -- Create the count indicator text
  local indicator_text
  -- use custom formatter if exists
  if config.options.todo_count_formatter and type(config.options.todo_count_formatter) == "function" then
    indicator_text = config.options.todo_count_formatter(counts.completed, counts.total)
  else
    -- default
    indicator_text = string.format("%d/%d", counts.completed, counts.total)
  end

  -- Add virtual text using extmark
  if config.options.todo_count_position == "inline" then
    local extmark_start_col = todo_item.todo_marker.position.col + #todo_item.todo_marker.text + 1
    vim.api.nvim_buf_set_extmark(bufnr, config.ns, todo_item.range.start.row, extmark_start_col, {
      virt_text = { { indicator_text, "CheckmateTodoCountIndicator" }, { " ", "Normal" } },
      virt_text_pos = "inline",
      priority = M.PRIORITY.TODO_MARKER + 1,
    })
  elseif config.options.todo_count_position == "eol" then
    vim.api.nvim_buf_set_extmark(bufnr, config.ns, todo_item.range.start.row, 0, {
      virt_text = { { indicator_text, "CheckmateTodoCountIndicator" } },
      virt_text_pos = "eol",
      priority = M.PRIORITY.CONTENT,
    })
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
