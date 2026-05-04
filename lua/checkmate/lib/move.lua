--- move.lua module
---
--- Provides business logic for "cut & paste" type functionality for
--- moving Checkmate Todo items within or between buffers
---
local M = {}
local H = {}

local diff = require("checkmate.lib.diff")
local log = require("checkmate.log")

---@class checkmate.InternalMoveTodosDestination : checkmate.MoveTodosDestination
---@field bufnr integer
---@field location? integer
---@field heading? checkmate.Heading
---@field root_spacing integer

---@class checkmate.InternalMoveTodosOpts : checkmate.MoveTodosOpts
---@field by { ids?: integer[], range?: checkmate.Range }
---@field destination checkmate.InternalMoveTodosDestination
---@field cleanup_source boolean

--- ////////////////////////

--- Moves selected todo subtrees from the source buffer to a destination.
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
---@param opts checkmate.InternalMoveTodosOpts
---@return checkmate.TextDiffHunk[] source_hunks Deletions in the source buffer
---@return checkmate.TextDiffHunk[] dest_hunks   Insertions in the destination buffer
function M.move_todos(src_bufnr, todo_map, opts)
  local ok, err = H.validate_move_opts(src_bufnr, opts)
  if not ok then
    log.warn("[lib.move.move_todos] " .. err)
    return {}, {}
  end

  local dest_bufnr = opts.destination.bufnr or src_bufnr
  local same_buffer = (src_bufnr == dest_bufnr)

  local target_row = opts.destination.location
  local target_heading = opts.destination.heading
  local root_spacing = math.max(opts.destination.root_spacing or 0, 0)
  local newest_first = opts.destination.append_top ~= false -- default true
  local ensure_blank_line_under_heading = opts.destination.blank_line_under_heading ~= false -- default true
  local cleanup_source = opts.cleanup_source ~= false -- default true

  local src_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  -- for cross-buffer moves- need a separate snapshot of the destination buffer
  local dest_lines = same_buffer and src_lines or vim.api.nvim_buf_get_lines(dest_bufnr, 0, -1, false)

  -- // Resolve source ranges
  --
  -- the payload we eventually move should contain each source line ONLY once at most...
  -- no selected todo should be moved separately if one of its ancestors is already being moved
  --
  -- Notes:
  -- - Selecting only a child moves that child subtree
  -- - Selecting a parent and any of its descendants moves only the parent subtree
  -- - Selecting multiple siblings moves each sibling subtree once
  -- - Duplicate ids are ignored

  local source_ranges = H.resolve_source_ranges(todo_map, opts.by)

  if #source_ranges == 0 then
    return {}, {} -- no source todos, return empty diff hunks
  end

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

  ---@param heading checkmate.Heading
  ---@param lines string[]
  ---@return string[]
  local function make_heading_payload(heading, lines)
    local insertion = { heading:to_string() }

    if ensure_blank_line_under_heading then
      insertion[#insertion + 1] = ""
    end

    for _, line in ipairs(lines) do
      insertion[#insertion + 1] = line
    end

    return insertion
  end

  local dest_hunks = {}

  if #payload == 0 then
    -- Source ranges existed but contained only blank lines after trimming...
    -- Hmm. this shouldn't occur with valid todos...we should abort entirely and log this
    log.error("[lib.move.move_todos] payload is empty after trimming; aborting move to avoid partial mutation")
    return {}, {}
  end

  -- Destination modes:
  --
  -- 1. location only:
  --      Insert payload directly at an explicit line boundary.
  --
  -- 2. heading only:
  --      Find an existing heading section and insert into it. If the heading does
  --      not exist, create the heading section at EOF.
  --
  -- 3. location + heading:
  --      Create a new heading section at the explicit line boundary. This mode
  --      does not search for or reuse an existing heading.

  if target_row ~= nil then
    -- explicit row destination ─────────────────────────────────────

    if not H.validate_line_boundary(target_row, dest_lines) then
      log.warn(
        string.format(
          "[lib.move.move_todos] destination row %s out of bounds; expected 0..%d",
          tostring(target_row),
          #dest_lines
        )
      )
      return {}, {}
    end

    -- don't allow same-buffer move into a source range
    if same_buffer then
      for _, r in ipairs(source_ranges) do
        if target_row >= r.start_row and target_row <= r.end_row + 1 then
          log.warn("[lib.move.move_todos] destination is inside moved range; aborting")
          return {}, {}
        end
      end
    end

    if target_heading then
      -- Explicit row + heading:
      -- create a new heading section exactly at this line boundary.
      dest_hunks[#dest_hunks + 1] = diff.make_line_insert(target_row, make_heading_payload(target_heading, payload))
    else
      -- Explicit row only:
      -- insert the moved payload directly.
      dest_hunks[#dest_hunks + 1] = diff.make_line_insert(target_row, payload)
    end
  elseif target_heading then
    -- heading destination ───────────────────────────────────────────
    --
    -- implementation notes:
    --
    -- Heading-only mode:
    --
    --   destination = { heading = Heading.new("Done", 1) }
    --
    -- means:
    --   1. Find the first matching heading section.
    --   2. Insert the moved todos into that section.
    --   3. If the heading does not exist, create a new heading section at EOF.
    --
    -- This is different from:
    --
    --   destination = { location = row, heading = heading }
    --
    -- which always creates a NEW heading section at that exact row

    local section_start, section_end = H.find_heading_section(dest_lines, target_heading)

    if not section_start then
      -- No matching heading exists
      --
      -- Create a new section at EOF:
      --
      --   [insert blank, if there isn't one already...]
      --   # Heading
      --
      --   moved todo
      --     moved child
      --
      -- the optional leading blank prevents gluing the new heading directly to
      -- the previous final line of the buffer

      local line_count = #dest_lines
      local insertion = {}

      local need_pre_blank = line_count > 0 and dest_lines[#dest_lines] ~= ""
      if need_pre_blank then
        insertion[#insertion + 1] = ""
      end

      vim.list_extend(insertion, make_heading_payload(target_heading, payload))

      dest_hunks[#dest_hunks + 1] = diff.make_line_insert(line_count, insertion)
    else
      -- Matching heading exists.
      --
      -- We now need to insert inside this section
      --
      -- Rows are 0-based:
      --   section_start = row containing "# Done"
      --   section_end   = last row belonging to that heading section
      --
      -- Example:
      --
      --   row 2: # Done          <- section_start
      --   row 3:
      --   row 4: - existing      <- first non-blank content
      --   row 5: # Later         <- not part of section
      --
      -- For this section, section_end is row 4

      -- First, we find the first non-blank line after the heading
      -- which tells us 3 important things:
      --   1. whether the heading already has a blank line under it
      --   2. whether the section has existing body content
      --   3. where "near top" insertion should occur
      --
      -- If the section is empty or contains only blanks, first_nonblank becomes
      -- section_end + 1.
      local first_nonblank = section_start + 1

      while first_nonblank <= section_end and dest_lines[first_nonblank + 1] == "" do
        first_nonblank = first_nonblank + 1
      end

      local blank_start = section_start + 1
      local blank_end = first_nonblank - 1
      local blank_count = math.max(blank_end - blank_start + 1, 0)
      local has_existing_content = first_nonblank <= section_end

      if newest_first then
        -- Insert near the top of the heading section.

        local insert_payload = {}

        if ensure_blank_line_under_heading then
          if blank_count == 0 then
            -- No blank under the heading:
            -- insert both the required blank and the payload before the first
            -- existing content line.
            insert_payload[#insert_payload + 1] = ""

            for _, line in ipairs(payload) do
              insert_payload[#insert_payload + 1] = line
            end

            if has_existing_content and root_spacing > 0 then
              add_spacing(insert_payload)
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, insert_payload)
          elseif blank_count == 1 then
            -- Exactly one blank already exists:
            -- insert payload after that blank.
            for _, line in ipairs(payload) do
              insert_payload[#insert_payload + 1] = line
            end

            if has_existing_content and root_spacing > 0 then
              add_spacing(insert_payload)
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 2, insert_payload)
          else
            -- More than one blank exists:
            -- replace the blank lines with exactly 1 blank followed by
            -- the payload
            insert_payload[#insert_payload + 1] = ""

            for _, line in ipairs(payload) do
              insert_payload[#insert_payload + 1] = line
            end

            if has_existing_content and root_spacing > 0 then
              add_spacing(insert_payload)
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_replace({ blank_start, blank_end }, insert_payload)
          end
        else
          -- opted out of blank-line normalization
          -- so...we insert right after the heading, even if it butts up against the heading
          for _, line in ipairs(payload) do
            insert_payload[#insert_payload + 1] = line
          end

          if has_existing_content and root_spacing > 0 then
            add_spacing(insert_payload)
          end

          dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, insert_payload)
        end
      else
        -- Append to the bottom of the existing section
        --
        -- even if there are a bunch of blank lines at the end of the section, we "trim" these...
        -- by appending after the last non-blank line.

        local tail = section_end

        while tail > section_start and dest_lines[tail + 1] == "" do
          tail = tail - 1
        end

        local has_body = tail > section_start
        local append_payload = {}

        if ensure_blank_line_under_heading and not has_body then
          -- Empty section: heading followed by 0 or more blanks
          -- In this case, appending to the "bottom" is effectively the same as
          -- inserting near the top: normalize the heading blank and place the
          -- payload immediately after it
          if blank_count == 0 then
            -- empty section with no blank under heading
            append_payload[#append_payload + 1] = ""

            for _, line in ipairs(payload) do
              append_payload[#append_payload + 1] = line
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, append_payload)
          elseif blank_count == 1 then
            -- empty section with exactly one blank already present
            -- easy! just insert payload after that blank
            for _, line in ipairs(payload) do
              append_payload[#append_payload + 1] = line
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 2, append_payload)
          else
            -- empty section with multiple blanks
            -- just collapse all the blanks to 1 blank then insert payload
            append_payload[#append_payload + 1] = ""

            for _, line in ipairs(payload) do
              append_payload[#append_payload + 1] = line
            end

            dest_hunks[#dest_hunks + 1] = diff.make_line_replace({ blank_start, blank_end }, append_payload)
          end
        else
          -- Non-empty section, or blank-line normalization is disabled

          if ensure_blank_line_under_heading then
            if blank_count == 0 then
              dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, { "" })
            elseif blank_count > 1 then
              dest_hunks[#dest_hunks + 1] = diff.make_line_replace({ blank_start, blank_end }, { "" })
            end
          end

          if has_body and root_spacing > 0 then
            add_spacing(append_payload)
          end

          for _, line in ipairs(payload) do
            append_payload[#append_payload + 1] = line
          end

          dest_hunks[#dest_hunks + 1] = diff.make_line_insert(tail + 1, append_payload)
        end
      end
    end
  else
    error("Checkmate: move_todos: destination must specify `destination.location` and/or `destination.heading`")
  end

  return source_hunks, dest_hunks
end

function H.has_source_selector(opts)
  return opts and opts.by and ((opts.by.ids and #opts.by.ids > 0) or opts.by.range ~= nil)
end

function H.is_heading(value)
  return type(value) == "table" and value.title ~= nil and value.level ~= nil
end

function H.validate_move_opts(src_bufnr, opts)
  if type(src_bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(src_bufnr) then
    return false, "invalid source buffer"
  end

  if not opts or type(opts) ~= "table" then
    return false, "missing opts"
  end

  if not H.has_source_selector(opts) then
    return false, "missing source selector: expected opts.by.ids or opts.by.range"
  end

  if not opts.destination then
    return false, "missing destination"
  end

  local dest_bufnr = opts.destination.bufnr or src_bufnr
  if not vim.api.nvim_buf_is_valid(dest_bufnr) then
    return false, "invalid destination buffer"
  end

  local location = opts.destination.location
  local heading = opts.destination.heading

  if location ~= nil and type(location) ~= "number" then
    return false, "destination.location must be a line-boundary integer"
  end

  if heading ~= nil and not H.is_heading(heading) then
    return false, "destination.heading must be a checkmate.Heading"
  end

  if location == nil and heading == nil then
    return false, "missing destination target: expected destination.location and/or destination.heading"
  end

  return true
end

function H.validate_line_boundary(row, lines)
  return type(row) == "number" and row >= 0 and row <= #lines
end

---@param todo_map checkmate.TodoMap
---@param by { ids?: integer[], range?: checkmate.Range }
---@return {start_row: integer, end_row: integer, id: integer}[]
function H.resolve_source_ranges(todo_map, by)
  local candidates = {}

  local function add_candidate(todo)
    if todo and todo.id and candidates[todo.id] == nil then
      candidates[todo.id] = todo
    end
  end

  if by.ids then
    for _, id in ipairs(by.ids) do
      local todo = todo_map[id]
      if todo then
        add_candidate(todo)
      else
        log.fmt_warn("[lib.move.move_todos] id %d not found in todo_map, skipping", id)
      end
    end
  end

  -- range must contain the todo's first line
  if by.range then
    for _, todo in ipairs(todo_map) do
      if by.range:contains({ row = todo.range.start.row, col = todo.range.start.col }) then
        add_candidate(todo)
      end
    end
  end

  local function has_selected_ancestor(todo)
    local parent = todo:get_parent(todo_map)

    while parent do
      if candidates[parent.id] then
        return true
      end
      parent = parent:get_parent(todo_map)
    end

    return false
  end

  local ranges = {}
  local seen = {}

  for _, todo in pairs(candidates) do
    if not seen[todo.id] and not has_selected_ancestor(todo) then
      ranges[#ranges + 1] = {
        start_row = todo.range.start.row,
        end_row = todo.range["end"].row,
        id = todo.id,
      }
      seen[todo.id] = true
    end
  end

  table.sort(ranges, function(a, b)
    return a.start_row < b.start_row
  end)

  return ranges
end

---@param line string
---@return integer|nil
function H.get_atx_heading_level(line)
  local hashes = line:match("^%s*(#+)%s+")
  if not hashes or #hashes > 6 then
    return nil
  end

  return #hashes
end

---@param line string
---@param heading checkmate.Heading
---@return boolean
function H.is_matching_heading(line, heading)
  local level = H.get_atx_heading_level(line)
  if level ~= heading.level then
    return false
  end

  -- Matches:
  --   ## Title
  --   ## Title ##
  -- but not:
  --   ## Title extra
  local title = vim.pesc(vim.trim(heading.title))
  return line:match("^%s*#+%s+" .. title .. "%s*#*%s*$") ~= nil
end

---@param lines string[]
---@param heading checkmate.Heading
---@return integer|nil section_start 0-based heading row
---@return integer|nil section_end 0-based inclusive final row in section
function H.find_heading_section(lines, heading)
  local section_start = nil ---@type integer|nil
  local section_end = nil ---@type integer|nil

  for i, line in ipairs(lines) do
    if H.is_matching_heading(line, heading) then
      section_start = i - 1
      section_end = #lines - 1

      for j = i + 1, #lines do
        local level = H.get_atx_heading_level(lines[j])

        -- A section ends at the line before the next heading of the same or
        -- higher rank. Example: a level-3 section is closed by level 1, 2, or 3.
        if level and level <= heading.level then
          section_end = j - 2
          break
        end
      end

      break
    end
  end

  return section_start, section_end
end

return M
