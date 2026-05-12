--- move.lua module
---
--- Provides business logic for "cut & paste" type functionality for
--- moving Checkmate Todo items within or between buffers
---
--- This module never edits buffers directly. It reads stable source/destination
--- snapshots, then returns hunks for the caller to apply in a transaction.
---
--- The move has two mostly independent halves:
---   1. source cleanup: resolve todo ranges, mark those rows for deletion,
---      and compress them into source delete hunks
---   2. destination insertion: build the lines to paste, then decide where
---      those lines should land
---
--- `preserve_source_headings` only changes the destination side. It enriches
--- the payload with source heading context, and may add separate merge hunks
--- when a matching nested destination heading already exists. Source deletion
--- stays exactly the same either way.
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
--- Blank lines between top-level moved todo blocks within the same final section.
---@field parent_spacing integer

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
  -- parent_spacing means "between top-level todo blocks in the same final
  -- section"
  local parent_spacing = math.max(opts.destination.parent_spacing or 0, 0)
  local newest_first = opts.destination.append_top ~= false -- default true
  local ensure_blank_line_under_heading = opts.destination.blank_line_under_heading ~= false -- default true
  local cleanup_source = opts.cleanup_source ~= false -- default true
  local preserve_source_headings = opts.preserve_source_headings or false

  -- all hunks below are computed from these snapshots
  -- ...so we don't want to re-read buffers mid move. been there, done that, not fun.
  local src_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  -- for cross-buffer moves- need a separate snapshot of the destination buffer
  local dest_lines = same_buffer and src_lines or vim.api.nvim_buf_get_lines(dest_bufnr, 0, -1, false)
  -- Treesitter gives us real Markdown heading sections, including section_end.
  -- Keep these lazy: explicit location moves do not need section discovery.
  local src_heading_sections = nil ---@type checkmate.HeadingSection[]|nil
  local dest_heading_sections = nil ---@type checkmate.HeadingSection[]|nil

  local function get_src_heading_sections()
    if not src_heading_sections then
      src_heading_sections = cm_heading.get_heading_sections(src_bufnr, src_lines)
    end

    return src_heading_sections
  end

  local function get_dest_heading_sections()
    if same_buffer then
      return get_src_heading_sections()
    end

    if not dest_heading_sections then
      dest_heading_sections = cm_heading.get_heading_sections(dest_bufnr, dest_lines)
    end

    return dest_heading_sections
  end

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
  local payload = H.build_source_payload(source_ranges, src_lines, parent_spacing) -- lines inserted at destination
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
    -- Convert the flat payload into heading-aware groups before destination
    -- insertion. Groups that can merge into an existing nested destination
    -- heading become their own hunks; the rest go back through the normal
    -- destination insertion path as one enriched payload.
    local target_rows = vim.tbl_map(function(r)
      return r.start_row
    end, source_ranges)
    local chains = H.build_heading_chains(target_rows, get_src_heading_sections())
    local groups = H.classify_source_groups(chains, source_ranges, preserve_source_headings, src_lines, parent_spacing)

    if target_heading and target_row == nil then
      local destination_sections = get_dest_heading_sections()
      local outer_section = cm_heading.find_section(destination_sections, target_heading)

      if outer_section then
        local merge_hunks, remaining_groups = H.try_merge_groups(
          dest_lines,
          outer_section,
          groups,
          target_heading,
          newest_first,
          ensure_blank_line_under_heading,
          parent_spacing,
          destination_sections
        )
        vim.list_extend(dest_hunks, merge_hunks)
        payload = H.build_enriched_payload(remaining_groups, target_heading, ensure_blank_line_under_heading)
      else
        payload = H.build_enriched_payload(groups, target_heading, ensure_blank_line_under_heading)
      end
    else
      payload = H.build_enriched_payload(groups, target_heading, ensure_blank_line_under_heading)
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

    local section = cm_heading.find_section(get_dest_heading_sections(), target_heading)

    if not section then
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
      vim.list_extend(
        dest_hunks,
        H.make_section_insert_hunks(
          dest_lines,
          section,
          payload,
          newest_first and "top" or "bottom",
          ensure_blank_line_under_heading,
          parent_spacing,
          parent_spacing
        )
      )
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

  if
    opts.preserve_source_headings ~= nil and not H.is_valid_preserve_source_headings(opts.preserve_source_headings)
  then
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
---@param parent_spacing integer
function H.add_spacing_before_existing_content(
  lines,
  existing_lines,
  first_existing_row,
  has_existing_content,
  parent_spacing
)
  if not has_existing_content then
    return
  end

  local spacing = parent_spacing
  local first_existing_line = existing_lines[first_existing_row + 1]

  -- A newly inserted todo block should never sit directly against an existing
  -- child heading, even when callers request no extra spacing between todos.
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

