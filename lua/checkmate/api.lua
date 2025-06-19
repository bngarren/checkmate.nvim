---Internal buffer operations API - not for public use
---For public API, see checkmate.init module

--[[
INDEXING CONVENTIONS:
- All row/col positions stored in data structures are 0-based byte positions
- string.find() returns 1-based positions - always subtract 1
- nvim_buf_set_text uses 0-based byte positions
- nvim_buf_set_extmark uses 0-based byte positions
- nvim_win_set_cursor uses 1-based row, 0-based byte column
- Ranges are end-exclusive (like Treesitter)
- Always use byte positions internally, only convert to char positions when absolutely necessary
--]]

---@class checkmate.Api
local M = {}

---@class checkmate.TextDiffHunk
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer
---@field insert string[]

--- Validates that the buffer is valid (per nvim) and Markdown filetype
function M.is_valid_buffer(bufnr)
  if not bufnr or type(bufnr) ~= "number" then
    vim.notify("Checkmate: Invalid buffer number", vim.log.levels.ERROR)
    return false
  end

  local ok, is_valid = pcall(vim.api.nvim_buf_is_valid, bufnr)
  if not ok or not is_valid then
    vim.notify("Checkmate: Invalid buffer", vim.log.levels.ERROR)
    return false
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    vim.notify("Checkmate: Buffer is not markdown filetype", vim.log.levels.ERROR)
    return false
  end

  return true
end

---Callers should check `require("checkmate.file_matcher").should_activate_for_buffer()` before calling setup_buffer
function M.setup_buffer(bufnr)
  if not M.is_valid_buffer(bufnr) then
    return false
  end

  local config = require("checkmate.config")
  local checkmate = require("checkmate")

  if not checkmate.is_initialized() then
    checkmate.on_initialized(function()
      M.setup_buffer(bufnr)
    end)
    return false
  end

  if checkmate.is_buffer_active(bufnr) then
    if vim.b[bufnr].checkmate_setup_complete then
      return true
    end
  end

  checkmate.register_buffer(bufnr)

  local parser = require("checkmate.parser")
  parser.convert_markdown_to_unicode(bufnr)

  if config.options.linter and config.options.linter.enabled ~= false then
    local linter = require("checkmate.linter")
    linter.setup(config.options.linter)
    linter.lint_buffer(bufnr)
  end

  local highlights = require("checkmate.highlights")
  highlights.apply_highlighting(bufnr, { debug_reason = "API setup" })

  -- User can opt out of TS highlighting if desired
  if config.options.disable_ts_highlights == true then
    vim.treesitter.stop(bufnr)
  else
    vim.treesitter.start(bufnr, "markdown")
    vim.api.nvim_set_option_value("syntax", "off", { buf = bufnr })
  end

  M.setup_keymaps(bufnr)
  M.setup_autocmds(bufnr)

  vim.b[bufnr].checkmate_setup_complete = true

  return true
end

-- { bufnr = {mode, key}[] }
local buffer_local_keys = {}

function M.clear_keymaps(bufnr)
  -- clear buffer local keymaps
  local items = buffer_local_keys[bufnr]
  if not items or #items == 0 then
    return
  end
  for _, item in ipairs(items) do
    vim.api.nvim_buf_del_keymap(bufnr, item[1], item[2])
  end
  buffer_local_keys[bufnr] = {}
end

function M.setup_keymaps(bufnr)
  local config = require("checkmate.config")
  local log = require("checkmate.log")
  local keys = config.options.keys or {}

  local function buffer_map(_bufnr, mode, lhs, rhs, desc)
    local opts = { buffer = _bufnr, silent = true, desc = desc }
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  local has_wk, wk = pcall(require, "which-key")

  -- TODO: need further which-key integration
  if has_wk then
    wk.add({
      "<leader>T",
      buffer = bufnr,
      group = "Checkmate [T]odos",
      icon = "⊡",
    })
  end

  buffer_local_keys[bufnr] = {}

  -- map legacy actions to commands
  ---@deprecated TODO: Remove in v0.10
  local action_to_command = {
    toggle = { cmd = "Checkmate toggle", desc = "Toggle todo item" },
    check = { cmd = "Checkmate check", desc = "Check todo item" },
    uncheck = { cmd = "Checkmate uncheck", desc = "Uncheck todo item" },
    create = { cmd = "Checkmate create", desc = "Create todo item" },
    remove_all_metadata = { cmd = "Checkmate remove_all_metadata", desc = "Remove all metadata" },
    archive = { cmd = "Checkmate archive", desc = "Archive completed todos" },
    select_metadata_value = { cmd = "Checkmate metadata select_value", desc = "Select metadata value" },
    jump_next_metadata = { cmd = "Checkmate metadata jump_next", desc = "Jump to next metadata" },
    jump_previous_metadata = { cmd = "Checkmate metadata jump_previous", desc = "Jump to previous metadata" },
  }

  -- pre v0.9
  local deprecated_actions = {}

  local DEFAULT_DESC = "Checkmate <unnamed>"
  local DEFAULT_MODES = { "n" }

  for key, value in pairs(keys) do
    if value ~= false then
      ---@type checkmate.KeymapConfig
      local mapping_config = {}

      -- backwards comptability
      if type(value) == "string" then
        table.insert(deprecated_actions, value)
        local action_info = action_to_command[value]
        if action_info then
          mapping_config = {
            rhs = "<cmd>" .. action_info.cmd .. "<CR>",
            desc = action_info.desc,
          }
        else
          log.warn(string.format("Unknown action '%s' for key '%s'", value, key), { module = "api" })
        end
        -- New table-based config
      elseif type(value) == "table" then
        -- sequence of {rhs, desc, modes}
        if value[1] ~= nil then
          local rhs, desc, modes = unpack(value)
          mapping_config = { rhs = rhs, desc = desc, modes = modes }
        else -- dict like table
          mapping_config = vim.deepcopy(value)
        end
      else
        log.warn(string.format("Invalid value type for key '%s'", key), { module = "api" })
      end

      if mapping_config and mapping_config.rhs then
        -- defaults
        mapping_config.modes = mapping_config.modes or DEFAULT_MODES
        mapping_config.desc = mapping_config.desc or DEFAULT_DESC

        for _, mode in ipairs(mapping_config.modes) do
          local success = false

          if mapping_config.rhs then
            success = pcall(function()
              buffer_map(bufnr, mode, key, mapping_config.rhs, mapping_config.desc)
            end)
          end

          if success then
            table.insert(buffer_local_keys[bufnr], { mode, key })
          end
        end
      end
    end
  end

  -- show deprecation warning
  if #deprecated_actions > 0 then
    vim.notify(
      string.format("Checkmate: deprecated config.keys entry for: %s", table.concat(deprecated_actions, ", ")),
      vim.log.levels.WARN
    )
  end

  -- Setup metadata keymaps
  if config.options.use_metadata_keymaps then
    for meta_name, meta_props in pairs(config.options.metadata) do
      if meta_props.key then
        local modes = { "n", "v" }

        -- Map metadata actions to both normal and visual modes
        for _, mode in ipairs(modes) do
          local key, desc
          -- we allow user to pass [key, desc] tuple
          if type(meta_props.key) == "table" then
            key = meta_props.key[1]
            desc = meta_props.key[2]
          else
            key = tostring(meta_props.key)
            desc = "Toggle '@" .. meta_name .. "' metadata"
          end

          local rhs = function()
            require("checkmate").toggle_metadata(meta_name)
          end

          log.debug("Mapping " .. mode .. " mode key " .. key .. " to metadata." .. meta_name, { module = "api" })

          buffer_map(bufnr, mode, key, rhs, desc)
          table.insert(buffer_local_keys[bufnr], { mode, key })
        end
      end
    end
  end
