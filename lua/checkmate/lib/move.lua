--- move.lua module
---
--- Provides business logic for "cut & paste" type functionality for
--- moving Checkmate Todo items within or between buffers
---
local M = {}
local H = {}

local diff = require("checkmate.lib.diff")
local cm_heading = require("checkmate.lib.heading")
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
  local preserve_source_headings = opts.preserve_source_headings or false

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

  ---@type string[]
  local payload = H.build_source_payload(source_ranges, src_lines, root_spacing) -- lines inserted at destination
  ---@type table<integer, boolean>
  local to_delete = {} -- 0-indexed row numbers of source buffer to eventually remove

  -- Mark the source lines to be removed. The destination payload is built from
  -- the same source snapshot so all hunk coordinates remain stable.
  for _, r in ipairs(source_ranges) do
    -- mark for deletion
    for row = r.start_row, r.end_row do
      to_delete[row] = true
    end
  end

  -- don't want the move payload to bring a dangling blank into the destination.
  H.trim_trailing_blank(payload)

  -- // Blank line cleanup in the source
  --
  -- if deleting a block would leave two consecutive blank
  -- lines in the source (one before the block, one after it), delete the
  -- trailing blank so the source compresses cleanly
  --
  -- conservative by design - better to leave an extra blank
  -- than to silently destroy intentional whitespace
  if cleanup_source then
    for _, r in ipairs(source_ranges) do
      local after = r.end_row + 1 -- 0-based row immediately after the deleted block
      local before = r.start_row - 1 -- 0-based row immediately before

      -- only act if the line after the block exists and is blank
      if after <= #src_lines - 1 and src_lines[after + 1] == "" then
        -- walk upward past any other deleted rows to find the nearest surviving line
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

  if preserve_source_headings then
    local target_rows = vim.tbl_map(function(r)
      return r.start_row
    end, source_ranges)
    local chains = H.build_heading_chains(src_lines, target_rows)
    local groups = H.classify_source_groups(chains, source_ranges, preserve_source_headings, src_lines, root_spacing)

    if target_heading and target_row == nil then
      local outer_start, outer_end = H.find_heading_section(dest_lines, target_heading)

      if outer_start then
        local merge_hunks, remaining_groups = H.try_merge_groups(
          dest_lines,
          H.make_section(outer_start, outer_end, target_heading.level),
          groups,
          target_heading,
          newest_first,
          ensure_blank_line_under_heading,
          root_spacing
        )
        vim.list_extend(dest_hunks, merge_hunks)
        payload = H.build_enriched_payload(remaining_groups, target_heading)
      else
        payload = H.build_enriched_payload(groups, target_heading)
      end
    else
      payload = H.build_enriched_payload(groups, target_heading)
    end

    H.trim_trailing_blank(payload)
  end

  if #payload == 0 then
    if #dest_hunks > 0 then
      return source_hunks, dest_hunks
    end

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

            H.add_spacing_before_existing_content(
              insert_payload,
              dest_lines,
              first_nonblank,
              has_existing_content,
              root_spacing
            )

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 1, insert_payload)
          elseif blank_count == 1 then
            -- Exactly one blank already exists:
            -- insert payload after that blank.
            for _, line in ipairs(payload) do
              insert_payload[#insert_payload + 1] = line
            end

            H.add_spacing_before_existing_content(
              insert_payload,
              dest_lines,
              first_nonblank,
              has_existing_content,
              root_spacing
            )

            dest_hunks[#dest_hunks + 1] = diff.make_line_insert(section_start + 2, insert_payload)
          else
            -- More than one blank exists:
            -- replace the blank lines with exactly 1 blank followed by
            -- the payload
            insert_payload[#insert_payload + 1] = ""

            for _, line in ipairs(payload) do
              insert_payload[#insert_payload + 1] = line
            end

            H.add_spacing_before_existing_content(
              insert_payload,
              dest_lines,
              first_nonblank,
              has_existing_content,
              root_spacing
            )

            dest_hunks[#dest_hunks + 1] = diff.make_line_replace({ blank_start, blank_end }, insert_payload)
          end
        else
          -- opted out of blank-line normalization
          -- so...we insert right after the heading, even if it butts up against the heading
          for _, line in ipairs(payload) do
            insert_payload[#insert_payload + 1] = line
          end

          H.add_spacing_before_existing_content(
            insert_payload,
            dest_lines,
            first_nonblank,
            has_existing_content,
            root_spacing
          )

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
            H.add_spacing(append_payload, root_spacing)
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

  if opts.preserve_source_headings ~= nil and not H.is_valid_preserve_source_headings(opts.preserve_source_headings) then
    return false, "preserve_source_headings must be false, 'nearest', or 'all'"
  end

  return true
end

function H.validate_line_boundary(row, lines)
  return type(row) == "number" and row >= 0 and row <= #lines
end

---@param value any
---@return boolean
function H.is_valid_preserve_source_headings(value)
  return value == nil or value == false or value == "nearest" or value == "all"
end

---@param lines string[]
---@param count integer
function H.add_spacing(lines, count)
  for _ = 1, count do
    lines[#lines + 1] = ""
  end
end

---@param lines string[]
function H.trim_trailing_blank(lines)
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
end

---@param lines string[]
---@param existing_lines string[]
---@param first_existing_row integer
---@param has_existing_content boolean
---@param root_spacing integer
function H.add_spacing_before_existing_content(lines, existing_lines, first_existing_row, has_existing_content, root_spacing)
  if not has_existing_content then
    return
  end

  local spacing = root_spacing
  local first_existing_line = existing_lines[first_existing_row + 1]

  if first_existing_line and cm_heading.get_atx_heading_level(first_existing_line) then
    spacing = math.max(spacing, 1)
  end

  if spacing > 0 then
    H.add_spacing(lines, spacing)
  end
end

---@param range {start_row: integer, end_row: integer}
---@param src_lines string[]
---@return string[]
function H.extract_range_payload(range, src_lines)
  local payload = {}

  for row = range.start_row, range.end_row do
    payload[#payload + 1] = src_lines[row + 1]
  end

  return payload
end

---@param source_ranges {start_row: integer, end_row: integer}[]
---@param src_lines string[]
---@param root_spacing integer
---@return string[]
function H.build_source_payload(source_ranges, src_lines, root_spacing)
  local payload = {}

  for idx, r in ipairs(source_ranges) do
    vim.list_extend(payload, H.extract_range_payload(r, src_lines))

    if idx < #source_ranges and root_spacing > 0 then
      H.add_spacing(payload, root_spacing)
    end
  end

  H.trim_trailing_blank(payload)
  return payload
end

---@param chain checkmate.Heading[]
---@return checkmate.Heading[]
function H.copy_chain(chain)
  local copy = {}

  for _, heading in ipairs(chain or {}) do
    copy[#copy + 1] = cm_heading.new(heading.title, heading.level)
  end

  return copy
end

---@param chain checkmate.Heading[]
---@param start_idx integer
---@return checkmate.Heading[]
function H.slice_chain(chain, start_idx)
  local slice = {}

  for idx = start_idx, #chain do
    slice[#slice + 1] = cm_heading.new(chain[idx].title, chain[idx].level)
  end

  return slice
end

---@param a checkmate.Heading[]
---@param b checkmate.Heading[]
---@return integer
function H.common_heading_prefix_len(a, b)
  local len = 0
  local max_len = math.min(#a, #b)

  for idx = 1, max_len do
    if a[idx].level ~= b[idx].level or a[idx].title ~= b[idx].title then
      break
    end
    len = idx
  end

  return len
end

---@param a checkmate.Heading[]
---@param b checkmate.Heading[]
---@return boolean
function H.heading_chains_equal(a, b)
  return #a == #b and H.common_heading_prefix_len(a, b) == #a
end

---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param group {chain: checkmate.Heading[], payload: string[]}
---@param root_spacing integer
function H.add_group(groups, group, root_spacing)
  local last = groups[#groups]

  if last and H.heading_chains_equal(last.chain, group.chain) then
    if #last.payload > 0 and #group.payload > 0 and root_spacing > 0 then
      H.add_spacing(last.payload, root_spacing)
    end

    vim.list_extend(last.payload, group.payload)
  else
    groups[#groups + 1] = group
  end
end

---@param line string
---@return boolean
function H.is_fence_boundary(line)
  return line:match("^%s*```") ~= nil or line:match("^%s*~~~") ~= nil
end

---@param src_lines string[]
---@param target_rows integer[]
---@return table<integer, checkmate.Heading[]>
function H.build_heading_chains(src_lines, target_rows)
  local target_lookup = {}

  for _, row in ipairs(target_rows) do
    target_lookup[row] = true
  end

  local chains = {}
  local stack = {}
  local in_fence = false

  for idx, line in ipairs(src_lines) do
    local row = idx - 1

    if target_lookup[row] then
      chains[row] = H.copy_chain(stack)
    end

    if H.is_fence_boundary(line) then
      in_fence = not in_fence
    elseif not in_fence and cm_heading.get_atx_heading_level(line) then
      local heading = cm_heading.from_atx_heading_string(line)

      if heading then
        while #stack > 0 and stack[#stack].level >= heading.level do
          stack[#stack] = nil
        end

        stack[#stack + 1] = heading
      end
    end
  end

  for _, row in ipairs(target_rows) do
    chains[row] = chains[row] or {}
  end

  return chains
end

---@param chains table<integer, checkmate.Heading[]>
---@param source_ranges {start_row: integer, end_row: integer}[]
---@param mode "nearest"|"all"
---@param src_lines string[]
---@param root_spacing integer
---@return {chain: checkmate.Heading[], payload: string[]}[]
function H.classify_source_groups(chains, source_ranges, mode, src_lines, root_spacing)
  local groups = {}

  for _, range in ipairs(source_ranges) do
    local chain = H.copy_chain(chains[range.start_row] or {})

    if mode == "nearest" and #chain > 0 then
      chain = { chain[#chain] }
    end

    local payload = H.extract_range_payload(range, src_lines)
    H.trim_trailing_blank(payload)

    H.add_group(groups, {
      chain = chain,
      payload = payload,
    }, root_spacing)
  end

  return groups
end

---@param heading checkmate.Heading
---@param dest_heading checkmate.Heading|nil
---@return checkmate.Heading
function H.normalized_heading(heading, dest_heading)
  if not dest_heading then
    return cm_heading.new(heading.title, heading.level)
  end

  -- Preserve source level gaps while capping at Markdown's deepest ATX level.
  return cm_heading.new(heading.title, math.min(heading.level + dest_heading.level, 6))
end

---@param chain checkmate.Heading[]
---@param dest_heading checkmate.Heading|nil
---@return checkmate.Heading[]
function H.normalized_chain(chain, dest_heading)
  local normalized = {}

  for _, heading in ipairs(chain) do
    normalized[#normalized + 1] = H.normalized_heading(heading, dest_heading)
  end

  return normalized
end

---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param dest_heading checkmate.Heading|nil
---@return string[]
function H.build_enriched_payload(groups, dest_heading)
  local output = {}
  local prev_chain = {}

  for idx, group in ipairs(groups) do
    local common_len = H.common_heading_prefix_len(prev_chain, group.chain)
    local diverging = H.slice_chain(group.chain, common_len + 1)

    if idx > 1 and #diverging > 0 and #output > 0 then
      output[#output + 1] = ""
    end

    for _, heading in ipairs(diverging) do
      output[#output + 1] = H.normalized_heading(heading, dest_heading):to_string()
      output[#output + 1] = ""
    end

    vim.list_extend(output, group.payload)
    prev_chain = group.chain
  end

  H.trim_trailing_blank(output)
  return output
end

---@param start_row integer
---@param end_row integer
---@param level integer
---@return {start_row: integer, end_row: integer, level: integer}
function H.make_section(start_row, end_row, level)
  return {
    start_row = start_row,
    end_row = end_row,
    level = level,
  }
end

---@param lines string[]
---@param heading_row integer
---@param level integer
---@param parent_end integer
---@return {start_row: integer, end_row: integer, level: integer}
function H.make_section_from_heading_row(lines, heading_row, level, parent_end)
  local section_end = parent_end
  local in_fence = false

  for row = heading_row + 1, parent_end do
    local line = lines[row + 1]

    if H.is_fence_boundary(line) then
      in_fence = not in_fence
    elseif not in_fence then
      local current_level = cm_heading.get_atx_heading_level(line)

      if current_level and current_level <= level then
        section_end = row - 1
        break
      end
    end
  end

  return H.make_section(heading_row, section_end, level)
end

---@param lines string[]
---@param row integer
---@param parent_end integer
---@param level integer
---@return integer
function H.next_section_row(lines, row, parent_end, level)
  local in_fence = false

  for next_row = row + 1, parent_end do
    local line = lines[next_row + 1]

    if H.is_fence_boundary(line) then
      in_fence = not in_fence
    elseif not in_fence then
      local next_level = cm_heading.get_atx_heading_level(line)

      if next_level and next_level <= level then
        return next_row
      end
    end
  end

  return parent_end + 1
end

---@param lines string[]
---@param parent_section {start_row: integer, end_row: integer, level: integer}
---@param title string
---@param level integer
---@return {start_row: integer, end_row: integer, level: integer}|nil
function H.find_sub_heading_section(lines, parent_section, title, level)
  local row = parent_section.start_row + 1
  local in_fence = false

  while row <= parent_section.end_row do
    local line = lines[row + 1]

    if H.is_fence_boundary(line) then
      in_fence = not in_fence
      row = row + 1
    elseif in_fence then
      row = row + 1
    else
      local current_level = cm_heading.get_atx_heading_level(line)

      if current_level and current_level <= parent_section.level then
        break
      elseif current_level and current_level == level then
        if H.is_matching_heading(line, cm_heading.new(title, level)) then
          return H.make_section_from_heading_row(lines, row, level, parent_section.end_row)
        end

        row = H.next_section_row(lines, row, parent_section.end_row, level)
      elseif current_level and current_level > parent_section.level and current_level < level then
        row = H.next_section_row(lines, row, parent_section.end_row, current_level)
      else
        row = row + 1
      end
    end
  end
end

---@param lines string[]
---@param outer_section {start_row: integer, end_row: integer, level: integer}
---@param normalized_chain checkmate.Heading[]
---@return {matched_depth: integer, deepest_section: {start_row: integer, end_row: integer, level: integer}}
function H.walk_chain_match(lines, outer_section, normalized_chain)
  local current_section = outer_section
  local matched_depth = 0

  for idx, heading in ipairs(normalized_chain) do
    local section = H.find_sub_heading_section(lines, current_section, heading.title, heading.level)

    if not section then
      break
    end

    matched_depth = idx
    current_section = section
  end

  return {
    matched_depth = matched_depth,
    deepest_section = current_section,
  }
end

---@param lines string[]
---@param section {start_row: integer, end_row: integer, level: integer}
---@return {first_nonblank: integer, blank_start: integer, blank_end: integer, blank_count: integer, has_existing_content: boolean, tail: integer, has_body: boolean}
function H.get_section_layout(lines, section)
  local first_nonblank = section.start_row + 1

  while first_nonblank <= section.end_row and lines[first_nonblank + 1] == "" do
    first_nonblank = first_nonblank + 1
  end

  local blank_start = section.start_row + 1
  local blank_end = first_nonblank - 1
  local blank_count = math.max(blank_end - blank_start + 1, 0)
  local has_existing_content = first_nonblank <= section.end_row
  local tail = section.end_row

  while tail > section.start_row and lines[tail + 1] == "" do
    tail = tail - 1
  end

  return {
    first_nonblank = first_nonblank,
    blank_start = blank_start,
    blank_end = blank_end,
    blank_count = blank_count,
    has_existing_content = has_existing_content,
    tail = tail,
    has_body = tail > section.start_row,
  }
end

---@param pending table<string, {section: table, position: "top"|"bottom", payload: string[], min_pre_spacing: integer}>
---@param order string[]
---@param section {start_row: integer, end_row: integer, level: integer}
---@param position "top"|"bottom"
---@param payload string[]
---@param root_spacing integer
---@param min_pre_spacing integer
function H.queue_section_insert(pending, order, section, position, payload, root_spacing, min_pre_spacing)
  if #payload == 0 then
    return
  end

  local key = table.concat({ section.start_row, section.end_row, section.level, position }, ":")
  local entry = pending[key]

  if not entry then
    entry = {
      section = section,
      position = position,
      payload = {},
      min_pre_spacing = min_pre_spacing,
    }
    pending[key] = entry
    order[#order + 1] = key
  else
    entry.min_pre_spacing = math.max(entry.min_pre_spacing, min_pre_spacing)

    if #entry.payload > 0 and root_spacing > 0 then
      H.add_spacing(entry.payload, root_spacing)
    elseif #entry.payload > 0 and min_pre_spacing > 0 and payload[1] and cm_heading.get_atx_heading_level(payload[1]) then
      entry.payload[#entry.payload + 1] = ""
    end
  end

  vim.list_extend(entry.payload, payload)
  H.trim_trailing_blank(entry.payload)
end

---@param lines string[]
---@param section {start_row: integer, end_row: integer, level: integer}
---@param payload string[]
---@param position "top"|"bottom"
---@param ensure_blank_line_under_heading boolean
---@param root_spacing integer
---@param min_pre_spacing integer
---@return checkmate.TextDiffHunk[]
function H.make_section_insert_hunks(
  lines,
  section,
  payload,
  position,
  ensure_blank_line_under_heading,
  root_spacing,
  min_pre_spacing
)
  local layout = H.get_section_layout(lines, section)
  local hunks = {}

  if position == "top" then
    local insert_payload = {}

    if ensure_blank_line_under_heading then
      if layout.blank_count == 0 then
        insert_payload[#insert_payload + 1] = ""
        vim.list_extend(insert_payload, payload)

        H.add_spacing_before_existing_content(
          insert_payload,
          lines,
          layout.first_nonblank,
          layout.has_existing_content,
          root_spacing
        )

        hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 1, insert_payload)
      elseif layout.blank_count == 1 then
        vim.list_extend(insert_payload, payload)

        H.add_spacing_before_existing_content(
          insert_payload,
          lines,
          layout.first_nonblank,
          layout.has_existing_content,
          root_spacing
        )

        hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 2, insert_payload)
      else
        insert_payload[#insert_payload + 1] = ""
        vim.list_extend(insert_payload, payload)

        H.add_spacing_before_existing_content(
          insert_payload,
          lines,
          layout.first_nonblank,
          layout.has_existing_content,
          root_spacing
        )

        hunks[#hunks + 1] = diff.make_line_replace({ layout.blank_start, layout.blank_end }, insert_payload)
      end
    else
      vim.list_extend(insert_payload, payload)

      H.add_spacing_before_existing_content(
        insert_payload,
        lines,
        layout.first_nonblank,
        layout.has_existing_content,
        root_spacing
      )

      hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 1, insert_payload)
    end

    return hunks
  end

  local append_payload = {}

  if ensure_blank_line_under_heading and not layout.has_body then
    if layout.blank_count == 0 then
      append_payload[#append_payload + 1] = ""
      vim.list_extend(append_payload, payload)
      hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 1, append_payload)
    elseif layout.blank_count == 1 then
      vim.list_extend(append_payload, payload)
      hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 2, append_payload)
    else
      append_payload[#append_payload + 1] = ""
      vim.list_extend(append_payload, payload)
      hunks[#hunks + 1] = diff.make_line_replace({ layout.blank_start, layout.blank_end }, append_payload)
    end
  else
    if ensure_blank_line_under_heading then
      if layout.blank_count == 0 then
        hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 1, { "" })
      elseif layout.blank_count > 1 then
        hunks[#hunks + 1] = diff.make_line_replace({ layout.blank_start, layout.blank_end }, { "" })
      end
    end

    local spacing = math.max(root_spacing, min_pre_spacing)
    if layout.has_body and spacing > 0 then
      H.add_spacing(append_payload, spacing)
    end

    vim.list_extend(append_payload, payload)
    hunks[#hunks + 1] = diff.make_line_insert(layout.tail + 1, append_payload)
  end

  return hunks
end

---@param lines string[]
---@param outer_section {start_row: integer, end_row: integer, level: integer}
---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param dest_heading checkmate.Heading
---@param append_top boolean
---@param ensure_blank_line_under_heading boolean
---@param root_spacing integer
---@return checkmate.TextDiffHunk[] hunks
---@return {chain: checkmate.Heading[], payload: string[]}[] remaining_groups
function H.try_merge_groups(
  lines,
  outer_section,
  groups,
  dest_heading,
  append_top,
  ensure_blank_line_under_heading,
  root_spacing
)
  local pending = {}
  local order = {}
  local remaining_groups = {}

  for _, group in ipairs(groups) do
    if #group.chain == 0 then
      remaining_groups[#remaining_groups + 1] = group
    else
      local normalized_chain = H.normalized_chain(group.chain, dest_heading)
      local match = H.walk_chain_match(lines, outer_section, normalized_chain)

      if match.matched_depth == 0 then
        remaining_groups[#remaining_groups + 1] = group
      elseif match.matched_depth == #group.chain then
        H.queue_section_insert(
          pending,
          order,
          match.deepest_section,
          append_top and "top" or "bottom",
          group.payload,
          root_spacing,
          0
        )
      else
        local tail_group = {
          chain = H.slice_chain(group.chain, match.matched_depth + 1),
          payload = group.payload,
        }
        local tail_payload = H.build_enriched_payload({ tail_group }, dest_heading)

        H.queue_section_insert(pending, order, match.deepest_section, "bottom", tail_payload, root_spacing, 1)
      end
    end
  end

  local hunks = {}

  for _, key in ipairs(order) do
    local entry = pending[key]
    vim.list_extend(
      hunks,
      H.make_section_insert_hunks(
        lines,
        entry.section,
        entry.payload,
        entry.position,
        ensure_blank_line_under_heading,
        root_spacing,
        entry.min_pre_spacing
      )
    )
  end

  return hunks, remaining_groups
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
---@param heading checkmate.Heading
---@return boolean
function H.is_matching_heading(line, heading)
  local level = cm_heading.get_atx_heading_level(line)
  if level ~= heading.level then
    return false
  end

  -- Matches:
  --   ## Title
  --   ## Title ##   (with the commonmark optional hashes at the end)
  -- but not:
  --   ## Title extra
  local hashes = string.rep("#", heading.level)
  local title = vim.pesc(vim.trim(heading.title))
  return line:match("^%s*" .. hashes .. "%s+" .. title .. "%s*#*%s*$") ~= nil
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
        local level = cm_heading.get_atx_heading_level(lines[j])

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
