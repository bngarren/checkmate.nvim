---@class checkmate.Highlights
local M = {}

--- Highlight priority levels
---@enum HighlightPriority
M.PRIORITY = {
  LIST_MARKER = 201,
  CONTENT = 202,
  TODO_MARKER = 203,
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
---@type LineCache|nil
M._current_line_cache = nil

function M.get_buffer_line(bufnr, row)
  -- Use current cache if available
  if M._current_line_cache then
    return M._current_line_cache:get(row)
  end

  -- Fallback: create a temporary cache just for this call
  -- This shouldn't happen in normal flow but provides safety
  local util = require("checkmate.util")
  local cache = util.create_line_cache(bufnr)
  return cache:get(row)
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

function M.apply_highlight_groups()
  local config = require("checkmate.config")
  local log = require("checkmate.log")

  -- Define highlight groups from config
  local highlights = {

    ---@type vim.api.keyset.highlight
    CheckmateNormal = { bold = false, force = true, nocombine = true },

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

function M.setup_highlights()
  local config = require("checkmate.config")

  M.clear_highlight_cache()

  -- Apply highlight groups with current settings
  M.apply_highlight_groups()

  -- Set up an autocmd to re-apply highlighting when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("CheckmateHighlighting", { clear = true }),
    callback = function()
      -- Re-apply highlight groups after a small delay
      vim.defer_fn(function()
        M.clear_highlight_cache()

        -- Get fresh theme-based defaults
        local theme = require("checkmate.theme")
        local colorscheme_aware_style = theme.generate_style_defaults()

        -- Get user's style (if any was explicitly set)
        local user_style = config._state.user_style or {}

        -- Update the style with a fresh merge of user settings and theme defaults
        config.options.style = vim.tbl_deep_extend("keep", user_style, colorscheme_aware_style)

        -- Re-apply highlights with updated styles
        M.apply_highlight_groups()

        -- Re-apply to all active buffers
        for bufnr, _ in pairs(require("checkmate").get_active_buffer_list()) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            M.apply_highlighting(bufnr, { debug_reason = "colorscheme_changed" })
          end
        end
      end, 10)
    end,
  })
end

---@class ApplyHighlightingOpts
---@field todo_map table<integer, checkmate.TodoItem>? Will use this todo_map instead of running discover_todos
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
  local profiler = require("checkmate.profiler")
  local util = require("checkmate.util")

  profiler.start("highlights.apply_highlighting")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  opts = opts or {}

  if opts.debug_reason then
    log.debug(("apply_highlighting called for: %s"):format(opts.debug_reason), { module = "highlights" })
  end

  vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

  -- line cache for this highlighting pass
  M._current_line_cache = util.create_line_cache(bufnr)

  ---@type table<integer, checkmate.TodoItem>
  local todo_map = opts.todo_map or parser.get_todo_map(bufnr)

  for _, todo_item in pairs(todo_map) do
    if not todo_item.parent_id then
      -- only process top-level todo items (children handled recursively)
      M.highlight_todo_item(bufnr, todo_item, todo_map, { recursive = true })
    end
  end

  log.debug("Highlighting applied", { module = "highlights" })

  M._current_line_cache = nil

  profiler.stop("highlights.apply_highlighting")
end

---@class HighlightTodoOpts
---@field recursive boolean? If `true`, also highlight all descendant todos.

---Process a todo item (and, if requested via `opts.recursive`, its descendants).
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem The todo item to highlight.
---@param todo_map table<integer, checkmate.TodoItem> Todo map from `discover_todos`
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
  M.highlight_content(bufnr, todo_item, todo_map)

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

    -- Get the actual line to verify the marker is there
    local line = M.get_buffer_line(bufnr, marker_pos.row)
    if not line then
      return
    end

    -- Verify the marker text is actually at the expected position
    local marker_at_pos = line:sub(marker_pos.col + 1, marker_pos.col + #marker_text)
    if marker_at_pos ~= marker_text then
      -- The marker isn't where we expect it, possibly due to buffer changes
      return
    end

    -- marker_pos.col is already in bytes (0-indexed)
    -- For extmarks, end_col is exclusive, so we add the byte length
    vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_pos.row, marker_pos.col, {
      end_row = marker_pos.row,
      end_col = marker_pos.col + #marker_text, -- # gives byte length for UTF-8
      hl_group = hl_group,
      priority = M.PRIORITY.TODO_MARKER,
      right_gravity = false,
      end_right_gravity = false,
      hl_eol = false, -- Important: don't extend to end of line
    })
  end