end

function M.setup_autocmds(bufnr)
  local augroup_name = "checkate_buffer_" .. bufnr
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

        -- Guard against re-entrancy
        -- Previously had bug due to setting modified flag causing BufWriteCmd to run multiple times
        if vim.b[bufnr]._checkmate_writing then
          return
        end
        vim.b[bufnr]._checkmate_writing = true

        local uv = vim.uv
        local was_modified = vim.bo[bufnr].modified

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
          vim.notify("Checkmate: Failed to save when attemping to convert to Markdown", vim.log.levels.ERROR)
          vim.b[bufnr]._checkmate_writing = false
          return false
        end

        local markdown_lines = vim.api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)

        local temp_filename = filename .. ".tmp"

        -- Write to temporary file first
        local write_result = vim.fn.writefile(markdown_lines, temp_filename, "b")

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
            vim.notify("Checkmate: Failed to save file", vim.log.levels.ERROR)
            vim.bo[bufnr].modified = was_modified
            vim.b[bufnr]._checkmate_writing = false
            return false
          end

          parser.convert_markdown_to_unicode(bufnr)

          -- For :wq to work, we need to set modified=false synchronously
          vim.bo[bufnr].modified = false
          vim.cmd("set nomodified")

          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.b[bufnr]._checkmate_writing = false
            end
          end, 0)

          util.notify("Saved", vim.log.levels.INFO)
        else
          -- Failed to write temp file
          -- Try to clean up
          pcall(function()
            uv.fs_unlink(temp_filename)
          end)
          util.notify("Failed to write file", vim.log.levels.ERROR)
          vim.bo[bufnr].modified = was_modified
          vim.b[bufnr]._checkmate_writing = nil

          return false
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "InsertLeave", "InsertEnter" }, {
      group = augroup,
      buffer = bufnr,
      callback = function(args)
        if vim.bo[bufnr].modified then
          M.process_buffer(bufnr, "full", args.event)
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = augroup,
      buffer = bufnr,
      callback = function()
        M.process_buffer(bufnr, "full", "TextChanged")
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChangedI" }, {
      group = augroup,
      buffer = bufnr,
      callback = function()
        M.process_buffer(bufnr, "highlight_only", "TextChangedI")
      end,
    })

    -- cleanup buffer when buffer is deleted
    vim.api.nvim_create_autocmd("BufDelete", {
      group = augroup,
      buffer = bufnr,
      callback = function()
        require("checkmate").unregister_buffer(bufnr)
        M._debounced_processors[bufnr] = nil
        -- clear the todo map cache for this buffer
        require("checkmate.parser").todo_map_cache[bufnr] = nil

        require("checkmate.metadata.picker").cleanup_ui(bufnr)
      end,
    })
    vim.b[bufnr].checkmate_autocmds_setup = true
  end
end

-- functions that process the buffer need to be debounced and stored
M._debounced_processors = {} -- bufnr -> { process_type -> debounced_fn }

-- we can "process" the buffer different ways depending on the need, the frequency we expect it
-- to occur, etc.
-- e.g. we don't want to convert during TextChangedI
M.PROCESS_CONFIGS = {
  full = {
    debounce_ms = 50,
    include_conversion = true,
    include_linting = true,
    include_highlighting = true,
  },
  highlight_only = {
    debounce_ms = 100,
    include_conversion = false,
    include_linting = false,
    include_highlighting = true,
  },
}

function M.process_buffer(bufnr, process_type, reason)
  local log = require("checkmate.log")

  process_type = process_type or "full"
  local process_config = M.PROCESS_CONFIGS[process_type]
  if not process_config then
    log.error("Unknown process type: " .. process_type, { module = "api" })
    return
  end

  if not M._debounced_processors[bufnr] then
    M._debounced_processors[bufnr] = {}
  end

  if not M._debounced_processors[bufnr][process_type] then
    local function process_impl()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        M._debounced_processors[bufnr] = nil
        return
      end

      local parser = require("checkmate.parser")
      local config = require("checkmate.config")
      local start_time = vim.uv.hrtime() / 1000000

      local todo_map = parser.get_todo_map(bufnr)

      if process_config.include_conversion then
        parser.convert_markdown_to_unicode(bufnr)
      end

      if process_config.include_highlighting then
        require("checkmate.highlights").apply_highlighting(
          bufnr,
          { todo_map = todo_map, debug_reason = "api process_buffer (" .. process_type .. ")" }
        )
      end

      if process_config.include_linting and config.options.linter and config.options.linter.enabled then
        require("checkmate.linter").lint_buffer(bufnr)
      end

      local end_time = vim.uv.hrtime() / 1000000
      local elapsed = end_time - start_time

      log.debug(
        ("Buffer processed (%s) in %d ms, reason: %s"):format(process_type, elapsed, reason or "unknown"),
        { module = "api" }
      )
    end

    M._debounced_processors[bufnr][process_type] = require("checkmate.util").debounce(process_impl, {
      ms = process_config.debounce_ms,
    })
  end

  M._debounced_processors[bufnr][process_type]()

  log.debug(
    ("Process (%s) scheduled for buffer %d, reason: %s"):format(process_type, bufnr, reason or "unknown"),
    { module = "api" }
  )
end

