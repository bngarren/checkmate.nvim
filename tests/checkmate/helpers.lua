local assert = require("busted").assert

local M = {}

-- Constants and Configuration
-- =============================================================================
M.DEFAULT_TEST_CONFIG = {
  metadata = {
    ---@diagnostic disable-next-line: missing-fields
    priority = { select_on_insert = false, jump_to_on_insert = false },
  },
  enter_insert_after_new = false,
  smart_toggle = { enabled = false },
  todo_states = {
    pending = {
      marker = "℗", --hard coded to avoid circular ref
      markdown = ".", -- i.e. [.]
    },
  },
}

-- Marker Accessors
-- =============================================================================
local _markers_cache = {}

---@return string marker
function M.get_unchecked_marker()
  if not _markers_cache.unchecked then
    _markers_cache.unchecked = require("checkmate.config").get_defaults().todo_states.unchecked.marker
  end
  return _markers_cache.unchecked
end

---@return string marker
function M.get_checked_marker()
  if not _markers_cache.checked then
    _markers_cache.checked = require("checkmate.config").get_defaults().todo_states.checked.marker
  end
  return _markers_cache.checked
end

---(test-specific, not in checkmate default config)
---@return string marker
function M.get_pending_marker()
  if not _markers_cache.pending then
    _markers_cache.pending = "℗"
  end
  return _markers_cache.pending
end

function M.clear_marker_cache()
  _markers_cache = {}
end

-- Setup and Teardown
-- =============================================================================

