---@class checkmate.Api
local M = {}

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
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  local util = require("checkmate.util")
  local config = require("checkmate.config")
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
          util.notify("Failed to save: conversion error", vim.log.levels.ERROR)
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

          -- Use schedule to set modified flag after command completes
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.bo[bufnr].modified = false
            end
          end)

          util.notify("File saved", vim.log.levels.INFO)
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
          parser.convert_markdown_to_unicode(bufnr)
          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          require("checkmate.highlights").apply_highlighting(
            bufnr,
            { todo_map = todo_map, debug_reason = "autocmd 'TextChanged'" }
          )
          require("checkmate.linter").lint_buffer(bufnr)
        end
      end,
    })

    -- Re-apply highlighting when text changes
    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = augroup,
      buffer = bufnr,
      callback = require("checkmate.util").debounce(function()
        local todo_map = require("checkmate.parser").discover_todos(bufnr)
        require("checkmate.highlights").apply_highlighting(
          bufnr,
          { todo_map = todo_map, debug_reason = "autocmd 'TextChanged'" }
        )
        require("checkmate.linter").lint_buffer(bufnr)
      end, { ms = 10 }),
    })
  end
end

---Toggles a todo item from checked to unchecked or vice versa
---@param todo_item checkmate.TodoItem The todo item to modify
---@param opts {target_state?: checkmate.TodoItemState, notify: boolean?}
---@return boolean success Whether the operation succeeded
function M.toggle_todo_item(todo_item, opts)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")
  local log = require("checkmate.log")

  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get the line with the todo marker
  local todo_line_row = todo_item.todo_marker.position.row
  local line = vim.api.nvim_buf_get_lines(bufnr, todo_line_row, todo_line_row + 1, false)[1]

  log.info(
    string.format("Found todo item at (editor) line %d (type: %s)", todo_line_row + 1, todo_item.state),
    { module = "api" }
  )

  local unchecked_marker = config.options.todo_markers.unchecked
  local checked_marker = config.options.todo_markers.checked

  -- Determine target state
  local target_state = opts.target_state
  if not target_state then
    -- Traditional toggle behavior
    target_state = todo_item.state == "unchecked" and "checked" or "unchecked"
  elseif target_state == todo_item.state then
    -- Already in target state, no change needed
    if opts.notify ~= false then
      util.notify("Todo item is already " .. target_state, log.levels.INFO)
    end
    return true
  end

  local patterns, replacement_marker

  if target_state == "checked" then
    patterns = util.build_unicode_todo_patterns(parser.list_item_markers, unchecked_marker)
    replacement_marker = checked_marker
  else
    patterns = util.build_unicode_todo_patterns(parser.list_item_markers, checked_marker)
    replacement_marker = unchecked_marker
  end

  -- Try to apply the first matching pattern
  local new_line
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
    return true
  else
    log.error("failed to replace todo marker during toggle", { module = "api" })
    return false
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

