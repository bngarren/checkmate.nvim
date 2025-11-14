local M = {}

M.mode = require("checkmate.util.mode")
M.debounce = require("checkmate.util.debounce")
M.string = require("checkmate.util.string")
M.line_cache = require("checkmate.util.line_cache")

function M.tbl_isempty_or_nil(t)
  if t == nil then
    return true
  end
  return vim.tbl_isempty(t)
end

---Calls vim.notify with the given message and log_level depending on if config.options.notify enabled
---@param msg any
---@param log_level any
function M.notify(msg, log_level, once)
  local config = require("checkmate.config")
  local prefix = "Checkmate: "
  if config.options.notify then
    if once ~= false then
      vim.notify_once(prefix .. msg, log_level)
    else
      vim.notify(prefix .. msg, log_level)
    end
  else
    --[[ local hl_group = "Normal"
    if log_level == vim.log.levels.WARN then
      hl_group = "WarningMsg"
    elseif log_level == vim.log.levels.ERROR then
      hl_group = "ErrorMsg"
    end
    vim.api.nvim_echo({ msg, hl_group }, true, {}) ]]
  end
end

--- Returns true if two ranges overlap
--- a1..a2 is the first range, b1..b2 is the second
--- These are end-exclusive ranges!
--- Overlap means they share at least one point; false if they are disjoint
function M.ranges_overlap(a1, a2, b1, b2)
  return not (a2 <= b1 or b2 <= a1)
end

--- Get the visible viewport bounds for a window
--- Returns 0-based, end exclusive row indices
---@param win? integer  -- window handle (defaults to current window)
---@param pad? integer  -- optional number of extra lines above/below
---@return integer? start_row, integer? end_row
function M.get_viewport_bounds(win, pad)
  pad = tonumber(pad) or 0

  local target = (win and win ~= 0) and win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(target) then
    local cur = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(cur) then
      return nil, nil
    end
    target = cur
  end

  local ok, bounds = pcall(vim.api.nvim_win_call, target, function()
    return {
      top = vim.fn.line("w0"), -- 1-based buffer line at top of window
      bot = vim.fn.line("w$"), -- 1-based buffer line at bottom of window
      bufnr = vim.api.nvim_win_get_buf(0),
    }
  end)
  if not ok or type(bounds) ~= "table" then
    return nil, nil
  end

  local linecount = vim.api.nvim_buf_line_count(bounds.bufnr)
  local top, bot = bounds.top, bounds.bot
  if type(top) ~= "number" or type(bot) ~= "number" then
    return nil, nil
  end

  -- convert to 0-based, clamp with padding
  local start0 = math.max(0, top - 1 - pad)
  local end0 = math.min(linecount - 1, bot - 1 + pad) + 1 -- end exclusive
  return start0, end0
end

