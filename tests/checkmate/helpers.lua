local M = {}

function M.cleanup_buffer(bufnr, file_path)
  if not bufnr then
    return
  end

  -- Ensure we're in normal mode
  vim.cmd("stopinsert")
  vim.cmd("normal! \27") -- ESC

  -- Clear any pending operations
  vim.cmd("redraw!")

  require("checkmate").stop()

  -- Delete buffer
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

  -- Remove file
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
function M.create_test_buffer(content, name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n"))
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].filetype = "markdown"
  return bufnr
end

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
-- @param content string The full content to check
-- @param expected_lines table List of expected lines with exact indentation
-- @param start_line number? Optional start line (default: 1)
-- @return boolean, string? success, error_message
function M.verify_content_lines(content, expected_lines, start_line)
  start_line = start_line or 1

  -- Split content into lines
  local lines = vim.split(content, "\n")

  -- Ensure there are enough lines
  if #lines < start_line + #expected_lines - 1 then
    return false,
      string.format(
        "Content has %d lines, but expected at least %d lines starting from line %d",
        #lines,
        #expected_lines,
        start_line
      )
  end

  -- Check each expected line
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
--- @param todo_map table<integer, checkmate.TodoItem> Map of extmark IDs to todo item objects
--- @param pattern string Lua pattern to match against each item's `todo_text`
--- @return checkmate.TodoItem? todo The matching todo item, or `nil` if none found
function M.find_todo_by_text(todo_map, pattern)
  for _, todo in pairs(todo_map) do
    if todo.todo_text:match(pattern) then
      return todo
    end
  end
  return nil
end

return M