end

---Highlight the list marker (-, +, *, 1., etc.)
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
function M.highlight_list_marker(bufnr, todo_item)
  local config = require("checkmate.config")
  local list_marker = todo_item.list_marker

  if not list_marker or not list_marker.node then
    return
  end

  local start_row, start_col, end_row, end_col = list_marker.node:range()

  -- Get the actual text to determine the real marker length
  local line = M.get_buffer_line(bufnr, start_row)
  if not line then
    return
  end

  -- Find the actual marker text (-, *, +, or digits followed by . or ))
  local marker_text = ""
  local marker_end_col = start_col

  -- Extract the marker text from the line
  local line_from_marker = line:sub(start_col + 1) -- +1 for 1-based substring
  local unordered_match = line_from_marker:match("^[%-%*%+]")
  local ordered_match = line_from_marker:match("^%d+[%.%)]")

  if unordered_match then
    marker_text = unordered_match
    marker_end_col = start_col + #marker_text
  elseif ordered_match then
    marker_text = ordered_match
    marker_end_col = start_col + #marker_text
  else
    -- Fallback to Treesitter's range, but limit it
    marker_end_col = math.min(end_col, start_col + 3)
  end

  local hl_group = list_marker.type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, start_row, start_col, {
    end_row = start_row, -- Never span multiple lines
    end_col = marker_end_col,
    hl_group = hl_group,
    priority = M.PRIORITY.LIST_MARKER,
    right_gravity = false,
    end_right_gravity = false,
    hl_eol = false,
  })
end

---Finds and highlights all markdown list_markers within the todo item, excluding the
---list_marker for the todo item itself (i.e. the first list_marker in the todo item's list_item node)
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
function M.highlight_child_list_markers(bufnr, todo_item)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")

  if not todo_item.node then
    return
  end

  local list_marker_query = parser.get_list_marker_query()

  for id, marker_node, _ in list_marker_query:iter_captures(todo_item.node, bufnr, 0, -1) do
    local name = list_marker_query.captures[id]
    local marker_type = parser.get_marker_type_from_capture_name(name)

    -- Only process if it's not the todo item's own list marker
    if not (todo_item.list_marker and todo_item.list_marker.node == marker_node) then
      local marker_start_row, marker_start_col, marker_end_row, marker_end_col = marker_node:range()

      -- Only highlight markers within the todo item's range
      if marker_start_row >= todo_item.range.start.row and marker_end_row <= todo_item.range["end"].row then
        -- Get the actual marker text to constrain the highlight
        local line = M.get_buffer_line(bufnr, marker_start_row)
        if line then
          -- Extract marker text from the line
          local line_from_marker = line:sub(marker_start_col + 1)
          local marker_text = line_from_marker:match("^[%-%*%+]") or line_from_marker:match("^%d+[%.%)]")

          if marker_text then
            local actual_end_col = marker_start_col + #marker_text
            local hl_group = marker_type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

            vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_start_row, marker_start_col, {
              end_row = marker_start_row, -- Never span lines
              end_col = actual_end_col, -- Use actual marker length
              hl_group = hl_group,
              priority = M.PRIORITY.LIST_MARKER,
              right_gravity = false,
              end_right_gravity = false,
              hl_eol = false,
            })
          end
        end
      end
    end
  end
end