-- Cleans up all checkmate state associated with a buffer
function M.shutdown(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    -- Attemp to convert buffer back to Markdown to leave the buffer in an expected state
    pcall(require("checkmate.parser").convert_unicode_to_markdown, bufnr)

    local config = require("checkmate.config")

    M.clear_keymaps(bufnr)

    vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, config.ns_todos, 0, -1)

    if package.loaded["checkmate.linter"] then
      pcall(function()
        require("checkmate.linter").disable(bufnr)
      end)
    end

    local group_name = "checkate_buffer_" .. bufnr
    pcall(function()
      vim.api.nvim_del_augroup_by_name(group_name)
    end)

    vim.b[bufnr].checkmate_setup_complete = nil
    vim.b[bufnr].checkmate_autocmds_setup = nil

    if M._debounced_processors and M._debounced_processors[bufnr] then
      M._debounced_processors[bufnr] = nil
    end
  end
end

--- Create a hunk that replaces only the todo marker character
---@param row integer
---@param todo_item checkmate.TodoItem
---@param new_marker string
---@return checkmate.TextDiffHunk
local function make_marker_replacement_hunk(row, todo_item, new_marker)
  local old_marker = todo_item.todo_marker.text
  local byte_col = todo_item.todo_marker.position.col -- Already in bytes (0-indexed)
  local old_marker_byte_len = #old_marker

  return {
    start_row = row,
    start_col = byte_col,
    end_row = row,
    end_col = byte_col + old_marker_byte_len,
    insert = { new_marker },
  }
end

--- Create a hunk that replaces everything after the todo marker
---@param row integer
---@param todo_item checkmate.TodoItem
---@param old_line string
---@param new_line string
---@return checkmate.TextDiffHunk|nil
local function make_post_marker_replacement_hunk(row, todo_item, old_line, new_line)
  local marker_col = todo_item.todo_marker.position.col -- In bytes
  local marker_text = todo_item.todo_marker.text
  local marker_byte_len = #marker_text

  -- position after the marker (0-based)
  local content_start = marker_col + marker_byte_len

  -- extract the portion to replace (from marker end to line end)
  -- for string operations, convert to 1-based
  local old_suffix = old_line:sub(content_start + 1)
  local new_suffix = new_line:sub(content_start + 1)

  if old_suffix == new_suffix then
    return nil
  end

  -- make hunk
  return {
    start_row = row,
    start_col = content_start,
    end_row = row,
    end_col = content_start + #old_suffix,
    insert = { new_suffix },
  }
end

