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

  -- Enable Treesitter highlighting
  vim.api.nvim_set_option_value("syntax", "OFF", { buf = bufnr })
  vim.cmd("TSBufDisable highlight")

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
      log.warn(string.format("Unknown action '%s' for mapping '%s'", action_name, key), { module = "keymaps" })
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

      log.debug(string.format("Mapping %s mode key %s to %s", mode, key, action_name), { module = "keymaps" })
      vim.api.nvim_buf_set_keymap(bufnr, mode, key, string.format("<cmd>%s<CR>", action.command), {
        noremap = true,
        silent = true,
        desc = mode_desc,
      })
    end

    ::continue::
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
local function handle_toggle(bufnr, line_row, col, opts)
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
  local error, success = handle_toggle(bufnr, row, col, { target_state = target_state })

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
      handle_toggle(bufnr, nil, nil, { existing_todo_item = todo_item, target_state = target_state })
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

return M