-- Function to apply metadata to a single todo item
---@param todo_item checkmate.TodoItem The todo item to modify
---@param opts {meta_name: string, custom_value: string?}
---@return boolean success Whether the operation succeeded
function M.apply_metadata(todo_item, opts)
  local log = require("checkmate.log")
  local config = require("checkmate.config")

  local bufnr = vim.api.nvim_get_current_buf()

  if not todo_item then
    return false
  end

  -- Get the metadata config
  local meta_name = opts.meta_name
  local meta_config = config.options.metadata[meta_name]
  if not meta_config then
    log.error("Metadata type '" .. meta_name .. "' is not configured", { module = "api" })
    return false
  end

  -- Get the first line of the todo item (where metadata should be added)
  local todo_row = todo_item.range.start.row
  local line = vim.api.nvim_buf_get_lines(bufnr, todo_row, todo_row + 1, false)[1]

  -- This is an error if the todo_item passed in doesn't have a legit line in the buffer...
  if not line or #line == 0 then
    return false
  end

  -- Determine the value to insert
  local value = opts.custom_value
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

  -- Jump the cursor, if enabled
  ---@type "tag" | "value" | false
  local jump_to = meta_config.jump_to_on_insert or false

  if jump_to ~= false then
    local updated_line = vim.api.nvim_buf_get_lines(bufnr, todo_row, todo_row + 1, false)[1]
    local tag_position = updated_line:find("@" .. meta_name .. "%(")
    local value_position = tag_position and updated_line:find("%(", tag_position) + 1 or nil

    -- ensure cursor movement happens after buffer update is complete
    vim.schedule(function()
      -- Safety checks before trying to set cursor position
      local win = vim.api.nvim_get_current_win()

      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(win) == bufnr then
        -- First set cursor position based on jump_to setting
        if jump_to == "tag" and tag_position then
          vim.api.nvim_win_set_cursor(0, { todo_row + 1, tag_position - 1 })

          -- Select the tag if enabled
          if meta_config.select_on_insert then
            -- Force normal mode first
            vim.cmd("stopinsert")
            -- Select the tag text (without the @ symbol)
            vim.cmd("normal! l" .. string.rep("l", #meta_name) .. "v" .. string.rep("h", #meta_name))
          end
        elseif jump_to == "value" and value_position then
          vim.api.nvim_win_set_cursor(0, { todo_row + 1, value_position - 1 })

          if meta_config.select_on_insert then
            -- Force normal mode first
            vim.cmd("stopinsert")

            local closing_paren = updated_line:find(")", value_position)
            if closing_paren and closing_paren > value_position then
              -- Select everything between value_position and closing_paren-1
              local selection_length = closing_paren - value_position
              if selection_length > 0 then
                -- Start visual mode and select the content
                vim.cmd("normal! v" .. string.rep("l", selection_length - 1))
              end
            end
          end
        end
      end
    end)
  end

  -- Call the on_add callback after successful operation
  if meta_config.on_add then
    meta_config.on_add(todo_item)
  end

  require("checkmate.highlights").apply_highlighting(bufnr, { debug_reason = "apply_metadata" })

  return true
end

-- Function to remove metadata from a single todo item
---@param todo_item checkmate.TodoItem The todo item to modify
---@param opts {meta_name: string}
---@return boolean success Whether the operation succeeded
function M.remove_metadata(todo_item, opts)
  local log = require("checkmate.log")
  local config = require("checkmate.config")
  local bufnr = vim.api.nvim_get_current_buf()

  if not todo_item then
    return false
  end

  local meta_name = opts.meta_name
  -- Check if metadata exists
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
    local todo_row = todo_item.range.start.row
    local line = vim.api.nvim_buf_get_lines(bufnr, todo_row, todo_row + 1, false)[1]

    -- This is an error if the todo_item passed in doesn't have a legit line in the buffer...
    if not line or #line == 0 then
      return false
    end

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

    -- Rebuild the line with sorted metadata
    local new_line = M.rebuild_line_with_sorted_metadata(line, updated_metadata)

    -- Update the line
    vim.api.nvim_buf_set_lines(bufnr, todo_row, todo_row + 1, false, { new_line })

    -- Call the on_remove callback if successful
    local meta_config = config.options.metadata[entry.tag] or config.options.metadata[entry.alias_for] or {}
    if meta_config.on_remove then
      meta_config.on_remove(todo_item)
    end

    require("checkmate.highlights").apply_highlighting(bufnr, { debug_reason = "remove_metadata" })

    log.debug("Removed metadata: " .. entry.tag, { module = "api" })
    return true
  end

  return false
end

-- Function to toggle metadata on a single todo item
---@param todo_item checkmate.TodoItem The todo item to modify
---@param opts {meta_name: string, custom_value: string?}
---@return boolean success Whether the operation succeeded
function M.toggle_metadata(todo_item, opts)
  local log = require("checkmate.log")

  if not todo_item then
    return false
  end

  local meta_name = opts.meta_name
  local custom_value = opts.custom_value

  -- Check if metadata exists (directly or via alias)
  local entry = todo_item.metadata.by_tag[meta_name]
  local canonical_name = meta_name

  -- Check for aliases
  if not entry then
    for c_name, props in pairs(require("checkmate.config").options.metadata) do
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
    return M.remove_metadata(todo_item, { meta_name = canonical_name })
  else
    -- It doesn't exist, add it
    log.debug("Toggling ON metadata: " .. canonical_name, { module = "api" })
    return M.apply_metadata(todo_item, {
      meta_name = canonical_name,
      custom_value = custom_value,
    })
  end
end

---Removes all metadata from a todo item
---@param todo_item checkmate.TodoItem
---@return boolean: Success
function M.remove_all_metadata(todo_item)
  if not todo_item then
    return false
  end

  local log = require("checkmate.log")
  local config = require("checkmate.config")

  local bufnr = vim.api.nvim_get_current_buf()

  -- Store the callbacks to run after successful operation
  local callbacks = {}

  -- Collect the callbacks, but don't run them yet
  for _, entry in ipairs(todo_item.metadata.entries) do
    local meta_config = config.options.metadata[entry.tag] or config.options.metadata[entry.alias_for] or {}
    if meta_config.on_remove then
      table.insert(callbacks, {
        tag = entry.tag,
        func = meta_config.on_remove,
      })
    end
  end

  todo_item.metadata.entries = {}
  todo_item.metadata.by_tag = {}

  local updated_metadata = vim.deepcopy(todo_item.metadata)

  local row = todo_item.range.start.row

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

  -- Rebuild the line with sorted metadata
  local new_line = M.rebuild_line_with_sorted_metadata(line, updated_metadata)

  -- Update the line
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })

  -- Run all callbacks after successful update
  for _, item in ipairs(callbacks) do
    log.debug(
      ("running on_remove callback for metadata %s on todo_item on row %d"):format(
        item.tag,
        todo_item.range.start.row + 1
      )
    )
    item.func(todo_item)
  end

  require("checkmate.highlights").apply_highlighting(bufnr, { debug_reason = "remove_all_metadata" })

  log.debug("Removed all metadata from todo item on row " .. row + 1, { module = "api" })

  return true