---Blends the foreground color with the background color
---
---Credit to github.com/folke/snacks.nvim
---@param fg string|nil Foreground color (default #ffffff)
---@param bg string|nil Background color (default #000000)
---@param alpha number Number between 0 and 1. 0 results in bg, 1 results in fg.
---@return string: Color in hex format
function M.blend(fg, bg, alpha)
  -- Default colors if nil
  fg = fg or "#ffffff"
  bg = bg or "#000000"

  -- Validate inputs are hex colors
  if not (fg:match("^#%x%x%x%x%x%x$") and bg:match("^#%x%x%x%x%x%x$")) then
    -- Return a safe default if the colors aren't valid
    return "#888888"
  end

  local bg_rgb = { tonumber(bg:sub(2, 3), 16), tonumber(bg:sub(4, 5), 16), tonumber(bg:sub(6, 7), 16) }
  local fg_rgb = { tonumber(fg:sub(2, 3), 16), tonumber(fg:sub(4, 5), 16), tonumber(fg:sub(6, 7), 16) }
  local blend = function(i)
    local ret = (alpha * fg_rgb[i] + ((1 - alpha) * bg_rgb[i]))
    return math.floor(math.min(math.max(0, ret), 255) + 0.5)
  end
  return string.format("#%02x%02x%02x", blend(1), blend(2), blend(3))
end

---Gets a color from an existing highlight group (see :highlight-groups)
---
---Credit to github.com/folke/snacks.nvim
---@param hl_group string|string[] Highlight group(s) to get prop's color
---@param prop? string Property to get color from (default "fg")
---@param default? string Fallback color if not found (in hex format)
---@return string?: Color in hex format or nil
function M.get_hl_color(hl_group, prop, default)
  prop = prop or "fg"
  hl_group = type(hl_group) == "table" and hl_group or { hl_group }

  for _, g in ipairs(hl_group) do
    -- First try to get attributes with link = false
    ---@cast g string
    local hl = vim.api.nvim_get_hl(0, { name = g, link = false })

    if hl[prop] then
      return string.format("#%06x", hl[prop])
    end

    -- If no direct attribute, try following the link
    if hl.link then
      local linked_hl = vim.api.nvim_get_hl(0, { name = hl.link, link = false })
      if linked_hl[prop] then
        return string.format("#%06x", linked_hl[prop])
      end
    end
  end

  return default
end

---Returns a todo_map table sorted by start row
---@generic T: checkmate.TodoMap
---@param todo_map T
---@return {id: integer, item: checkmate.TodoItem}
function M.get_sorted_todo_list(todo_map)
  -- Convert map to array of {id, item} pairs
  local todo_list = {}
  for id, item in pairs(todo_map) do
    table.insert(todo_list, { id = id, item = item })
  end

  -- Sort by item.range.start.row
  table.sort(todo_list, function(a, b)
    return a.item.range.start.row < b.item.range.start.row
  end)

  return todo_list
end

--- Converts TreeSitter's technical range to a semantically meaningful range for todo items
---
--- TreeSitter ranges have two quirks to address:
--- 1. End-of-line positions are represented as [next_line, 0] instead of [current_line, line_length]
--- 2. Multi-line nodes may not include the full line content in their ranges
---
--- This function transforms these ranges to better represent the semantic boundaries of todo items:
--- - When end_col=0, it means "end of previous line" rather than "start of current line"
--- - For multi-line ranges, ensures the end position captures the entire line content
---
--- - Returns end-inclusive for the row, end-exclusive for the column:
---   start = {row, col}, end = {row_inclusive, col_exclusive}
---   - Callers must treat end.row as inclusive and end.col as exclusive.
---   - If passing to helpers expecting end-exclusive rows, convert with:
---     `local row_end_excl = semantic.end.row + 1`
---
--- @param range {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} Raw TreeSitter range (0-indexed, end-exclusive)
--- @param bufnr integer Buffer number
--- @return {start: {row: integer, col: integer}, ['end']: {row: integer, col: integer}} range
function M.get_semantic_range(range, bufnr)
  -- Create a new range object to avoid modifying the original
  local new_range = {
    start = { row = range.start.row, col = range.start.col },
    ["end"] = { row = range["end"].row, col = range["end"].col },
  }

  -- Standard TS range adjustment when end_col is 0
  if new_range["end"].col == 0 then
    new_range["end"].row = new_range["end"].row - 1
  end

  -- Get the first line to determine indentation level of this todo item
  local first_line = vim.api.nvim_buf_get_lines(bufnr, new_range.start.row, new_range.start.row + 1, false)[1] or ""
  local indent_match = first_line:match("^(%s+)")
  local current_indent_level = indent_match and #indent_match or 0

  -- Scan through lines to find where this todo item actually ends
  -- We're looking for the last line that:
  -- 1. Has content (not just whitespace)
  -- 2. Is indented at the same level or greater than our todo item
  -- 3. But stops when we hit another list item at the same indentation level
  -- (which would be a sibling, not a child)
  local end_row = new_range.start.row
  for row = new_range.start.row + 1, new_range["end"].row do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    -- Skip empty lines (but don't update end_row)
    if not line:match("^%s*$") then
      -- Get this line's indentation
      local line_indent_match = line:match("^(%s+)")
      local line_indent = line_indent_match and #line_indent_match or 0

      -- Check if this line is a new list item (contains a list marker)
      local is_list_item = line:match("^%s*[-+*]%s") or line:match("^%s*%d+[.)]%s")

      -- If this is a list item at same or lower indent level, it's a sibling or parent
      -- and should not be part of our current todo's range
      if is_list_item and line_indent <= current_indent_level then
        break
      end

      -- Otherwise, this line is part of our todo item's content
      end_row = row
    end
  end

  -- Update the range
  new_range["end"].row = end_row

  -- Get the end column by finding the length of the last line (minus trailing whitespace)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local trimmed_line = last_line:gsub("%s+$", "")
  new_range["end"].col = #trimmed_line

  -- Preserve the actual indentation level in col, not set to 0
  new_range.start.col = current_indent_level

  return new_range
end

---Returns a string of the node's range data
---@param node TSNode
function M.get_ts_node_range_string(node)
  if not node then
    return ""
  end
  local start_row, start_col, end_row, end_col = node:range()
  return ("[%d,%d] → [%d,%d]"):format(start_row, start_col, end_row, end_col)
end

---Build a Markdown heading
---@param title string text after the hashes
---@param level? integer 1-6; clamped; defaults to 2
---@return string
function M.get_heading_string(title, level)
  level = tonumber(level) or 2
  level = math.min(math.max(level, 1), 6)
  return string.rep("#", level) .. " " .. title
end

--- Captures the range in a single vim.api.nvim_buf_get_lines call and returns
--- the per-row content
---
--- IMPORTANT: assumes `rows` are sorted in ascending order unless `opts.sort` is true
--- Returns a map of row number (0-indexed) → line content
---
---@param bufnr integer
---@param rows integer[] 0-based row numbers
--- If `sort` is true, the rows will be sorted first, leave nil if they are already pre-sorted (expectation)
---@param opts? { sort?: boolean }
---@return table<integer, string> lines_by_row
function M.get_buf_lines_for_rows(bufnr, rows, opts)
  if not rows or #rows == 0 then
    return {}
  end

  opts = opts or {}

  local count = #rows

  if count == 1 then
    local row = rows[1]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    return { [row] = line }
  end

  local sorted_rows

  if opts.sort then
    sorted_rows = {}
    for i = 1, count do
      sorted_rows[i] = rows[i]
    end
    table.sort(sorted_rows)
  else
    -- assume rows are in ascending order
    sorted_rows = rows
  end

  local min_row = sorted_rows[1]
  local max_row = sorted_rows[count]

  local block = vim.api.nvim_buf_get_lines(bufnr, min_row, max_row + 1, false)

  ---@type table<integer, string>
  local result = {}

  -- map each requested row -> line from nvim_buf_get_lines
  for i = 1, count do
    local row = sorted_rows[i]
    local idx = row - min_row + 1
    result[row] = block[idx] or ""
  end

  return result
end

---Opens in the content in a scratch buffer or uses vim.print
---Currently only supports Snacks.scratch
---@param content any Will use `vim.inspect()` internally to stringify
---@param scratch_opts table
function M.scratch_buf_or_print(content, scratch_opts)
  local has_snacks, snacks = pcall(require, "snacks.scratch")
  if has_snacks then
    local opts = vim.tbl_deep_extend("force", {
      name = scratch_opts.name or "checkmate.nvim",
      autowrite = false,
      ft = "lua",
      template = vim.inspect(content),
      win = {
        width = 140,
        height = 40,
        keys = {
          ["source"] = false,
        },
      },
    }, scratch_opts)
    local win = snacks.open(opts)
    if win and win.buf then
      vim.bo[win.buf].ro = true
    end
  else
    vim.print(content)
  end
end

---Creates a public facing checkmate.Todo from the internal checkmate.TodoItem representation
---
---exposes a public api while still providing access to the underlying todo_item
---@param todo_item checkmate.TodoItem
---@return checkmate.Todo
function M.build_todo(todo_item)
  local parser = require("checkmate.parser")

  local metadata_array = {}
  for _, entry in ipairs(todo_item.metadata.entries) do
    table.insert(metadata_array, { entry.tag, entry.value })
  end

  local function is_checked()
    return todo_item.state == "checked"
  end

  local function is_unchecked()
    return todo_item.state == "unchecked"
  end

  local function is_complete()
    return todo_item.state_type == "complete"
  end

  local function is_incomplete()
    return todo_item.state_type == "incomplete"
  end

  local function is_inactive()
    return todo_item.state_type == "inactive"
  end

  local function get_metadata(name)
    local result = vim
      .iter(metadata_array)
      :filter(function(m)
        return m[1] == name
      end)()
    if not result then
      return nil, nil
    end
    return result[1], result[2]
  end

  local function get_parent()
    if not todo_item.parent_id then
      return nil
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local parent_item = parser.get_todo_map(bufnr)[todo_item.parent_id]
    return parent_item and M.build_todo(parent_item) or nil
  end

  ---@type checkmate.Todo
  return {
    bufnr = todo_item.bufnr,
    row = todo_item.range.start.row,
    state = todo_item.state,
    text = todo_item.todo_text,
    indent = todo_item.range.start.col,
    list_marker = todo_item.list_marker.text,
    todo_marker = todo_item.todo_marker.text,
    metadata = metadata_array,
    is_checked = is_checked,
    is_unchecked = is_unchecked,
    is_complete = is_complete,
    is_incomplete = is_incomplete,
    is_inactive = is_inactive,
    get_metadata = get_metadata,
    get_parent = get_parent,
    _get_todo_item = function()
      return todo_item
    end,
  }
end

--- Run `fn` with the given window as current and always restore its view
--- - saves & restores everything tracked by winsaveview() (cursor, topline, etc.)
--- - safe if `fn` errors (rethrows after restore)
--- - default `win` is the current window (0)
---@param fn fun()
---@param win? integer
function M.with_preserved_view(fn, win)
  win = win or 0
  if type(fn) ~= "function" then
    return
  end

  -- a specific window was requested but it no longer exists, just run fn
  if win ~= 0 and not vim.api.nvim_win_is_valid(win) then
    return fn()
  end

  local ok, err
  local w = (win == 0) and vim.api.nvim_get_current_win() or win

  if not vim.api.nvim_win_is_valid(w) then
    return fn()
  end

  ok, err = xpcall(function()
    vim.api.nvim_win_call(w, function()
      local bufnr = vim.api.nvim_win_get_buf(w)
      local view = vim.fn.winsaveview()

      local uok, uerr = xpcall(fn, debug.traceback)

      -- try to restore even if user code failed
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_call(w, function()
          if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(w) ~= bufnr then
            pcall(vim.api.nvim_win_set_buf, w, bufnr)
          end
          pcall(vim.fn.winrestview, view)
        end)
      end

      if not uok then
        error(uerr)
      end
    end)
  end, debug.traceback)

  if not ok then
    error(err)
  end
end

return M
