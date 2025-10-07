-- [[
-- # Adaptive and progressive highlighting
-- "adaptive" - we pick a highlighting strategy based on the size of the region that needs updating (i.e. for region-scoped highlighting passes during TextChangedI) as well as the size of the buffer and number of root todos present.
-- "progressive" - a partially asynchronous strategy in which the viewport is prioritized first (synchronously) and the rest of the buffer is updated in batches
--
--  - All extmarks set here must pass end_col as exclusive (Neovim API)
--  - Callers using `util.get_semantic_range()` MUST convert end.row (inclusive) to end-exclusive:
--     `local row_end_excl = range["end"].row + 1`
-- ]]
local util = require("checkmate.util")
local config = require("checkmate.config")
local api = require("checkmate.api")
local log = require("checkmate.log")
local parser = require("checkmate.parser")
local profiler = require("checkmate.profiler")

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

-- minimum buffer lines before a progressive highlighting strategy is used
-- If less than this, will perform an "immediate" (synchronous) highlighting pass only
M.MIN_LINE_COUNT_PROGRESSIVE = 500
-- minimum number of root level todos before a progressive highlighting strategy is used
M.MIN_ROOT_TODOS_PROGRESSIVE = 30
-- number of millesconds allowed for each progressive step
M.MS_PER_PROGRESSIVE_STEP = 8000

-- helper that returns the primary highlights namespace
local function hl_ns()
  return config.ns_hl
end

---@return vim.api.keyset.get_extmark_item[]
---e.g. each {} has:
--- [1] integer extmark_id
--- [2] integer row
--- [3] integer col
--- [4] vim.api.keyset.extmark_details?
function M.get_hl_marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, hl_ns(), 0, -1, { details = true })
end

function M.clear_hl_ns(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns(), 0, -1)
end

--- clear namespace over an end-exclusive row span [start_row, end_row_excl)
function M.clear_hl_ns_range(bufnr, start_row, end_row)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns(), start_row, end_row)
end

--- clear highlight namespace over the todo's range
---@param bufnr any
---@param todo checkmate.TodoItem
function M.clear_todo_hls(bufnr, todo)
  -- convert the todo's end inclusive row to end exclusive by +1
  M.clear_hl_ns_range(bufnr, todo.range.start.row, todo.range["end"].row + 1)
end

-- -------- Progressive highlighting ---------

-- per-buffer progressive highlighting state
-- bufnr -> { running:boolean, gen:integer, idx:integer, roots:checkmate.TodoItem[], max_slice_time:integer, max_batch:integer }
M._progressive = {}

--- cancel any in-flight progressive pass for a buffer
function M.cancel_progressive(bufnr)
  local st = M._progressive[bufnr]
  if st then
    st.running = false
    -- bump gen to invalidate any in-flight steps
    st.gen = (st.gen or 0) + 1
    M._progressive[bufnr] = nil
  end
end

--- apply immediate full-buffer highlighting (synchronous)
---@private
function M._apply_immediate(bufnr, todo_map)
  M._line_cache_by_buf[bufnr] = util.create_line_cache(bufnr)

  M.clear_hl_ns(bufnr)

  for _, todo_item in pairs(todo_map) do
    if not todo_item.parent_id then
      M.highlight_todo_item(bufnr, todo_item, todo_map, { recursive = true })
    end
  end

  M._line_cache_by_buf[bufnr] = nil
end

--- apply regional highlighting
--- `region` should have end exclusive row
---@private
function M._apply_region(bufnr, todo_map, region)
  if not region or not region.affected_roots then
    return
  end

  M._line_cache_by_buf[bufnr] = util.create_line_cache(bufnr)

  -- clear only the affected range
  -- note: region has end-exclusive rows
  M.clear_hl_ns_range(bufnr, region.start_row, region.end_row)

  for _, root in ipairs(region.affected_roots) do
    M.highlight_todo_item(bufnr, root, todo_map, { recursive = true })
  end

  M._line_cache_by_buf[bufnr] = nil
end

--- apply progressive highlighting, prioritizing the viewport
---@private
function M._apply_progressive(bufnr, todo_map, opts)
  opts = opts or {}

  M.clear_buf_line_cache(bufnr)
  M.cancel_progressive(bufnr)

  local all_roots = {}
  for _, item in pairs(todo_map) do
    if not item.parent_id then
      -- skip_region is end-exclusive
      -- we convert todo.range (semantic range) to end exclusive (+1)
      local should_skip = opts.skip_region
        and util.ranges_overlap(
          item.range.start.row,
          item.range["end"].row + 1,
          opts.skip_region.start_row,
          opts.skip_region.end_row
        )

      if not should_skip then
        table.insert(all_roots, item)
      end
    end
  end

  if #all_roots == 0 then
    return
  end

  table.sort(all_roots, function(a, b)
    return a.range.start.row < b.range.start.row
  end)

  local viewport_start, viewport_end = util.get_viewport_bounds(0, 5)
  local immediate_roots = {}
  local deferred_roots = {}

  if viewport_start then
    for _, root in ipairs(all_roots) do
      -- convert todo.range (semantic range) to end-exclusive (+1)
      if util.ranges_overlap(root.range.start.row, root.range["end"].row + 1, viewport_start, viewport_end) then
        table.insert(immediate_roots, root)
      else
        table.insert(deferred_roots, root)
      end
    end
  else
    -- no viewport info, process all progressively
    deferred_roots = all_roots
  end

  M._line_cache_by_buf[bufnr] = util.create_line_cache(bufnr)

  -- process viewport's root todos immediately (synchronous)
  if #immediate_roots > 0 then
    for _, root_todo in ipairs(immediate_roots) do
      M.clear_todo_hls(bufnr, root_todo)
      M.highlight_todo_item(bufnr, root_todo, todo_map, { recursive = true })
    end
  end

  -- force a repaint for the immediate roots before we proceed with deferred roots
  vim.cmd("redraw")

  -- remaining root todos progressively
  if #deferred_roots > 0 then
    M._start_progressive_loop(bufnr, deferred_roots, todo_map)
  else
    M._line_cache_by_buf[bufnr] = nil
  end