---@param ctx checkmate.TransactionContext Transaction context
---@param start_row number 0-based range start
---@param end_row number 0-based range end (inclusive)
---@param is_visual boolean true if from visual selection
---@return checkmate.TextDiffHunk[] hunks array of diff hunks or {}
function M.create_todos(ctx, start_row, end_row, is_visual)
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")

  local hunks = {}

  local bufnr = ctx.get_buf()

  if is_visual then
    -- for each line in the range, convert if not already a todo
    for row = start_row, end_row do
      local cur_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local state = parser.get_todo_item_state(cur_line)
      if state == nil then
        local new_hunks = M.compute_diff_convert_to_todo(bufnr, row)
        if new_hunks and #new_hunks > 0 then
          vim.list_extend(hunks, new_hunks)
        end
      end
    end
  else
    -- normal mode, is current line a todo?
    local row = start_row
    local todo_item = ctx.get_todo_by_row(row)

    if todo_item then
      local new_hunks = M.compute_diff_insert_todo_below(bufnr, row)
      if new_hunks and #new_hunks > 0 then
        vim.list_extend(hunks, new_hunks)

        if config.options.enter_insert_after_new then
          ctx.add_cb(function()
            local new_row = row + 1
            local new_line = vim.api.nvim_buf_get_lines(bufnr, new_row, new_row + 1, false)[1] or ""
            vim.api.nvim_win_set_cursor(0, { new_row + 1, #new_line })
            vim.cmd("startinsert!")
          end)
        end
      end
    else
      local new_hunks = M.compute_diff_convert_to_todo(bufnr, row)
      if new_hunks and #new_hunks > 0 then
        vim.list_extend(hunks, new_hunks)

        if config.options.enter_insert_after_new then
          ctx.add_cb(function()
            local new_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
            vim.api.nvim_win_set_cursor(0, { row + 1, #new_line })
            vim.cmd("startinsert!")
          end)
        end
      end
    end
  end

  return hunks
end

--- Convert a single line into an “unchecked” todo
---@param bufnr integer Buffer number
---@param row integer 0-based row to convert
---@return checkmate.TextDiffHunk[]
function M.compute_diff_convert_to_todo(bufnr, row)
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local parser = require("checkmate.parser")

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

  -- existing indentation
  local indent = line:match("^(%s*)") or ""

  -- does the line already already have a list marker
  local list_marker = util.match_first(
    util.create_list_prefix_patterns({
      simple_markers = parser.list_item_markers,
      use_numbered_list_markers = true,
      with_capture = true,
    }),
    line
  )

  local unchecked = config.options.todo_markers.unchecked
  local new_text

  if list_marker then
    -- keep the existing list marker (“- ” or “1. ”), just insert the unchecked todo marker
    new_text = line:gsub("^(" .. vim.pesc(list_marker) .. ")", "%1" .. unchecked .. " ")
  else
    local default_marker = config.options.default_list_marker or "-"
    new_text = indent .. default_marker .. " " .. unchecked .. " " .. line:gsub("^%s*", "")
  end

  return {
    {
      start_row = row,
      start_col = 0,
      end_row = row,
      end_col = -1, -- this will force apply_diff to use set_text rather than set_lines
      insert = { new_text },
    },
  }
end

--- Insert a new, empty “unchecked” todo directly below the given row.
---
---@param bufnr integer Buffer number
---@param row integer  -- 0-based row where we want to insert below
---@return checkmate.TextDiffHunk[]
function M.compute_diff_insert_todo_below(bufnr, row)
  local config = require("checkmate.config")
  local parser = require("checkmate.parser")

  local todo_map = parser.get_todo_map(bufnr)
  local cur_todo = parser.get_todo_item_at_position(bufnr, row, 0, { todo_map = todo_map })

  local indent, marker_text
  if cur_todo then
    local list_node = cur_todo.list_marker and cur_todo.list_marker.node
    if list_node then
      -- list_node:range() → { start_row, start_col, end_row, end_col }
      local sr, sc, _, ec = list_node:range()
      indent = string.rep(" ", sc)
      -- marker_text = text of the marker, e.g. "-" or "1."
      marker_text = vim.api.nvim_buf_get_text(bufnr, sr, sc, sr, ec - 1, {})[1]

      -- handle ordered lists by incrementing the number
      local num = marker_text:match("^(%d+)[.)]")
      if num then
        local delimiter = marker_text:match("[.)]")
        marker_text = tostring(tonumber(num) + 1) .. delimiter
      end
    else
      -- shouldn't get here..but oh well, a fallback
      indent = string.rep(" ", cur_todo.range.start.col)
      marker_text = config.options.default_list_marker or "-"
    end
  else
    indent = ""
    marker_text = config.options.default_list_marker or "-"
  end

  local new_row = row + 1
  local unchecked = config.options.todo_markers.unchecked or "□"
  local new_line = indent .. marker_text .. " " .. unchecked .. " "

  return {
    {
      start_row = new_row,
      start_col = 0,
      end_row = new_row,
      end_col = 0,
      insert = { new_line },
    },
  }
end

--- Compute diff hunks for toggling a batch of items with their target states
---@param items_with_states table[] Array of {item: checkmate.TodoItem, target_state: checkmate.TodoItemState}
---@return checkmate.TextDiffHunk[] hunks
function M.compute_diff_toggle(items_with_states)
  local config = require("checkmate.config")
  local profiler = require("checkmate.profiler")

  profiler.start("api.compute_diff_toggle")

  local hunks = {}

  for _, entry in ipairs(items_with_states) do
    local todo_item = entry.item
    local target_state = entry.target_state
    local row = todo_item.todo_marker.position.row

    local new_marker = target_state == "checked" and config.options.todo_markers.checked
      or config.options.todo_markers.unchecked

    local hunk = make_marker_replacement_hunk(row, todo_item, new_marker)
    table.insert(hunks, hunk)
  end

  profiler.stop("api.compute_diff_toggle")
  return hunks
end

--- Toggle state of todo item(s)
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, target_state: checkmate.TodoItemState}
---@return checkmate.TextDiffHunk[] hunks
function M.toggle_state(ctx, operations)
  local items_with_states = {}

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if item and item.state ~= op.target_state then
      table.insert(items_with_states, {
        item = item,
        target_state = op.target_state,
      })
    end
  end

  return M.compute_diff_toggle(items_with_states)
end

--- Set todo items to specific state
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, target_state: checkmate.TodoItemState}
---@return checkmate.TextDiffHunk[] hunks
function M.set_todo_item(ctx, operations)
  return M.toggle_state(ctx, operations)
end

---Toggle a batch of todo items with proper parent/child propagation
---i.e. 'smart toggle'
---@param ctx checkmate.TransactionContext Transaction context
---@param items checkmate.TodoItem[] List of initial todo items to toggle
---@param todo_map table<integer, checkmate.TodoItem>
---@param target_state? checkmate.TodoItemState Optional target state, otherwise toggle each item
function M.propagate_toggle(ctx, items, todo_map, target_state)
  local config = require("checkmate.config")
  local smart_config = config.options.smart_toggle

  local want = {} -- id -> desired state

  -- downward propagation
  local function mark_down(id, state, depth)
    if want[id] == state then
      return
    end

    want[id] = state

    -- determine if we should propagate to children
    local item = todo_map[id]
    if not item or not item.children or #item.children == 0 then
      return
    end

    local propagate_config = state == "checked" and smart_config.check_down or smart_config.uncheck_down

    if propagate_config == "none" then
      return
    elseif propagate_config == "direct_children" and depth > 0 then
      return -- only propagate to direct children (depth 0 -> 1)
    end

    for _, child_id in ipairs(item.children) do
      mark_down(child_id, state, depth + 1)
    end
  end

  -- initialize the downward pass for each selected item
  for _, item in ipairs(items) do
    local item_target_state = target_state
    if not item_target_state then
      -- if no explicit target, toggle based on current state
      item_target_state = (item.state == "unchecked") and "checked" or "unchecked"
    end

    mark_down(item.id, item_target_state, 0)
  end

  -- upward propagation

  -- helper checks if all relevant children are checked
  local function should_check_parent(parent_id)
    if smart_config.check_up == "none" then
      return false
    end

    local parent = todo_map[parent_id]
    if not parent or not parent.children or #parent.children == 0 then
      return true -- no children means we can check it
    end

    if smart_config.check_up == "direct_children" then
      -- check only direct children
      for _, child_id in ipairs(parent.children) do
        local child = todo_map[child_id]
        if not child then
          return false
        end
        local will_be_checked = want[child_id] == "checked" or (want[child_id] == nil and child.state == "checked")
        if not will_be_checked then
          return false
        end
      end
      return true
    else -- "all_children"
      -- check all descendants recursively
      local function all_descendants_checked(id)
        local item = todo_map[id]
        if not item then
          return false
        end

        local will_be_checked = want[id] == "checked" or (want[id] == nil and item.state == "checked")
        if not will_be_checked then
          return false
        end

        -- check all children recursively
        if item.children then
          for _, child_id in ipairs(item.children) do
            if not all_descendants_checked(child_id) then
              return false
            end
          end
        end

        return true
      end

      -- check all direct children and their descendants
      for _, child_id in ipairs(parent.children) do
        if not all_descendants_checked(child_id) then
          return false
        end
      end
      return true
    end
  end

  -- helper checks if parent should be unchecked
  local function should_uncheck_parent(parent_id)
    if smart_config.uncheck_up == "none" then
      return false
    end

    local parent = todo_map[parent_id]
    if not parent or not parent.children or #parent.children == 0 then
      return false -- no children means no reason to uncheck
    end

    if smart_config.uncheck_up == "direct_children" then
      -- check only direct children
      for _, child_id in ipairs(parent.children) do
        local child = todo_map[child_id]
        if child then
          local will_be_unchecked = want[child_id] == "unchecked"
            or (want[child_id] == nil and child.state == "unchecked")
          if will_be_unchecked then
            return true -- Any direct child unchecked
          end
        end
      end
      return false
    else -- "all_children"
      -- check all descendants recursively
      local function any_descendant_unchecked(id)
        local item = todo_map[id]
        if not item then
          return false
        end

        local will_be_unchecked = want[id] == "unchecked" or (want[id] == nil and item.state == "unchecked")
        if will_be_unchecked then
          return true
        end

        -- check all children recursively
        if item.children then
          for _, child_id in ipairs(item.children) do
            if any_descendant_unchecked(child_id) then
              return true
            end
          end
        end

        return false
      end

      -- check all direct children and their descendants
      for _, child_id in ipairs(parent.children) do
        if any_descendant_unchecked(child_id) then
          return true
        end
      end
      return false
    end
  end

  -- process upward propagation for checked items
  local function propagate_check_up(id)
    local item = todo_map[id]
    if not item or not item.parent_id then
      return
    end

    if should_check_parent(item.parent_id) then
      if want[item.parent_id] ~= "checked" then
        want[item.parent_id] = "checked"
        -- recursively propagate up
        propagate_check_up(item.parent_id)
      end
    end
  end

  -- process upward propagation for unchecked items
  local function propagate_uncheck_up(id)
    local item = todo_map[id]
    if not item or not item.parent_id then
      return
    end

    if should_uncheck_parent(item.parent_id) then
      if want[item.parent_id] ~= "unchecked" then
        want[item.parent_id] = "unchecked"
        -- recursively propagate up
        propagate_uncheck_up(item.parent_id)
      end
    end
  end

  -- run upward propagation based on what we're setting items to
  for id, desired_state in pairs(want) do
    if desired_state == "checked" then
      propagate_check_up(id)
    else -- unchecked
      propagate_uncheck_up(id)
    end
  end

  local operations = {}

  for id, desired_state in pairs(want) do
    local item = todo_map[id]
    if item and item.state ~= desired_state then
      table.insert(operations, {
        id = id,
        target_state = desired_state,
      })
    end
  end

  -- single batched operation with all state changes
  if #operations > 0 then
    ctx.add_op(M.toggle_state, operations)
  end
end

---@param items checkmate.TodoItem[]
---@param meta_name string Metadata tag name
---@param meta_value string Metadata default value
---@return checkmate.TextDiffHunk[], table<integer, {old_value: string, new_value: string}>
function M.compute_diff_add_metadata(items, meta_name, meta_value)
  local log = require("checkmate.log")
  local meta_module = require("checkmate.metadata")

  local meta_props = meta_module.get_meta_props(meta_name)
  if not meta_props then
    log.error("Metadata type '" .. meta_name .. "' is not configured", { module = "api" })
    return {}, {}
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}
  local changes = {} -- track for on_change callback

  for _, todo_item in ipairs(items) do
    local row = todo_item.range.start.row
    local original_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

    if original_line and #original_line ~= 0 then
      local value = meta_value

      -- check if metadata already exists
      local existing_entry = todo_item.metadata.by_tag[meta_name]

      local updated_metadata = vim.deepcopy(todo_item.metadata)

      if existing_entry then
        -- track for on_change callbacks
        if existing_entry.value ~= value then
          changes[todo_item.id] = {
            old_value = existing_entry.value,
            new_value = value,
          }
        end

        for i, entry in ipairs(updated_metadata.entries) do
          if entry.tag == existing_entry.tag then
            updated_metadata.entries[i].value = value
            break
          end
        end
        updated_metadata.by_tag[meta_name].value = value
      else
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

      -- rebuild line with sorted metadata
      local new_line = M.rebuild_line_with_sorted_metadata(original_line, updated_metadata)

      local hunk = make_post_marker_replacement_hunk(row, todo_item, original_line, new_line)
      if hunk then
        table.insert(hunks, hunk)
      end
    end
  end
  return hunks, changes
end

--- Add metadata to todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, meta_name: string, meta_value?: string}
---@return checkmate.TextDiffHunk[] hunks
function M.add_metadata(ctx, operations)
  local config = require("checkmate.config")
  local meta_module = require("checkmate.metadata")

  local bufnr = ctx.get_buf()
  local hunks = {}
  local to_jump = nil

  -- group by metadata type for callbacks
  local new_adds_by_meta = {} -- track new additions for on_add callbacks
  local changes_by_meta = {} -- track changes for on_change callbacks

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if not item then
      return {}
    end

    local meta_props = meta_module.get_meta_props(op.meta_name)
    if not meta_props then
      return {}
    end

    -- get value with fallback to get_value()
    local context = meta_module.create_context(item, op.meta_name, "", bufnr)
    local meta_value = op.meta_value or meta_module.evaluate_value(meta_props, context) or ""

    local item_hunks, item_changes = M.compute_diff_add_metadata({ item }, op.meta_name, meta_value)
    vim.list_extend(hunks, item_hunks)

    -- add callbacks
    if item_changes[item.id] then
      changes_by_meta[op.meta_name] = changes_by_meta[op.meta_name] or {}
      table.insert(changes_by_meta[op.meta_name], {
        id = op.id,
        old_value = item_changes[item.id].old_value,
        new_value = item_changes[item.id].new_value,
      })
    elseif not item.metadata.by_tag[op.meta_name] and meta_props.on_add then
      -- only queue on_add if it's actually a new addition
      new_adds_by_meta[op.meta_name] = new_adds_by_meta[op.meta_name] or {}
      table.insert(new_adds_by_meta[op.meta_name], op.id)
    end

    -- track jump target (for single item operations)
    if #operations == 1 and meta_props.jump_to_on_insert then
      to_jump = { item = item, meta_name = op.meta_name, meta_config = meta_props }
    end
  end

  -- queue on_add cbs
  for meta_name, ids in pairs(new_adds_by_meta) do
    local meta_config = config.options.metadata[meta_name]
    for _, id in ipairs(ids) do
      ctx.add_cb(function(tx_ctx)
        local updated_item = tx_ctx.get_todo_by_id(id)
        if updated_item then
          meta_config.on_add(updated_item)
        end
      end)
    end
  end

  -- queue on_change cbs
  for meta_name, changes in pairs(changes_by_meta) do
    local meta_config = config.options.metadata[meta_name]
    if meta_config.on_change then
      for _, change in ipairs(changes) do
        ctx.add_cb(function(tx_ctx)
          local updated_item = tx_ctx.get_todo_by_id(change.id)
          if updated_item then
            meta_config.on_change(updated_item, change.old_value, change.new_value)
          end
        end)
      end
    end
  end

  if to_jump then
    M._handle_metadata_cursor_jump(bufnr, to_jump.item, to_jump.meta_name, to_jump.meta_config)
  end

  return hunks
