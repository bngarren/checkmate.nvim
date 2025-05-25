---@class checkmate.Api
local M = {}

---@class checkmate.DiffHunk
---@field start integer
---@field delete integer
---@field insert string[]

--- Validates that the buffer is valid (per nvim) and Markdown filetype
function M.is_valid_buffer(bufnr)
  if not bufnr or type(bufnr) ~= "number" then
    vim.notify("Checkmate: Invalid buffer number", vim.log.levels.ERROR)
    return false
  end

  -- pcall to safely check if the buffer is valid
  local ok, is_valid = pcall(vim.api.nvim_buf_is_valid, bufnr)
  if not ok or not is_valid then
    vim.notify("Checkmate: Invalid buffer", vim.log.levels.ERROR)
    return false
  end

  -- Only check filetype if buffer actually exists
  if vim.bo[bufnr].filetype ~= "markdown" then
    vim.notify("Checkmate: Buffer is not markdown filetype", vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.setup(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Check if buffer is valid
  if not M.is_valid_buffer(bufnr) then
    return false
  end

  local config = require("checkmate.config")

  -- Check if already set up
  if vim.b[bufnr].checkmate_setup_complete then
    return true
  end

  if not config.is_running() then
    vim.notify("Failed to initialize plugin", vim.log.levels.ERROR)
    return false
  end

  vim.b[bufnr].checkmate_setup_complete = true

  local parser = require("checkmate.parser")
  -- Convert markdown to Unicode
  parser.convert_markdown_to_unicode(bufnr)

  -- Only initialize linter if enabled in config
  if config.options.linter and config.options.linter.enabled ~= false then
    local linter = require("checkmate.linter")
    linter.setup(config.options.linter)
    -- Initial lint buffer
    linter.lint_buffer(bufnr)
  end

  -- Apply highlighting
  local highlights = require("checkmate.highlights")
  highlights.apply_highlighting(bufnr, { debug_reason = "API setup" })

  local has_nvim_treesitter, _ = pcall(require, "nvim-treesitter")
  if has_nvim_treesitter then
    vim.cmd("TSBufDisable highlight")
  else
    vim.api.nvim_set_option_value("syntax", "OFF", { buf = bufnr })
  end

  -- Apply keymappings
  M.setup_keymaps(bufnr)

  -- Set up auto commands for this buffer
  M.setup_autocmds(bufnr)

  config.register_buffer(bufnr)

  return true
end

function M.setup_keymaps(bufnr)
  local config = require("checkmate.config")
  local log = require("checkmate.log")
  local keys = config.options.keys or {}

  -- Get command descriptions from the commands module
  local commands_module = require("checkmate.commands")
  local command_descs = {}

  -- Build a mapping of command names to their descriptions
  for _, cmd in ipairs(commands_module.commands) do
    command_descs[cmd.cmd] = cmd.opts.desc
  end

  -- Define actions with their properties and behavior
  ---@type table<checkmate.Action, table>
  local actions = {
    toggle = {
      command = "CheckmateToggle",
      modes = { "n", "v" },
    },
    check = {
      command = "CheckmateCheck",
      modes = { "n", "v" },
    },
    uncheck = {
      command = "CheckmateUncheck",
      modes = { "n", "v" },
    },
    create = {
      command = "CheckmateCreate",
      modes = { "n" },
    },
    remove_all_metadata = {
      command = "CheckmateRemoveAllMetadata",
      modes = { "n", "v" },
    },
    archive = {
      command = "CheckmateArchive",
      modes = { "n" },
    },
  }

  for key, action_name in pairs(keys) do
    -- Skip if mapping is explicitly disabled with false
    if action_name ~= false then
      -- Check if action exists
      local action = actions[action_name]
      if action then
        -- Get description from commands module
        local base_desc = command_descs[action.command] or "Checkmate action"

        -- Map for each supported mode
        for _, mode in ipairs(action.modes) do
          local mode_desc = base_desc
          if mode == "v" then
            mode_desc = mode_desc .. " (visual)"
          end

          log.debug(string.format("Mapping %s mode key %s to %s", mode, key, action_name), { module = "api" })
          vim.api.nvim_buf_set_keymap(bufnr, mode, key, string.format("<cmd>%s<CR>", action.command), {
            noremap = true,
            silent = true,
            desc = mode_desc,
          })
        end
      else
        log.warn(string.format("Unknown action '%s' for mapping '%s'", action_name, key), { module = "api" })
      end
    end
  end

  -- Setup metadata keymaps
  if config.options.use_metadata_keymaps then
    -- For each metadata tag with a key defined
    for meta_name, meta_props in pairs(config.options.metadata) do
      if meta_props.key then
        local modes = { "n", "v" }

        -- Map metadata actions to both normal and visual modes
        for _, mode in ipairs(modes) do
          -- Map the key to the quick_metadata function
          log.debug(
            "Mapping " .. mode .. " mode key " .. meta_props.key .. " to metadata." .. meta_name,
            { module = "api" }
          )

          vim.api.nvim_buf_set_keymap(
            bufnr,
            mode,
            meta_props.key,
            string.format("<cmd>lua require('checkmate').toggle_metadata('%s')<CR>", meta_name),
            {
              noremap = true,
              silent = true,
              desc = "Checkmate: Set toggle '" .. meta_name .. "' metadata",
            }
          )
        end
      end
    end
  end
end

function M.setup_autocmds(bufnr)
  local augroup_name = "CheckmateApiGroup_" .. bufnr
  local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  if not vim.b[bufnr].checkmate_autocmds_setup then
    -- This implementation addresses several subtle behavior issues:
    --   1. vim.schedule() is used to defer setting the modified=false until after
    -- the autocmd completes. Otherwise, Neovim wasn't calling BufWritCmd on subsequent rewrites.
    --   2. Atomic write operation - ensures data integrity (either complete write success or
    -- complete failure, with preservation of the original buffer) by using temp file with a
    -- rename operation (which is atomic at the POSIX filesystem level)
    --   3. A temp buffer is used to perform the unicode to markdown conversion in order to
    -- keep a consistent visual experience for the user, maintain a clean undo history, and
    -- maintain a clean separation between the display format (unicode) and storage format (Markdown)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = augroup,
      buffer = bufnr,
      desc = "Checkmate: Convert and save .todo files",
      callback = function()
        local parser = require("checkmate.parser")
        local log = require("checkmate.log")
        local util = require("checkmate.util")

        local uv = vim.uv
        local was_modified = vim.bo[bufnr].modified

        -- Get the current lines and filename
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local filename = vim.api.nvim_buf_get_name(bufnr)

        -- Create temp buffer and convert to markdown
        local temp_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, current_lines)

        -- Convert Unicode to markdown
        local success = parser.convert_unicode_to_markdown(temp_bufnr)
        if not success then
          log.error("Failed to convert Unicode to Markdown", { module = "api" })
          vim.api.nvim_buf_delete(temp_bufnr, { force = true })
          util.notify("Failed to save when attemping to convert to Markdown", vim.log.levels.ERROR)
          return false
        end

        -- Get converted lines and write to file
        local markdown_lines = vim.api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)

        -- Create temporary file path
        local temp_filename = filename .. ".tmp"

        -- Write to temporary file first
        local write_result = vim.fn.writefile(markdown_lines, temp_filename, "b")

        -- Clean up temp buffer
        vim.api.nvim_buf_delete(temp_bufnr, { force = true })

        if write_result == 0 then
          -- Atomically rename the temp file to the target file
          local ok, rename_err = pcall(function()
            uv.fs_rename(temp_filename, filename)
          end)

          if not ok then
            -- If rename fails, try to clean up and report error
            pcall(function()
              uv.fs_unlink(temp_filename)
            end)
            log.error("Failed to rename temp file: " .. (rename_err or "unknown error"), { module = "api" })
            util.notify("Failed to save file", vim.log.levels.ERROR)
            vim.bo[bufnr].modified = was_modified
            return false
          end

          -- Convert the main buffer content to Unicode for display
          parser.convert_markdown_to_unicode(bufnr)

          -- Use schedule to set modified flag after command completes
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.bo[bufnr].modified = false
            end
          end)

          util.notify("Saved", vim.log.levels.INFO)
        else
          -- Failed to write temp file
          -- Try to clean up
          pcall(function()
            uv.fs_unlink(temp_filename)
          end)
          util.notify("Failed to write file", vim.log.levels.ERROR)
          vim.bo[bufnr].modified = was_modified
          return false
        end
      end,
    })

    vim.api.nvim_create_autocmd("InsertLeave", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        if vim.bo[bufnr].modified then
          M.process_buffer(bufnr, "InsertLeave")
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = augroup,
      buffer = bufnr,
      callback = function()
        M.process_buffer(bufnr, "TextChanged")
      end,
    })
  end