end

---A callback function passed to `apply_todo_operation` that will act on the given todo_item
---params
---  notify - whether to allow notify for this operation. This allows notify to be turned off
---  if an operation is run in visual selection mode, i.e. so we don't get a bunch of notifications for one action
---@alias checkmate.TodoOperation fun(todo_item: checkmate.TodoItem, params: {notify: boolean?}): boolean

---@class ApplyTodoOperationOpts table Operation configuration
---@field operation checkmate.TodoOperation The operation to perform on each todo item
---@field is_visual boolean Whether to process a visual selection (true) or cursor position (false)
---@field action_name string Human-readable name of the action (for logging and notifications)
---@field params any? Additional parameters to pass to the operation function, excluding the todo_item

---Apply an operation to todo items either at cursor or in a visual selection
---@param opts ApplyTodoOperationOpts
---@return table results Operation results { success: boolean, processed: number, succeeded: number, errors: table[] }
function M.apply_todo_operation(opts)
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local bufnr = vim.api.nvim_get_current_buf()

  -- Initialize results
  local results = {
    success = false,
    processed = 0,
    succeeded = 0,
    errors = {},
  }

  if not config.get_active_buffers()[bufnr] then
    util.notify("attempted to apply_todo_operation on non-existent buffer", log.levels.WARN)
    return results
  end

  -- Collection of todo items to process
  local todo_items = {}

  -- Save current cursor state
  local cursor_state = util.Cursor.save()

  -- Get todo items based on mode (visual or normal)
  if opts.is_visual then
    -- Exit visual mode first
    vim.cmd([[execute "normal! \<Esc>"]])

    -- Get visual selection range
    local start_line = vim.fn.line("'<") - 1 -- 0-indexed
    local end_line = vim.fn.line("'>") - 1 -- 0-indexed

    log.debug(
      string.format("Visual mode %s from line %d to %d", opts.action_name, start_line + 1, end_line + 1),
      { module = "api" }
    )

    -- Perform full parsing of buffer only once for this operation
    local full_todo_map = parser.discover_todos(bufnr)

    -- Collect unique todo items in selection
    local selected_todo_map = {}

    for line_row = start_line, end_line do
      local todo_item = parser.get_todo_item_at_position(
        bufnr,
        line_row,
        0,
        { todo_map = full_todo_map, max_depth = config.options.todo_action_depth }
      )

      if todo_item then
        -- Create a unique key based on the marker position
        local marker_key =
          string.format("%d:%d", todo_item.todo_marker.position.row, todo_item.todo_marker.position.col)

        if not selected_todo_map[marker_key] then
          selected_todo_map[marker_key] = true
          table.insert(todo_items, todo_item)
        end
      end
    end
  else
    -- Normal mode - just get the item at cursor
    local row = cursor_state.cursor[1] - 1 -- 0-indexed
    local col = cursor_state.cursor[2]

    local todo_item =
      parser.get_todo_item_at_position(bufnr, row, col, { max_depth = config.options.todo_action_depth })

    if todo_item then
      table.insert(todo_items, todo_item)
    end
  end

  -- Process collected todo items
  if #todo_items > 0 then
    for _, todo_item in ipairs(todo_items) do
      results.processed = results.processed + 1

      -- We pass a notify=false option to the todo operation so that notifications
      -- can be ignored when multiple todos are being actioned
      local params = vim.tbl_extend("force", opts.params or {}, { notify = #todo_items < 2 })

      -- Apply the operation and catch any errors
      local success, result = pcall(opts.operation, todo_item, params)

      if success and result then
        results.succeeded = results.succeeded + 1
      else
        -- Handle error
        local error_msg = (not success and result) or "Operation failed"
        table.insert(results.errors, {
          item = todo_item,
          message = error_msg,
        })
        log.error(string.format("Error in %s: %s", opts.action_name, error_msg), { module = "api" })
      end
    end

    -- Determine overall success
    results.success = (results.succeeded > 0)

    -- Apply highlighting after all operations
    if results.succeeded > 0 then
      require("checkmate.highlights").apply_highlighting(bufnr, {
        debug_reason = opts.action_name,
      })

      -- Notify user of results
      if opts.is_visual and results.processed > 1 then
        util.notify(
          string.format("Checkmate: %s %d items", opts.action_name:gsub("^%l", string.upper), results.succeeded),
          vim.log.levels.INFO
        )
      end
    end
  else
    -- No todo items found
    local mode_msg = opts.is_visual and "selection" or "cursor position"
    util.notify(string.format("No todo items found at %s", mode_msg), vim.log.levels.INFO)
  end

  -- Restore cursor position
  util.Cursor.restore(cursor_state)

  return results
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

return M