--- Builds the plain, no-heading payload used by the normal move path.
--- If preserve_source_headings is enabled, this gets replaced later by an
--- enriched payload built from the same source ranges.
---@param source_ranges {start_row: integer, end_row: integer}[]
---@param src_lines string[]
---@param parent_spacing integer
---@return string[]
function H.build_source_payload(source_ranges, src_lines, parent_spacing)
  local payload = {}

  for idx, r in ipairs(source_ranges) do
    vim.list_extend(payload, H.extract_range_payload(r, src_lines))

    if idx < #source_ranges and parent_spacing > 0 then
      H.add_spacing(payload, parent_spacing)
    end
  end

  H.trim_trailing_blank(payload)
  return payload
end

---@param chain checkmate.Heading[]
---@return checkmate.Heading[]
function H.copy_heading_chain(chain)
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

--- Adds a source range to a heading group list.
--- Adjacent ranges with the same source heading chain stay in one group so
--- their shared headings are emitted once.
---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param group {chain: checkmate.Heading[], payload: string[]}
---@param parent_spacing integer
function H.add_group(groups, group, parent_spacing)
  local last = groups[#groups]

  if last and H.heading_chains_equal(last.chain, group.chain) then
    if #last.payload > 0 and #group.payload > 0 and parent_spacing > 0 then
      H.add_spacing(last.payload, parent_spacing)
    end

    vim.list_extend(last.payload, group.payload)
  else
    groups[#groups + 1] = group
  end
end

--- Finds the heading chain above each target row
---
--- We snapshot the stack before reading the target row itself. That keeps the
--- lookup strictly "headings above this row", which matches how callers expect
--- preserve_source_headings to behave.
---@param target_rows integer[] i.e. first row of each todo
---@param heading_sections checkmate.HeadingSection[]
---@return table<integer, checkmate.Heading[]>
function H.build_heading_chains(target_rows, heading_sections)
  local chains = {}

  for _, target_row in ipairs(target_rows) do
    local chain = {}

    for _, section in ipairs(heading_sections) do
      if section.start_row >= target_row then
        break
      end

      if target_row <= section.end_row then
        chain[#chain + 1] = section.heading
      end
    end

    chains[target_row] = H.copy_heading_chain(chain)
  end

  return chains
end

--- Turns source ranges into heading groups.
--- The payload in each group is still raw todo lines; headings are stamped only
--- when H.build_enriched_payload renders the final destination payload.
---@param chains table<integer, checkmate.Heading[]>
---@param source_ranges {start_row: integer, end_row: integer}[]
---@param mode "nearest"|"all"
---@param src_lines string[]
---@param parent_spacing integer
---@return {chain: checkmate.Heading[], payload: string[]}[]
function H.classify_source_groups(chains, source_ranges, mode, src_lines, parent_spacing)
  local groups = {}

  for _, range in ipairs(source_ranges) do
    local chain = H.copy_heading_chain(chains[range.start_row] or {})

    if mode == "nearest" and #chain > 0 then
      chain = { chain[#chain] }
    end

    local payload = H.extract_range_payload(range, src_lines)
    H.trim_trailing_blank(payload)

    H.add_group(groups, {
      chain = chain,
      payload = payload,
    }, parent_spacing)
  end

  return groups
end

--- Normalizes a source heading for a destination section.
--- With a destination heading, source levels are shifted underneath it. Without
--- one, source levels are preserved.
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

--- Renders heading groups into one destination payload.
--- This is where common-prefix dedup happens: when two consecutive groups share
--- `# School`, we emit that heading once and only stamp the diverging tail.
---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param dest_heading checkmate.Heading|nil
---@param blank_line_under_heading boolean
---@return string[]
function H.build_enriched_payload(groups, dest_heading, blank_line_under_heading)
  local output = {}
  local prev_chain = {}

  for idx, group in ipairs(groups) do
    local common_len = H.common_heading_prefix_len(prev_chain, group.chain)
    local diverging = H.slice_chain(group.chain, common_len + 1)

    -- Separate a moved todo block from the next newly emitted heading.
    -- `parent_spacing` is handled inside group payloads; this is heading hygiene.
    if idx > 1 and #diverging > 0 and #output > 0 then
      output[#output + 1] = ""
    end

    for _, heading in ipairs(diverging) do
      output[#output + 1] = H.normalized_heading(heading, dest_heading):to_string()

      if blank_line_under_heading then
        output[#output + 1] = ""
      end
    end

    vim.list_extend(output, group.payload)
    prev_chain = group.chain
  end

  H.trim_trailing_blank(output)
  return output
end

--- Finds an exact child heading section inside a parent section.
--- This intentionally searches by normalized level + title. A `### School`
--- under Archive is different from a `#### School`.
---@param parent_section checkmate.HeadingSection
---@param title string
---@param level integer
---@param heading_sections checkmate.HeadingSection[]
---@return checkmate.HeadingSection|nil
function H.find_sub_heading_section(parent_section, title, level, heading_sections)
  return cm_heading.find_section(heading_sections, cm_heading.new(title, level), parent_section.start_row)
end

--- Walks a normalized source chain through the destination section tree.
--- The result tells the merge path where to insert:
--- - matched_depth == 0: no usable destination heading
--- - matched_depth == #chain: insert todos into deepest_section
--- - otherwise: emit the remaining heading tail inside deepest_section
---@param outer_section checkmate.HeadingSection
---@param normalized_chain checkmate.Heading[]
---@param heading_sections checkmate.HeadingSection[]
---@return {matched_depth: integer, deepest_section: checkmate.HeadingSection}
function H.walk_chain_match(outer_section, normalized_chain, heading_sections)
  local current_section = outer_section
  local matched_depth = 0

  for idx, heading in ipairs(normalized_chain) do
    local section = H.find_sub_heading_section(current_section, heading.title, heading.level, heading_sections)

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

--- Reads the whitespace shape of a destination section.
--- Insertion code uses this to avoid duplicating the same "how many blanks
--- live under this heading?" logic across top and bottom insertion paths.
---@param lines string[]
---@param section checkmate.HeadingSection
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

--- Collects multiple insertions that target the same section/position.
--- This happens when several source groups merge into one existing destination
--- heading. Coalescing them here keeps the final diff small and prevents two
--- hunks from fighting over the same row.
---@param pending table<string, {section: checkmate.HeadingSection, position: "top"|"bottom", payload: string[], min_pre_spacing: integer}>
---@param order string[]
---@param section checkmate.HeadingSection
---@param position "top"|"bottom"
---@param payload string[]
---@param parent_spacing integer
---@param min_pre_spacing integer
function H.queue_section_insert(pending, order, section, position, payload, parent_spacing, min_pre_spacing)
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

    if #entry.payload > 0 then
      if payload[1] and cm_heading.get_atx_heading_level(payload[1]) then
        -- A diverging source-heading tail is a new section boundary; keep that
        -- structural separator independent of todo parent spacing.
        H.add_spacing(entry.payload, min_pre_spacing)
      elseif parent_spacing > 0 then
        H.add_spacing(entry.payload, parent_spacing)
      end
    end
  end

  vim.list_extend(entry.payload, payload)
  H.trim_trailing_blank(entry.payload)
end

--- Builds the actual insertion hunks for one destination section.
--- This helper owns the local whitespace rules for "top" vs "bottom" insertion:
--- blank under heading, parent spacing between todo blocks, and the small
--- structural separator before a newly emitted child heading.
---@param lines string[]
---@param section checkmate.HeadingSection
---@param payload string[]
---@param position "top"|"bottom"
---@param ensure_blank_line_under_heading boolean
---@param parent_spacing integer
---@param min_pre_spacing integer
---@return checkmate.TextDiffHunk[]
function H.make_section_insert_hunks(
  lines,
  section,
  payload,
  position,
  ensure_blank_line_under_heading,
  parent_spacing,
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
          parent_spacing
        )

        hunks[#hunks + 1] = diff.make_line_insert(section.start_row + 1, insert_payload)
      elseif layout.blank_count == 1 then
        vim.list_extend(insert_payload, payload)

        H.add_spacing_before_existing_content(
          insert_payload,
          lines,
          layout.first_nonblank,
          layout.has_existing_content,
          parent_spacing
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
          parent_spacing
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
        parent_spacing
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

    local payload_starts_with_heading = payload[1] and cm_heading.get_atx_heading_level(payload[1])
    local spacing = payload_starts_with_heading and min_pre_spacing or parent_spacing
    if layout.has_body and spacing > 0 then
      H.add_spacing(append_payload, spacing)
    end

    vim.list_extend(append_payload, payload)
    hunks[#hunks + 1] = diff.make_line_insert(layout.tail + 1, append_payload)
  end

  return hunks
end

--- Tries to land preserve_source_headings groups inside existing nested
--- destination headings.
---
--- Full match:
---   existing `### School` + group chain `[School]` -> insert just the todo
---   payload inside `### School`
---
--- Partial match:
---   existing `### School` + group chain `[School, Campus]` -> insert a new
---   `#### Campus` subsection inside `### School`
---
--- No match and orphan groups go back to the normal enriched-payload path.
---@param lines string[]
---@param outer_section checkmate.HeadingSection
---@param groups {chain: checkmate.Heading[], payload: string[]}[]
---@param dest_heading checkmate.Heading
---@param append_top boolean
---@param ensure_blank_line_under_heading boolean
---@param parent_spacing integer
---@param heading_sections checkmate.HeadingSection[]
---@return checkmate.TextDiffHunk[] hunks
---@return {chain: checkmate.Heading[], payload: string[]}[] remaining_groups
function H.try_merge_groups(
  lines,
  outer_section,
  groups,
  dest_heading,
  append_top,
  ensure_blank_line_under_heading,
  parent_spacing,
  heading_sections
)
  local pending = {}
  local order = {}
  local remaining_groups = {}

  for _, group in ipairs(groups) do
    if #group.chain == 0 then
      remaining_groups[#remaining_groups + 1] = group
    else
      local normalized_chain = H.normalized_chain(group.chain, dest_heading)
      local match = H.walk_chain_match(outer_section, normalized_chain, heading_sections)

      if match.matched_depth == 0 then
        remaining_groups[#remaining_groups + 1] = group
      elseif match.matched_depth == #group.chain then
        H.queue_section_insert(
          pending,
          order,
          match.deepest_section,
          append_top and "top" or "bottom",
          group.payload,
          parent_spacing,
          0
        )
      else
        local tail_group = {
          chain = H.slice_chain(group.chain, match.matched_depth + 1),
          payload = group.payload,
        }
        local tail_payload = H.build_enriched_payload({ tail_group }, dest_heading, ensure_blank_line_under_heading)

        H.queue_section_insert(pending, order, match.deepest_section, "bottom", tail_payload, parent_spacing, 1)
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
        parent_spacing,
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

return M