end

M._debounced_process_buffer_fns = {}
M.PROCESS_DEBOUNCE = 50 -- ms

function M.process_buffer(bufnr, reason)
  local log = require("checkmate.log")

  -- Create a debounced function for this buffer if it doesn't exist
  if not M._debounced_process_buffer_fns[bufnr] then
    local function process_buffer_impl()
      -- Skip if buffer is no longer valid
      if not vim.api.nvim_buf_is_valid(bufnr) then
        M._debounced_process_buffer_fns[bufnr] = nil
        return
      end

      local parser = require("checkmate.parser")
      local config = require("checkmate.config")
      local linter = require("checkmate.linter")

      local start_time = vim.uv.hrtime() / 1000000

      local todo_map = parser.discover_todos(bufnr)
      parser.convert_markdown_to_unicode(bufnr)

      require("checkmate.highlights").apply_highlighting(
        bufnr,
        { todo_map = todo_map, debug_reason = "api process_buffer" }
      )

      if config.options.linter and config.options.linter.enabled then
        linter.lint_buffer(bufnr)
      end

      local end_time = vim.uv.hrtime() / 1000000
      local elapsed = end_time - start_time

      log.debug(("Buffer processed in %d ms, reason: %s"):format(elapsed, reason or "unknown"), { module = "api" })
    end

    -- Create a debounced version of the process function
    M._debounced_process_buffer_fns[bufnr] = require("checkmate.util").debounce(process_buffer_impl, {
      ms = M.PROCESS_DEBOUNCE,
    })
  end

  -- Call the debounced processor - this will reset the timer
  M._debounced_process_buffer_fns[bufnr]()

  -- Log that the process was scheduled
  log.debug(("Process scheduled for buffer %d, reason: %s"):format(bufnr, reason or "unknown"), { module = "api" })
end

