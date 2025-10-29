local config = require("checkmate.config")
local assert = require("busted").assert

local M = {}

---Get the default unchecked marker from config
---@return string marker
function M.get_unchecked_marker()
  return config.get_defaults().todo_states.unchecked.marker
end

---Get the default checked marker from config
---@return string marker
function M.get_checked_marker()
  return config.get_defaults().todo_states.checked.marker
end

function M.get_pending_marker()
  return "℗"
end

M.DEFAULT_TEST_CONFIG = {
  metadata = {
    ---@diagnostic disable-next-line: missing-fields
    priority = { select_on_insert = false, jump_to_on_insert = false },
  },
  enter_insert_after_new = false,
  smart_toggle = { enabled = false },
  todo_states = {
    pending = {
      marker = M.get_pending_marker(),
      markdown = ".", -- i.e. [.]
    },
  },
}

--- Creates a temp file and sets up a Checkmate buffer for this file
--- @param content string|string[]
--- @param opts? {file_path?: string, config?: table, wait_ms?: integer, skip_setup?: boolean}
--- @return integer bufnr
--- @return string file_path
function M.setup_todo_file_buffer(content, opts)
  opts = opts or {}

  local content_str
  if type(content) == "table" then
    content_str = table.concat(content, "\n")
  else
    content_str = content
  end

  local file_path = opts.file_path or M.create_temp_file()

  if not M.write_file_content(file_path, content_str) then
    error("Failed to write content to file: " .. file_path)
  end

  if not opts.skip_setup then
    local _config = vim.tbl_deep_extend("force", M.DEFAULT_TEST_CONFIG, opts.config or {})
    local ok = require("checkmate").setup(_config)
    if not ok then
      error("Failed to setup Checkmate in setup_todo_buffer")
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, file_path)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.cmd("edit!")

  vim.bo[bufnr].filetype = "markdown"

  local wait_ms = opts.wait_ms or 5
  vim.wait(wait_ms)
  vim.cmd("redraw")

  return bufnr, file_path
end

--- stops checkmate
--- ensures normal mode
--- deletes buffer
--- removes file, if present
function M.cleanup_buffer(bufnr, file_path)
  if not bufnr then
    return
  end

  -- Ensure we're in normal mode
  vim.cmd("stopinsert")
  vim.cmd("normal! \27") -- ESC

  -- Clear any pending operations
  vim.cmd("redraw!")

  pcall(function()
    require("checkmate").stop()
  end)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

  if file_path then
    pcall(os.remove, file_path)
  end
end

-- Create a temporary file for testing
function M.create_temp_file()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/test.todo"
  return file_path
end

