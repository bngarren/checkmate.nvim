---@class checkmate.Highlights
local M = {}

--- Highlight priority levels
---@enum HighlightPriority
M.PRIORITY = {
  NORMAL_OVERRIDE = 100,
  LIST_MARKER = 201,
  CONTENT = 202,
  TODO_MARKER = 203,
}

--- Get highlight group for todo content based on state and relation
---@param todo_state string
---@param is_main_content boolean Whether this is main content or additional content
---@return string highlight_group The highlight group to use
function M.get_todo_content_highlight(todo_state, is_main_content)
  local state_name = require("checkmate.util").snake_to_camel(todo_state)

  if is_main_content then
    return "Checkmate" .. state_name .. "MainContent"
  else
    return "Checkmate" .. state_name .. "AdditionalContent"
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

-- Maps hash -> { highlight_group, style }
M._style_cache = {}

-- Simple hash function for style tables
local function hash_style(style)
  local keys = vim.tbl_keys(style)
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    local value = style[key]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      table.insert(parts, key .. ":" .. tostring(value))
    end
  end

  -- Create a hash from the concatenated string
  local str = table.concat(parts, ",")
  local hash = 0
  for i = 1, #str do
    hash = (hash * 31 + string.byte(str, i)) % 2147483647
  end

  return tostring(hash)
end

function M.clear_highlight_cache()
  M._style_cache = {}
end

function M.register_highlight_groups()
  local config = require("checkmate.config")
  local log = require("checkmate.log")

  local highlights = {
    ---this is used when we apply an extmark to override , e.g. setext headings
    ---@type vim.api.keyset.highlight
    CheckmateNormal = { bold = false, force = true, nocombine = true, fg = "fg" },
  }

  -- generate highlight groups for each todo state
  for state_name, _ in pairs(config.options.todo_states) do
    local state_name_camel = require("checkmate.util").snake_to_camel(state_name)

    local marker_group = "Checkmate" .. state_name_camel .. "Marker"
    local main_content_group = "Checkmate" .. state_name_camel .. "MainContent"
    local additional_content_group = "Checkmate" .. state_name_camel .. "AdditionalContent"

    if config.options.style[marker_group] then
      highlights[marker_group] = config.options.style[marker_group]
    end
    if config.options.style[main_content_group] then
      highlights[main_content_group] = config.options.style[main_content_group]
    end
    if config.options.style[additional_content_group] then
      highlights[additional_content_group] = config.options.style[additional_content_group]
    end
  end

  for group_name, settings in pairs(config.options.style or {}) do
    if not highlights[group_name] then
      highlights[group_name] = settings
    end
  end

  -- For metadata tags, we only set up the base highlight groups from static styles
  -- Dynamic styles (functions) will be handled during the actual highlighting process
  for meta_name, meta_props in pairs(config.options.metadata) do
    if type(meta_props.style) ~= "function" then
      ---@diagnostic disable-next-line: assign-type-mismatch
      highlights["CheckmateMeta" .. "_" .. meta_name] = meta_props.style
    end
  end

  for group_name, group_settings in pairs(highlights) do
    vim.api.nvim_set_hl(0, group_name, group_settings)
    log.debug("Applied highlight group: " .. group_name, { module = "parser" })
  end

  require("checkmate.debug.debug_highlights").setup()
end

function M.setup_highlights()
  local config = require("checkmate.config")

  M.clear_highlight_cache()

  M.register_highlight_groups()

  -- autocmd to re-apply highlighting when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("checkmate_highlights", { clear = true }),
    callback = function()
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
        M.register_highlight_groups()

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

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

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
---@field _context? {visited: table, depth: number, max_depth: number}