-- Create a new todo item from the current line
function M.create_todo()
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")
  local log = require("checkmate.log")

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

  local todo_state = parser.get_todo_item_state(line)
  if todo_state ~= nil then
    log.debug("Line already has a todo marker, skipping", { module = "api" })
    util.notify(("Todo item already exists on row %d!"):format(row + 1), log.levels.INFO)
    return
  end

  -- Extract indentation
  local indent = line:match("^(%s*)") or ""

  -- Detect whether the line already starts with a list marker
  local list_marker_match = util.match_first(
    util.create_list_prefix_patterns({
      simple_markers = parser.list_item_markers,
      use_numbered_list_markers = true,
      with_capture = true,
    }),
    line
  )

  local new_line
  local unchecked = config.options.todo_markers.unchecked

  if list_marker_match then
    log.debug("Found existing list marker: '" .. list_marker_match .. "'", { module = "api" })
    -- Replace the list marker with itself followed by the unchecked todo marker
    -- The list marker was captured as %1 in the pattern
    new_line = line:gsub("^(" .. vim.pesc(list_marker_match) .. ")", "%1" .. unchecked .. " ")
  else
    -- Create a new line with the default list marker
    local default_marker = config.options.default_list_marker or "-"
    new_line = indent .. default_marker .. " " .. unchecked .. " " .. line:gsub("^%s*", "")
    log.debug("Created new todo line with default marker: '" .. default_marker .. "'", { module = "api" })
  end

  -- If no match or no list marker, fall back to new line creation
  if not new_line then
    new_line = indent .. "- " .. unchecked .. " " .. line:gsub("^%s*", "")
  end

  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })

  -- Place cursor at end of line and enter insert mode
  vim.api.nvim_win_set_cursor(0, { cursor[1], #new_line })

  -- Apply highlighting immediately
  -- parser.apply_highlighting(bufnr)
  require("checkmate.highlights").apply_highlighting(bufnr, { debug_reason = "create_todo" })

  if config.options.enter_insert_after_new then
    vim.cmd("startinsert!")
  end
end

---Sorts metadata entries based on their configured sort_order
---@param entries checkmate.MetadataEntry[] The metadata entries to sort
---@return checkmate.MetadataEntry[] The sorted entries
function M.sort_metadata_entries(entries)
  local config = require("checkmate.config")

  -- Create a copy to avoid modifying the original array
  local sorted = vim.deepcopy(entries)

  table.sort(sorted, function(a, b)
    -- Get canonical names
    local a_name = a.alias_for or a.tag
    local b_name = b.alias_for or b.tag

    -- Get sort_order values, default to 100 if not specified
    local a_config = config.options.metadata[a_name] or {}
    local b_config = config.options.metadata[b_name] or {}

    local a_order = a_config.sort_order or 100
    local b_order = b_config.sort_order or 100

    -- If sort_order is the same, maintain original order
    if a_order == b_order then
      return (a.position_in_line or 0) < (b.position_in_line or 0)
    end

    return a_order < b_order
  end)

  return sorted
end

---Rebuilds a buffer line with sorted metadata tags
---@param line string The original buffer line
---@param metadata checkmate.TodoMetadata The metadata structure
---@return string: The rebuilt line with sorted metadata
function M.rebuild_line_with_sorted_metadata(line, metadata)
  local log = require("checkmate.log")

  -- Remove all metadata tags but preserve all other content including whitespace
  local content_without_metadata = line:gsub("@%w+%([^)]*%)", "")

  -- Remove trailing whitespace but keep all indentation
  content_without_metadata = content_without_metadata:gsub("%s+$", "")

  -- If no metadata entries, just return the cleaned content
  if not metadata or not metadata.entries or #metadata.entries == 0 then
    return content_without_metadata
  end

  -- Sort the metadata entries
  local sorted_entries = M.sort_metadata_entries(metadata.entries)

  -- Rebuild the line with content and sorted metadata
  local result_line = content_without_metadata

  -- Add back each metadata tag in sorted order
  for _, entry in ipairs(sorted_entries) do
    result_line = result_line .. " @" .. entry.tag .. "(" .. entry.value .. ")"
  end

  log.debug("Rebuilt line with sorted metadata: " .. result_line, { module = "parser" })
  return result_line
end

--- Count completed and total child todos for a todo item
---@param todo_item checkmate.TodoItem The parent todo item
---@param todo_map table<string, checkmate.TodoItem> Full todo map
---@param opts? {recursive: boolean?}
---@return {completed: number, total: number} Counts
function M.count_child_todos(todo_item, todo_map, opts)
  local counts = { completed = 0, total = 0 }

  for _, child_id in ipairs(todo_item.children or {}) do
    local child = todo_map[child_id]
    if child then
      counts.total = counts.total + 1
      if child.state == "checked" then
        counts.completed = counts.completed + 1
      end

      -- Recursively count grandchildren
      if opts and opts.recursive then
        local child_counts = M.count_child_todos(child, todo_map, opts)
        counts.total = counts.total + child_counts.total
        counts.completed = counts.completed + child_counts.completed
      end
    end
  end

  return counts
end

--- Archives completed todo items to a designated section
--- @param opts? {heading?: {title?: string, level?: integer}, include_children?: boolean} Archive options
--- @return boolean success Whether any items were archived
function M.archive_todos(opts)
  local util = require("checkmate.util")
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local highlights = require("checkmate.highlights")
  local config = require("checkmate.config")

  opts = opts or {}

  -- Create the Markdown heading that the user has defined, e.g. ## Archived
  local archive_heading_string = util.get_heading_string(
    opts.heading and opts.heading.title or config.options.archive.heading.title or "Archived",
    opts.heading and opts.heading.level or config.options.archive.heading.level or 2
  )
  local include_children = opts.include_children ~= false -- default: true
  local parent_spacing = math.max(config.options.archive.parent_spacing or 0, 0)

  -- helpers
  ---------------------------------------------------------------------------

  -- adds blank lines to the end of string[]
  local function add_spacing(lines)
    for _ = 1, parent_spacing do
      lines[#lines + 1] = ""
    end
  end

  local function trim_trailing_blank(lines)
    while #lines > 0 and lines[#lines] == "" do
      lines[#lines] = nil
    end
  end

  -- discover todos and current archive block boundaries
  ---------------------------------------------------------------------------
  local bufnr = vim.api.nvim_get_current_buf()
  local todo_map = parser.discover_todos(bufnr)
  local sorted_todos = util.get_sorted_todo_list(todo_map)
  local current_buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local archive_start_row, archive_end_row
  do
    local heading_level = archive_heading_string:match("^(#+)")
    local heading_level_len = heading_level and #heading_level or 0
    -- The 'next' heading level is a heading at the same or higher level
    -- which represents a new section
    local next_heading_pat = heading_level
        and ("^%s*" .. string.rep("#", heading_level_len, heading_level_len) .. "+%s")
      or "^%s*#+%s"

    for i, line in ipairs(current_buf_lines) do
      if line:match("^%s*" .. vim.pesc(archive_heading_string) .. "%s*$") then
        archive_start_row = i - 1 -- 0-indexed
        archive_end_row = #current_buf_lines - 1

        for j = i + 1, #current_buf_lines do
          if current_buf_lines[j]:match(next_heading_pat) then
            archive_end_row = j - 2
            break
          end
        end
        log.debug(("Found existing archive section: lines %d-%d"):format(archive_start_row + 1, archive_end_row + 1))
        break
      end
    end
  end

  -- determine which root todos (and descendants) to archive
  ---------------------------------------------------------------------------
  local todos_to_archive = {}
  local archived_ranges = {} ---@type {start_row:integer, end_row:integer}[]
  local archived_root_cnt = 0

  for _, entry in ipairs(sorted_todos) do
    local todo = entry.item ---@type checkmate.TodoItem
    local id = entry.id
    local in_arch = archive_start_row
      and todo.range.start.row > archive_start_row
      and todo.range["end"].row <= (archive_end_row or -1)

    if not in_arch and todo.state == "checked" and not todo.parent_id and not todos_to_archive[id] then
      -- mark root
      todos_to_archive[id] = true
      archived_root_cnt = archived_root_cnt + 1
      archived_ranges[#archived_ranges + 1] = {
        start_row = todo.range.start.row,
        end_row = todo.range["end"].row,
      }

      -- mark descendants if requested
      if include_children then
        local function mark_descendants(pid)
          for _, child_id in ipairs(todo_map[pid].children or {}) do
            if not todos_to_archive[child_id] then
              todos_to_archive[child_id] = true
              mark_descendants(child_id)
            end
          end
        end
        mark_descendants(id)
      end
    end
  end

  if archived_root_cnt == 0 then
    util.notify("No completed todo items to archive", vim.log.levels.INFO)
    return false
  end
  log.debug(("Found %d root todos to archive"):format(archived_root_cnt))

  table.sort(archived_ranges, function(a, b)
    return a.start_row < b.start_row
  end)

  -- rebuild buffer content
  -- start with re-creating the buffer's 'active' section (non-archived)
  ---------------------------------------------------------------------------
  local new_content = {} --- lines that will remain in the main document
  local archive_lines = {} --- lines that will live under the Archive heading

  -- Walk every line of the current buffer.
  --    We copy it into `new_content` unless it is:
  --       a) part of the existing archive section, or
  --       b) part of a todo block we’re about to archive, or
  --       c) the single blank line that immediately follows such a block
  --         (to avoid stray empty rows after removal).
  local i = 1
  while i <= #current_buf_lines do
    local idx = i - 1 -- 0-indexed (current row)

    -- skip over existing archive section in one jump
    if archive_start_row and idx >= archive_start_row and idx <= archive_end_row then
      i = archive_end_row + 2
    else
      -- skip lines inside newly-archived ranges (plus trailing blank directly after each)
      local skip = false
      for _, r in ipairs(archived_ranges) do
        if idx >= r.start_row and idx <= r.end_row then
          skip = true -- inside a soon-to-be-archived todo
          break
        end
        if idx == r.end_row + 1 and current_buf_lines[i] == "" then
          skip = true -- blank line directly after todo (skip/remove it)
          break
        end
      end
      if not skip then
        new_content[#new_content + 1] = current_buf_lines[i]
      end
      i = i + 1
    end
  end

  -- preserve existing archive content
  -- If an archive section already exists, copy everything below its heading
  ---------------------------------------------------------------------------
  if archive_start_row and archive_end_row and archive_end_row >= archive_start_row + 1 then
    local start = archive_start_row + 2
    while start <= archive_end_row + 1 and current_buf_lines[start] == "" do
      start = start + 1
    end
    for j = start, archive_end_row + 1 do
      archive_lines[#archive_lines + 1] = current_buf_lines[j]
    end
    trim_trailing_blank(archive_lines)
  end

  -- append newly-archived root todo items with spacing
  ---------------------------------------------------------------------------
  if #archived_ranges > 0 then
    if #archive_lines > 0 and parent_spacing > 0 then
      add_spacing(archive_lines) -- gap between old and new archive content
    end

    -- Copy each root todo (and its children) in original order.
    for idx, r in ipairs(archived_ranges) do
      for row = r.start_row, r.end_row do
        archive_lines[#archive_lines + 1] = current_buf_lines[row + 1]
      end

      -- spacing after each root todo except the last (easier to trim once at end)
      if idx < #archived_ranges and parent_spacing > 0 then
        add_spacing(archive_lines)
      end
    end
  end

  -- make sure we don’t leave more than `parent_spacing`
  -- blank lines at the very end of the archive section.
  trim_trailing_blank(archive_lines)

  -- inject archive section into document
  ---------------------------------------------------------------------------
  if #archive_lines > 0 then
    -- blank line before archive heading if needed
    if #new_content > 0 and new_content[#new_content] ~= "" then
      new_content[#new_content + 1] = ""
    end
    new_content[#new_content + 1] = archive_heading_string
    new_content[#new_content + 1] = "" -- blank after heading
    for _, line in ipairs(archive_lines) do
      new_content[#new_content + 1] = line
    end
  end

  -- write buffer + housekeeping
  ---------------------------------------------------------------------------
  local cursor_state = util.Cursor.save()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_content)
  util.Cursor.restore(cursor_state)
  highlights.apply_highlighting(bufnr, { debug_reason = "archive_todos" })

  util.notify(
    ("Archived %d todo item%s"):format(archived_root_cnt, archived_root_cnt > 1 and "s" or ""),
    vim.log.levels.INFO
  )
  return true
end

-- Helper function for handling cursor jumps after metadata operations
function M._handle_metadata_cursor_jump(bufnr, todo_item, meta_name, meta_config)
  local jump_to = meta_config.jump_to_on_insert
  if not jump_to or jump_to == false then
    return
  end

  vim.schedule(function()
    local row = todo_item.range.start.row
    local updated_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if not updated_line then
      return
    end

    local tag_position = updated_line:find("@" .. meta_name .. "%(")
    local value_position = tag_position and updated_line:find("%(", tag_position) + 1 or nil

    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(win) == bufnr then
      if jump_to == "tag" and tag_position then
        vim.api.nvim_win_set_cursor(0, { row + 1, tag_position - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")
          vim.cmd("normal! l" .. string.rep("l", #meta_name) .. "v" .. string.rep("h", #meta_name))
        end
      elseif jump_to == "value" and value_position then
        vim.api.nvim_win_set_cursor(0, { row + 1, value_position - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")

          local closing_paren = updated_line:find(")", value_position)
          if closing_paren and closing_paren > value_position then
            local selection_length = closing_paren - value_position
            if selection_length > 0 then
              vim.cmd("normal! v" .. string.rep("l", selection_length - 1))
            end
          end
        end
      end
    end
  end)
end

-- EXPERIMENTAL

--- Collect todo items under cursor or visual selection
---@param is_visual boolean Whether to collect items in visual selection (true) or under cursor (false)
---@return checkmate.TodoItem[] items
function M.collect_todo_items_from_selection(is_visual)
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("api.collect_todo_items_from_selection")

  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  -- Pre-parse all todos once
  local full_map = parser.discover_todos(bufnr)

  if is_visual then
    -- Exit visual mode first
    vim.cmd([[execute "normal! \<Esc>"]])
    local start_line = vim.fn.line("'<") - 1
    local end_line = vim.fn.line("'>") - 1
    local seen = {}
    for row = start_line, end_line do
      local todo = parser.get_todo_item_at_position(
        bufnr,
        row,
        0,
        { todo_map = full_map, max_depth = config.options.todo_action_depth }
      )
      if todo then
        local key = string.format("%d:%d", todo.todo_marker.position.row, todo.todo_marker.position.col)
        if not seen[key] then
          seen[key] = true
          table.insert(items, todo)
        end
      end
    end
  else
    -- Normal mode: single item at cursor
    local cursor = util.Cursor.save()
    local row = cursor.cursor[1] - 1
    local col = cursor.cursor[2]
    local todo = parser.get_todo_item_at_position(
      bufnr,
      row,
      col,
      { todo_map = full_map, max_depth = config.options.todo_action_depth }
    )
    util.Cursor.restore(cursor)
    if todo then
      table.insert(items, todo)
    end
  end

  profiler.stop("api.collect_todo_items_from_selection")

  return items
end

--- Compute diff hunks for toggling a set of todo items
---@param items checkmate.TodoItem[]
---@param target_state checkmate.TodoItemState?
---@return checkmate.DiffHunk[] hunks Each hunk = { start:number, delete:number, insert:string[] }
function M.compute_diff_toggle(items, target_state)
  local config = require("checkmate.config")
  local log = require("checkmate.log")
  local util = require("checkmate.util")
  local parser = require("checkmate.parser")
  local profiler = require("checkmate.profiler")

  local unchecked_marker = config.options.todo_markers.unchecked
  local checked_marker = config.options.todo_markers.checked

  profiler.start("api.compute_diff_toggle")

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  for _, todo_item in ipairs(items) do
    local row = todo_item.todo_marker.position.row
    local original_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    -- Determine target state for THIS specific item
    local item_target_state
    if target_state then
      -- If a specific target state is provided, use it
      item_target_state = target_state
    else
      -- Otherwise, toggle to the opposite of current state
      item_target_state = (todo_item.state == "unchecked") and "checked" or "unchecked"
    end

    if todo_item.state ~= item_target_state then
      local patterns, replacement_marker

      if item_target_state == "checked" then
        patterns = util.build_unicode_todo_patterns(parser.list_item_markers, unchecked_marker)
        replacement_marker = checked_marker
      else
        patterns = util.build_unicode_todo_patterns(parser.list_item_markers, checked_marker)
        replacement_marker = unchecked_marker
      end

      log.debug(
        string.format("Toggle patterns for %s->%s: %s", todo_item.state, item_target_state, vim.inspect(patterns)),
        { module = "api" }
      )
      log.debug(string.format("Line to match: %q", original_line), { module = "api" })

      -- Try to apply the first matching pattern
      local new_line
      for _, pattern in ipairs(patterns) do
        local replaced, count = original_line:gsub(pattern, "%1" .. replacement_marker, 1)
        if count > 0 then
          new_line = replaced
          break
        end
      end

      -- Only create hunk if we successfully found and replaced a pattern
      if new_line and new_line ~= original_line then
        table.insert(hunks, { start = row, delete = 1, insert = { new_line } })
      else
        -- Log when pattern matching fails - this indicates a bug in pattern generation or todo detection
        log.warn(
          string.format(
            "Failed to toggle line %d: %q (state=%s, target=%s)",
            row + 1,
            original_line,
            todo_item.state,
            target_state
          ),
          { module = "api" }
        )
      end
    end
  end
  profiler.stop("api.compute_diff_toggle")

  return hunks
end

---@param items checkmate.TodoItem[]
---@param meta_name string Metadata tag name
---@param meta_value string? Metadata default value
---@return checkmate.DiffHunk[]
function M.compute_diff_add_metadata(items, meta_name, meta_value)
  local config = require("checkmate.config")
  local log = require("checkmate.log")

  local meta_props = config.options.metadata[meta_name]
  if not meta_props then
    log.error("Metadata type '" .. meta_name .. "' is not configured", { module = "api" })
    return {}
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  for _, todo_item in ipairs(items) do
    local row = todo_item.range.start.row
    local original_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

    if original_line and #original_line ~= 0 then
      -- Determine value
      local value = meta_value
      if not value and meta_props.get_value then
        value = meta_props.get_value()
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
      elseif not value then
        value = ""
      end

      -- Check if metadata already exists
      local existing_entry = todo_item.metadata.by_tag[meta_name]

      -- Create updated metadata structure
      local updated_metadata = vim.deepcopy(todo_item.metadata)

      if existing_entry then
        -- Update existing entry
        for i, entry in ipairs(updated_metadata.entries) do
          if entry.tag == existing_entry.tag then
            updated_metadata.entries[i].value = value
            break
          end
        end
        updated_metadata.by_tag[meta_name].value = value
      else
        -- Add new entry
        local new_entry = {
          tag = meta_name,
          value = value,
          range = {
            start = { row = row, col = #original_line },
            ["end"] = { row = row, col = #original_line + #meta_name + #value + 3 },
          },
          position_in_line = #original_line + 1,
        }
        table.insert(updated_metadata.entries, new_entry)
        updated_metadata.by_tag[meta_name] = new_entry
      end

      -- Rebuild line with sorted metadata
      local new_line = M.rebuild_line_with_sorted_metadata(original_line, updated_metadata)

      if new_line ~= original_line then
        table.insert(hunks, {
          start = row,
          delete = 1,
          insert = { new_line },
        })
      end
    end
  end
  return hunks
end

--- Compute diff hunks for removing metadata from todo items
---@param items checkmate.TodoItem[]
---@param meta_name string Metadata tag name
---@return checkmate.DiffHunk[]
function M.compute_diff_remove_metadata(items, meta_name)
  local config = require("checkmate.config")
  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  for _, todo_item in ipairs(items) do
    local row = todo_item.range.start.row
    local original_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

    if original_line and #original_line ~= 0 then
      -- Check if metadata exists (including aliases)
      local entry = todo_item.metadata.by_tag[meta_name]
      if not entry then
        -- Check for aliases
        for canonical, props in pairs(config.options.metadata) do
          for _, alias in ipairs(props.aliases or {}) do
            if alias == meta_name then
              entry = todo_item.metadata.by_tag[canonical]
              break
            end
          end
          if entry then
            break
          end
        end
      end

      if entry then
        -- Create updated metadata structure
        local updated_metadata = vim.deepcopy(todo_item.metadata)

        -- Remove from entries
        for i = #updated_metadata.entries, 1, -1 do
          if updated_metadata.entries[i].tag == entry.tag then
            table.remove(updated_metadata.entries, i)
            break
          end
        end

        -- Remove from by_tag
        updated_metadata.by_tag[entry.tag] = nil
        if entry.alias_for then
          updated_metadata.by_tag[entry.alias_for] = nil
        end

        -- Rebuild line
        local new_line = M.rebuild_line_with_sorted_metadata(original_line, updated_metadata)

        if new_line ~= original_line then
          table.insert(hunks, {
            start = row,
            delete = 1,
            insert = { new_line },
          })
        end
      end
    end
  end

  return hunks
end

--- Compute diff hunks for removing all metadata from todo items
---@param items checkmate.TodoItem[]
---@return checkmate.DiffHunk[]
function M.compute_diff_remove_all_metadata(items)
  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  for _, todo_item in ipairs(items) do
    if todo_item.metadata and todo_item.metadata.entries and #todo_item.metadata.entries ~= 0 then
      local row = todo_item.range.start.row
      local original_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

      if original_line and #original_line ~= 0 then
        -- Create empty metadata structure
        local empty_metadata = {
          entries = {},
          by_tag = {},
        }

        -- Rebuild line without metadata
        local new_line = M.rebuild_line_with_sorted_metadata(original_line, empty_metadata)

        if new_line ~= original_line then
          table.insert(hunks, {
            start = row,
            delete = 1,
            insert = { new_line },
          })
        end
      end
    end
  end

  return hunks
end

--- Compute diff hunks for toggling metadata on todo items
---@param items checkmate.TodoItem[]
---@param meta_name string
---@param custom_value? string
---@return checkmate.DiffHunk[]
function M.compute_diff_toggle_metadata(items, meta_name, custom_value)
  local profiler = require("checkmate.profiler")
  profiler.start("api.compute_diff_toggle_metadata")

  local hunks = {}

  for _, todo_item in ipairs(items) do
    -- Check if metadata exists
    local entry = todo_item.metadata.by_tag[meta_name]
    local canonical_name = meta_name

    -- Check for aliases if not found
    if not entry then
      local config = require("checkmate.config")
      for c_name, props in pairs(config.options.metadata) do
        if c_name == meta_name then
          break
        end

        for _, alias in ipairs(props.aliases or {}) do
          if alias == meta_name then
            entry = todo_item.metadata.by_tag[c_name]
            canonical_name = c_name
            break
          end
        end
        if entry then
          break
        end
      end
    end

    -- Compute appropriate diff based on whether metadata exists
    local item_hunks
    if entry then
      -- Remove it
      item_hunks = M.compute_diff_remove_metadata({ todo_item }, canonical_name)
    else
      -- Add it
      item_hunks = M.compute_diff_add_metadata({ todo_item }, canonical_name, custom_value)
    end

    -- Merge hunks
    for _, hunk in ipairs(item_hunks) do
      table.insert(hunks, hunk)
    end
  end
  profiler.stop("api.compute_diff_toggle_metadata")

  return hunks
end

--- Validate and debug diff hunks
---@param bufnr integer Buffer number
---@param hunks checkmate.DiffHunk[]
---@return boolean valid, string? error_message
local function validate_and_debug_hunks(bufnr, hunks)
  local log = require("checkmate.log")
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  log.debug(string.format("Validating %d hunks for buffer with %d lines", #hunks, line_count), { module = "api" })

  for i, hunk in ipairs(hunks) do
    -- Log each hunk for debugging
    log.debug(
      string.format("Hunk %d: start=%d, delete=%d, insert=%d lines", i, hunk.start, hunk.delete, #hunk.insert),
      { module = "api" }
    )

    -- Validate hunk bounds
    if hunk.start < 0 then
      return false, string.format("Hunk %d has negative start position: %d", i, hunk.start)
    end

    if hunk.start >= line_count then
      return false, string.format("Hunk %d start position %d exceeds buffer size %d", i, hunk.start, line_count)
    end

    if hunk.delete < 0 then
      return false, string.format("Hunk %d has negative delete count: %d", i, hunk.delete)
    end

    if hunk.start + hunk.delete > line_count then
      return false,
        string.format(
          "Hunk %d delete range [%d, %d) exceeds buffer size %d",
          i,
          hunk.start,
          hunk.start + hunk.delete,
          line_count
        )
    end

    if not hunk.insert or type(hunk.insert) ~= "table" then
      return false, string.format("Hunk %d has invalid insert data", i)
    end

    -- Log the actual content being changed
    if hunk.delete > 0 then
      local existing_lines = vim.api.nvim_buf_get_lines(bufnr, hunk.start, hunk.start + hunk.delete, false)
      log.debug(string.format("Hunk %d deleting: %s", i, vim.inspect(existing_lines)), { module = "api" })
    end
    if #hunk.insert > 0 then
      log.debug(string.format("Hunk %d inserting: %s", i, vim.inspect(hunk.insert)), { module = "api" })
    end
  end

  return true, nil
end

--- Apply diff hunks to buffer with per-hunk API (single undo entry)
---@param bufnr integer Buffer number
---@param hunks checkmate.DiffHunk[]
function M.apply_diff(bufnr, hunks)
  local log = require("checkmate.log")
  if vim.tbl_isempty(hunks) then
    return
  end

  local valid, error_msg = validate_and_debug_hunks(bufnr, hunks)
  if not valid then
    log.error("Hunk validation failed: " .. error_msg, { module = "api" })
    return false, error_msg
  end

  local api = vim.api

  -- Sort hunks by start position (descending - highest line first)
  table.sort(hunks, function(a, b)
    return a.start > b.start
  end)

  -- Apply all hunks (first one creates undo entry, rest join)
  for i, h in ipairs(hunks) do
    if i > 1 then
      vim.cmd("silent! undojoin")
    end
    api.nvim_buf_set_lines(bufnr, h.start, h.start + h.delete, false, h.insert)
  end
end

-----------------------------------------------------------
-- Bulk context API
--[[
-- What does this solve?
--  - In the prior version, if an api function operated on multiple todo items, callbacks were individually run on 
--  each todo item. E.g. If add_metadata was called on 100 items, then on_add callback (which might call set_todo_item)
--  was called 100 times, which was terrible for performance.
--  - Now, these callbacks are queued and deduped, such that the primary api function runs first, all callbacks are queued,
--  and at the end run in batch 
--
--]]

M._bulk_context = {
  active = false,
  depth = 0,
  pending_changes = {},
  queued_operations = {},
  post_process_fn = nil, -- will run once after all queued_operations complete
}

-- Helper to start a bulk operation
function M._start_bulk_operation()
  local ctx = M._bulk_context
  ctx.active = true
  ctx.depth = 0
  ctx.pending_changes = {}
  ctx.queued_operations = {}
  ctx.post_process_fn = nil
end

-- Helper to end bulk operation and process all queued changes
function M._end_bulk_operation(bufnr)
  local ctx = M._bulk_context
  if not ctx.active then
    return {}
  end

  local pending_changes = M._bulk_context.pending_changes

  -- Reset context
  ctx.active = false
  ctx.depth = 0
  ctx.pending_changes = {}
  ctx.queued_operations = {}
  ctx.post_process_fn = nil

  -- Process the pending changes into hunks
  if #pending_changes > 0 then
    return M._process_pending_changes(bufnr, pending_changes)
  end

  return {}
end

-- Helper to queue a change during bulk operation
function M._queue_bulk_change(change)
  if not M._bulk_context.active then
    return false
  end

  -- Create a unique key to prevent duplicate operations
  local key = string.format(
    "%s:%d:%d:%s",
    change.type,
    change.todo_item.range.start.row,
    change.todo_item.range.start.col,
    tostring(change.target_state or change.meta_name or "")
  )

  -- Avoid queueing duplicate operations
  if not M._bulk_context.queued_operations[key] then
    M._bulk_context.queued_operations[key] = true
    table.insert(M._bulk_context.pending_changes, change)
  end

  return true
end

---@param bufnr integer Buffer number
---@param todo_items checkmate.TodoItem[]
---@param main_op_fn fun(items: checkmate.TodoItem[]) Function that will perform the operation(computing + applying the initial diff)
---@param post_process_fn fun()? Called after all changes have been applied (e.g. for highlighting or post-processing)
function M.with_bulk_context(bufnr, todo_items, main_op_fn, post_process_fn)
  local api = require("checkmate.api")
  local ctx = api._bulk_context

  -- Track if we are the outermost caller
  local is_outermost = not ctx.active

  if is_outermost then
    ctx.active = true
    ctx.depth = 1
    ctx.pending_changes = {}
    ctx.queued_operations = {}
    ctx.post_process_fn = post_process_fn
  else
    ctx.depth = ctx.depth + 1
    -- Only allow post_process_fn from the outermost call
  end

  main_op_fn(todo_items)

  -- Only process queued changes on outermost context exit
  local bulk_hunks = {}
  ctx.depth = ctx.depth - 1
  if is_outermost then
    ctx.active = false
    local pending_changes = ctx.pending_changes
    ctx.pending_changes = {}
    ctx.queued_operations = {}
    local fn = ctx.post_process_fn
    ctx.post_process_fn = nil

    if #pending_changes > 0 then
      bulk_hunks = api._process_pending_changes(bufnr, pending_changes)
      if #bulk_hunks > 0 then
        api.apply_diff(bufnr, bulk_hunks)
      end
    end

    -- Run post-processing once at the end
    if fn then
      fn()
    end
  end
end

-- Process all pending changes into diff hunks
function M._process_pending_changes(bufnr, pending_changes)
  local profiler = require("checkmate.profiler")

  profiler.start("api._process_pending_changes")
  local hunks = {}
  local changes_by_type = {}

  -- Group changes by type for efficient processing
  for _, change in ipairs(pending_changes) do
    changes_by_type[change.type] = changes_by_type[change.type] or {}
    table.insert(changes_by_type[change.type], change)
  end

  -- Process toggle state changes
  if changes_by_type.toggle_state then
    -- Group by target state
    local by_state = {}
    for _, change in ipairs(changes_by_type.toggle_state) do
      local state = change.target_state
      by_state[state] = by_state[state] or {}
      table.insert(by_state[state], change.todo_item)
    end

    -- Compute diffs for each target state
    for target_state, items in pairs(by_state) do
      local state_hunks = M.compute_diff_toggle(items, target_state)
      for _, hunk in ipairs(state_hunks) do
        table.insert(hunks, hunk)
      end
    end
  end

  -- Process metadata additions
  if changes_by_type.add_metadata then
    -- Group by metadata name and value
    local by_meta = {}
    for _, change in ipairs(changes_by_type.add_metadata) do
      local key = change.meta_name .. "|" .. (change.value or "")
      by_meta[key] = by_meta[key]
        or {
          meta_name = change.meta_name,
          value = change.value,
          items = {},
        }
      table.insert(by_meta[key].items, change.todo_item)
    end

    -- Compute diffs
    for _, meta_group in pairs(by_meta) do
      local meta_hunks = M.compute_diff_add_metadata(meta_group.items, meta_group.meta_name, meta_group.value)
      for _, hunk in ipairs(meta_hunks) do
        table.insert(hunks, hunk)
      end
    end
  end

  -- Process metadata removals
  if changes_by_type.remove_metadata then
    -- Group by metadata name
    local by_meta = {}
    for _, change in ipairs(changes_by_type.remove_metadata) do
      by_meta[change.meta_name] = by_meta[change.meta_name] or {}
      table.insert(by_meta[change.meta_name], change.todo_item)
    end

    -- Compute diffs
    for meta_name, items in pairs(by_meta) do
      local meta_hunks = M.compute_diff_remove_metadata(items, meta_name)
      for _, hunk in ipairs(meta_hunks) do
        table.insert(hunks, hunk)
      end
    end
  end

  profiler.stop("api._process_pending_changes")

  return hunks
end

return M
