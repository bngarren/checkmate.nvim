--[[

Some notes:
- The 'pending' todo state is often tested. This is not a plugin default but added via the helpers.DEFAULT_TEST_CONFIG

]]
describe("API", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.api"
  local api

  ---@module "checkmate.parser"
  local parser

  ---@module "checkmate.util"
  local util

  ---@type {unchecked: string, checked: string, pending: string}
  local m -- markers

  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    api = require("checkmate.api")
    parser = require("checkmate.parser")
    util = require("checkmate.util")

    m = {
      unchecked = h.get_unchecked_marker(),
      checked = h.get_checked_marker(),
      pending = h.get_pending_marker(),
    }

    h.ensure_normal_mode()
    h.delete_all_buffers()
  end)

  describe("file operations", function()
    it("should save (write) todo buffer with correct Markdown syntax", function()
      local content = [[
# Complex Todo List
## Work Tasks
- ]] .. m.unchecked .. [[ Major project planning
  * ]] .. m.unchecked .. [[ Research competitors
  * ]] .. m.checked .. [[ Create timeline
  * ]] .. m.unchecked .. [[ Assign resources
    + ]] .. m.checked .. [[ Allocate budget
    + ]] .. m.unchecked .. [[ Schedule meetings
    + ]] .. m.unchecked .. [[ Set milestones
  * ]] .. m.checked .. [[ Draft proposal
- ]] .. m.checked .. [[ Email weekly report
## Personal Tasks
1. ]] .. m.unchecked .. [[ Grocery shopping
2. ]] .. m.checked .. [[ Call dentist
3. ]] .. m.unchecked .. [[ Plan vacation
   - ]] .. m.unchecked .. [[ Research destinations
   - ]] .. m.checked .. [[ Check budget
- ]] .. m.pending .. [[ Pending task
- ]] .. m.unchecked

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      vim.cmd("write")
      h.wait_for_write(bufnr)

      local saved_content = h.exists(h.read_file_content(file_path))

      local lines = vim.split(saved_content, "\n")
      -- handle eof (empty string)
      if lines[#lines] == "" then
        lines[#lines] = nil
      end

      h.assert_lines_equal(lines, {
        "# Complex Todo List",
        "## Work Tasks",
        "- [ ] Major project planning",
        "  * [ ] Research competitors",
        "  * [x] Create timeline",
        "  * [ ] Assign resources",
        "    + [x] Allocate budget",
        "    + [ ] Schedule meetings",
        "    + [ ] Set milestones",
        "  * [x] Draft proposal",
        "- [x] Email weekly report",
        "## Personal Tasks",
        "1. [ ] Grocery shopping",
        "2. [x] Call dentist",
        "3. [ ] Plan vacation",
        "   - [ ] Research destinations",
        "   - [x] Check budget",
        "- [.] Pending task",
        "- [ ]",
      }, "saved_content")

      -- verify unicode symbols are NOT present in the saved file
      assert.no.matches(m.unchecked, saved_content)
      assert.no.matches(m.checked, saved_content)
      assert.no.matches(m.pending, saved_content)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should load todo file with Markdown checkboxes converted to Unicode", function()
      local content = [[
# Todo List

- [ ] Unchecked task
- [x] Checked task
- [.] Pending task
      ]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.matches("- " .. m.unchecked .. " Unchecked task", lines[3])
      assert.matches("- " .. m.checked .. " Checked task", lines[4])
      assert.matches("- " .. m.pending .. " Pending task", lines[5])

      local todo_map = parser.discover_todos(bufnr)
      assert.equal(3, vim.tbl_count(todo_map))

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should maintain todo state through edit-write-reload cycle", function()
      local content = [[
# Todo List

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
      ]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local todo_map = parser.discover_todos(bufnr)
      local task_2 = h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " Task 2")
      task_2 = h.exists(task_2)

      local task_2_todo = util.build_todo(task_2)

      local success = require("checkmate").set_todo_state(task_2_todo, "checked")
      assert.is_true(success)

      vim.cmd("write")
      h.wait_for_write(bufnr)

      -- close and reopen the file
      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.cmd("edit " .. file_path)
      bufnr = vim.api.nvim_get_current_buf()

      -- should already be, but just to be safe
      vim.bo[bufnr].filetype = "markdown"

      todo_map = parser.discover_todos(bufnr)
      local task_2_reloaded = h.find_todo_by_text(todo_map, "- " .. m.checked .. " Task 2")
      task_2_reloaded = h.exists(task_2_reloaded)

      assert.equal("checked", task_2_reloaded.state)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    describe("BufWriteCmd behavior", function()
      it("should handle :wa (write all modified buffers)", function()
        local bufnr1, file1 = h.setup_todo_file_buffer("- [ ] File 1 todo")
        local bufnr2, file2 = h.setup_todo_file_buffer("- [ ] File 2 todo")

        vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, { "- [ ] File 1 new" })
        vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, { "- [ ] File 2 new", "" })

        assert.is_true(vim.bo[bufnr1].modified)
        assert.is_true(vim.bo[bufnr2].modified)

        vim.cmd("silent wa")

        vim.wait(20)

        assert.is_false(vim.bo[bufnr1].modified)
        assert.is_false(vim.bo[bufnr2].modified)

        local content1 = h.read_file_content(file1)
        if not content1 then
          error("failed read file1")
        end

        local content2 = h.read_file_content(file2)
        if not content2 then
          error("failed read file2")
        end

        -- we manually handle EOL in BufWriteCmd in binary mode so there should always be a blank last line
        assert.equal("- [ ] File 1 new\n", content1)
        assert.equal("- [ ] File 2 new\n", content2)

        finally(function()
          h.cleanup_buffer(bufnr1, file1)
          h.cleanup_buffer(bufnr2, file2)
        end)
      end)

      it("should not trigger multiple writes on single save command", function()
        local bufnr, file_path = h.setup_todo_file_buffer("- [ ] Test")

        local write_attempts = 0
        local original_writefile = vim.fn.writefile
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.writefile = function(...)
          write_attempts = write_attempts + 1
          return original_writefile(...)
        end

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] New line" })
        vim.cmd("write")

        assert.equal(1, write_attempts, "Write was called multiple times")

        finally(function()
          vim.fn.writefile = original_writefile
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should call BufWritePre and BufWritePost", function()
        local bufnr, file_path = h.setup_todo_file_buffer("")
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [ ] Todo new" })
        assert.is_true(vim.bo[bufnr].modified)

        local buf_write_pre_called = false
        local buf_write_post_called = false

        local augroup = vim.api.nvim_create_augroup("test", { clear = true })

        vim.api.nvim_create_autocmd("BufWritePre", {
          buffer = bufnr,
          group = augroup,
          callback = function()
            buf_write_pre_called = true
          end,
        })
        vim.api.nvim_create_autocmd("BufWritePre", {
          buffer = bufnr,
          group = augroup,
          callback = function()
            buf_write_post_called = true
          end,
        })

        vim.cmd("silent write")
        vim.wait(20)

        assert.is_true(buf_write_pre_called)
        assert.is_true(buf_write_post_called)

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
          vim.api.nvim_clear_autocmds({ group = augroup })
        end)
      end)
    end)
  end)

  describe("todo collection from cursor/selection", function()
    local cm
    before_each(function()
      cm = h.cm_setup()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should collect a single todo under cursor in normal mode", function()
      local content = [[
- ]] .. m.unchecked .. [[ Task A
- ]] .. m.unchecked .. [[ Task B
]]
      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local items = api.collect_todo_items_from_selection(false)
      assert.equal(1, #items)

      assert.matches("Task A", items[1].todo_text)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should collect multiple todos within a visual selection", function()
      local content = [[
- [ ] Task A
- [ ] Task B
  - [ ] Task C
]]
      local bufnr = h.setup_test_buffer(content)

      -- linewise select top 2 todo lines
      h.make_selection(1, 0, 2, 0, "V")

      local items = api.collect_todo_items_from_selection(true)
      assert.equal(2, #items)

      local foundA, foundB = false, false
      for _, todo in ipairs(items) do
        local taskA = todo.todo_text:match("Task A")
        local taskB = todo.todo_text:match("Task B")
        if taskA then
          foundA = true
        end
        if taskB then
          foundB = true
        end
      end
      assert.is_true(foundA)
      assert.is_true(foundB)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("todo creation", function()
    ---@module "checkmate"
    local cm
    local todo_line

    before_each(function()
      cm = h.cm_setup()
      todo_line = h.todo_line
    end)

    after_each(function()
      cm.stop()
    end)

    local function test_create_scenario(opts)
      local bufnr = h.setup_test_buffer(opts.content or opts.lines)

      if opts.cursor then
        vim.api.nvim_win_set_cursor(0, opts.cursor)
      end

      if opts.selection then
        h.make_selection(unpack(opts.selection))
      end

      require("checkmate").create(opts.create_opts or {})

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      if opts.expected then
        h.assert_lines_equal(lines, opts.expected, opts.name)
      end

      h.cleanup_buffer(bufnr)
      return lines
    end

    describe("normal mode", function()
      it("should convert lines to todos", function()
        local test_cases = {
          {
            name = "plain text",
            content = "This is a regular line",
            expected = { todo_line({ text = "This is a regular line" }) },
          },
          {
            name = "empty line",
            content = "",
            expected = { todo_line() },
          },
          {
            name = "list item",
            content = "- Regular list item",
            expected = { todo_line({ text = "Regular list item" }) },
          },
          {
            name = "ordered list",
            content = "1. Ordered item",
            expected = { todo_line({ list_marker = "1.", text = "Ordered item" }) },
          },
          {
            name = "nested list",
            content = "  - Nested list item",
            expected = { todo_line({ indent = 2, text = "Nested list item" }) },
          },
        }

        for _, tc in ipairs(test_cases) do
          test_create_scenario({
            name = tc.name,
            content = tc.content,
            cursor = { 1, 0 },
            expected = tc.expected,
          })
        end
      end)

      it("should create new todos from existing todos", function()
        local parent = todo_line({ text = "Parent todo" })

        local test_cases = {
          -- default behavior for normal mode
          {
            name = "sibling below",
            create_opts = {},
            expected = { parent, todo_line() },
          },
          {
            name = "sibling above",
            create_opts = { position = "above" },
            expected = { todo_line(), parent },
          },
          {
            name = "nested child",
            create_opts = { indent = true },
            expected = { parent, todo_line({ indent = "  " }) },
          },
          {
            name = "with content",
            create_opts = { content = "Custom content" },
            expected = { parent, todo_line({ text = "Custom content" }) },
          },
          {
            name = "with custom state",
            create_opts = { target_state = "checked" },
            expected = { parent, todo_line({ state = "checked" }) },
          },
          {
            name = "inherit state",
            content = todo_line({ state = "checked", text = "Completed" }),
            create_opts = { inherit_state = true },
            expected = {
              todo_line({ state = "checked", text = "Completed" }),
              todo_line({ state = "checked" }),
            },
          },
        }

        for _, tc in ipairs(test_cases) do
          test_create_scenario({
            name = tc.name,
            content = tc.content or parent,
            cursor = { 1, 0 },
            create_opts = tc.create_opts,
            expected = tc.expected,
          })
        end
      end)

      it("should maintain indentation when inserting new todo", function()
        local content = [[
  - ]] .. m.unchecked .. [[ Indented todo
Some other content]]

        test_create_scenario({
          name = "maintain indent when inserting new todo",
          content = content,
          cursor = { 1, 0 },
          expected = {
            todo_line({ indent = 2, text = "Indented todo" }),
            todo_line({ indent = 2 }), -- match parent/origin's indent
            "Some other content",
          },
        })
      end)

      it("should handle indent option variations", function()
        local parent = todo_line({ text = "Parent" })

        local indent_tests = {
          { indent = false, expected_indent = "" },
          { indent = true, expected_indent = "  " },
          { indent = "nested", expected_indent = "  " },
          { indent = 0, expected_indent = "" },
          { indent = 2, expected_indent = "  " },
          { indent = 4, expected_indent = "    " },
        }

        for _, tc in ipairs(indent_tests) do
          test_create_scenario({
            name = "indent=" .. tostring(tc.indent),
            content = parent,
            cursor = { 1, 0 },
            create_opts = { indent = tc.indent },
            expected = {
              parent,
              todo_line({ indent = tc.expected_indent }),
            },
          })
        end
      end)

      it("should handle ordered list numbering", function()
        test_create_scenario({
          name = "increment ordered list",
          content = {
            todo_line({ marker = "1.", text = "First" }),
            todo_line({ marker = "2.", text = "Second" }),
          },
          cursor = { 1, 0 },
          expected = {
            todo_line({ marker = "1.", text = "First" }),
            todo_line({ marker = "2." }),
            todo_line({ marker = "2.", text = "Second" }),
          },
        })
      end)

      it("should handle position option with indent", function()
        local content = "- " .. m.unchecked .. " Parent todo"

        test_create_scenario({
          name = "position with indent",
          content = content,
          cursor = { 1, 0 },
          create_opts = {
            position = "above",
            indent = true,
          },
          expected = {
            todo_line({ indent = 2 }),
            todo_line({ text = "Parent todo" }),
          },
        })

        test_create_scenario({
          name = "position with indent",
          content = content,
          cursor = { 1, 0 },
          create_opts = {
            position = "above",
            indent = 4,
          },
          expected = {
            todo_line({ indent = 4 }),
            todo_line({ text = "Parent todo" }),
          },
        })
      end)

      it("should handle target_state overriding inherit_state", function()
        test_create_scenario({
          name = "target_state overrides inherit_state",
          content = todo_line({ state = "unchecked", text = "Parent" }),
          cursor = { 1, 0 },
          create_opts = {
            inherit_state = true, -- would normally inherit "unchecked"
            target_state = "checked", -- but this takes precedence
          },
          expected = {
            todo_line({ state = "unchecked", text = "Parent" }),
            todo_line({ state = "checked" }),
          },
        })
      end)

      it("should handle position option with non-todo lines", function()
        test_create_scenario({
          name = "create above plain text preserves original",
          content = "Some plain text",
          cursor = { 1, 0 },
          create_opts = { position = "above" },
          expected = {
            todo_line(),
            "Some plain text",
          },
        })

        test_create_scenario({
          name = "create below plain text preserves original",
          content = "Some plain text",
          cursor = { 1, 0 },
          create_opts = { position = "below" },
          expected = {
            "Some plain text",
            todo_line(),
          },
        })
      end)

      it("should replace content when converting", function()
        test_create_scenario({
          name = "content option replaces text",
          content = "Original text",
          cursor = { 1, 0 },
          create_opts = { content = "Replaced content" },
          expected = { todo_line({ text = "Replaced content" }) },
        })
      end)

      it("should create in an empty line", function()
        local content = [[
- Parent

  - Child1]]

        test_create_scenario({
          name = "create in empty line",
          content = content,
          cursor = { 2, 0 },
          expected = {
            "- Parent",
            todo_line(),
            "  - Child1",
          },
        })
      end)

      it("should convert a list item nested in another todo", function()
        local content = [[
- [ ] Parent todo
  - Regular list item]]

        test_create_scenario({
          name = "convert nested list item to todo",
          content = content,
          cursor = { 2, 0 }, -- on "Regular list item"
          expected = {
            todo_line({ text = "Parent todo" }),
            todo_line({ indent = 2, text = "Regular list item" }),
          },
        })
      end)
    end)

    describe("visual mode", function()
      it("should convert multiple lines", function()
        test_create_scenario({
          name = "convert selection to todos",
          lines = {
            "# Header",
            "Regular text",
            "- List item",
            "  Indented text",
            "1. Ordered item",
          },
          selection = { 2, 0, 5, 0, "V" },
          expected = {
            "# Header",
            todo_line({ text = "Regular text" }),
            todo_line({ text = "List item" }),
            todo_line({ indent = "  ", text = "Indented text" }),
            todo_line({ list_marker = "1.", text = "Ordered item" }),
          },
        })
      end)

      it("should skip existing todos", function()
        test_create_scenario({
          name = "skip existing todos in selection",
          lines = {
            "Plain text",
            todo_line({ text = "Already todo" }),
            "Another plain",
          },
          selection = { 1, 0, 3, 0, "V" },
          expected = {
            todo_line({ text = "Plain text" }),
            todo_line({ text = "Already todo" }),
            todo_line({ text = "Another plain" }),
          },
        })
      end)

      it("should apply visual mode options correctly", function()
        local lines = { "Line 1", "Line 2" }

        -- target_state
        test_create_scenario({
          name = "apply target_state",
          lines = lines,
          selection = { 1, 0, 2, 0, "V" },
          create_opts = { target_state = "checked" },
          expected = {
            todo_line({ state = "checked", text = "Line 1" }),
            todo_line({ state = "checked", text = "Line 2" }),
          },
        })

        -- list_marker
        test_create_scenario({
          name = "apply list_marker",
          lines = lines,
          selection = { 1, 0, 2, 0, "V" },
          create_opts = { list_marker = "*" },
          expected = {
            todo_line({ list_marker = "*", text = "Line 1" }),
            todo_line({ list_marker = "*", text = "Line 2" }),
          },
        })

        -- content replacement
        test_create_scenario({
          name = "replace content",
          lines = lines,
          selection = { 1, 0, 2, 0, "V" },
          create_opts = { content = "Replaced" },
          expected = {
            todo_line({ text = "Replaced" }),
            todo_line({ text = "Replaced" }),
          },
        })

        -- using position
        -- this should make it behave like normal mode, creating a new todo above without any line conversion
        test_create_scenario({
          name = "use position to create new todo",
          lines = lines,
          selection = { 1, 0, 2, 0, "V" },
          create_opts = { position = "above", content = "Test" },
          expected = {
            todo_line({ text = "Test" }),
            "Line 1",
            "Line 2",
          },
        })
      end)
    end)

    describe("insert mode", function()
      --[[
      Since I can't figure out how to test within INSERT mode, we don't call the public API. We test the internal
      `create_todo_insert` api which receives the cursor pos. 
      
      Notably: in insert mode, cursor col represents insertion point, i.e. new char will be at that pos
      This is like having the insertion | caret right before the normal mode position.

      `create_todo_insert` expects the `col` to be relative to INSERT mode, not normal mode

      Whitespace: 
      When splitting a line in insert mode, whitespace after the cursor is preserved on the new line.
      This matches standard editor behavior where pressing Enter preserves the text exactly as it was.

      ]]

      local function test_insert_mode_create(opts)
        local bufnr = h.setup_test_buffer(opts.line or opts.lines)

        local cursor_col = opts.cursor_col
        if not cursor_col and opts.cursor_after then
          cursor_col = h.find_cursor_after_text(opts.line or opts.lines[1], opts.cursor_after)
        end

        require("checkmate.transaction").run(bufnr, function(ctx)
          ctx.add_op(api.create_todo_insert, opts.row or 0, {
            position = opts.position or "below",
            indent = opts.indent,
            inherit_state = opts.inherit_state,
            target_state = opts.target_state,
            cursor_pos = { row = opts.row or 0, col = cursor_col },
          })
        end)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        if opts.expected then
          h.assert_lines_equal(lines, opts.expected, opts.name)
        end

        if opts.expect_cursor_line then
          local cursor = vim.api.nvim_win_get_cursor(0)
          assert.equal(opts.expect_cursor_line, cursor[1], (opts.name or "") .. ": cursor line")
        end

        h.cleanup_buffer(bufnr)
        return lines
      end

      it("should split lines at cursor", function()
        local test_cases = {
          {
            name = "split after word",
            line = todo_line({ text = "First todo with more text" }),
            cursor_after = "First",
            expected = {
              todo_line({ text = "First" }),
              todo_line({ text = " todo with more text" }),
            },
          },
          {
            name = "split at beginning",
            line = todo_line({ text = "Complete text" }),
            cursor_after = "",
            expected = {
              todo_line(),
              todo_line({ text = "Complete text" }),
            },
          },
          {
            name = "split at end",
            line = todo_line({ text = "Complete" }),
            cursor_after = "Complete",
            expected = {
              todo_line({ text = "Complete" }),
              todo_line(),
            },
          },
          {
            name = "split mid-word",
            line = todo_line({ text = "SomeLongWord" }),
            cursor_after = "Some",
            expected = {
              todo_line({ text = "Some" }),
              todo_line({ text = "LongWord" }),
            },
          },
        }

        for _, tc in ipairs(test_cases) do
          test_insert_mode_create({
            name = tc.name,
            line = tc.line,
            cursor_after = tc.cursor_after,
            expected = tc.expected,
            expect_cursor_line = 2,
          })
        end
      end)

      it("should handle indentation", function()
        local test_cases = {
          {
            name = "maintain indent",
            line = todo_line({ indent = "  ", text = "Child text" }),
            cursor_after = "Child",
            indent = false,
            expected = {
              todo_line({ indent = "  ", text = "Child" }),
              todo_line({ indent = "  ", text = " text" }),
            },
          },
          {
            name = "create nested",
            line = todo_line({ indent = "  ", text = "Child text" }),
            cursor_after = "Child",
            indent = true,
            expected = {
              todo_line({ indent = "  ", text = "Child" }),
              todo_line({ indent = "    ", text = " text" }),
            },
          },
          {
            name = "explicit indent",
            line = todo_line({ text = "Text" }),
            cursor_after = "Text",
            indent = 4,
            expected = {
              todo_line({ text = "Text" }),
              todo_line({ indent = "    " }),
            },
          },
        }

        for _, tc in ipairs(test_cases) do
          test_insert_mode_create({
            name = tc.name,
            line = tc.line,
            cursor_after = tc.cursor_after,
            indent = tc.indent,
            expected = tc.expected,
          })
        end
      end)

      it("should handle state inheritance", function()
        local test_cases = {
          {
            name = "inherit checked",
            line = todo_line({ state = "checked", text = "Done" }),
            inherit_state = true,
            expected_state = "checked",
          },
          {
            name = "don't inherit",
            line = todo_line({ state = "checked", text = "Done" }),
            inherit_state = false,
            expected_state = "unchecked",
          },
          {
            name = "target overrides inherit",
            line = todo_line({ state = "unchecked", text = "Task" }),
            inherit_state = true,
            target_state = "checked",
            expected_state = "checked",
          },
        }

        for _, tc in ipairs(test_cases) do
          test_insert_mode_create({
            name = tc.name,
            line = tc.line,
            cursor_after = tc.line:match("(%w+)$") or "",
            inherit_state = tc.inherit_state,
            target_state = tc.target_state,
            expected = {
              tc.line,
              todo_line({ state = tc.expected_state }),
            },
          })
        end
      end)

      it("should handle position option", function()
        local line = todo_line({ text = "First second" })

        test_insert_mode_create({
          name = "create below",
          line = line,
          cursor_after = "First",
          position = "below",
          expected = {
            todo_line({ text = "First" }),
            todo_line({ text = " second" }),
          },
          expect_cursor_line = 2,
        })

        test_insert_mode_create({
          name = "create above",
          line = line,
          cursor_after = "First",
          position = "above",
          expected = {
            todo_line({ text = " second" }),
            todo_line({ text = "First" }),
          },
          expect_cursor_line = 1,
        })
      end)

      it("should handle edge cases", function()
        local test_cases = {
          {
            name = "empty todo",
            line = todo_line(),
            cursor_col = #todo_line(),
            expected = { todo_line(), todo_line() },
          },
          {
            name = "unicode characters",
            line = todo_line({ text = "你好 世界" }),
            cursor_after = "你好",
            expected = {
              todo_line({ text = "你好" }),
              todo_line({ text = " 世界" }),
            },
          },
          {
            name = "markdown formatting",
            line = todo_line({ text = "**bold** _italic_" }),
            cursor_after = "**bold**",
            expected = {
              todo_line({ text = "**bold**" }),
              todo_line({ text = " _italic_" }),
            },
          },
          {
            name = "metadata tags",
            line = todo_line({ text = "Task @due(2024) text" }),
            cursor_after = "Task",
            expected = {
              todo_line({ text = "Task" }),
              todo_line({ text = " @due(2024) text" }),
            },
          },
        }

        for _, tc in ipairs(test_cases) do
          test_insert_mode_create({
            name = tc.name,
            line = tc.line,
            cursor_after = tc.cursor_after,
            cursor_col = tc.cursor_col,
            expected = tc.expected,
          })
        end
      end)

      it("should preserve whitespace when splitting", function()
        test_insert_mode_create({
          name = "preserve multiple spaces",
          line = todo_line({ text = "First    second" }),
          cursor_after = "First",
          expected = {
            todo_line({ text = "First" }),
            todo_line({ text = "    second" }),
          },
        })
      end)

      it("should create todo from non-todo list item line", function()
        test_insert_mode_create({
          name = "non todo list item parent",
          line = "- Parent",
          cursor_col = 8,
          expected = {
            "- Parent",
            todo_line(),
          },
        })

        test_insert_mode_create({
          name = "non todo list item parent (indented)",
          line = "  - Parent",
          cursor_col = 10,
          expected = {
            "  - Parent",
            todo_line({ indent = "  " }),
          },
        })

        test_insert_mode_create({
          name = "non todo ordered list item parent",
          line = "1. Parent",
          cursor_col = 9,
          expected = {
            "1. Parent",
            todo_line({ list_marker = "2." }),
          },
        })
      end)
    end)
  end)

  describe("todo removal", function()
    ---@module "checkmate"
    local cm
    local todo_line

    before_each(function()
      cm = h.cm_setup()
      todo_line = h.todo_line
    end)

    after_each(function()
      cm.stop()
    end)

    local function test_remove_scenario(opts)
      local bufnr = h.setup_test_buffer(opts.content or opts.lines)

      if opts.cursor then
        vim.api.nvim_win_set_cursor(0, opts.cursor)
      end

      if opts.selection then
        h.make_selection(unpack(opts.selection))
      end

      require("checkmate").remove(opts.remove_opts or {})

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      if opts.expected then
        h.assert_lines_equal(lines, opts.expected, opts.name)
      end

      h.cleanup_buffer(bufnr)
      return lines
    end

    describe("normal mode", function()
      it("should remove checkbox and keep list item and strip metadata (default)", function()
        local line = todo_line({ text = "Task @due(2025-10-01) @priority(high)" })
        test_remove_scenario({
          name = "default remove: preserve list, strip metadata",
          content = line,
          cursor = { 1, 0 },
          expected = { "- Task" },
        })
      end)

      it("should remove checkbox and list item when preserve_list_marker=false", function()
        local line = todo_line({ text = "Write tests" })
        test_remove_scenario({
          name = "remove list marker also",
          content = line,
          cursor = { 1, 0 },
          remove_opts = { preserve_list_marker = false },
          expected = { "Write tests" },
        })
      end)

      it("should preserve indentation when keeping list marker", function()
        local line = todo_line({ indent = 2, text = "Child work @tag(val)" })
        test_remove_scenario({
          name = "preserve indent",
          content = line,
          cursor = { 1, 0 },
          expected = { "  - Child work" },
        })
      end)

      it("should handle ordered list markers", function()
        local line = todo_line({ list_marker = "3.", text = "Numbered thing @x(1)" })
        test_remove_scenario({
          name = "ordered list preserved",
          content = line,
          cursor = { 1, 0 },
          expected = { "3. Numbered thing" },
        })
      end)

      it("should no-op on non-todo line", function()
        local content = "Plain text"
        test_remove_scenario({
          name = "non-todo no-op",
          content = content,
          cursor = { 1, 0 },
          expected = { "Plain text" },
        })
      end)

      it("should keep metadata when requested", function()
        local line = todo_line({ text = "Keep meta @due(2026-01-01)" })
        test_remove_scenario({
          name = "preserve metadata by option",
          content = line,
          cursor = { 1, 0 },
          remove_opts = { remove_metadata = false },
          expected = { "- Keep meta @due(2026-01-01)" },
        })
      end)

      it("should remove a multi-line todo block and strip metadata across its body (default)", function()
        local lines = {
          todo_line({ text = "Main @due(2025-10-01)" }),
          "  More details @priority(high)",
          "  trailing text",
        }
        test_remove_scenario({
          name = "remove multi-line todo, strip meta",
          lines = lines,
          cursor = { 1, 0 },
          expected = {
            "- Main",
            "  More details",
            "  trailing text",
          },
        })
      end)

      it("should strip a metadata entry that spans across lines", function()
        local lines = {
          -- metadata starts on line 1 and closes on line 2
          todo_line({ text = "Complex @x(This spans" }),
          "  multiple lines) and more",
        }
        test_remove_scenario({
          name = "remove split-across-lines metadata",
          lines = lines,
          cursor = { 1, 0 },
          expected = {
            "- Complex",
            "  and more",
          },
        })
      end)

      -- regression test
      -- remove() first queues remove_metadata then (via callback) queues remove_todo
      -- the metadata engine’s on_remove handler also enqueues a state toggle
      -- ensuring the final remove_todo runs after all on_remove-driven ops prevents prefix corruption
      it("should remove todo cleanly when metadata has on_remove callback e.g., @done", function()
        local line = todo_line({
          text = "Item 6 @priority(high) @started(today) @done(09/16/25 08:23)",
        })
        test_remove_scenario({
          name = "remove with @done on_remove",
          content = line,
          cursor = { 1, 0 },
          expected = { "- Item 6" },
        })
      end)
    end)

    describe("visual mode", function()
      it("should remove across a multi-line selection, skipping non-todos", function()
        local lines = {
          "# Header",
          todo_line({ text = "A @due(2024)" }),
          "Plain",
          todo_line({ indent = 2, text = "B @x(1)" }),
          todo_line({ list_marker = "1.", text = "C" }),
        }
        test_remove_scenario({
          name = "visual multi-line",
          lines = lines,
          selection = { 2, 0, 5, 0, "V" },
          expected = {
            "# Header",
            "- A",
            "Plain",
            "  - B",
            "1. C",
          },
        })
      end)

      it("should support preserve_list_marker=false in visual mode", function()
        local lines = {
          todo_line({ text = "One @tag(yes)" }),
          todo_line({ text = "Two" }),
          "Not a todo",
        }
        test_remove_scenario({
          name = "visual remove list markers",
          lines = lines,
          selection = { 1, 0, 2, 0, "V" },
          remove_opts = { preserve_list_marker = false },
          expected = {
            "One",
            "Two",
            "Not a todo",
          },
        })
      end)
    end)
  end)

  describe("todo manipulation", function()
    describe("metadata operations", function()
      describe("find_metadata_insert_position", function()
        -- find byte position after a pattern in a line
        ---@return integer pos 1-based index
        local function find_byte_pos_after(line, pattern)
          local _, end_pos = line:find(pattern)
          return end_pos
        end

        -- get the byte position at end of content (excluding trailing whitespace)
        ---@return integer pos 1-based
        local function get_content_end_pos(line)
          local trimmed = line:match("^(.-)%s*$")
          return #trimmed
        end

        it("should find correct position when no metadata exists", function()
          h.cm_setup()

          local content = [[
- [ ] Single line todo
- [ ] 
- [ ] Multi-line todo
  that continues here
- [ ] Another todo

  With a separate paragraph
- [ ] ⭐️ Unicode ✅]]

          local bufnr = h.setup_test_buffer(content)
          local todo_item, insert_pos, lines

          -- Test 1: Single line todo
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
          lines = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
          insert_pos = api.find_metadata_insert_position(todo_item, "priority", bufnr)

          local expected_col = get_content_end_pos(lines[1])
          assert.are.equal(0, insert_pos.row)
          assert.are.equal(expected_col, insert_pos.col)
          assert.is_true(insert_pos.insert_after_space)

          -- Test 2: Empty todo
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 1, 0))
          lines = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)
          insert_pos = api.find_metadata_insert_position(todo_item, "priority", bufnr)

          -- after the unchecked marker
          expected_col = find_byte_pos_after(lines[1], m.unchecked)
          assert.are.equal(1, insert_pos.row)
          assert.are.equal(expected_col, insert_pos.col)

          -- Test 3: Multi-line todo
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 2, 0))
          lines = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false) -- get the continuation line
          insert_pos = api.find_metadata_insert_position(todo_item, "priority", bufnr)

          expected_col = get_content_end_pos(lines[1])
          assert.are.equal(3, insert_pos.row)
          assert.are.equal(expected_col, insert_pos.col)

          -- Test 4: Unicode content
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 7, 0))
          lines = vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)
          insert_pos = api.find_metadata_insert_position(todo_item, "priority", bufnr)

          expected_col = get_content_end_pos(lines[1])
          assert.are.equal(7, insert_pos.row)
          assert.are.equal(expected_col, insert_pos.col)

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should respect sort_order when metadata exists", function()
          ---@diagnostic disable-next-line: missing-fields
          h.cm_setup({
            metadata = {
              -- higher sort_order will be positioned to the right
              low = { sort_order = 10 },
              medium = { sort_order = 20 },
              high = { sort_order = 30 },
            },
          })
          local content = [[
- [ ] Todo with metadata @low(1)
- [ ] ⭐️ @high(3)
- [ ] Mixed @high(3) @low(1)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_item, insert_pos

          -- NOTE: since a metadata entry's range col is end-exlusive (one after the last char), it should match the col pos
          -- of the insert_pos

          -- test 1: Insert medium after low
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
          insert_pos = api.find_metadata_insert_position(todo_item, "medium", bufnr)

          -- should be after @low(1)
          local low_entry = todo_item.metadata.by_tag.low
          assert.are.equal(low_entry.range["end"].row, insert_pos.row)
          assert.are.equal(low_entry.range["end"].col, insert_pos.col)

          -- test 2: Insert medium before high
          todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 1, 0))
          insert_pos = api.find_metadata_insert_position(todo_item, "medium", bufnr)

          -- should be before @high(3)
          local high_entry = todo_item.metadata.by_tag.high
          assert.are.equal(high_entry.range.start.row, insert_pos.row)
          assert.are.equal(high_entry.range.start.col, insert_pos.col)

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle complex multi-line scenarios", function()
          ---@diagnostic disable-next-line: missing-fields
          h.cm_setup({
            metadata = {
              a = { sort_order = 10 },
              b = { sort_order = 20 },
              c = { sort_order = 30 },
              d = { sort_order = 25 },
            },
          })
          local content = [[
- [ ] First line @a(1)
  continuation @c(3)
  more text @b(2)
  final line]]

          local bufnr = h.setup_test_buffer(content)

          local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
          local insert_pos = api.find_metadata_insert_position(todo_item, "d", bufnr)

          -- NOTE: since a metadata entry's range col is end-exlusive (one after the last char), it should match the col pos
          -- of the insert_pos

          -- should insert after @b(2) since d's sort_order is 25
          local b_entry = todo_item.metadata.by_tag.b
          assert.are.equal(b_entry.range["end"].row, insert_pos.row)
          assert.are.equal(b_entry.range["end"].col, insert_pos.col)

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)
      end)

      it("should add metadata to todo items", function()
        local cm = h.cm_setup()

        local content = "# Todo List\n\n- [ ] Task without metadata\n"

        require("checkmate").setup()

        local bufnr = h.setup_test_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 3, 0 })

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 2, 0))

        local success = cm.add_metadata("priority", "high")
        assert.is_true(success)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. m.unchecked .. " Task without metadata @priority%(high%)", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should add metadata to a nested todo item", function()
        local cm = h.cm_setup()

        local content = [[
- [ ] Parent todo
  - [ ] Child todo A
  - [ ] Child todo B
]]
        local bufnr = h.setup_test_buffer(content)

        -- move cursor to the Child todo A on line 2 (1-indexed)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 1, 0)) -- 0-indexed

        cm.add_metadata("priority", "high")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. m.unchecked .. " Parent todo", lines[1])
        assert.matches("- " .. m.unchecked .. " Child todo A @priority%(high%)", lines[2])
        assert.matches("- " .. m.unchecked .. " Child todo B", lines[3])

        -- Now repeat for the parent todo
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

        cm.add_metadata("priority", "medium")

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. m.unchecked .. " Parent todo @priority%(medium%)", lines[1])
        assert.matches("- " .. m.unchecked .. " Child todo", lines[2])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should add metadata to a multi-line todo", function()
        -- NOTE: the expected behavior is that the metadata tag is inserted according to sort_order,
        -- immediately following a lower sort_order tag or before a higher sort_order tag

        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            test1 = {
              sort_order = 1,
            },
            test2 = {
              sort_order = 2,
            },
            test3 = {
              sort_order = 3,
            },
            test4 = {
              sort_order = 4,
            },
          },
        })

        local content = [[
- [ ] Todo item @test1(foo)
      @test3(baz)
        ]]

        local bufnr = h.setup_test_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

        local success = cm.add_metadata("test2", "bar")
        assert.is_true(success)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("Todo item @test1%(foo%) @test2%(bar%)$", lines[1])

        success = cm.add_metadata("test4", "gah")
        assert.is_true(success)

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("     @test3%(baz%) @test4%(gah%)$", lines[2])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should upsert metadata value via `add_metadata` when cursor is on todo with existing metadata", function()
        local cm = h.cm_setup()

        local content = [[
- ]] .. m.unchecked .. [[ Task @priority(low) @status(pending)]]

        local bufnr = h.setup_test_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        cm.add_metadata("priority", "high")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("@priority%(high%)", lines[1])
        assert.matches("@status%(pending%)", lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should update metadata via `update_metadata` but not create", function()
        local cm = h.cm_setup()

        local content = [[
- ]] .. m.unchecked .. [[ Task @priority(low) @status(pending)
- ]] .. m.unchecked .. [[ Task @status(pending)]]

        local bufnr = h.setup_test_buffer(content)

        h.make_selection(1, 0, 2, 0, "V")

        cm.update_metadata("priority", "high")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("@priority%(high%)", lines[1])
        assert.matches("@status%(pending%)", lines[1])
        -- line 2 should not have gotten new priority metadata
        assert.Not.matches("@priority%(high%)", lines[2])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should remove metadata from todo with wrapped metadata", function()
        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            test1 = {
              sort_order = 1,
            },
            test2 = {
              sort_order = 2,
            },
          },
        })

        -- each test starts with buffer content and the key (tag) to remove
        -- expectations are based on the post- remove_metadata buffer lines
        local cases = {
          {
            name = "remove @test1",
            key = "test1",
            content = [[
- [ ] Task @test1(foo) @test2(metadata with
      broken value)
      ]],
            expect = {
              function(lines)
                assert.equal("- " .. m.unchecked .. " Task @test2(metadata with", lines[1])
              end,
              function(lines)
                assert.matches("^%s*broken value%)", lines[2])
              end,
            },
          },
          {
            name = "remove @done (multi-line value)",
            key = "done",
            content = "- "
              .. m.unchecked
              .. " This is some extra content @started(06/30/25 20:21) @done(06/30/25 \n  20:21) @branch(fix/multi-line-todos)",
            expect = {
              function(lines)
                assert.equal("- " .. m.unchecked .. " This is some extra content @started(06/30/25 20:21)", lines[1])
              end,
              function(lines)
                assert.equal("  @branch(fix/multi-line-todos)", lines[2])
              end,
            },
          },
          {
            name = "remove @func (nested parens)",
            key = "func",
            content = "- " .. m.unchecked .. " Task @func(call(nested,\n  args)) @other(value)\n  ",
            expect = {
              function(lines)
                assert.equal("- " .. m.unchecked .. " Task", lines[1])
              end,
              function(lines)
                assert.equal("  @other(value)", lines[2])
              end,
            },
          },
        }

        local bufnr
        for _, case in ipairs(cases) do
          bufnr = h.setup_test_buffer(case.content)
          vim.api.nvim_win_set_cursor(0, { 1, 0 })

          cm.remove_metadata(case.key)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          for i, check in ipairs(case.expect) do
            local ok, err = pcall(check, lines)
            if not ok then
              error(("case '%s' failed at expectation #%d: %s"):format(case.name, i, tostring(err)))
            end
          end
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should remove metadata with complex value", function()
        local cm = h.cm_setup()

        local content = [[
- [ ] Task @issue(issue #1 - fix(api): broken! @author)
      ]]

        local bufnr = h.setup_test_buffer(content)

        local todo_map = parser.discover_todos(bufnr)
        local first_todo = h.exists(h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " Task @issue"))

        assert.is_not_nil(first_todo.metadata)
        assert.is_true(#first_todo.metadata.entries > 0)

        -- remove @issue
        vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 }) -- adjust from 0 index to 1-indexed
        cm.remove_metadata("issue")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.no.matches("@issue", lines[1])
        assert.matches("- " .. m.unchecked .. " Task", lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should remove all metadata from todo items", function()
        local tags_on_removed_called = false

        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            ---@diagnostic disable-next-line: missing-fields
            tags = {
              on_remove = function()
                tags_on_removed_called = true
              end,
            },
          },
        })

        -- content with todos that have multiple metadata tags
        local content = [[
# Todo Metadata Test

- ]] .. m.unchecked .. [[ Task with @priority(high) @due(2023-05-15) @tags(important,urgent)
- ]] .. m.unchecked .. [[ Another task @priority(medium) @assigned(john)
  @issue(2)
- ]] .. m.unchecked .. [[ A todo without metadata
]]

        local bufnr = h.setup_test_buffer(content)

        -- get 1st todo
        local todo_map = parser.discover_todos(bufnr)
        local first_todo = h.exists(h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " Task with"))

        assert.is_not_nil(first_todo.metadata)
        assert.is_true(#first_todo.metadata.entries > 0)

        -- remove all metadata
        vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 }) -- adjust from 0 index to 1-indexed
        cm.remove_all_metadata()

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.no.matches("@priority", lines[3])
        assert.no.matches("@due", lines[3])
        assert.no.matches("@tags", lines[3])
        assert.matches("- " .. m.unchecked .. " Task with", lines[3])

        assert.is_true(tags_on_removed_called)

        local second_todo = h.exists(h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " Another task"))
        local third_todo = h.exists(h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " A todo without"))

        h.make_selection(first_todo.range.start.row + 1, 0, third_todo.range.start.row + 1, 0, "V")

        cm.remove_all_metadata()

        vim.wait(10)

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- second todo's metadata was removed
        assert.no.matches("@priority", lines[4])
        assert.no.matches("@assigned", lines[4])
        assert.no.matches("@issue", lines[5])

        -- third todo's line text wasn't changed
        assert.matches("A todo without metadata", lines[6])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should handle metadata removal at end of buffer", function()
        local cm = h.cm_setup()

        local content = "- " .. m.unchecked .. " Task @meta(value\n  continues)"

        local bufnr = h.setup_test_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.remove_metadata("meta")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(1, #lines)
        assert.equal("- " .. m.unchecked .. " Task", lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should provide static choices", function()
        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            status = {
              choices = { "todo", "in-progress", "done", "blocked" },
            },
          },
        })

        local meta_module = require("checkmate.metadata")

        local content = [[- ]] .. m.unchecked .. [[ Task with metadata @status()]]

        local bufnr = h.setup_test_buffer(content)

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

        local results
        meta_module.get_choices("status", function(items)
          results = items
        end, todo_item, bufnr)
        assert.same({ "todo", "in-progress", "done", "blocked" }, results)

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should support synchronous 'choices' functions", function()
        local choices_fn_called = false
        ---@type checkmate.MetadataContext
        local received_context = nil

        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            assignee = {
              choices = function(context)
                choices_fn_called = true
                received_context = context
                return { "john", "jane", "jack", "jill", "bob", "alice" }
              end,
            },
          },
        })

        local meta_module = require("checkmate.metadata")

        local content = [[- ]] .. m.unchecked .. [[ Task @assignee(john)]]

        local bufnr = h.setup_test_buffer(content)

        local todo_map = parser.discover_todos(bufnr)
        local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task @assignee"))

        local results
        meta_module.get_choices("assignee", function(items)
          results = items
        end, todo_item, bufnr)

        assert.is_true(choices_fn_called)
        assert.is_not_nil(received_context)
        assert.is_true(type(received_context) == "table")

        assert.equal("assignee", received_context.name)
        assert.equal(bufnr, received_context.buffer)
        assert.same({ "john", "jane", "jack", "jill", "bob", "alice" }, results)

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should support asynchronous 'choices' functions", function()
        local choices_fn_called = false
        ---@type checkmate.MetadataContext
        local received_context = nil

        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            project = {
              choices = function(context, callback)
                choices_fn_called = true
                received_context = context
                -- async operation
                vim.defer_fn(function()
                  local projects = { "project-a", "project-b", "project-c" }
                  callback(projects)
                end, 10)
              end,
            },
          },
        })

        local meta_module = require("checkmate.metadata")

        local content = [[- [ ] Task needing data @project()]]

        local bufnr = h.setup_test_buffer(content)

        local todo_map = parser.discover_todos(bufnr)
        local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task needing data"))

        local results
        meta_module.get_choices("project", function(items)
          results = items
        end, todo_item, bufnr)

        -- wait up to 100ms for that deferred callback to fire
        local ok = vim.wait(100, function()
          return results ~= nil
        end, 5)
        assert.is_true(ok)

        assert.is_true(choices_fn_called)
        assert.is_not_nil(received_context)
        assert.is_true(type(received_context) == "table")
        assert.same({ "project-a", "project-b", "project-c" }, results)

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should use `position` opt with `select_metadata_value`", function()
        -- the position opt, when passed, should be used instead of the cursor position
        local cm = h.cm_setup()
        local content = [[
  - [ ] Todo A @due(today)
  - [ ] Todo B]]
        local bufnr = h.setup_test_buffer(content)

        -- cursor is NOT over the metadata
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        cm.select_metadata_value({
          position = { row = 0, col = 18 }, -- pos within the @due() metadata
          picker_fn = function(_, complete)
            complete("tomorrow")
          end,
        })

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.match("@due%(tomorrow%)", lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should update metadata via `with_custom_picker`", function()
        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          metadata = {
            project = {
              style = { fg = "#3f3fee" },
            },
          },
        })

        local content = [[- [ ] Task needing data @project()]]

        local bufnr = h.setup_test_buffer(content)

        local line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
        local t, _, _ = line:find("@")

        vim.api.nvim_win_set_cursor(0, { 1, t })

        ---@type checkmate.MetadataContext
        local received_context

        cm.select_metadata_value({
          picker_fn = function(context, complete)
            received_context = context
            -- simulate user selecting a choice
            vim.schedule(function()
              complete("hello")
            end)
          end,
        })

        vim.wait(20)

        h.exists(received_context --[[@as checkmate.MetadataContext]])

        h.assert_lines_equal(
          vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
          { "- " .. h.get_unchecked_marker() .. " Task needing data @project(hello)" },
          "project value should be correctly updated"
        )

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      describe("metadata callbacks", function()
        it("should call on_add only when metadata is successfully added", function()
          -- spy to track callback execution
          local on_add_called = false
          ---@type checkmate.Todo
          local test_todo

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              test = {
                on_add = function(todo)
                  on_add_called = true
                  test_todo = todo
                end,
                select_on_insert = false,
              },
            },
          })

          local content = [[
# Metadata Callbacks Test

- ]] .. m.unchecked .. [[ A test todo]]

          local bufnr = h.setup_test_buffer(content)

          -- todo item at row 2 (0-indexed)
          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "A test todo"))

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          local success = require("checkmate").add_metadata("test", "test_value")

          vim.wait(10)
          vim.cmd("redraw")

          assert.is_true(success)
          assert.is_true(on_add_called)

          -- check that the todo item was passed to the callback
          assert.is_not_nil(test_todo)
          -- verify some shape re: the received todo, i.e. did we receive a `checkmate.Todo`?
          assert.equal(2, test_todo.row)
          assert.equal("unchecked", test_todo.state)
          assert.equal(0, test_todo.indent)
          assert.equal("-", test_todo.list_marker)
          assert.equal(m.unchecked, test_todo.todo_marker)
          assert.is_not_nil(test_todo.get_metadata("test"))
          assert.is_nil(test_todo.get_parent())
          assert.is_not_nil(test_todo._todo_item)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@test%(test_value%)", lines[3])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_remove only when metadata is successfully removed", function()
          -- spy to track callback execution
          local on_remove_called = false
          ---@type checkmate.Todo
          local test_todo

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              test = {
                on_remove = function(todo)
                  on_remove_called = true
                  test_todo = todo
                end,
              },
            },
          })

          local content = [[
# Metadata Callbacks Test

- ]] .. m.unchecked .. [[ A test todo @test(test_value)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "A test todo"))

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 }) -- set the cursor on the todo item
          local success = require("checkmate").remove_metadata("test")

          vim.wait(10)
          vim.cmd("redraw")

          assert.is_true(success)
          assert.is_true(on_remove_called)
          -- check that the todo item was passed to the callback
          assert.is_not_nil(test_todo)
          assert.is_not_nil(test_todo._todo_item)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.no.matches("@test", lines[3])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_add callback for all todos in bulk (normal and visual mode)", function()
          local unchecked = h.get_unchecked_marker()
          local on_add_calls = {}

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              bulk = {
                on_add = function(todo)
                  -- record the todo's line (1-based)
                  table.insert(on_add_calls, todo.row + 1)
                end,
                select_on_insert = false,
              },
            },
          })

          -- todo file with many todos
          local total_todos = 30

          -- Generate N todos, each on its own line
          local todo_lines = {}
          for i = 1, total_todos do
            table.insert(todo_lines, "- " .. unchecked .. " Bulk task " .. i)
          end
          local content = "# Bulk Metadata Test\n\n" .. table.concat(todo_lines, "\n")

          -- register the metadata tag with a callback that tracks which todos are affected
          local bufnr = h.setup_test_buffer(content)

          -- Normal mode first
          vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- first todo line (after 2 header lines)
          on_add_calls = {}
          cm.toggle_metadata("bulk")

          vim.wait(10)
          vim.cmd("redraw")

          -- callback fired once for todo with added metadata
          assert.equal(1, #on_add_calls, "on_add should be called once")

          -- remove all metadata for next test (reset state)
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          cm.remove_metadata("bulk")

          vim.wait(10)
          vim.cmd("redraw")

          -- Test Visual mode

          -- move to first todo
          -- extend to last todo line
          h.make_selection(3, 0, 2 + total_todos, 0, "V")

          on_add_calls = {}
          cm.toggle_metadata("bulk")
          vim.cmd("normal! \27") -- exit visual mode

          vim.wait(10)
          vim.cmd("redraw")

          -- callback fired once per selected todo (should be all)
          assert.equal(total_todos, #on_add_calls, "on_add should be called for every visually-selected todo")
          -- each line should have metadata
          for i = 3, 2 + total_todos do
            local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
            assert.matches("@bulk", line)
          end

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should not call on_add when updating existing metadata value", function()
          local on_add_called = false
          local on_change_called = false

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              test = {
                on_add = function()
                  on_add_called = true
                end,
                on_change = function()
                  on_change_called = true
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task with existing metadata @test(old_value)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task with existing"))

          -- called on existing metadata - should NOT trigger on_add
          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          cm.add_metadata("test", "new_value")

          vim.wait(10)

          assert.is_false(on_add_called)
          assert.is_true(on_change_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@test%(new_value%)", lines[1])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change when metadata value is updated", function()
          local on_change_called = false
          local received_todo = nil
          local received_old_value = nil
          local received_new_value = nil

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              priority = {
                on_change = function(todo, old_value, new_value)
                  on_change_called = true
                  received_todo = todo
                  received_old_value = old_value
                  received_new_value = new_value
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task with metadata @priority(low)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task with metadata"))

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          cm.add_metadata("priority", "high")

          vim.wait(10)

          assert.is_true(on_change_called)
          assert.is_not_nil(received_todo)
          assert.equal("low", received_old_value)
          assert.equal("high", received_new_value)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@priority%(high%)", lines[1])

          -- call again with same value
          on_change_called = false

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          cm.add_metadata("priority", "high")

          vim.wait(10)
          assert.is_false(on_change_called)

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change via metadata picker selection", function()
          local on_change_called = false
          local received_old_value = nil
          local received_new_value = nil

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              priority = {
                choices = { "low", "medium", "high" },
                on_change = function(_, old_value, new_value)
                  on_change_called = true
                  received_old_value = old_value
                  received_new_value = new_value
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task @priority(medium)]]

          local bufnr = h.setup_test_buffer(content)

          local transaction = require("checkmate.transaction")

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task @priority"))

          local metadata_entry = h.exists(todo_item.metadata.by_tag["priority"])

          -- use transaction to simulate public api that calls a picker
          -- see `select_metadata_value`
          transaction.run(bufnr, function(ctx)
            ctx.add_op(api.set_metadata_value, metadata_entry, "high")
          end)

          vim.wait(10)

          assert.is_true(on_change_called)
          assert.equal("medium", received_old_value)
          assert.equal("high", received_new_value)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@priority%(high%)", lines[1])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle on_change callbacks that trigger other metadata operations", function()
          local on_change_called = false
          local on_add_called = false

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              status = {
                on_change = function(_, _, new_value)
                  on_change_called = true
                  if new_value == "done" then
                    require("checkmate").add_metadata("completed", "today")
                  end
                end,
              },
              ---@diagnostic disable-next-line: missing-fields
              completed = {
                on_add = function()
                  on_add_called = true
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task @status(in-progress)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task @status"))

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          cm.add_metadata("status", "done")

          vim.wait(10)

          assert.is_true(on_change_called)
          assert.is_true(on_add_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@status%(done%)", lines[1])
          assert.matches("@completed%(today%)", lines[1])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change for bulk operations in visual mode", function()
          local change_count = 0
          local changes = {}

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              priority = {
                on_change = function(todo, old_value, new_value)
                  change_count = change_count + 1
                  table.insert(changes, {
                    text = todo.text,
                    old = old_value,
                    new = new_value,
                  })
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task 1 @priority(low)
- ]] .. m.unchecked .. [[ Task 2 @priority(medium)
- ]] .. m.unchecked .. [[ Task 3 @priority(high)]]

          local bufnr = h.setup_test_buffer(content)

          h.make_selection(1, 0, 3, 0, "V")

          cm.add_metadata("priority", "urgent")

          vim.wait(10)

          assert.equal(3, change_count)

          assert.equal("low", changes[1].old)
          assert.equal("urgent", changes[1].new)

          assert.equal("medium", changes[2].old)
          assert.equal("urgent", changes[2].new)

          assert.equal("high", changes[3].old)
          assert.equal("urgent", changes[3].new)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          for i = 1, 3 do
            assert.matches("@priority%(urgent%)", lines[i])
          end

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle errors in metadata callbacks gracefully", function()
          local on_add_called = false
          local on_change_called = false
          local on_remove_called = false

          ---@diagnostic disable-next-line: missing-fields
          local cm = h.cm_setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              errortest = {
                on_add = function()
                  on_add_called = true
                  error("error in on_add callback")
                end,
                on_change = function()
                  on_change_called = true
                  error("error in on_change callback")
                end,
                on_remove = function()
                  on_remove_called = true
                  error("error in on_remove callback")
                end,
              },
            },
          })

          local content = [[
- ]] .. m.unchecked .. [[ Task for testing callback errors]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.exists(h.find_todo_by_text(todo_map, "Task for testing"))

          -- add
          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          local add_success = cm.add_metadata("errortest", "initial")

          vim.wait(10)

          assert.is_true(add_success)
          assert.is_true(on_add_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@errortest%(initial%)", lines[1])

          -- update
          local change_success = cm.add_metadata("errortest", "changed")

          vim.wait(10)

          assert.is_true(change_success)
          assert.is_true(on_change_called)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@errortest%(changed%)", lines[1])

          -- remove
          local remove_success = cm.remove_metadata("errortest")

          vim.wait(10)

          assert.is_true(remove_success)
          assert.is_true(on_remove_called)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.no.matches("@errortest", lines[1])

          local todo_map_after = parser.discover_todos(bufnr)
          assert.is_not_nil(todo_map_after)
          assert.equal(1, vim.tbl_count(todo_map_after), "Todo map should still be valid")

          -- can still perform operations
          local toggle_success = cm.toggle()
          assert.is_true(toggle_success)

          vim.wait(10)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("- " .. m.checked .. " Task for testing", lines[1])

          finally(function()
            h.cleanup_buffer(bufnr)
          end)
        end)
      end)
    end)

    it("should handle todo hierarchies with correct write to file", function()
      local content = [[
# Todo Hierarchy

- [ ] Parent task
  - [ ] Child task 1
  - [ ] Child task 2
    - [ ] Grandchild task
  - [ ] Child task 3
- [ ] Another parent]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local todo_map = parser.discover_todos(bufnr)

      -- Find parent todo
      local parent_todo_item = h.find_todo_by_text(todo_map, "- " .. m.unchecked .. " Parent task")
      parent_todo_item = h.exists(parent_todo_item)
      local parent_todo = util.build_todo(parent_todo_item)

      assert.equal(3, #parent_todo_item.children)

      require("checkmate").set_todo_state(parent_todo, "checked")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.matches("- " .. m.checked .. " Parent task", lines[3])

      vim.cmd("write")
      h.wait_for_write(bufnr)

      local saved_content = h.read_file_content(file_path)

      if not saved_content then
        error("error reading file content")
      end

      local saved_lines = {}
      for line in saved_content:gmatch("([^\n]*)\n?") do
        table.insert(saved_lines, line)
      end

      h.assert_lines_equal(saved_lines, {
        "# Todo Hierarchy",
        "",
        "- [x] Parent task",
        "  - [ ] Child task 1",
        "  - [ ] Child task 2",
        "    - [ ] Grandchild task",
        "  - [ ] Child task 3",
        "- [ ] Another parent",
        "",
      }, "read from file")

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should handle multiple todo operations in sequence", function()
      local content = [[
# Todo Sequence

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      -- toggle task 1
      vim.api.nvim_win_set_cursor(0, { 3, 3 }) -- on Task 1
      require("checkmate").toggle()
      vim.wait(20)

      -- add metadata to task 2
      vim.api.nvim_win_set_cursor(0, { 4, 3 }) -- on Task 2
      require("checkmate").add_metadata("priority", "high")
      vim.cmd(" ")
      vim.wait(20)

      -- check task 3
      vim.api.nvim_win_set_cursor(0, { 5, 3 }) -- on Task 3
      require("checkmate").check()
      vim.wait(20)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.matches("- " .. m.checked .. " Task 1", lines[3])
      assert.matches("- " .. m.unchecked .. " Task 2 @priority%(high%)", lines[4])
      assert.matches("- " .. m.checked .. " Task 3", lines[5])

      vim.cmd("write")
      h.wait_for_write(bufnr)

      local saved_content = h.read_file_content(file_path)
      if not saved_content then
        error("error reading file content")
      end

      assert.matches("- %[x%] Task 1", saved_content)
      assert.matches("- %[ %] Task 2 @priority%(high%)", saved_content)
      assert.matches("- %[x%] Task 3", saved_content)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should handle partial visual selections correctly when toggling", function()
      local cm = h.cm_setup()

      local content = [[
- ]] .. m.unchecked .. [[ Task 1
  with continuation
- ]] .. m.unchecked .. [[ Task 2
- ]] .. m.unchecked .. [[ Task 3
  also continues]]

      local bufnr = h.setup_test_buffer(content)

      -- middle of Task 1 to middle of Task 3
      h.make_selection(1, 5, 4, 10, "v")

      cm.toggle()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      -- all covered todos should be toggled
      assert.matches("- " .. m.checked .. " Task 1", lines[1])
      assert.matches("- " .. m.checked .. " Task 2", lines[3])
      assert.matches("- " .. m.checked .. " Task 3", lines[4])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    describe("cycle state", function()
      -- ensure that "cycling" state will propagate state up/down the same way that "toggle" does
      it("should propagate state when cycling", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.unchecked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
    - ]] .. m.unchecked .. [[ Grandchild 1]]

        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({
          smart_toggle = {
            enabled = true,
            include_cycle = true,
            check_down = "direct_children",
            uncheck_down = "none",
            check_up = "direct_children",
            uncheck_up = "direct_children",
          },
        })

        local bufnr = h.setup_test_buffer(content)

        -- cursor to parent task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        -- should cycle to checked since it defaults to next `order` (unchecked = 1, checked = 2)
        cm.cycle()

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        h.assert_lines_equal(lines, {
          "- " .. m.checked .. " Parent task",
          "  - " .. m.checked .. " Child 1",
          "  - " .. m.checked .. " Child 2",
          -- grandchild should NOT be checked (only direct children)
          -- stylua: ignore
          "    - " .. m.unchecked .. " Grandchild 1",
        })

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should cycle between default states when no custom states exist", function()
        local cm = require("checkmate")
        cm.setup() -- dont use h.cm_setup() here because it includes a pending state

        local content = [[
- ]] .. m.unchecked .. [[ Task to cycle]]

        local bufnr = h.setup_test_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        -- cycle forward (unchecked -> checked)
        cm.cycle()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked, lines[1])

        -- cycle forward again (checked -> unchecked, wrapping)
        cm.cycle()
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked, lines[1])

        -- cycle backward (unchecked -> checked, wrapping)
        cm.cycle({ backward = true })
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked, lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)
  end)

  describe("get_todo()", function()
    local cm
    before_each(function()
      cm = h.cm_setup()
      h.ensure_normal_mode()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should return todo under cursor in normal mode", function()
      local content = "- " .. m.unchecked .. " Task A"
      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo = h.exists(cm.get_todo())
      assert.equal("unchecked", todo.state)
      assert.matches("Task A", todo.text)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should return nil on non-todo line", function()
      local bufnr = h.setup_test_buffer("Plain text line")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local todo = cm.get_todo()
      assert.is_nil(todo)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should resolve using the FIRST line of the selection in visual mode", function()
      local unchecked = h.get_unchecked_marker()
      local content = {
        "- " .. unchecked .. " First",
        "- " .. unchecked .. " Second",
      }
      local bufnr = h.setup_test_buffer(content)

      -- select both lines, linewise
      h.make_selection(1, 0, 2, 0, "V")

      local todo = h.exists(cm.get_todo())
      assert.matches("First", todo.text)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should resolve from a continuation line; with root_only=true returns nil", function()
      local content = [[
- [ ] Todo item @test1(foo)
      @test3(baz)
]]
      local bufnr = h.setup_test_buffer(content)

      -- cursor on the continuation line (2nd line)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      -- should resolve to the same todo
      local todo = h.exists(cm.get_todo())
      assert.matches("Todo item", todo.text)

      -- root_only=true: should not resolve from continuation line
      local root_only_todo = cm.get_todo({ root_only = true })
      assert.is_nil(root_only_todo)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should return nil for non-active buffers (non-markdown)", function()
      -- scratch buffer with a non-markdown ft so Checkmate doesn't activate it
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [ ] Looks like a todo, but in lua ft" })
      vim.bo[bufnr].filetype = "lua"

      local todo = cm.get_todo({ bufnr = bufnr })
      assert.is_nil(todo)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("movement", function()
    local cm
    before_each(function()
      cm = h.cm_setup()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should move cursor to next metadata entry and wrap around", function()
      local content = "- [ ] Task @foo(1) @bar(2) @baz(3)"
      local bufnr = h.setup_test_buffer(content)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
      local row = todo_item.range.start.row + 1

      vim.api.nvim_win_set_cursor(0, { row, 0 })

      -- api is the internal api.lua module

      -- cycle forward through each metadata
      api.move_cursor_to_metadata(bufnr, todo_item)
      local _, col1 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[1].range.start.col, col1)

      api.move_cursor_to_metadata(bufnr, todo_item)
      local _, col2 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[2].range.start.col, col2)

      api.move_cursor_to_metadata(bufnr, todo_item)
      local _, col3 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[3].range.start.col, col3)

      -- wrap back to the first
      api.move_cursor_to_metadata(bufnr, todo_item)
      local _, col4 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[1].range.start.col, col4)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should move cursor to previous metadata entry and wrap around, skipping current metadata", function()
      local content = "- [ ] Task @foo(1) @bar(2) @baz(3)"
      local bufnr = h.setup_test_buffer(content)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
      local row = todo_item.range.start.row + 1

      -- place cursor inside the second metadata range
      local bar = todo_item.metadata.entries[2]
      local mid = bar.range.start.col + 2
      vim.api.nvim_win_set_cursor(0, { row, mid })

      -- go backwards: should skip the one we're in and land on the first
      api.move_cursor_to_metadata(bufnr, todo_item, true)
      local _, col1 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[1].range.start.col, col1)

      -- another backwards wraps to the last
      api.move_cursor_to_metadata(bufnr, todo_item, true)
      local _, col2 = unpack(vim.api.nvim_win_get_cursor(0))
      assert.equal(todo_item.metadata.entries[3].range.start.col, col2)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("smart toggle", function()
    local function setup_smart_toggle_buffer(content, smart_toggle_config)
      -- merge our 'testing' smart_toggle config with base config
      local config_override = {
        smart_toggle = vim.tbl_extend("force", {
          enabled = true,
          check_down = "direct_children",
          uncheck_down = "none",
          check_up = "direct_children",
          uncheck_up = "direct_children",
        }, smart_toggle_config or {}),
      }

      local cm = h.cm_setup(config_override)

      return h.setup_test_buffer(content), cm
    end

    describe("downward propagation", function()
      it("should check all direct children when parent is checked (check_down='direct_children')", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.unchecked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
    - ]] .. m.unchecked .. [[ Grandchild 1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("- " .. m.checked .. " Child 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 2", lines[3])
        -- grandchild should NOT be checked (only direct children)
        assert.matches("- " .. m.unchecked .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should check all descendants when parent is checked (check_down='all_children')", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.unchecked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
    - ]] .. m.unchecked .. [[ Grandchild 1
      - ]] .. m.unchecked .. [[ Great-grandchild 1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { check_down = "all_children" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        -- all descendants should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("- " .. m.checked .. " Child 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 2", lines[3])
        assert.matches("- " .. m.checked .. " Grandchild 1", lines[4])
        assert.matches("- " .. m.checked .. " Great%-grandchild 1", lines[5])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should not affect children when parent is checked (check_down='none')", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.unchecked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { check_down = "none" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        -- only parent is checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("- " .. m.unchecked .. " Child 1", lines[2])
        assert.matches("- " .. m.unchecked .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should uncheck direct children when parent is unchecked (uncheck_down='direct_children')", function()
        local content = [[
- ]] .. m.checked .. [[ Parent task
  - ]] .. m.checked .. [[ Child 1
  - ]] .. m.checked .. [[ Child 2
    - ]] .. m.checked .. [[ Grandchild 1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { uncheck_down = "direct_children" })

        -- cursor to parent task and toggle (uncheck it)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked .. " Parent task", lines[1])
        assert.matches("- " .. m.unchecked .. " Child 1", lines[2])
        assert.matches("- " .. m.unchecked .. " Child 2", lines[3])
        -- grandchild should remain checked (only direct children affected)
        assert.matches("- " .. m.checked .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)

    describe("upward propagation", function()
      it("should check parent when all direct children are checked (check_up='direct_children')", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.checked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
  - ]] .. m.checked .. [[ Child 3
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { check_up = "direct_children" })

        -- check the remaining unchecked child
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        cm.toggle()

        vim.wait(10)

        -- parent should now be checked since all direct children are checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("- " .. m.checked .. " Child 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 2", lines[3])
        assert.matches("- " .. m.checked .. " Child 3", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should check parent when all descendants are checked (check_up='all_children')", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.checked .. [[ Child 1
  - ]] .. m.unchecked .. [[ Child 2
    - ]] .. m.checked .. [[ Grandchild 1
    - ]] .. m.unchecked .. [[ Grandchild 2
]]

        -- we use a check_down = "none" here to test only the check_up functionality,
        -- otherwise, the first check with propagate the check to all children
        local bufnr, cm = setup_smart_toggle_buffer(content, { check_up = "all_children", check_down = "none" })

        -- check Child 2 first
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        cm.toggle()
        vim.wait(10)

        -- parent should NOT be checked yet (grandchild 2 is still unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked .. " Parent task", lines[1])

        -- now check Grandchild 2
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        cm.toggle()
        vim.wait(10)

        -- now parent should be checked (all descendants are checked)
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("- " .. m.checked .. " Child 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 2", lines[3])
        assert.matches("- " .. m.checked .. " Grandchild 1", lines[4])
        assert.matches("- " .. m.checked .. " Grandchild 2", lines[5])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should uncheck parent when any direct child is unchecked (uncheck_up='direct_children')", function()
        local content = [[
- ]] .. m.checked .. [[ Parent task
  - ]] .. m.checked .. [[ Child 1
  - ]] .. m.checked .. [[ Child 2
    - ]] .. m.unchecked .. [[ Grandchild 1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { uncheck_up = "direct_children" })

        -- uncheck one child
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        cm.toggle()

        vim.wait(10)

        -- parent should be unchecked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked .. " Parent task", lines[1])
        assert.matches("- " .. m.unchecked .. " Child 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should uncheck parent when any descendant is unchecked (uncheck_up='all_children')", function()
        local content = [[
- ]] .. m.checked .. [[ Parent task
  - ]] .. m.checked .. [[ Child 1
  - ]] .. m.checked .. [[ Child 2
    - ]] .. m.checked .. [[ Grandchild 1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { uncheck_up = "all_children", uncheck_down = "none" })

        -- uncheck the grandchild
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        cm.toggle()

        vim.wait(10)

        -- parent should be unchecked (because a descendant is unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked .. " Parent task", lines[1])
        assert.matches("- " .. m.checked .. " Child 1", lines[2])
        -- child 2 is unchecked as it is a parent of Grandchild 1
        assert.matches("- " .. m.unchecked .. " Child 2", lines[3])
        assert.matches("- " .. m.unchecked .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)

    describe("complex scenarios", function()
      it("should handle multiple parent todo selection with smart toggle", function()
        local content = [[
- ]] .. m.unchecked .. [[ Task A
  - ]] .. m.unchecked .. [[ Task A.1
- ]] .. m.unchecked .. [[ Task B
  - ]] .. m.unchecked .. [[ Task B.1
    - ]] .. m.unchecked .. [[ Task B.1.1
- ]] .. m.unchecked .. [[ Task C
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- select both parent tasks in visual mode
        h.make_selection(1, 0, 3, 0, "V")

        cm.toggle()

        vim.wait(10)

        -- all tasks should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Task A", lines[1])
        assert.matches("- " .. m.checked .. " Task A%.1", lines[2])
        assert.matches("- " .. m.checked .. " Task B", lines[3])
        assert.matches("- " .. m.checked .. " Task B%.1", lines[4])
        -- should not propagate check to grandchild if check_down = "direct_children"
        assert.matches("- " .. m.unchecked .. " Task B%.1%.1", lines[5])
        -- should not check sibling parent Task C
        assert.matches("- " .. m.unchecked .. " Task C", lines[6])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should check common parent when all selected siblings become checked (complete)", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent
  - ]] .. m.unchecked .. [[ A
  - ]] .. m.unchecked .. [[ B
- ]] .. m.unchecked .. [[ Other
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, {
          check_down = "none",
          check_up = "direct_children",
        })

        -- visually select A and B
        h.make_selection(2, 0, 3, 0, "V")
        cm.toggle()
        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        -- A and B now checked, so Parent should check
        assert.matches("- " .. m.checked .. " Parent", lines[1])
        assert.matches("A", lines[2])
        assert.matches("B", lines[3])
        assert.matches("- " .. m.unchecked .. " Other", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should handle cascading propagation correctly", function()
        local content = [[
- ]] .. m.unchecked .. [[ Grandparent
  - ]] .. m.unchecked .. [[ Parent 1
    - ]] .. m.checked .. [[ Child 1.1
    - ]] .. m.unchecked .. [[ Child 1.2
  - ]] .. m.checked .. [[ Parent 2
    - ]] .. m.checked .. [[ Child 2.1
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, {
          check_down = "none",
          check_up = "direct_children",
        })

        -- check Child 1.2 - this should cascade up
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        cm.toggle()

        vim.wait(10)

        -- should check Child 1.2, Parent 1, and Grandparent
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Grandparent", lines[1])
        assert.matches("- " .. m.checked .. " Parent 1", lines[2])
        assert.matches("- " .. m.checked .. " Child 1%.1", lines[3])
        assert.matches("- " .. m.checked .. " Child 1%.2", lines[4])
        assert.matches("- " .. m.checked .. " Parent 2", lines[5])
        assert.matches("- " .. m.checked .. " Child 2%.1", lines[6])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should handle smart toggle with mixed custom states", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.pending .. [[ Child pending
  - ]] .. m.unchecked .. [[ Child unchecked
  - ]] .. m.checked .. [[ Child checked
]]

        local bufnr, cm = setup_smart_toggle_buffer(content, {
          check_down = "direct_children",
          check_up = "direct_children",
        })

        -- toggle parent to checked
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- parent becomes checked
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        -- pending child stays pending (custom states don't changed during propagation)
        assert.matches("- " .. m.pending .. " Child pending", lines[2])
        -- unchecked child becomes checked
        assert.matches("- " .. m.checked .. " Child unchecked", lines[3])
        -- checked child stays checked
        assert.matches("- " .. m.checked .. " Child checked", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)
    describe("edge cases", function()
      it("should not propagate when smart_toggle is disabled", function()
        local content = [[
- ]] .. m.unchecked .. [[ Task A
  - ]] .. m.unchecked .. [[ Task A.1
  - ]] .. m.unchecked .. [[ Task A.2
- ]] .. m.unchecked .. [[ Task B
]]

        local bufnr, cm = setup_smart_toggle_buffer(
          content,
          { enabled = false, check_down = "direct_children", check_up = "direct_children" }
        )

        -- toggle first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.toggle()

        vim.wait(10)

        -- only first task should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.checked .. " Task A", lines[1])
        assert.matches("- " .. m.unchecked .. " Task A%.1", lines[2])
        assert.matches("- " .. m.unchecked .. " Task A%.2", lines[3])
        assert.matches("- " .. m.unchecked .. " Task B", lines[4])

        -- reset first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        cm.uncheck()

        -- select both child tasks in visual mode
        h.make_selection(2, 0, 3, 0, "V")

        cm.check()
        vim.wait(10)

        -- first task should not be checked (no propagation from children)
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. m.unchecked .. " Task A", lines[1])
        assert.matches("- " .. m.checked .. " Task A%.1", lines[2])
        assert.matches("- " .. m.checked .. " Task A%.2", lines[3])
        assert.matches("- " .. m.unchecked .. " Task B", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      -- NOTE: may update this in the future if we allow custom states to mimic behavior of
      -- checked or unchecked. i.e. a "pending" state could be set to behave as "unchecked", thus
      -- blocking the below `check_up` (whereas it does not block currently)
      it("should ignore custom states when deciding parent propagation", function()
        local content = [[
- ]] .. m.unchecked .. [[ Parent task
  - ]] .. m.pending .. [[ Child custom
  - ]] .. m.unchecked .. [[ Child unchecked
]]

        -- only looking at check_up/all_children, no down propagation
        local bufnr, cm = setup_smart_toggle_buffer(content, { check_up = "all_children", check_down = "none" })

        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        cm.toggle()
        vim.wait(10)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        -- child “pending” stays pending, the other child becomes checked,
        -- and parent becomes checked because “pending” is ignored.
        assert.matches("- " .. m.checked .. " Parent task", lines[1])
        assert.matches("Child custom", lines[2])
        assert.matches("Child unchecked", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)
  end)

  describe("archive system", function()
    it("should not create archive section when no checked todos exist", function()
      local cm = h.cm_setup()

      local config = require("checkmate.config")

      local content = [[
# Todo List
- ]] .. m.unchecked .. [[ Task 1
- ]] .. m.unchecked .. [[ Task 2
  - ]] .. m.unchecked .. [[ Subtask 2.1
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- no archive section should have been created
      local archive_heading_string = util.get_heading_string(
        config.get_defaults().archive.heading.title,
        config.get_defaults().archive.heading.level
      )
      assert.no.matches(vim.pesc(archive_heading_string), buffer_content)

      local expected_main_content = {
        "# Todo List",
        "- " .. m.unchecked .. " Task 1",
        "- " .. m.unchecked .. " Task 2",
        "  - " .. m.unchecked .. " Subtask 2.1",
      }

      -- original content is unchanged
      local result, err = h.verify_content_lines(buffer_content, expected_main_content)
      assert.equal(result, true, err)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should archive completed todo items to specified section", function()
      local cm = h.cm_setup()

      local config = require("checkmate.config")

      local content = [[
# Todo List

- ]] .. m.unchecked .. [[ Unchecked task 1
- ]] .. m.checked .. [[ Checked task 1
  - ]] .. m.checked .. [[ Checked subtask 1.1
  - ]] .. m.unchecked .. [[ Unchecked subtask 1.2
- ]] .. m.unchecked .. [[ Unchecked task 2
- ]] .. m.checked .. [[ Checked task 2
  - ]] .. m.checked .. [[ Checked subtask 2.1

## Existing Section
Some content here
]]

      local bufnr = h.setup_test_buffer(content)

      local heading_title = "Completed Todos"
      cm.archive({ heading = { title = heading_title } })

      vim.wait(10)
      vim.cmd("redraw")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(heading_title, config.get_defaults().archive.heading.level)

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      -- checked top-level tasks were removed
      assert.no.matches("- " .. m.checked .. " Checked task 1", main_section)
      assert.no.matches("- " .. m.checked .. " Checked task 2", main_section)

      -- unchecked tasks remain
      assert.matches("- " .. m.unchecked .. " Unchecked task 1", main_section)
      assert.matches("- " .. m.unchecked .. " Unchecked task 2", main_section)

      -- archive section was created
      assert.matches(archive_heading_string, buffer_content)

      -- contents were moved to archive section
      local archive_section = buffer_content:match(archive_heading_string .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. heading_title,
        "",
        "- " .. m.checked .. " Checked task 1",
        "  - " .. m.checked .. " Checked subtask 1.1",
        "  - " .. m.unchecked .. " Unchecked subtask 1.2",
        "- " .. m.checked .. " Checked task 2",
        "  - " .. m.checked .. " Checked subtask 2.1",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      -- 'Existing Section' should still be present
      assert.matches("## Existing Section", buffer_content)
      assert.matches("Some content here", buffer_content)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should work with custom archive heading", function()
      -- setup with custom archive heading
      local heading_title = "Completed Items"
      local heading_level = 4 -- ####

      ---@diagnostic disable-next-line: missing-fields
      local cm = h.cm_setup({
        archive = { heading = { title = heading_title, level = heading_level } },
      })

      local content = [[
# Custom Archive Heading Test

- ]] .. m.unchecked .. [[ Unchecked task
- ]] .. m.checked .. [[ Checked task
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()
      vim.wait(10)
      vim.cmd("redraw")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(heading_title, heading_level)

      -- custom heading was used
      assert.matches(archive_heading_string, buffer_content)

      -- content was archived correctly
      local archive_section = buffer_content:match("#### Completed Items" .. ".*$")
      assert.is_not_nil(archive_section)
      assert.matches("- " .. m.checked .. " Checked task", archive_section)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should merge with existing archive section", function()
      local config = require("checkmate.config")

      ---@diagnostic disable-next-line: missing-fields
      local cm = h.cm_setup({
        ---@diagnostic disable-next-line: missing-fields
        archive = {
          newest_first = false, -- ensure newly added todos end up at top of archive section
        },
      })

      local archive_heading_string = util.get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local content = [[
# Existing Archive Test

- ]] .. m.unchecked .. [[ Unchecked task
- ]] .. m.checked .. [[ Checked task to archive

]] .. archive_heading_string .. [[

- ]] .. m.checked .. [[ Previously archived task
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- checked task was removed from main content
      local main_content = buffer_content:match("^(.-)" .. archive_heading_string)
      assert.is_not_nil(main_content)
      assert.no.matches("- " .. m.checked .. " Checked task to archive", main_content)

      -- unchecked task remains in main content
      assert.matches("- " .. m.unchecked .. " Unchecked task", main_content)

      local archive_section = buffer_content:match(archive_heading_string .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. config.get_defaults().archive.heading.title,
        "",
        "- " .. m.checked .. " Previously archived task",
        "- " .. m.checked .. " Checked task to archive",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      -- verify that parent_spacing is respected when merging with existing archive
      -- this assumes default parent_spacing = 0, so no extra blank lines between archived items
      local lines_array = vim.split(archive_section, "\n", { plain = true })
      for i = 2, #lines_array - 1 do -- Skip heading and last line
        if lines_array[i] == "" and lines_array[i + 1] and lines_array[i + 1] == "" then
          error("Found multiple consecutive blank lines in archive section")
        end
      end

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should insert the configured parent_spacing between archived parent blocks", function()
      local config = require("checkmate.config")

      for _, spacing in ipairs({ 0, 1, 2 }) do
        ---@diagnostic disable-next-line: missing-fields
        local cm = h.cm_setup({ archive = { parent_spacing = spacing } })
        local content = [[
# Tasks
- ]] .. m.unchecked .. [[ Active task
- ]] .. m.checked .. [[ Done task A
  - ]] .. m.checked .. [[ Done subtask A.1
- ]] .. m.checked .. [[ Done task B
]]

        local bufnr = h.setup_test_buffer(content)

        cm.archive()
        vim.wait(10)
        vim.cmd("redraw")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local buffer_content = table.concat(lines, "\n")

        local archive_heading_string = util.get_heading_string(
          vim.pesc(config.get_defaults().archive.heading.title),
          config.get_defaults().archive.heading.level
        )

        -- find archive section
        local start_idx = buffer_content:find(archive_heading_string, 1, true)
        assert.is_not_nil(start_idx)
        ---@cast start_idx integer

        -- grab everything from the heading to EOF
        local archive_section = buffer_content:sub(start_idx)
        local archive_lines = vim.split(archive_section, "\n", { plain = true })

        -- locate the two parent tasks
        local first_root = "- " .. m.checked .. " Done task A"
        local second_root = "- " .. m.checked .. " Done task B"
        local first_idx, second_idx

        for idx, l in ipairs(archive_lines) do
          if l == first_root then
            first_idx = idx
          end
          if l == second_root then
            second_idx = idx
          end
        end

        assert.is_not_nil(first_idx)
        assert.is_not_nil(second_idx)
        assert.is_true(second_idx > first_idx)

        -- count blank lines between the two roots
        -- we need to count from after the last line of the first block
        -- (which includes its subtask) to just before the second root
        local first_block_end = first_idx + 1 -- The subtask is right after the parent
        local blanks_between = 0

        for i = first_block_end + 1, second_idx - 1 do
          if archive_lines[i] == "" then
            blanks_between = blanks_between + 1
          end
        end

        assert.equal(
          spacing,
          blanks_between,
          string.format(
            "For parent_spacing = %d: Expected %d blank lines between parent blocks, got %d",
            spacing,
            spacing,
            blanks_between
          )
        )

        -- not in finally since part of a loop
        h.cleanup_buffer(bufnr)
      end
    end)

    it("should preserve single blank line when todo has spacing on both sides", function()
      local config = require("checkmate.config")

      local cm = h.cm_setup()

      local content = [[
# Todo List

- ]] .. m.unchecked .. [[ Task A

- ]] .. m.checked .. [[ Task B (to archive)

- ]] .. m.unchecked .. [[ Task C
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "# Todo List",
        "",
        "- " .. m.unchecked .. " Task A",
        "",
        "- " .. m.unchecked .. " Task C",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should not create double spacing when archiving adjacent todos", function()
      local config = require("checkmate.config")

      local cm = h.cm_setup()

      local content = [[
- ]] .. m.unchecked .. [[ Task A

- ]] .. m.checked .. [[ Task B (to archive)
- ]] .. m.checked .. [[ Task C (to archive)

- ]] .. m.unchecked .. [[ Task D
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "- " .. m.unchecked .. " Task A",
        "",
        "- " .. m.unchecked .. " Task D",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle no spacing between todos correctly", function()
      local config = require("checkmate.config")

      local cm = h.cm_setup()

      local content = [[
- ]] .. m.unchecked .. [[ Task A
- ]] .. m.checked .. [[ Task B (to archive)
- ]] .. m.unchecked .. [[ Task C
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "- " .. m.unchecked .. " Task A",
        "- " .. m.unchecked .. " Task C",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle spacing for complex mixed content correctly", function()
      local config = require("checkmate.config")

      local cm = h.cm_setup()

      local content = [[
# Project

Some intro text.

- ]] .. m.unchecked .. [[ Task A

- ]] .. m.checked .. [[ Task B (to archive)
  - ]] .. m.checked .. [[ Subtask B.1

## Section 1

Content for section 1.

- ]] .. m.checked .. [[ Task C (to archive)

More content.

- ]] .. m.unchecked .. [[ Task D

## Section 2

Final content.
]]

      local bufnr = h.setup_test_buffer(content)

      cm.archive()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = util.get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "# Project",
        "",
        "Some intro text.",
        "",
        "- " .. m.unchecked .. " Task A",
        "",
        "## Section 1",
        "",
        "Content for section 1.",
        "",
        "More content.",
        "",
        "- " .. m.unchecked .. " Task D",
        "",
        "## Section 2",
        "",
        "Final content.",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should be idempotent when run twice", function()
      local cm = h.cm_setup()

      local content = [[
- ]] .. m.checked .. [[ A
]]
      local bufnr = h.setup_test_buffer(content)

      cm.archive()
      local once = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      cm.archive()
      local twice = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

      assert.equal(once, twice, "Second archive changed buffer")

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)
end)
