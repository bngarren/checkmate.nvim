---@class checkmate.Api
local M = {}

function M.setup(bufnr)
  local parser = require("checkmate.parser")
  local highlights = require("checkmate.highlights")

  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Checkmate: Invalid buffer", vim.log.levels.ERROR)
    return false
  end

  -- Convert markdown to Unicode
  parser.convert_markdown_to_unicode(bufnr)

  -- Apply highlighting
  highlights.apply_highlighting(bufnr)

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
  }

  for key, action_name in pairs(keys) do
    -- Skip if mapping is explicitly disabled with false
    if action_name == false then
      goto continue
    end

    -- Check if action exists
    local action = actions[action_name]
    if not action then
      log.warn(string.format("Unknown action '%s' for mapping '%s'", action_name, key), { module = "api" })
      goto continue
    end

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

    ::continue::
  end

  -- Setup metadata keymaps
  if config.options.use_metadata_keymaps then
    -- For each metadata tag with a key defined
    for meta_name, meta_props in pairs(config.options.metadata) do
      if meta_props.key then
        -- Map the key to the quick_metadata function
        log.debug("Mapping n mode key " .. meta_props.key .. " to metadata." .. meta_name, { module = "api" })

        vim.api.nvim_buf_set_keymap(
          bufnr,
          "n",
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

function M.setup_autocmds(bufnr)
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  local augroup = vim.api.nvim_create_augroup("CheckmateApiGroup_" .. bufnr, { clear = true })

  if not vim.b[bufnr].checkmate_autocmds_setup then
    -- We create a temporary buffer that the user never sees. We convert to markdown in the temp buffer.
    -- Then, manually write to file using io lib. We mark the real buffer as saved without ever modifying it.
    -- The user continues to see their Unicode style todo items and highlighting.
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local filename = vim.api.nvim_buf_get_name(bufnr)

        -- Create a temporary buffer (hidden from user)
        local temp_bufnr = vim.api.nvim_create_buf(false, true)

        -- Copy content to temp buffer
        vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, current_lines)

        -- Convert Unicode to markdown in the temporary buffer
        local success = parser.convert_unicode_to_markdown(temp_bufnr)

        if not success then
          log.error("Failed to convert Unicode to Markdown", { module = "api" })
          vim.api.nvim_buf_delete(temp_bufnr, { force = true })
          return false
        end

        -- Get the converted markdown content
        local markdown_lines = vim.api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)

        -- Write directly to file
        local file = io.open(filename, "w")
        if file then
          for _, line in ipairs(markdown_lines) do
            file:write(line .. "\n")
          end
          file:close()

          -- Mark buffer as saved
          vim.bo[bufnr].modified = false

          -- Clean up temp buffer
          vim.api.nvim_buf_delete(temp_bufnr, { force = true })

          -- Signal success
          vim.api.nvim_echo({ { "File saved" } }, false, {})
          return true
        else
          -- Signal failure
          vim.api.nvim_echo({ { "Failed to write file", "ErrorMsg" } }, false, {})
          vim.api.nvim_buf_delete(temp_bufnr, { force = true })
          return false
        end
      end,
    })

    -- When leaving insert mode, detect and convert any manually typed todo items
    vim.api.nvim_create_autocmd("InsertLeave", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        if vim.bo[bufnr].modified then
          parser.convert_markdown_to_unicode(bufnr)
          require("checkmate.highlights").apply_highlighting(bufnr)
        end
      end,
    })

    -- Re-apply highlighting when text changes
    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = augroup,
      buffer = bufnr,
      callback = require("checkmate.util").debounce(function()
        require("checkmate.highlights").apply_highlighting(bufnr)
      end, { ms = 50 }),
    })

    -- Mark autocmds as set up
    vim.b[bufnr].checkmate_autocmds_setup = true
  end
end