end

---@private
local function _progressive_step(bufnr, todo_map, cur_gen)
  local st = M._progressive[bufnr]
  if not st or st.gen ~= cur_gen or not vim.api.nvim_buf_is_valid(bufnr) then
    M.clear_buf_line_cache(bufnr)
    M.cancel_progressive(bufnr)
    return
  end

  local start = vim.uv.hrtime()
  local processed = 0
  local roots = st.roots

  -- process until either we hit the batch cap OR the time budget
  while st.idx <= #roots do
    local root = roots[st.idx]
    st.idx = st.idx + 1

    if root then
      M.clear_todo_hls(bufnr, root)
      M.highlight_todo_item(bufnr, root, todo_map, { recursive = true })
      processed = processed + 1
    end

    if processed >= st.max_batch then
      break
    end

    if (vim.uv.hrtime() - start) >= st.budget_us then
      break
    end
  end

  if st.idx > #roots then
    -- done
    M.clear_buf_line_cache(bufnr)
    M.cancel_progressive(bufnr)
    return
  end

  -- yield to UI, then schedule the next slice
  vim.schedule(function()
    _progressive_step(bufnr, todo_map, cur_gen)
  end)
end

--- start the progressive highlighting loop
---@private
function M._start_progressive_loop(bufnr, roots, todo_map)
  local budget_us = M.MS_PER_PROGRESSIVE_STEP -- ms per UI slice
  local max_batch = math.max(50, math.floor(math.min(20 + #roots / 100, 400)))

  local gen = vim.uv.hrtime() or 0
  M._progressive[bufnr] = {
    running = true,
    gen = gen,
    idx = 1,
    roots = roots,
    budget_us = budget_us,
    max_batch = max_batch,
  }

  vim.schedule(function()
    _progressive_step(bufnr, todo_map, gen)
  end)
end

--- Get highlight group for todo content based on state and relation
---@param todo_state string
---@param is_main_content boolean Whether this is main content or additional content
---@return string highlight_group
function M.get_todo_content_highlight(todo_state, is_main_content)
  local state_name = util.snake_to_camel(todo_state)
  if is_main_content then
    return "Checkmate" .. state_name .. "MainContent"
  else
    return "Checkmate" .. state_name .. "AdditionalContent"
  end
end

-- Caching
-- To avoid redundant nvim_buf_get_lines calls during highlighting passes
---@type table<integer, LineCache>
M._line_cache_by_buf = {}

function M.get_buffer_line(bufnr, row)
  local cache = M._line_cache_by_buf[bufnr]
  if cache then
    return cache:get(row)
  end
  -- fallback: create a throwaway cache for isolated calls
  return util.create_line_cache(bufnr):get(row)
end

function M.clear_buf_line_cache(bufnr)
  M._line_cache_by_buf[bufnr] = nil
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
  local function normal_fg_or_nil()
    local normal_exists = vim.fn.hlexists("Normal")
    if not normal_exists then
      log.fmt_warn("[highlights/register_highlight_groups] Missing 'Normal' hl. ")
      return nil
    end
    local hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    return hl and hl.fg or nil
  end

  local highlights = {
    ---this is used when we apply an extmark to override , e.g. setext headings
    ---@type vim.api.keyset.highlight
    CheckmateNormal = { bold = false, force = true, nocombine = true, fg = normal_fg_or_nil() },
  }

  -- generate highlight groups for each todo state
  for state_name, _ in pairs(config.options.todo_states) do
    local state_name_camel = util.snake_to_camel(state_name)

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
  end

  log.fmt_debug("[highlights] %d highlights registered (excluding dynamic styles)", vim.tbl_count(highlights))

  require("checkmate.debug.debug_highlights").setup()
end

function M.setup_highlights()
  M.clear_highlight_cache()

  M.register_highlight_groups()

  -- autocmd to re-apply highlighting when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("checkmate_highlights", { clear = true }),
    callback = function()
      vim.defer_fn(function()
        log.info("[autocmd] ColorScheme")

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
---@field todo_map? checkmate.TodoMap Pre-computed todo map
---@field region? {start_row: integer, end_row: integer, affected_roots?: checkmate.TodoItem[]} Regional update bounds
---@field strategy? "immediate"|"adaptive" Highlighting strategy (default: "adaptive")
---@field debug_reason? string Debug context

--- Apply highlighting with intelligent strategy selection
--- @param bufnr? integer
--- @param opts? ApplyHighlightingOpts
function M.apply_highlighting(bufnr, opts)
  profiler.start("highlights.apply_highlighting")

  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    profiler.stop("highlights.apply_highlighting")
    return
  end

  opts = opts or {}
  local todo_map = opts.todo_map or parser.get_todo_map(bufnr)
  local strategy = opts.strategy or "adaptive"

  -- regional updates first (always immediate +/- a full progressive update)
  if opts.region then
    M._apply_region(bufnr, todo_map, opts.region)

    -- for larger regions, also queue a full update for consistency
    local region_size = opts.region.end_row - opts.region.start_row
    if region_size > config.get_region_limit(bufnr) and strategy == "adaptive" then
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          M._apply_progressive(bufnr, todo_map, {
            skip_region = opts.region,
          })
        end
      end, 100)
    end
    profiler.stop("highlights.apply_highlighting")
    return
  end

  -- full buffer update
  if strategy == "immediate" then
    M._apply_immediate(bufnr, todo_map)
  else -- adaptive
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local root_count = 0
    for _, item in pairs(todo_map) do
      if not item.parent_id then
        root_count = root_count + 1
      end
    end

    -- use progressive for large buffers, immediate for small
    if line_count > M.MIN_LINE_COUNT_PROGRESSIVE or root_count > M.MIN_ROOT_TODOS_PROGRESSIVE then
      M._apply_progressive(bufnr, todo_map)
    else
      M._apply_immediate(bufnr, todo_map)
    end
  end

  profiler.stop("highlights.apply_highlighting")
end

---@class HighlightTodoOpts
---@field recursive boolean? If `true`, also highlight all descendant todos.
---@field _context? {visited: table, depth: number, max_depth: number}

---Process a todo item (and, if requested via `opts.recursive`, its descendants).
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem The todo item to highlight.
---@param todo_map checkmate.TodoMap Todo map from `discover_todos`
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
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), marker_pos.row, marker_pos.col, {
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
---@param todo_rows checkmate.TodoMap row to todo lookup table
function M.highlight_list_markers(bufnr, todo_item, todo_rows)
  -- highlight the todo item's own marker
  if todo_item.list_marker and todo_item.list_marker.node then
    local start_row, start_col = todo_item.list_marker.node:range()
    local marker_text = todo_item.list_marker.text

    if marker_text then
      local hl_group = todo_item.list_marker.type == "ordered" and "CheckmateListMarkerOrdered"
        or "CheckmateListMarkerUnordered"

      vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), start_row, start_col, {
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
      -- - another todo item
      if marker_start_row > todo_item.range.start.row and not todo_rows[marker_start_row] then
        local marker_type = parser.get_marker_type_from_capture_name(capture_name)
        local hl_group = marker_type == "ordered" and "CheckmateListMarkerOrdered" or "CheckmateListMarkerUnordered"

        vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), marker_start_row, marker_start_col, {
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
---@param todo_item checkmate.TodoItem Todo item for this metadata
function M.highlight_metadata(bufnr, todo_item)
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

      vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), entry.range.start.row, entry.range.start.col, {
        end_row = entry.range["end"].row,
        end_col = entry.range["end"].col, -- end exclusive
        hl_group = highlight_group,
        priority = M.PRIORITY.TODO_MARKER,
        right_gravity = false,
        end_right_gravity = false,
      })
    end
  end
end

-- Highlight content directly attached to the todo item
---@param bufnr integer
---@param todo_item checkmate.TodoItem
function M.highlight_content(bufnr, todo_item, todo_map)
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

      vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), sr, 0, {
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
          vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), row, content_start, {
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
          vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), row, content_start, {
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
          vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), row, content_start, {
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

  M.highlight_metadata(bufnr, todo_item)
end

---Show todo count indicator
---@param bufnr integer Buffer number
---@param todo_item checkmate.TodoItem
---@param todo_map checkmate.TodoMap
function M.show_todo_count_indicator(bufnr, todo_item, todo_map)
  if not config.options.show_todo_count then
    return
  end

  if not todo_item.children or #todo_item.children == 0 then
    return
  end

  local use_recursive = config.options.todo_count_recursive ~= false
  local counts = api.count_child_todos(todo_item, todo_map, { recursive = use_recursive })

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
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), todo_item.range.start.row, extmark_start_col, {
      end_col = extmark_start_col + #indicator_text,
      virt_text = { { indicator_text, "CheckmateTodoCountIndicator" }, { " ", "Normal" } },
      virt_text_pos = "inline",
      priority = M.PRIORITY.TODO_MARKER + 1,
    })
  elseif config.options.todo_count_position == "eol" then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns(), todo_item.range.start.row, 0, {
      end_col = #indicator_text,
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