end

--- Compute diff hunks for removing metadata from todo items
---@param items checkmate.TodoItem[]
---@param meta_name string Metadata tag name
---@return checkmate.TextDiffHunk[]
function M.compute_diff_remove_metadata(items, meta_name)
  local util = require("checkmate.util")
  local meta_module = require("checkmate.metadata")

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  -- batch read all required lines
  local rows = {}
  for _, item in ipairs(items) do
    table.insert(rows, item.todo_marker.position.row)
  end
  local lines = util.batch_get_lines(bufnr, rows)

  for _, todo_item in ipairs(items) do
    local row = todo_item.range.start.row
    local original_line = lines[row]

    if original_line and #original_line ~= 0 then
      local entry = todo_item.metadata.by_tag[meta_name]
      if not entry then
        -- Check for aliases
        local canonical = meta_module.get_canonical_name(meta_name)
        if canonical then
          entry = todo_item.metadata.by_tag[canonical]
        end
      end

      if entry then
        local updated_metadata = vim.deepcopy(todo_item.metadata)

        -- remove from entries
        for i = #updated_metadata.entries, 1, -1 do
          if updated_metadata.entries[i].tag == entry.tag then
            table.remove(updated_metadata.entries, i)
            break
          end
        end

        -- remove from by_tag
        updated_metadata.by_tag[entry.tag] = nil
        if entry.alias_for then
          updated_metadata.by_tag[entry.alias_for] = nil
        end

        local new_line = M.rebuild_line_with_sorted_metadata(original_line, updated_metadata)

        local hunk = make_post_marker_replacement_hunk(row, todo_item, original_line, new_line)
        if hunk then
          table.insert(hunks, hunk)
        end
      end
    end
  end

  return hunks