---Toggles or sets a todo item's state
---@param bufnr integer Buffer number
---@param line_row integer? Row to search for todo item
---@param col integer? Col to search for todo item
---@param opts? {existing_todo_item?: checkmate.TodoItem, target_state?: "checked"|"unchecked"} Options
---@return string? error, checkmate.TodoItem? todo_item
function M.handle_toggle(bufnr, line_row, col, opts)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  opts = opts or {}

  -- Get todo item - either use provided one or find at position
  local todo_item = opts.existing_todo_item
  if not todo_item then
    todo_item = parser.get_todo_item_at_position(bufnr, line_row, col, {
      max_depth = config.options.todo_action_depth,
    })
  end

  if not todo_item then
    return "No todo item found at position", nil
  end

  -- Get the line with the todo marker - use the row from the todo_item's range
  local todo_line_row = todo_item.todo_marker.position.row
  local line = vim.api.nvim_buf_get_lines(bufnr, todo_line_row, todo_line_row + 1, false)[1]

  log.info(
    string.format("Found todo item at (editor) line %d (type: %s)", todo_line_row + 1, todo_item.state),
    { module = "api" }
  )
  log.debug("Line content: '" .. line .. "'", { module = "api" })

  local unchecked_marker = config.options.todo_markers.unchecked
  local checked_marker = config.options.todo_markers.checked

  -- Determine target state based on options
  -- i.e. do we simply toggle, or do we set to a specific state only?
  local target_state = opts.target_state
  if not target_state then
    -- Traditional toggle behavior
    target_state = todo_item.state == "unchecked" and "checked" or "unchecked"
  elseif target_state == todo_item.state then
    -- Already in target state, no change needed
    log.debug("Todo item already in target state: " .. target_state, { module = "api" })
    return nil, todo_item
  end

  local patterns, replacement_marker

  if target_state == "checked" then
    patterns = util.build_unicode_todo_patterns(parser.list_item_markers, unchecked_marker)
    replacement_marker = checked_marker
    log.debug("Setting to checked", { module = "api" })
  else
    patterns = util.build_unicode_todo_patterns(parser.list_item_markers, checked_marker)
    replacement_marker = unchecked_marker
    log.debug("Setting to unchecked", { module = "api" })
  end

  local new_line

  -- Try to apply the first matching pattern
  for _, pattern in ipairs(patterns) do
    local replaced, count = line:gsub(pattern, "%1" .. replacement_marker, 1)
    if count > 0 then
      new_line = replaced
      break
    end
  end

  if new_line and new_line ~= line then
    vim.api.nvim_buf_set_lines(bufnr, todo_line_row, todo_line_row + 1, false, { new_line })
    log.debug("Successfully toggled todo item", { module = "api" })

    -- Update the todo item's state to reflect the change
    todo_item.state = target_state

    return nil, todo_item
  else
    log.error("failed to replace (gsub) todo marker during toggle", { module = "api" })
  end

  return "Failed to update todo item", nil
end

-- Toggle the todo item under the cursor
---@param target_state checkmate.TodoItemState?
function M.toggle_todo_at_cursor(target_state)
  local log = require("checkmate.log")
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  log.debug(string.format("Toggle called with cursor at row=%d, col=%d", row, col), { module = "api" })

  -- Try to toggle the item
  local error, success = M.handle_toggle(bufnr, row, col, { target_state = target_state })

  if success then
    -- Re-apply highlighting after toggle
    require("checkmate.highlights").apply_highlighting(bufnr)
  else
    log.debug("aborting toggle_todo_at_cursor: " .. error, { module = "api" })
    require("checkmate.util").notify("No todo item found at cursor position", vim.log.levels.INFO)
  end

  -- Restore cursor position
  vim.api.nvim_win_set_cursor(0, cursor)
end