---Process a todo item (and, if requested via `opts.recursive`, its descendants).
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem The todo item to highlight.
---@param todo_map table<integer, checkmate.TodoItem> Todo map from `discover_todos`
---@param opts HighlightTodoOpts? Optional settings.
---@return nil
function M.highlight_todo_item(bufnr, todo_item, todo_map, opts)
  opts = opts or {}

  if not todo_item or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- init context on first call
  if not opts._context then
    opts._context = {
      visited = {},
      depth = 0,
      max_depth = 50,
    }
  end

  local ctx = opts._context
  ---@cast ctx {visited: table, depth: number, max_depth: number}

  if ctx.visited[todo_item.id] then
    return
  end

  -- depth limit check
  if ctx.depth >= ctx.max_depth then
    local log = require("checkmate.log")
    log.warn(string.format("Max depth %d reached at todo %s", ctx.max_depth, todo_item.id))
    return
  end

  ctx.visited[todo_item.id] = true
  ctx.depth = ctx.depth + 1

  local success, err = pcall(function()
    -- row lookup for todo items for O(1) access
    local todo_rows = {}
    for _, todo in pairs(todo_map) do
      todo_rows[todo.range.start.row] = true
    end

    M.highlight_todo_marker(bufnr, todo_item)

    M.highlight_list_markers(bufnr, todo_item, todo_rows)

    M.highlight_content(bufnr, todo_item, todo_map)

    M.show_todo_count_indicator(bufnr, todo_item, todo_map)
  end)

  if not success then
    local log = require("checkmate.log")
    log.error(string.format("Highlight error for todo %s: %s", todo_item.id, err))
    return
  end

  -- process children
  if opts.recursive and todo_item.children and #todo_item.children > 0 then
    local batch_size = 50
    for i = 1, #todo_item.children, batch_size do
      -- allow event loop to run between batches
      if i > 1 then
        vim.schedule(function()
          M.process_children_batch(
            bufnr,
            todo_item,
            todo_map,
            opts,
            i,
            math.min(i + batch_size - 1, #todo_item.children)
          )
        end)
      else
        M.process_children_batch(bufnr, todo_item, todo_map, opts, i, math.min(i + batch_size - 1, #todo_item.children))
      end
    end
  end

  -- Restore depth
  ctx.depth = ctx.depth - 1
end

function M.process_children_batch(bufnr, parent_item, todo_map, opts, start_idx, end_idx)
  for i = start_idx, end_idx do
    local child_id = parent_item.children[i]
    local child = todo_map[child_id]
    if child then
      M.highlight_todo_item(bufnr, child, todo_map, opts)
    end
  end
end

-- Highlight the todo marker (e.g. ✓ or □)
---@param bufnr integer
---@param todo_item checkmate.TodoItem
function M.highlight_todo_marker(bufnr, todo_item)
  local config = require("checkmate.config")
  local marker_pos = todo_item.todo_marker.position
  local marker_text = todo_item.todo_marker.text

  if marker_pos.col >= 0 then
    local state_name_camel = require("checkmate.util").snake_to_camel(todo_item.state)
    local hl_group = "Checkmate" .. state_name_camel .. "Marker"

    local line = M.get_buffer_line(bufnr, marker_pos.row)
    if not line then
      return
    end

    -- marker_pos.col is already in bytes (0-indexed)
    -- for extmarks, end_col is exclusive, so we add the byte length
    vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_pos.row, marker_pos.col, {
      end_row = marker_pos.row,
      end_col = marker_pos.col + #marker_text, -- end col is the last col of marker + 1 (end exclusive)
      hl_group = hl_group,
      priority = M.PRIORITY.TODO_MARKER,
      right_gravity = false,
      end_right_gravity = false,
      hl_eol = false,
    })
  end
end

---Highlight list markers for todo items and their child list items
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
---@param todo_rows table<integer, checkmate.TodoItem> row to todo lookup table
function M.highlight_list_markers(bufnr, todo_item, todo_rows)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")

  -- highlight the todo item's own marker
  if todo_item.list_marker and todo_item.list_marker.node then
    local start_row, start_col = todo_item.list_marker.node:range()
    local marker_text = todo_item.list_marker.text

    if marker_text then
      local hl_group = todo_item.list_marker.type == "ordered" and "CheckmateListMarkerOrdered"
        or "CheckmateListMarkerUnordered"

      vim.api.nvim_buf_set_extmark(bufnr, config.ns, start_row, start_col, {
        end_row = start_row,
        end_col = start_col + #marker_text,
        hl_group = hl_group,
        priority = M.PRIORITY.LIST_MARKER,
        right_gravity = false,
        end_right_gravity = false,
        hl_eol = false,
      })
    end
  end

  local query = parser.FULL_TODO_QUERY

  for id, node in query:iter_captures(todo_item.node, bufnr) do
    local capture_name = query.captures[id]

    if capture_name == "list_marker" or capture_name == "list_marker_ordered" then
      local marker_start_row, marker_start_col, _, marker_end_col = node:range()

      -- skip if:
      -- - the todo item's own marker (same row)
      -- - not another todo item
      if marker_start_row > todo_item.range.start.row and not todo_rows[marker_start_row] then
        local marker_type = parser.get_marker_type_from_capture_name(capture_name)
        local hl_group = marker_type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

        vim.api.nvim_buf_set_extmark(bufnr, config.ns, marker_start_row, marker_start_col, {
          end_row = marker_start_row,
          end_col = marker_end_col - 1, -- ts includes trailing space after list marker, we exclude it here
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

---Applies highlight groups to metadata entries
---@param bufnr integer Buffer number
---@param config checkmate.Config.mod Configuration module
---@param todo_item checkmate.TodoItem Todo item for this metadata
function M.highlight_metadata(bufnr, config, todo_item)
  local log = require("checkmate.log")
  local meta_module = require("checkmate.metadata")

  local metadata = todo_item.metadata

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
        local context = meta_module.create_context(todo_item, canonical_name, value, bufnr)
        local style = meta_module.evaluate_style(meta_config, context)

        if not vim.tbl_isempty(style) then
          local style_hash = hash_style(style)

          if M._style_cache[style_hash] then
            highlight_group = M._style_cache[style_hash].highlight_group
          else
            highlight_group = "CheckmateMeta_" .. canonical_name .. "_" .. style_hash
            vim.api.nvim_set_hl(0, highlight_group, style)

            M._style_cache[style_hash] = {
              highlight_group = highlight_group,
              style = style,
            }
          end
        end
      else
        -- static styles
        highlight_group = "CheckmateMeta_" .. canonical_name
      end

      vim.api.nvim_buf_set_extmark(bufnr, config.ns, entry.range.start.row, entry.range.start.col, {
        end_row = entry.range["end"].row,
        end_col = entry.range["end"].col, -- end exclusive
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

  -- row ranges that belong to child todo items
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
  -- addresses visual highlighting glitch in which the following:
  -- ```md
  -- - ☑︎ Todo
  --   -
  -- ````
  -- causes the todo line to be bolded. This is because the "-" only line
  -- is parsed as a setext_heading applied heading style to the line above it
  for child in todo_item.node:iter_children() do
    if child:type() == "setext_heading" then
      local sr, _, er, _ = child:range()

      vim.api.nvim_buf_set_extmark(bufnr, config.ns, sr, 0, {
        end_row = er,
        end_col = 0,
        hl_group = "CheckmateNormal",
        hl_eol = true,
        priority = M.PRIORITY.NORMAL_OVERRIDE,
      })
    end
  end

  -- highlight main content (first inline range)

  local function get_content_start(line, start)
    local content_start = nil
    for i = start, #line do
      local char = line:sub(i + 1, i + 1) -- +1 for 1-based substring
      if char ~= " " and char ~= "\t" then
        content_start = i -- 0-based position
        break
      end
    end
    return content_start
  end

  local main_range = todo_item.first_inline_range
  for row = main_range.start.row, main_range["end"].row do
    local line = M.get_buffer_line(bufnr, row)

    if line and #line > 0 then
      if row == todo_item.range.start.row then
        local marker_pos = todo_item.todo_marker.position.col -- byte pos (0-based)
        local marker_len = #todo_item.todo_marker.text -- byte length
        -- find the actual content start after the todo marker and any whitespace
        local search_start = marker_pos + marker_len
        local content_start = get_content_start(line, search_start)

        if content_start and content_start < #line then
          vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
            end_row = row,
            end_col = #line, -- byte length
            hl_group = main_content_hl,
            priority = M.PRIORITY.CONTENT,
            hl_eol = false,
            end_right_gravity = true,
            right_gravity = false,
          })
        end
      else
        local content_start = get_content_start(line, 0)
        if content_start and content_start < #line then
          vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
            end_row = row,
            end_col = #line, -- byte length
            hl_group = main_content_hl,
            priority = M.PRIORITY.CONTENT,
            hl_eol = false,
            end_right_gravity = true,
            right_gravity = false,
          })
        end
      end
    end
  end

  -- Process additional content (lines after the first inline range)
  for row = todo_item.first_inline_range["end"].row + 1, todo_item.range["end"].row do
    if not child_todo_rows[row] then
      local row_line = M.get_buffer_line(bufnr, row)

      -- skip empty lines
      if row_line and not row_line:match("^%s*$") then
        local content_start = nil

        local list_marker_pattern = "^(%s*)[%-%*%+]%s+" -- unordered
        local ordered_pattern = "^(%s*)%d+[%.%)]%s+" -- ordered

        local _, marker_end = row_line:find(list_marker_pattern)
        if not marker_end then
          _, marker_end = row_line:find(ordered_pattern)
        end

        if marker_end then
          content_start = marker_end -- already 0-based since find returns 1-based
        else
          -- no list marker, find first non-whitespace
          for i = 0, #row_line - 1 do
            local char = row_line:sub(i + 1, i + 1)
            if char ~= " " and char ~= "\t" then
              content_start = i
              break
            end
          end
        end

        if content_start and content_start < #row_line then
          vim.api.nvim_buf_set_extmark(bufnr, config.ns, row, content_start, {
            end_row = row,
            end_col = #row_line,
            hl_group = additional_content_hl,
            priority = M.PRIORITY.CONTENT,
            hl_eol = false,
            end_right_gravity = true,
            right_gravity = false,
          })
        end
      end
    end
  end

  M.highlight_metadata(bufnr, config, todo_item)
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

  if not todo_item.children or #todo_item.children == 0 then
    return
  end

  local use_recursive = config.options.todo_count_recursive ~= false
  local counts = require("checkmate.api").count_child_todos(todo_item, todo_map, { recursive = use_recursive })

  if counts.total == 0 then
    return
  end

  local indicator_text
  -- use custom formatter if exists
  if config.options.todo_count_formatter and type(config.options.todo_count_formatter) == "function" then
    indicator_text = config.options.todo_count_formatter(counts.completed, counts.total)
  else
    -- default
    indicator_text = string.format("%d/%d", counts.completed, counts.total)
  end

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