end

--- Remove metadata from todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, meta_name: string}
---@return checkmate.TextDiffHunk[] hunks
function M.remove_metadata(ctx, operations)
  local config = require("checkmate.config")
  local hunks = {}
  local callbacks_by_meta = {}

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if item and item.metadata.by_tag and item.metadata.by_tag[op.meta_name] then
      local item_hunks = M.compute_diff_remove_metadata({ item }, op.meta_name)
      vim.list_extend(hunks, item_hunks)

      local meta_config = config.options.metadata[op.meta_name]
      if meta_config and meta_config.on_remove then
        callbacks_by_meta[op.meta_name] = callbacks_by_meta[op.meta_name] or {}
        table.insert(callbacks_by_meta[op.meta_name], op.id)
      end
    end
  end

  for meta_name, ids in pairs(callbacks_by_meta) do
    local meta_config = config.options.metadata[meta_name]
    for _, id in ipairs(ids) do
      ctx.add_cb(function(tx_ctx)
        local updated_item = tx_ctx.get_todo_by_id(id)
        if updated_item then
          meta_config.on_remove(updated_item)
        end
      end)
    end
  end

  return hunks
end

--- Compute diff hunks for removing all metadata from todo items
---@param items checkmate.TodoItem[]
---@return checkmate.TextDiffHunk[]
function M.compute_diff_remove_all_metadata(items)
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local hunks = {}

  -- batch read all required lines
  local rows = {}
  for _, item in ipairs(items) do
    table.insert(rows, item.todo_marker.position.row)
  end
  local lines = util.batch_get_lines(bufnr, rows)

  for _, todo_item in ipairs(items) do
    if todo_item.metadata and todo_item.metadata.entries and #todo_item.metadata.entries ~= 0 then
      local row = todo_item.range.start.row
      local original_line = lines[row]

      if original_line and #original_line ~= 0 then
        local empty_metadata = {
          entries = {},
          by_tag = {},
        }

        local new_line = M.rebuild_line_with_sorted_metadata(original_line, empty_metadata)

        local hunk = make_post_marker_replacement_hunk(row, todo_item, original_line, new_line)
        if hunk then
          table.insert(hunks, hunk)
        end
      end
    end
  end

  return hunks
end

--- Remove all metadata from todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param todo_ids integer[] Array of extmark ids (or single id)
---@return checkmate.TextDiffHunk[] hunks
function M.remove_all_metadata(ctx, todo_ids)
  local config = require("checkmate.config")
  local items = {}
  local callbacks_to_queue = {} -- array of {meta_name, id}

  for _, id in ipairs(todo_ids) do
    local item = ctx.get_todo_by_id(id)
    if item and item.metadata and item.metadata.entries and #item.metadata.entries > 0 then
      table.insert(items, item)

      for _, entry in ipairs(item.metadata.entries) do
        local meta_config = config.options.metadata[entry.tag]
        if meta_config and meta_config.on_remove then
          table.insert(callbacks_to_queue, { meta_name = entry.tag, id = id })
        end
      end
    end
  end

  local hunks = M.compute_diff_remove_all_metadata(items)

  for _, cb_info in ipairs(callbacks_to_queue) do
    local meta_config = config.options.metadata[cb_info.meta_name]
    ctx.add_cb(function(tx_ctx)
      local updated_item = tx_ctx.get_todo_by_id(cb_info.id)
      if updated_item then
        meta_config.on_remove(updated_item)
      end
    end)
  end

  return hunks
end

--- Toggle metadata on todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, meta_name: string, custom_value?: string}
---@return checkmate.TextDiffHunk[] hunks
function M.toggle_metadata(ctx, operations)
  local hunks = {}

  local to_add = {}
  local to_remove = {}

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if item then
      local has_metadata = item.metadata.by_tag and item.metadata.by_tag[op.meta_name]
      if has_metadata then
        table.insert(to_remove, { id = op.id, meta_name = op.meta_name })
      else
        table.insert(to_add, { id = op.id, meta_name = op.meta_name, meta_value = op.custom_value })
      end
    end
  end

  if #to_remove > 0 then
    local remove_hunks = M.remove_metadata(ctx, to_remove)
    vim.list_extend(hunks, remove_hunks)
  end

  if #to_add > 0 then
    local add_hunks = M.add_metadata(ctx, to_add)
    vim.list_extend(hunks, add_hunks)
  end

  return hunks
end

---@param ctx checkmate.TransactionContext
---@param metadata checkmate.MetadataEntry
---@param new_value string
---@return checkmate.TextDiffHunk[]
function M.set_metadata_value(ctx, metadata, new_value)
  local bufnr = ctx.get_buf()
  local row = metadata.range.start.row

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return {}
  end

  -- queue on_change callback
  if metadata.value ~= new_value then
    local config = require("checkmate.config")
    local canonical_name = metadata.alias_for or metadata.tag
    local meta_config = config.options.metadata[canonical_name]

    if meta_config and meta_config.on_change then
      local todo_item = ctx.get_todo_by_row(row)
      if todo_item then
        ctx.add_cb(function(tx_ctx)
          local updated_item = tx_ctx.get_todo_by_id(todo_item.id)
          if updated_item then
            meta_config.on_change(updated_item, metadata.value, new_value)
          end
        end)
      end
    end
  end

  return M.compute_diff_update_metadata(line, metadata, new_value)
end