-- Function for toggling multiple todo items (visual mode)
---@param target_state checkmate.TodoItemState?
function M.toggle_todo_visual(target_state)
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local bufnr = vim.api.nvim_get_current_buf()

  -- This needs to be executed BEFORE the following is run, since running a command exits visual mode
  -- We need to ensure we've exited visual mode properly and the marks are set
  vim.cmd([[execute "normal! \<Esc>"]])

  -- Get the start and end of visual selection
  local start_line = vim.fn.line("'<") - 1 -- 0-indexed
  local end_line = vim.fn.line("'>") - 1 -- 0-indexed

  log.debug(
    string.format("Visual mode toggle from (0-indexed) line %d to %d", start_line, end_line),
    { module = "api" }
  )

  -- First, collect all unique todo items by their marker position
  -- This is more reliable than node ID for identifying unique items
  local unique_todo_items = {}

  for line_row = start_line, end_line do
    local todo_item =
      parser.get_todo_item_at_position(bufnr, line_row, 0, { max_depth = config.options.todo_action_depth })

    if todo_item then
      -- Create a unique key based on the marker position
      local marker_key = string.format("%d:%d", todo_item.todo_marker.position.row, todo_item.todo_marker.position.col)

      if not unique_todo_items[marker_key] then
        -- Store the todo item using marker position as key
        unique_todo_items[marker_key] = todo_item
        log.debug(string.format("Found unique todo item at marker position %s", marker_key), { module = "api" })
      else
        log.debug(
          string.format("Already found todo item at marker position %s, skipping", marker_key),
          { module = "api" }
        )
      end
    end
  end

  -- Toggle each unique todo item only once
  local modified_count = 0
  for marker_key, todo_item in pairs(unique_todo_items) do
    -- Now toggle the item
    local error, success =
      M.handle_toggle(bufnr, nil, nil, { existing_todo_item = todo_item, target_state = target_state })
    if success then
      modified_count = modified_count + 1
      log.debug("Toggled todo item at marker position: " .. marker_key, { module = "api" })
    else
      log.warn("Could not toggle todo item: " .. (error or "unknown error"), { module = "api" })
    end
  end

  local notify = require("checkmate.util").notify

  -- Apply highlighting after all toggles
  if modified_count > 0 then
    require("checkmate.highlights").apply_highlighting(bufnr)
    log.debug(string.format("Successfully toggled %d todo items", modified_count), { module = "api" })
    notify(("Toggled %d todo items"):format(modified_count), vim.log.levels.INFO)
  else
    log.debug("No todo items found in visual selection", { module = "api" })
    notify("No todo items found in selection", vim.log.levels.INFO)
  end
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

  local todo_markers = config.options.todo_markers
  -- Check if line already has a task marker
  if line:match(todo_markers.unchecked) or line:match(todo_markers.checked) then
    log.debug("Line already has a todo marker, skipping", { module = "api" })
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
  require("checkmate.highlights").apply_highlighting(bufnr)

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
    log.debug("Removed all metadata tags from line", { module = "parser" })
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

