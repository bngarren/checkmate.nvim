--- @class checkmate.TodoItem
--- Stable key. Uses extmark id positioned just prior to the todo marker.
--- This allows tracking the same todo item across buffer modifications.
--- @field id integer
--- @field bufnr integer Source buffer
--- @field state string The todo state, e.g. "checked", "unchecked", or a custom state like "pending"
--- @field state_type checkmate.TodoStateType
--- @field node TSNode The Treesitter node
--- Todo item's buffer range
--- This range is adjusted from the raw TS node range via *get_semantic_range*:
---   - The start col is adjusted to the indentation level
---   - The end col is adjusted so that it accurately reflects the end of the content
--- @field range checkmate.Range
--- @field ts_range checkmate.Range
--- This is the range of the first inline node of the first paragraph which is (currently) the best representation
--- of the todo item's main content. This allows the first todo line to be hard-wrapped but still
--- allow the broken subsequent lines to work, e.g. have metadata extracted.
--- @field first_inline_range checkmate.Range
--- @field todo_marker TodoMarkerInfo Information about the todo marker (0-indexed position)
--- @field list_marker checkmate.ListMarkerInfo Information about the list marker (0-indexed position)
--- @field metadata checkmate.TodoMetadata | {} Metadata for this todo item
--- @field todo_text string Text content of the todo item line (first line, including the markers)
--- @field children integer[] IDs of child todo items
--- @field parent_id integer? ID of parent todo item
local TodoItem = {}
TodoItem.__index = TodoItem

--- @class checkmate.TodoItemNewOpts
--- @field id integer
--- @field bufnr integer
--- @field node TSNode
--- @field state string
--- @field ts_range checkmate.Range
--- @field first_inline_range? checkmate.Range Fallback to semantic range if nil
--- @field todo_marker {position: {row: integer, col: integer}, text: string}
--- @field list_marker checkmate.ListMarkerInfo
--- @field metadata checkmate.TodoMetadata
--- @field todo_text string
--- @field parent_id? integer
--- @field children? integer[]

--- @param opts checkmate.TodoItemNewOpts
--- @return checkmate.TodoItem
function TodoItem.new(opts)
  assert(type(opts) == "table", "TodoItem.new: opts table is required")

  local config = require("checkmate.config")

  local self = setmetatable({}, TodoItem)

  self.id = assert(opts.id, "TodoItem.new: opts.id is required")
  self.bufnr = assert(opts.bufnr, "TodoItem.new: opts.bufnr is required")
  self.node = assert(opts.node, "TodoItem.new: opts.node is required")

  self.state = assert(opts.state, "TodoItem.new: opts.state is required")
  self.state_type = config.get_todo_state_type(self.state)

  self.ts_range = assert(opts.ts_range, "TodoItem.new: opts.ts_range is required")
  self.range = TodoItem._get_semantic_range(self.ts_range, self.bufnr)
  self.first_inline_range = opts.first_inline_range or self.range

  self.todo_marker = assert(opts.todo_marker, "TodoItem.new: opts.todo_marker is required")
  self.list_marker = assert(opts.list_marker, "TodoItem.new: opts.list_marker is required")

  self.metadata = opts.metadata or { entries = {}, by_tag = {} }
  self.todo_text = assert(opts.todo_text, "TodoItem.new: opts.todo_text is required")

  self.parent_id = opts.parent_id
  self.children = opts.children or {}

  return self
end

---Creates a public facing checkmate.Todo from the internal checkmate.TodoItem representation
---
---exposes a public api while still providing access to the underlying todo_item
---@param todo_map table<integer, checkmate.TodoItem>
---@return checkmate.Todo
function TodoItem:build_todo(todo_map)
  local todo_item = self
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
    ---@type checkmate.TodoItem?
    local parent_item = todo_map[todo_item.parent_id]
    return parent_item and parent_item:build_todo(todo_map) or nil
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

function TodoItem:set_parent(parent_id)
  self.parent_id = parent_id
end

function TodoItem:add_child(child_id)
  table.insert(self.children, child_id)
end

function TodoItem:has_children()
  return #self.children > 0
end

function TodoItem:has_metadata()
  return #self.metadata.entries > 0
end

function TodoItem:get_metadata(name)
  if self.metadata then
    return self.metadata.by_tag[name]
  else
    return nil
  end
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
function TodoItem._get_semantic_range(range, bufnr)
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

return TodoItem