function M.compute_diff_update_metadata(line, metadata, value)
  local row = metadata.range.start.row
  -- 1-indexed for string operations
  local tag_start_1indexed = metadata.range.start.col + 1
  local tag_end_1indexed = metadata.range["end"].col -- end is exclusive, so no +1

  local metadata_str = line:sub(tag_start_1indexed, tag_end_1indexed)

  -- find the outer parentheses
  local paren_open, paren_close = metadata_str:find("%b()")
  if not paren_open then
    return {}
  end

  -- need 0-indexed for the hunk
  local value_start_0indexed = metadata.range.start.col + paren_open -- position after '('
  local value_end_0indexed = metadata.range.start.col + paren_close - 1 -- position before ')'

  local hunk = {
    start_row = row,
    start_col = value_start_0indexed,
    end_row = row,
    end_col = value_end_0indexed,
    insert = { value },
  }

  return { hunk }
end

--- moves the cursor forward or backward to the next metadata tag for the todo item
--- under the cursor, if present
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param backward boolean? if true, move to previous
function M.move_cursor_to_metadata(bufnr, todo_item, backward)
  if not (todo_item and todo_item.metadata and #todo_item.metadata.entries > 0) then
    return
  end

  -- current cursor (row is 1-based, col is 0-based)
  local win = vim.api.nvim_get_current_win()

  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local cur = vim.api.nvim_win_get_cursor(win)
  local cur_col = cur[2]

  local entries = vim.tbl_map(function(e)
    return e
  end, todo_item.metadata.entries)
  table.sort(entries, function(a, b)
    return a.range.start.col < b.range.start.col
  end)

  local target
  if backward then
    for i = #entries, 1, -1 do
      local e = entries[i]
      local s = e.range.start.col
      local fin = e.range["end"].col -- end-exclusive
      -- only metadata that are fully left of cursor (skip if cursor is inside)
      if s < cur_col and cur_col >= fin then
        target = e
        break
      end
    end
    -- wrap
    if not target then
      target = entries[#entries]
    end
  else
    for _, entry in ipairs(entries) do
      if cur_col < entry.range.start.col then
        target = entry
        break
      end
    end
    -- wrap
    if not target then
      target = entries[1]
    end
  end

  if target then
    vim.api.nvim_win_set_cursor(win, { todo_item.range.start.row + 1, target.range.start.col })
  end
end

---Sorts metadata entries based on their configured sort_order
---@param entries checkmate.MetadataEntry[] The metadata entries to sort
---@return checkmate.MetadataEntry[] The sorted entries
function M.sort_metadata_entries(entries)
  local config = require("checkmate.config")

  local sorted = vim.deepcopy(entries)

  table.sort(sorted, function(a, b)
    -- Get canonical names
    local a_name = a.alias_for or a.tag
    local b_name = b.alias_for or b.tag

    local a_config = config.options.metadata[a_name] or {}
    local b_config = config.options.metadata[b_name] or {}

    local a_order = a_config.sort_order or 100
    local b_order = b_config.sort_order or 100

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

  -- remove all metadata tags but preserve all other content including whitespace
  local content_without_metadata = line:gsub("@[%a][%w_%-]*%b()", "")

  -- remove trailing whitespace but keep all indentation
  content_without_metadata = content_without_metadata:gsub("%s+$", "")

  if not metadata or not metadata.entries or #metadata.entries == 0 then
    return content_without_metadata
  end

  local sorted_entries = M.sort_metadata_entries(metadata.entries)

  local result_line = content_without_metadata

  -- add back each metadata tag in sorted order
  for _, entry in ipairs(sorted_entries) do
    result_line = result_line .. " @" .. entry.tag .. "(" .. entry.value .. ")"
  end

  log.debug("Rebuilt line with sorted metadata: " .. result_line, { module = "parser" })
  return result_line
end

--- Count completed and total child todos for a todo item
---@param todo_item checkmate.TodoItem The parent todo item
---@param todo_map table<integer, checkmate.TodoItem> Full todo map
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

      -- recursively count grandchildren
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
--- @param opts? {heading?: {title?: string, level?: integer}, include_children?: boolean, newest_first?: boolean} Archive options
--- @return boolean success Whether any items were archived
function M.archive_todos(opts)
  local util = require("checkmate.util")
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local highlights = require("checkmate.highlights")
  local config = require("checkmate.config")

  opts = opts or {}

  -- create the Markdown heading that the user has defined, e.g. ## Archived
  local archive_heading_string = util.get_heading_string(
    opts.heading and opts.heading.title or config.options.archive.heading.title or "Archived",
    opts.heading and opts.heading.level or config.options.archive.heading.level or 2
  )
  local include_children = opts.include_children ~= false -- default: true
  local newest_first = opts.newest_first or config.options.archive.newest_first ~= false -- default: true
  local parent_spacing = math.max(config.options.archive.parent_spacing or 0, 0)

  -- helpers

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

  local bufnr = vim.api.nvim_get_current_buf()
  local todo_map = parser.get_todo_map(bufnr)
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

  local todos_to_archive = {}
  local archived_ranges = {} ---@type {start_row:integer, end_row:integer}[]
  local archived_root_cnt = 0

  for _, entry in ipairs(sorted_todos) do
    ---@cast entry {id: integer, item: checkmate.TodoItem}
    local todo = entry.item
    local id = entry.id
    local in_arch = archive_start_row -- could be nil if no archive section exists
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

  local new_main_content = {} -- lines that will remain in the main document
  local new_archive_content = {} -- lines that will live under the Archive heading
  local newly_archived_lines = {} -- temp storage for newly added archived todos

  -- Walk every line of the current buffer.
  --    we copy it into `new_content` unless it is:
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
      end
      -- handle spacing preservation
      if not skip and current_buf_lines[i] == "" then
        for _, r in ipairs(archived_ranges) do
          if idx == r.end_row + 1 then
            -- this blank line is immediately after an archived todo
            -- ...so check if there was a blank line before the todo
            local has_blank_before = r.start_row > 0 and current_buf_lines[r.start_row] == ""

            -- check if we already added content (which means there's something before)
            local has_content_before = #new_main_content > 0

            -- Skip this blank line if:
            --  - already have blank line before todo
            --  - the last line we added to new_main_content is blank
            if has_blank_before or (has_content_before and new_main_content[#new_main_content] == "") then
              skip = true
            end
            break
          end
        end
      end

      if not skip then
        new_main_content[#new_main_content + 1] = current_buf_lines[i]
      end
      i = i + 1
    end
  end

  -- If an archive section already exists, copy everything below its heading

  if archive_start_row and archive_end_row and archive_end_row >= archive_start_row + 1 then
    local start = archive_start_row + 2
    while start <= archive_end_row + 1 and current_buf_lines[start] == "" do
      start = start + 1
    end
    for j = start, archive_end_row + 1 do
      new_archive_content[#new_archive_content + 1] = current_buf_lines[j]
    end
    trim_trailing_blank(new_archive_content)
  end

  -- collect newly archived todo items

  if #archived_ranges > 0 then
    for idx, r in ipairs(archived_ranges) do
      for row = r.start_row, r.end_row do
        newly_archived_lines[#newly_archived_lines + 1] = current_buf_lines[row + 1]
      end

      -- spacing after each root todo except the last
      if idx < #archived_ranges and parent_spacing > 0 then
        add_spacing(newly_archived_lines)
      end
    end
  end

  -- combine existing and new archive content based on newest_first option

  if newest_first then
    -- newest items go at the top of the archive section
    local combined_lines = {}

    -- add new items first
    for _, line in ipairs(newly_archived_lines) do
      combined_lines[#combined_lines + 1] = line
    end

    -- add spacing between new and existing content if both exist
    if #newly_archived_lines > 0 and #new_archive_content > 0 and parent_spacing > 0 then
      add_spacing(combined_lines)
    end

    -- add existing archive content
    for _, line in ipairs(new_archive_content) do
      combined_lines[#combined_lines + 1] = line
    end

    new_archive_content = combined_lines
  else
    -- newest items go at the bottom (default behavior)
    if #new_archive_content > 0 and #newly_archived_lines > 0 and parent_spacing > 0 then
      add_spacing(new_archive_content) -- gap between old and new archive content
    end

    for _, line in ipairs(newly_archived_lines) do
      new_archive_content[#new_archive_content + 1] = line
    end
  end

  -- make sure we don't leave more than `parent_spacing`
  -- blank lines at the very end of the archive section.
  trim_trailing_blank(new_archive_content)

  -- inject archive section into document

  if #new_archive_content > 0 then
    -- blank line before archive heading if needed
    if #new_main_content > 0 and new_main_content[#new_main_content] ~= "" then
      new_main_content[#new_main_content + 1] = ""
    end
    new_main_content[#new_main_content + 1] = archive_heading_string
    new_main_content[#new_main_content + 1] = "" -- blank after heading
    for _, line in ipairs(new_archive_content) do
      new_main_content[#new_main_content + 1] = line
    end
  end

  -- write buffer

  local cursor_state = util.Cursor.save()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_main_content)
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
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local row = todo_item.range.start.row
    local updated_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if not updated_line then
      return
    end

    local tag_byte_pos = updated_line:find("@" .. meta_name .. "%(", 1)
    local value_byte_pos = tag_byte_pos and (updated_line:find("%(", tag_byte_pos) + 1) or nil

    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(win) == bufnr then
      if jump_to == "tag" and tag_byte_pos then
        vim.api.nvim_win_set_cursor(0, { row + 1, tag_byte_pos - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")
          vim.cmd("normal! l" .. string.rep("l", #meta_name) .. "v" .. string.rep("h", #meta_name))
        end
      elseif jump_to == "value" and value_byte_pos then
        vim.api.nvim_win_set_cursor(0, { row + 1, value_byte_pos - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")

          local closing_paren = updated_line:find(")", value_byte_pos)
          if closing_paren and closing_paren > value_byte_pos then
            local selection_length = closing_paren - value_byte_pos
            if selection_length > 0 then
              vim.cmd("normal! v" .. string.rep("l", selection_length - 1))
            end
          end
        end
      end
    end
  end)
end

--- Collect todo items under cursor or visual selection
---@param is_visual boolean Whether to collect items in visual selection (true) or under cursor (false)
---@return checkmate.TodoItem[] items
---@return table<integer, checkmate.TodoItem> todo_map
function M.collect_todo_items_from_selection(is_visual)
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local profiler = require("checkmate.profiler")

  profiler.start("api.collect_todo_items_from_selection")

  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}

  -- Pre-parse all todos once
  local full_map = parser.get_todo_map(bufnr)

  if is_visual then
    -- Exit visual mode first
    vim.cmd([[execute "normal! \<Esc>"]])
    local mark_start = vim.api.nvim_buf_get_mark(bufnr, "<")
    local mark_end = vim.api.nvim_buf_get_mark(bufnr, ">")

    -- convert from 1-based mark to 0-based rows
    local start_line = mark_start[1] - 1
    local end_line = mark_end[1] - 1

    -- pre-build lookup table for faster todo item location
    local row_to_todo = {}
    for _, todo_item in pairs(full_map) do
      for row = todo_item.range.start.row, todo_item.range["end"].row do
        if not row_to_todo[row] or row == todo_item.range.start.row then
          row_to_todo[row] = todo_item
        end
      end
    end

    local seen = {}
    for row = start_line, end_line do
      local todo = row_to_todo[row]
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

  return items, full_map
end

--[[
Apply diff hunks to buffer 

Line insertion vs text replacement
- nvim_buf_set_text: used for replacements and insertions WITHIN a line
  this is important because it preserves extmarks that are not directly in the replaced range
  i.e. the extmarks that track todo location
- nvim_buf_set_lines: used for inserting NEW LINES
  when used with same start/end positions, it inserts new lines without affecting
  existing lines or their extmarks.

We use nvim_buf_set_lines for whole line insertions (when start_col = end_col = 0)
because it's cleaner and doesn't risk affecting extmarks on adjacent lines.
For all other operations (replacements, partial line edits), we use nvim_buf_set_text
to preserve extmarks as much as possible.
--]]
---@param bufnr integer Buffer number
---@param hunks checkmate.TextDiffHunk[]
function M.apply_diff(bufnr, hunks)
  if vim.tbl_isempty(hunks) then
    return
  end

  -- Sort hunks bottom to top so that row numbers don't change as we apply hunks
  table.sort(hunks, function(a, b)
    if a.start_row ~= b.start_row then
      return a.start_row > b.start_row
    end
    return a.start_col > b.start_col
  end)

  -- apply hunks (first one creates undo entry, rest join)
  for i, hunk in ipairs(hunks) do
    if i > 1 then
      vim.cmd("silent! undojoin")
    end

    local is_line_insertion = hunk.start_row == hunk.end_row
      and hunk.start_col == 0
      and hunk.end_col == 0
      and #hunk.insert > 0

    if is_line_insertion then
      vim.api.nvim_buf_set_lines(bufnr, hunk.start_row, hunk.start_row, false, hunk.insert)
    else
      vim.api.nvim_buf_set_text(bufnr, hunk.start_row, hunk.start_col, hunk.end_row, hunk.end_col, hunk.insert)
    end
  end
end

return M