---Applies highlight groups to metadata entries
---@param bufnr integer Buffer number
---@param config checkmate.Config.mod Configuration module
---@param metadata checkmate.TodoMetadata The metadata for this todo item
function M.highlight_metadata(bufnr, config, metadata)
  local log = require("checkmate.log")

  if not metadata or not metadata.entries or #metadata.entries == 0 then
    return
  end

  for _, entry in ipairs(metadata.entries) do
    local tag = entry.tag
    local value = entry.value
    local canonical_name = entry.alias_for or tag

    local meta_config = config.options.metadata[canonical_name]
    if meta_config then
      local highlight_group

      if type(meta_config.style) == "function" then
        local cache_key = canonical_name .. "_" .. value
        highlight_group = M.get_or_create_dynamic_highlight("metadata", cache_key, "CheckmateMeta", function()
          return meta_config.style(value)
        end)
      else
        highlight_group = "CheckmateMeta_" .. canonical_name
      end

      -- The entry.range values should already be properly calculated byte positions
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, entry.range.start.row, entry.range.start.col, {
        end_row = entry.range["end"].row,
        end_col = entry.range["end"].col, -- Already exclusive
        hl_group = highlight_group,
        priority = M.PRIORITY.TODO_MARKER,
        right_gravity = false,
        end_right_gravity = false,
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
function M.highlight_content(bufnr, todo_item, todo_map)
  local config = require("checkmate.config")

  local main_content_hl = M.get_todo_content_highlight(todo_item.state, true)
  local additional_content_hl = M.get_todo_content_highlight(todo_item.state, false)

  -- Map of row ranges that belong to child todo items
  local child_todo_rows = {}
  for _, child_id in ipairs(todo_item.children or {}) do
    local child = todo_map[child_id]
    if child then
      for row = child.range.start.row, child.range["end"].row do
        child_todo_rows[row] = true
      end
    end
  end

  -- clear setext style
  for child in todo_item.node:iter_children() do
    if child:type() == "setext_heading" then
      local row = todo_item.todo_marker.position.row
      local line = M.get_buffer_line(bufnr, row)

      vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, 0, {
        end_row = row,
        end_col = #line,
        hl_group = "CheckmateNormal",
        hl_eol = true,
        priority = 10000,
      })
    end
  end

  -- Highlight main content (first line)
  local first_row = todo_item.range.start.row
  local line = M.get_buffer_line(bufnr, first_row)

  if line and #line > 0 then
    local marker_pos = todo_item.todo_marker.position.col -- byte pos (0-based)
    local marker_len = #todo_item.todo_marker.text -- byte length

    -- Find the actual content start after the marker and any whitespace
    -- We need to be careful here to find content AFTER the todo marker
    local search_start = marker_pos + marker_len + 1 -- Start searching after the marker

    -- Find first non-space character after the todo marker
    local content_start = nil
    for i = search_start, #line do
      local char = line:sub(i + 1, i + 1) -- +1 for 1-based substring
      if char ~= " " and char ~= "\t" then
        content_start = i -- 0-based position
        break
      end
    end

    if content_start and content_start < #line then
      -- Only highlight if we found actual content
      vim.api.nvim_buf_set_extmark(bufnr, config.ns, first_row, content_start, {
        end_row = first_row,
        end_col = #line, -- Byte length of line
        hl_group = main_content_hl,
        priority = M.PRIORITY.CONTENT,
        hl_eol = true,
        end_right_gravity = true,
        right_gravity = false,
      })
    end
  end

  -- Process additional content (lines after the first)
  -- Be more careful about what constitutes "additional content"
  for row = first_row + 1, todo_item.range["end"].row do
    if not child_todo_rows[row] then
      local row_line = M.get_buffer_line(bufnr, row)

      -- Skip empty lines and potential setext underlines
      if row_line and not row_line:match("^%s*$") then
        -- Skip lines that look like setext underlines (just hyphens or equals)
        if not row_line:match("^%s*%-+%s*$") and not row_line:match("^%s*=+%s*$") then
          -- Find first non-space (0-based)
          local content_start = nil
          for i = 0, #row_line - 1 do
            local char = row_line:sub(i + 1, i + 1)
            if char ~= " " and char ~= "\t" then
              content_start = i
              break
            end
          end

          if content_start then
            vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
              end_row = row,
              end_col = #row_line, -- Byte length
              hl_group = additional_content_hl,
              priority = M.PRIORITY.CONTENT,
              hl_eol = true,
              end_right_gravity = true,
              right_gravity = false,
            })
          end
        end
      end
    end
  end

  -- Highlight metadata
  M.highlight_metadata(bufnr, config, todo_item.metadata)
end

---Show todo count indicator
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
---@param todo_map table<integer, checkmate.TodoItem>
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
