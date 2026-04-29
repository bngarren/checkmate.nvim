--- move.lua module
---
--- Provides business logic for "cut & paste" type functionality for
--- moving Checkmate Todo items within or between buffers
---
local M = {}

local diff = require("checkmate.lib.diff")

---@class checkmate.MoveTodosDestination
---
--- Target buffer
--- Defaults to source buffer.
---@field bufnr? integer
---
--- Location within the target buffer to insert the todos
--- - `integer` - will insert *before* an explicit 0-based row
--- - `checkmate.Heading` - will insert under this Markdown heading.
---   Will use the first heading that matches from the beginning of the buffer.
---   If the heading does not exist, will it will be created at the end of the target buffer.
---@field location integer|checkmate.Heading
---
--- When inserting into a heading section: true = inserted items at the top (default),
--- false = append to the bottom of the Markdown section
---@field append_top? boolean
---
--- Number of blank lines to insert between consecutive root todo blocks
--- The root todos are the top level, sibling todos that are transferred.
---@field root_spacing? integer
---
--- Ensures a blank line exists under the heading in the destination buffer
--- Default is true.
---@field blank_line_under_heading? boolean

--- ////////////////////////

---@class checkmate.MoveTodosOpts
---
---
---@field by {ids: integer[], rows: integer[]}
---
--- IDs of the *root* TodoItems to move.
--- Child todos are carried along automatically.
--- The caller is responsible for only passing IDs of root todos,
--- (don't pass an ID whose ancestor is also in this list), or lines will be double-collected.
---@field ids integer[]
---
--- Specifies the destination buffer and location to insert, among other characteristics.
---@field destination checkmate.MoveTodosDestination
---
--- Removes residual blank lines surrounding the removed todo content in the source buffer
--- Default is true.
---@field cleanup_source? boolean
---

--- ////////////////////////

--- Moves a set of root todos (and their subtrees) from their current
--- location in the source buffer to a destination.
---
--- Returns two hunk arrays (see `checkmate.TextDiffHunk`):
---   [1] source_hunks  – deletions to apply to source buffer
---   [2] dest_hunks    – insertions to apply to the destination buffer
---
--- For same-buffer moves the caller may concatenate both arrays and pass them to
--- a single apply_diff / transaction. For cross-buffer moves the caller must run
--- two separate transactions (one per buffer).
---
---@param src_bufnr integer Source buffer
---@param todo_map checkmate.TodoMap Source todo map
---@param opts checkmate.MoveTodosOpts
---@return checkmate.TextDiffHunk[] source_hunks Deletions in the source buffer
---@return checkmate.TextDiffHunk[] dest_hunks   Insertions in the destination buffer
function M.move_todos(src_bufnr, todo_map, opts)
  opts = opts or {}

  local dest_bufnr = opts.destination.bufnr or src_bufnr
  local same_buffer = (src_bufnr == dest_bufnr)

  local target_location = opts.destination.location
  local root_spacing = math.max(opts.destination.root_spacing or 0, 0)
  local newest_first = opts.destination.append_top ~= false -- default true
  local ensure_blank_line_under_heading = opts.destination.blank_line_under_heading ~= false -- default true
  local cleanup_source = opts.cleanup_source ~= false -- default true

  local src_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  -- for cross-buffer moves- need a separate snapshot of the destination buffer
  local dest_lines = same_buffer and src_lines or vim.api.nvim_buf_get_lines(dest_bufnr, 0, -1, false)

  -- // Resolve source ranges

  ---@type {start_row: integer, end_row: integer, id: integer}[]
  local source_ranges = {}

  if opts.by.ids then
    for _, id in ipairs(opts.ids) do
      local todo = todo_map[id]
      if not todo then
        require("checkmate.log").fmt_warn("[lib.move][move_todos] id %d not found in todo_map, skipping", id)
      else
        table.insert(source_ranges, { start_row = todo.range.start.row, end_row = todo.range["end"].row, id = id })
      end
    end
  end

  if opts.by.rows then
    for _, todo in ipairs(todo_map) do
      for _, row in ipairs(opts.by.rows) do 
        if todo.range:contains(row) then
         todo. 
        end
      end
    end
  end


  if #source_ranges == 0 then
    return {}, {} -- no source todos, return empty diff hunks
  end

  -- sort by position to process lines in order (top to bottom)
  table.sort(source_ranges, function(a, b)
    return a.start_row < b.start_row
  end)

  -- // Collect the lines that will be moved and mark for deletion

  local function trim_trailing_blank(lines)
    while #lines > 0 and lines[#lines] == "" do
      lines[#lines] = nil
    end
  end

  local function add_spacing(lines)
    for _ = 1, root_spacing do
      lines[#lines + 1] = ""
    end
  end

  ---@type string[]
  local payload = {} -- lines that will be inserted at the destination
  ---@type table<integer, boolean>
  local to_delete = {} -- 0-indexed row numbers of source buffer to eventually remove

  -- basically we iterate through each line in the source rows identified above,
  -- then we 1) add the line to the payload that will be inserted into the destination and
  -- 2) mark the line to be removed from the source buffer.
  -- We add spacing between root blocks (todos) as specified.
  for idx, r in ipairs(source_ranges) do
    for row = r.start_row, r.end_row do
      -- the todo range is 0-based, and src-lines is 1-based
      payload[#payload + 1] = src_lines[row + 1]
    end

    -- spacing between root todos (not after the last one)
    if idx < #source_ranges and root_spacing > 0 then
      add_spacing(payload)
    end

    -- mark for deletion
    for row = r.start_row, r.end_row do
      to_delete[row] = true
    end
  end

  trim_trailing_blank(payload)

  -- // Blank line cleanup in the source
  -- i.e., after we remove todos, we compress the remaining content so that weird gaps aren't left
  -- TODO: this section likely needs more nuance and edge case handling so as not
  -- to remove too much whitespace in the user's document
  if cleanup_source then
    for _, r in ipairs(source_ranges) do
      local after = r.end_row + 1 -- 0-based row immediately after the deleted block
      local before = r.start_row - 1 -- 0-based row immediately before

      -- only act if the line after the block exists and is blank
      if after <= #src_lines - 1 and src_lines[after + 1] == "" then
        -- walk upward to find the nearest surviving (non-deleted) line above
        while before >= 0 and to_delete[before] do
          before = before - 1
        end

        local has_blank_before = (before >= 0) and (src_lines[before + 1] == "")

        -- removing the block would leave two consecutive blanks → delete the trailing one
        if has_blank_before then
          to_delete[after] = true
        end
      end
    end
  end

  -- // Build the source delete hunks

  local source_hunks = {}
  local run_start = nil ---@type integer|nil

  -- performance logic: instead of making delete hunks for every row in `to_delete`, we compress
  -- contiguous rows into hunks
  -- e.g. to_delete = {2,3,4, 7} → [{2,4}, {7,7}] instead of four single-row hunks

  local function flush(last_row)
    if run_start ~= nil then
      table.insert(source_hunks, diff.make_line_delete({ run_start, last_row }))
      run_start = nil
    end
  end

  for row = 0, #src_lines - 1 do
    if to_delete[row] then
      if run_start == nil then
        run_start = row
      end
    else
      if run_start ~= nil then
        flush(row - 1)
      end
    end
  end
  flush(#src_lines - 1)

  -- // Build destination (insert) hunks

  local dest_hunks = {}

  if #payload == 0 then
    -- Source ranges existed but contained only blank lines after trimming...
    -- Hmm. this shouldn't occur with valid todos...we should abort entirely and log this
    require("checkmate.log").error(
      "[lib.move][move_todos] payload is empty after trimming; aborting move to avoid partial mutation"
    )
    return {}, {}
  end

  -- following logic depends on type of target_location: integer (row) or `checkmate.Heading`

  if target_location and type(target_location) == "number" then
    -- explicit row destination ─────────────────────────────────────

    -- when inserting into the same buffer, the target row is expressed in terms
    -- of the current (pre-mutation) buffer
    -- apply_diff's bottom-to-top sort should handle the offset automatically
    dest_hunks[#dest_hunks + 1] = diff.make_line_insert(target_location, payload)
  elseif
    target_location
    and type(target_location) == "table"
    and (target_location.title ~= nil and target_location.level ~= nil)
  then
    -- heading destination ───────────────────────────────────────────

    local target_heading = target_location

    -- Locate the heading section in the destination buffer
    -- starting with the heading, look for a "closing" heading, i.e. one at the same or higher level (fewer or equal #s)

    local heading_pattern = target_heading:get_atx_heading_pattern()

    local section_start = nil ---@type integer|nil  0-based row of the heading line
    local section_end = nil ---@type integer|nil  0-based row of last line in section (inclusive)

    for i, line in ipairs(dest_lines) do
      if line:match(heading_pattern .. target_heading.title) then
        section_start = i - 1 -- to 0-based
        section_end = #dest_lines - 1 -- run to EOF

        for j = i + 1, #dest_lines do
          if dest_lines[j]:match(heading_pattern) then
            section_end = j - 2 -- 0-based row of the line before the next heading
            break
          end
        end
        break
      end
    end

    if not section_start then
      -- Heading doesn't exist → create it at the end of the destination buffer

      local line_count = #dest_lines
      local insertion = {}

      -- ensure a blank line before the new heading if the buffer isn't empty
      local need_pre_blank = line_count > 0 and dest_lines[#dest_lines] ~= ""
      if need_pre_blank then
        insertion[#insertion + 1] = ""
      end

      insertion[#insertion + 1] = target_heading:to_string()
      -- blank line after heading
      insertion[#insertion + 1] = ""

      for _, l in ipairs(payload) do
        insertion[#insertion + 1] = l
      end

      dest_hunks[#dest_hunks + 1] = diff.make_line_insert(line_count, insertion)
    else
      -- Heading exists

      -- ensure exactly one blank line immediately after the heading
      if ensure_blank_line_under_heading then
        local first_nonblank = section_start + 1
        while first_nonblank <= section_end and dest_lines[first_nonblank + 1] == "" do
          first_nonblank = first_nonblank + 1
        end
        if first_nonblank == section_start + 1 then
          dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, { "" })
        else
          -- one or more blanks should collapse to exactly one
          if first_nonblank - 1 > section_start + 1 then
            dest_hunks[#dest_hunks + 1] = diff.make_line_replace({ section_start + 1, first_nonblank - 1 }, { "" })
          end
        end
      end

      -- the content starts at section_start + 2 (heading + 1 blank)
      local content_start = section_start + 2

      if newest_first then
        -- insert payload right after the single blank under the heading
        local insert_at = content_start
        local insert_payload = {}

        for _, l in ipairs(payload) do
          insert_payload[#insert_payload + 1] = l
        end

        -- If the section already has content and spacing is requested,
        -- add a spacer between the newly inserted block and the existing content.
        --
        -- "Has existing content" means the section extends past content_start.
        -- We check section_end (from the pre-mutation snapshot) accounting for the
        -- normalization hunk we just emitted (which may have changed effective rows
        -- by at most 1 — but since apply_diff sorts bottom-to-top, by the time the
        -- insert is applied the normalization has already happened).
        local has_existing = section_end >= content_start
        if has_existing and root_spacing > 0 then
          add_spacing(insert_payload)
        end

        dest_hunks[#dest_hunks + 1] = diff.make_line_insert(insert_at, insert_payload)
      else
        -- Append to the bottom of the existing section.
        -- Find the last non-blank row inside the section to avoid double-blanks.
        local tail = section_end
        while tail > section_start and dest_lines[tail + 1] == "" do
          tail = tail - 1
        end

        local append_at = tail + 1
        local append_payload = {}

        -- Spacer before newly appended content (if existing content present)
        local has_existing = tail > section_start
        if has_existing and root_spacing > 0 then
          add_spacing(append_payload)
        end

        for _, l in ipairs(payload) do
          append_payload[#append_payload + 1] = l
        end

        dest_hunks[#dest_hunks + 1] = diff.make_line_insert(append_at, append_payload)
      end
    end
  else
    error("Checkmate: move_todos: destination must specify either `heading` or `row`")
  end

  return source_hunks, dest_hunks
end

return M