--- Add or update a metadata tag to the current todo item
---@param meta_name string Name of the metadata to add/update
---@param custom_value? string Optional custom value (uses default get_value if nil)
---@return boolean
function M.apply_metadata(meta_name, custom_value)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  -- Find the todo item at cursor position
  local todo_item = parser.get_todo_item_at_position(bufnr, row, col, {
    max_depth = config.options.todo_action_depth,
  })

  if not todo_item then
    util.notify("Checkmate: No todo item found at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Get the metadata config
  local meta_config = config.options.metadata[meta_name]
  if not meta_config then
    util.notify("Checkmate: Metadata type '" .. meta_name .. "' is not configured", vim.log.levels.ERROR)
    return false
  end

  -- Get the first line of the todo item (where metadata should be added)
  local todo_row = todo_item.range.start.row
  local line = vim.api.nvim_buf_get_lines(bufnr, todo_row, todo_row + 1, false)[1]

  -- Determine the value to insert
  local value = custom_value
  if not value and meta_config.get_value then
    value = meta_config.get_value()
    -- trim whitespace
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
  elseif not value then
    value = ""
  end

  -- Check if this metadata already exists in the line
  local existing_entry = todo_item.metadata.by_tag[meta_name]

  -- Create an updated metadata structure
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
    log.debug("Updated existing metadata: " .. meta_name, { module = "api" })
  else
    -- Add new entry
    ---@type checkmate.MetadataEntry
    local new_entry = {
      tag = meta_name,
      value = value,
      range = {
        start = { row = todo_row, col = #line }, -- Will be at end of line
        ["end"] = { row = todo_row, col = #line + #meta_name + #value + 3 }, -- +3 for "@()"
      },
      position_in_line = #line + 1, -- Will be added at the end
    }
    table.insert(updated_metadata.entries, new_entry)
    updated_metadata.by_tag[meta_name] = new_entry
    log.debug("Added new metadata: " .. meta_name, { module = "api" })
  end

  -- Rebuild the line with sorted metadata
  local new_line = M.rebuild_line_with_sorted_metadata(line, updated_metadata)

  -- Update the line
  vim.api.nvim_buf_set_lines(bufnr, todo_row, todo_row + 1, false, { new_line })

  -- Re-extract metadata to ensure consistency
  todo_item.metadata = parser.extract_metadata(new_line, todo_row)

  -- Reapply highlighting
  require("checkmate.highlights").apply_highlighting(bufnr)

  if meta_config.on_add then
    meta_config.on_add(todo_item)
  end

  return true
end

--- Remove a metadata tag from the current todo item
---@param meta_name string Name of the metadata to remove
---@return boolean
function M.remove_metadata(meta_name)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  -- Find the todo item at cursor position
  local todo_item = parser.get_todo_item_at_position(bufnr, row, col, {
    max_depth = config.options.todo_action_depth,
  })

  if not todo_item then
    util.notify("Checkmate: No todo item found at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Check if the metadata exists
  local entry = todo_item.metadata.by_tag[meta_name]
  if not entry then
    -- Check if it might be under an alias
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
    local todo_row = todo_item.range.start.row
    local line = vim.api.nvim_buf_get_lines(bufnr, todo_row, todo_row + 1, false)[1]

    -- Create a copy of the metadata with the entry removed
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

    -- Rebuild the line with sorted metadata
    log.debug("rebuilding line: " .. line)
    local new_line = M.rebuild_line_with_sorted_metadata(line, updated_metadata)

    -- Update the line
    vim.api.nvim_buf_set_lines(bufnr, todo_row, todo_row + 1, false, { new_line })

    -- Update the metadata
    todo_item.metadata = parser.extract_metadata(new_line, todo_row)

    -- Reapply highlighting
    require("checkmate.highlights").apply_highlighting(bufnr)

    local meta_config = config.options.metadata[entry.tag] or config.options.metadata[entry.alias_for] or {}
    if meta_config.on_remove then
      meta_config.on_remove(todo_item)
    end

    log.debug("Removed metadata: " .. entry.tag, { module = "api" })
    return true
  else
    util.notify("Checkmate: Metadata @" .. meta_name .. " not found on this todo item", vim.log.levels.INFO)
    return false
  end
end

--- Toggle a metadata tag on the current todo item
---@param meta_name string Name of the metadata to toggle
---@param custom_value? string Optional custom value to use when adding (uses default get_value if nil)
---@return boolean success
function M.toggle_metadata(meta_name, custom_value)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2]

  -- Find the todo item at cursor position
  local todo_item = parser.get_todo_item_at_position(bufnr, row, col, {
    max_depth = config.options.todo_action_depth,
  })

  if not todo_item then
    util.notify("Checkmate: No todo item found at cursor position", vim.log.levels.INFO)
    return false
  end

  -- Check if the metadata exists (directly or via alias)
  local entry = todo_item.metadata.by_tag[meta_name]
  local canonical_name = meta_name

  -- If not found, check for aliases
  if not entry then
    for c_name, props in pairs(config.options.metadata) do
      if c_name == meta_name then
        break -- Already using canonical name
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

  -- Toggle action
  if entry then
    -- It exists, remove it
    log.debug("Toggling OFF metadata: " .. canonical_name, { module = "api" })
    return M.remove_metadata(canonical_name)
  else
    -- It doesn't exist, add it
    log.debug("Toggling ON metadata: " .. canonical_name, { module = "api" })
    return M.apply_metadata(canonical_name, custom_value)
  end
end

return M