-- Read file contents directly (not via Neovim buffer)
---@return string|nil
function M.read_file_content(file_path)
  local f = io.open(file_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*all")
  f:close()
  return content
end

-- Write content to file directly
function M.write_file_content(file_path, content)
  local f = io.open(file_path, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

-- Helper function to create a test buffer with todo content
--- @param content string|string[]
--- @param name string?
--- @return integer bufnr
function M.setup_test_buffer(content, name)
  local filename = name or "todo.md"

  local bufnr = vim.api.nvim_create_buf(true, false)

  vim.api.nvim_buf_set_name(bufnr, filename)

  local lines
  if type(content) == "table" then
    lines = content
  else
    lines = vim.split(content, "\n")
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  vim.api.nvim_win_set_buf(0, bufnr)

  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true

  vim.api.nvim_set_current_buf(bufnr)

  return bufnr
end

--- Asserts that x is not nil, or errors.
---@generic T
---@param x T?
---@return T
function M.exists(x)
  assert(x ~= nil, "Does not exist!")
  return x
end

---@param bufnr integer
---@param ns integer
---@return table extmarks
function M.get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

function M.ensure_normal_mode()
  local mode = vim.fn.mode()
  if mode ~= "n" then
    -- Exit any mode back to normal mode
    vim.cmd([[noautocmd normal! <Esc>]])
    vim.cmd("stopinsert")
    vim.cmd("redraw")
  end
end

-- Verify text content line by line
---@param content string The full content to check
---@param expected_lines table List of expected lines with exact indentation
---@param start_line number? Optional start line (default: 1)
--- @return boolean success
--- @return string? error_message
function M.verify_content_lines(content, expected_lines, start_line)
  start_line = start_line or 1

  -- split into lines
  local lines = vim.split(content, "\n")

  if #lines < start_line + #expected_lines - 1 then
    return false,
      string.format(
        "Content has %d lines, but expected at least %d lines starting from line %d",
        #lines,
        #expected_lines,
        start_line
      )
  end

  for i, expected in ipairs(expected_lines) do
    local line_num = start_line + i - 1
    local actual = lines[line_num]

    actual = actual:gsub("%s+$", "")

    if actual ~= expected then
      return false, string.format("Line %d mismatch:\nExpected: '%s'\nActual:   '%s'", line_num, expected, actual)
    end
  end

  return true
end

--- Finds the first todo item in a todo_map whose `todo_text` matches the given Lua pattern.
--- @param todo_map? checkmate.TodoMap Map of extmark IDs to todo item objects
--- @param pattern string Lua pattern to match against each item's `todo_text`
--- @return checkmate.TodoItem? todo The matching todo item, or `nil` if none found
function M.find_todo_by_text(todo_map, pattern)
  todo_map = todo_map or require("checkmate.parser").get_todo_map(0)
  for _, todo in pairs(todo_map) do
    if todo.todo_text:match(pattern) then
      return todo
    end
  end
  return nil
end

---@param bufnr integer?
---@return checkmate.TodoItem? todo
function M.get_todo_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local parser = require("checkmate.parser")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  return parser.get_todo_item_at_position(bufnr, row, col)
end

--- Create a visual selection from (row1, col1) to (row2, col2)
--- 1 based rows, 0 based col
--- @param row1 integer Start row (1-based)
--- @param col1 integer Start column (0-based)
--- @param row2 integer End row (1-based)
--- @param col2 integer End column (0-based)
--- @param mode string? mode: 'v' (default), 'V', or '<C-v>'
function M.make_selection(row1, col1, row2, col2, mode)
  mode = mode or "v"

  vim.api.nvim_win_set_cursor(0, { row1, col1 })

  vim.cmd("normal! " .. mode)

  vim.api.nvim_win_set_cursor(0, { row2, col2 })

  vim.wait(5)
end

---@param actual string[]
---@param expected string[]
---@param test_name? string
function M.assert_lines_equal(actual, expected, test_name)
  local prefix = test_name and (test_name .. ": ") or ""
  assert.equal(#expected, #actual, prefix .. "line count mismatch")
  for i, expected_line in ipairs(expected) do
    if expected_line ~= false then
      assert.equal(expected_line, actual[i], prefix .. "line " .. i)
    end
  end
end

--- Returns the cursor location that is 1 after the last character of the found text
--- uses the todo markers: unchecked, checked, and pending
function M.find_cursor_after_text(line, text)
  local todo_markers = { M.get_unchecked_marker(), M.get_checked_marker(), M.get_pending_marker() }
  local prefix = line:match("^(.-" .. "[" .. table.concat(todo_markers, "") .. "]" .. " )")
  return #prefix + #text
end

---@param opts? table
--- - indent: integer|string Indent string (whitespace) or number of spaces
--- - list_marker: string
--- - state: string Todo state, e.g. "unchecked" (default), "checked", "pending"
--- - text: string Text after the todo marker + 1 space
function M.todo_line(opts)
  opts = opts or {}
  local m = {
    unchecked = M.get_unchecked_marker(),
    checked = M.get_checked_marker(),
    pending = M.get_pending_marker(),
  }
  local indent_str = ""
  if opts.indent then
    if type(opts.indent) == "number" then
      indent_str = string.rep(" ", opts.indent)
    elseif type(opts.indent) == "string" then
      indent_str = opts.indent
    end
  end
  ---@cast indent_str string
  local marker = opts.list_marker or require("checkmate.config").get_defaults().default_list_marker
  local state = opts.state or "unchecked"
  local text = opts.text or ""

  local state_marker = m[state] or m.unchecked
  return indent_str .. marker .. " " .. state_marker .. " " .. text
end

return M