---Calls `require("checkmate").setup()` and merges with helpers.DEFAULT_TEST_CONFIG`
---@param _config? checkmate.Config
---@param cm? Checkmate
function M.cm_setup(_config, cm)
  if not cm then
    cm = require("checkmate")
  end
  cm.setup(vim.tbl_deep_extend("force", M.DEFAULT_TEST_CONFIG, _config or {}))
  return cm
end

--- stops checkmate
--- ensures normal mode
--- deletes buffer
---@param bufnr integer?
function M.cleanup_test(bufnr)
  M.ensure_normal_mode()

  pcall(require("checkmate").stop)

  if not bufnr then
    return
  end

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.cleanup_file(file_path)
  if file_path then
    pcall(os.remove, file_path)
  end
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

-- Buffer Creation and File Operations
-- =============================================================================

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

---@param bufnr integer
---@param timeout_ms? integer Default: 100ms
function M.wait_for_write(bufnr, timeout_ms)
  timeout_ms = timeout_ms or 100
  local ok = vim.wait(timeout_ms, function()
    return not vim.bo[bufnr].modified
  end, 10)
  assert(ok, "Timeout waiting for buffer write")
end

--- Creates a temp file and sets up a Checkmate buffer for this file
--- @param content string|string[]
--- @param opts? {file_path?: string, config?: table, wait_ms?: integer, skip_setup?: boolean}
--- @return integer bufnr
--- @return string file_path
function M.setup_todo_file_buffer(content, opts)
  opts = opts or {}

  local content_str = type(content) == "table" and table.concat(content, "\n") or content

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

-- Assertion and Validation Helpers
-- =============================================================================

---Asserts that x is not nil, or errors
---@generic T
---@param x T?
---@param msg? string Custom error message
---@return T
function M.exists(x, msg)
  assert(x ~= nil, msg or "Does not exist!")
  return x
end

---Assert that buffer lines match expected lines
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

-- Todo Item Finders and Accessors
-- =============================================================================

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

-- Cursor and Selection Helpers
-- =============================================================================

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

--- Returns the cursor location that is 1 after the last character of the found text
--- uses the todo markers: unchecked, checked, and pending
function M.find_cursor_after_text(line, text)
  local todo_markers = { M.get_unchecked_marker(), M.get_checked_marker(), M.get_pending_marker() }
  local prefix = line:match("^(.-" .. "[" .. table.concat(todo_markers, "") .. "]" .. " )")
  return #prefix + #text
end

-- Extmark Helpers
-- =============================================================================

---@param bufnr integer
---@param ns integer
---@return table extmarks
function M.get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

-- Todo Line Builder
-- =============================================================================

---Build a todo line string
---@param opts? table
--- - indent: integer|string Indent string (whitespace) or number of spaces
--- - list_marker: string (default: from config)
--- - state: string Todo state, e.g. "unchecked" (default), "checked", "pending"
--- - text: string Text after the todo marker + 1 space (default: "")
---@return string
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

  local marker = opts.list_marker or require("checkmate.config").get_defaults().default_list_marker
  local state = opts.state or "unchecked"
  local text = opts.text or ""

  local state_marker = m[state] or m.unchecked
  return indent_str .. marker .. " " .. state_marker .. " " .. text
end

-- Test Case Runners
-- =============================================================================

---@class checkmate.TestCase
---@field name string Test case description
---@field content string|string[] Buffer content to test with
---@field cursor? [integer, integer] Cursor position (1-indexed row, 0-indexed col)
---@field selection? [integer, integer, integer, integer, string?] Visual selection params
---@field config? table Checkmate config overrides for this test
---@field merge_default_config? boolean (default: true) If false, will not merge with DEFAULT_TEST_CONFIG
---Optional setup function returning context
---This is called before action and can setup context, declare some variables, etc.
---@field setup? fun(bufnr: integer): any
---Action to perform on the test case (e.g. toggle, create, etc.)
---Receives context from setup function, if called. Can modify context that will
---be passed to `assert` function
---
---Can be used to set cursor as well:
---```
---local line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
---local t = line:find("@")
---vim.api.nvim_win_set_cursor(0, { 1, t })
---```
---
---@field action fun(cm: Checkmate, ctx?: any)
---@field expected? string[] Expected buffer lines after action
---@field assert? fun(bufnr: integer, lines: string[], ctx?: {buffer: integer, cm: Checkmate}) Custom assertion function
---@field wait_ms? integer Duration to wait after action before assertions (default 0 ms)
---@field skip? boolean Skip this test case
---@field only? boolean Run only this test case

--- Run multiple test cases with automatic setup/teardown
---@param test_cases checkmate.TestCase[]
---@param opts? {config?: table, merge_default_config?: boolean, wait_ms?: integer}
function M.run_test_cases(test_cases, opts)
  opts = opts or {}

  local has_only = false
  for _, tc in ipairs(test_cases) do
    if tc.only then
      has_only = true
      break
    end
  end

  local cm_config =
    vim.tbl_deep_extend("force", opts.merge_default_config ~= false and M.DEFAULT_TEST_CONFIG or {}, opts.config or {})
  local cm = require("checkmate")
  cm.setup(cm_config)

  -- sets up checkmate once for all test cases
  -- each test case gets it's own buffer
  -- if a tc.config is passed, we re-setup checkmate for that test case

  ---@param tc checkmate.TestCase
  local function run_single_case(tc)
    if has_only and not tc.only then
      return
    end

    if tc.skip then
      return
    end

    if tc.config then
      cm.stop()

      local merge_config = true
      if tc.merge_default_config == false then
        merge_config = false
      elseif opts.merge_default_config == false then
        merge_config = false
      end

      cm_config = vim.tbl_deep_extend("force", merge_config and M.DEFAULT_TEST_CONFIG or {}, cm_config, tc.config or {})
      cm.setup(cm_config)
    end

    local bufnr = M.setup_test_buffer(tc.content)

    if not cm.is_running() then
      error("failed to run test case because checkmate isn't running")
      return
    end

    if tc.cursor then
      vim.api.nvim_win_set_cursor(0, tc.cursor)
    end

    if tc.selection then
      M.make_selection(unpack(tc.selection))
    end

    -- optional setup (returns context for assertions)
    local ctx = {}
    if tc.setup then
      ctx = tc.setup(bufnr)
    end

    ctx.buffer = ctx.buffer or bufnr
    ctx.cm = ctx.cm or cm

    tc.action(cm, ctx)

    local wait_ms = tc.wait_ms or opts.wait_ms or 0
    vim.wait(wait_ms)
    vim.cmd("redraw")

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if tc.expected then
      M.assert_lines_equal(lines, tc.expected, tc.name)
    end

    if tc.assert then
      tc.assert(bufnr, lines, ctx)
    end

    M.cleanup_test_buffer(bufnr)
  end

  for _, tc in ipairs(test_cases) do
    run_single_case(tc)
  end

  pcall(cm.stop)
end

---Runner for basic content (string or string[]) -> action -> expected (string [])
---## When to use?
---All test cases have the same action (toggle, create, etc) and we only need to verify buffer lines
---
---Defaults cursor position to [1,0] as 1-indexed (same as win cursor api)
---
---#### Example
---```lua
---local test_cases = {
---   { name = "plain text", content = "This is a regular line",
---     expected = { "- ☐ This is a regular line" } },
---   { name = "empty line", content = "",
---     expected = { "- ☐" } },
--- }
---
--- h.run_simple_cases(test_cases, function(cm)
---   cm.create()
--- end)
---```
---@param test_cases checkmate.TestCase[]
---@param default_action fun(cm: Checkmate) Default action applied if not specified per-case
---@param opts? table Additional options (same as run_test_cases)
function M.run_simple_cases(test_cases, default_action, opts)
  opts = opts or {}

  local normalized_cases = {}
  for _, tc in ipairs(test_cases) do
    table.insert(normalized_cases, {
      name = tc.name,
      content = tc.content,
      cursor = tc.cursor or { 1, 0 },
      action = tc.action or default_action,
      expected = tc.expected,
      config = tc.config,
      skip = tc.skip,
      only = tc.only,
      wait_ms = tc.wait_ms,
    })
  end

  M.run_test_cases(normalized_cases, opts)
end

function M.cleanup_test_buffer(bufnr)
  if not bufnr then
    return
  end

  vim.cmd("stopinsert")
  vim.cmd("normal! \27")
  vim.cmd("redraw!")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

return M
