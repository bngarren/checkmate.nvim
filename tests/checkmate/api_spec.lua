describe("API", function()
  local h = require("tests.checkmate.helpers")

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

    h.ensure_normal_mode()
  end)

  describe("file operations", function()
    it("should save todo file with correct Markdown syntax", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
# Complex Todo List
## Work Tasks
- ]] .. unchecked .. [[ Major project planning
  * ]] .. unchecked .. [[ Research competitors
  * ]] .. checked .. [[ Create timeline
  * ]] .. unchecked .. [[ Assign resources
    + ]] .. checked .. [[ Allocate budget
    + ]] .. unchecked .. [[ Schedule meetings
    + ]] .. unchecked .. [[ Set milestones
  * ]] .. checked .. [[ Draft proposal
- ]] .. checked .. [[ Email weekly report
## Personal Tasks
1. ]] .. unchecked .. [[ Grocery shopping
2. ]] .. checked .. [[ Call dentist
3. ]] .. unchecked .. [[ Plan vacation
   - ]] .. unchecked .. [[ Research destinations
   - ]] .. checked .. [[ Check budget]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      vim.cmd("write")

      vim.cmd("sleep 10m")

      local saved_content = h.read_file_content(file_path)

      if not saved_content then
        error("error reading file content")
      end

      local lines = vim.split(saved_content, "\n")

      assert.equal("# Complex Todo List", lines[1])
      assert.equal("## Work Tasks", lines[2])
      assert.equal("- [ ] Major project planning", lines[3]:gsub("%s+$", ""))
      assert.equal("  * [ ] Research competitors", lines[4]:gsub("%s+$", ""))
      assert.equal("  * [x] Create timeline", lines[5]:gsub("%s+$", ""))
      assert.equal("  * [ ] Assign resources", lines[6]:gsub("%s+$", ""))
      assert.equal("    + [x] Allocate budget", lines[7]:gsub("%s+$", ""))
      assert.equal("    + [ ] Schedule meetings", lines[8]:gsub("%s+$", ""))
      assert.equal("    + [ ] Set milestones", lines[9]:gsub("%s+$", ""))
      assert.equal("  * [x] Draft proposal", lines[10]:gsub("%s+$", ""))
      assert.equal("- [x] Email weekly report", lines[11]:gsub("%s+$", ""))
      assert.equal("## Personal Tasks", lines[12])
      assert.equal("1. [ ] Grocery shopping", lines[13]:gsub("%s+$", ""))
      assert.equal("2. [x] Call dentist", lines[14]:gsub("%s+$", ""))
      assert.equal("3. [ ] Plan vacation", lines[15]:gsub("%s+$", ""))
      assert.equal("   - [ ] Research destinations", lines[16]:gsub("%s+$", ""))
      assert.equal("   - [x] Check budget", lines[17]:gsub("%s+$", ""))

      -- verify unicode symbols are NOT present in the saved file
      assert.no.matches(vim.pesc(unchecked), saved_content)
      assert.no.matches(vim.pesc(checked), saved_content)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should load todo file with Markdown checkboxes converted to Unicode", function()
      local content = [[
# Todo List

- [ ] Unchecked task
- [x] Checked task
      ]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", lines[3])
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", lines[4])

      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      assert.equal(vim.tbl_count(todo_map), 2)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should maintain todo state through edit-save-reload cycle", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
# Todo List

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
      ]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local task_2 = h.find_todo_by_text(todo_map, "- " .. unchecked .. " Task 2")

      assert.is_not_nil(task_2)
      ---@cast task_2 checkmate.TodoItem

      local success = require("checkmate").set_todo_item(task_2, "checked")
      assert.is_true(success)

      vim.cmd("write")
      vim.cmd("sleep 10m")

      -- close and reopen the file
      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.cmd("edit " .. file_path)
      bufnr = vim.api.nvim_get_current_buf()

      -- should already be, but just to be safe
      vim.bo[bufnr].filetype = "markdown"

      todo_map = require("checkmate.parser").discover_todos(bufnr)
      local task_2_reloaded = h.find_todo_by_text(todo_map, "- " .. checked .. " Task 2")

      assert.is_not_nil(task_2_reloaded)
      ---@cast task_2_reloaded checkmate.TodoItem
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

        vim.fn.writefile = original_writefile

        finally(function()
          vim.fn.writefile = original_writefile
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should call BufWritePre and BufWritePost", function()
        local bufnr = h.setup_todo_file_buffer("")
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
          h.cleanup_buffer(bufnr)
          vim.api.nvim_clear_autocmds({ group = augroup })
        end)
      end)
    end)
  end)

  describe("todo collection", function()
    local cm
    before_each(function()
      cm = require("checkmate")
      cm.setup()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should collect a single todo under cursor in normal mode", function()
      local unchecked = h.get_unchecked_marker()

      local content = [[
- ]] .. unchecked .. [[ Task A
- ]] .. unchecked .. [[ Task B
]]
      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local items = require("checkmate.api").collect_todo_items_from_selection(false)
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

      local items = require("checkmate.api").collect_todo_items_from_selection(true)
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
    local cm
    before_each(function()
      cm = require("checkmate")
      cm.setup()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should convert a regular line to a todo item", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local default_list_marker = config.get_defaults().default_list_marker

      local content = [[
# Todo List

This is a regular line
      ]]

      local bufnr = h.setup_test_buffer(content)

      -- move cursor to the regular line
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.matches(default_list_marker .. " " .. vim.pesc(unchecked) .. " This is a regular line", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should convert a line with existing list marker to todo", function()
      local unchecked = h.get_unchecked_marker()

      local content = [[
- Regular list item
* Another list item
+ Yet another
1. Ordered item
  - Nested list item]]

      local bufnr = h.setup_test_buffer(content)

      local expected = {
        "- " .. unchecked .. " Regular list item",
        "* " .. unchecked .. " Another list item",
        "+ " .. unchecked .. " Yet another",
        "1. " .. unchecked .. " Ordered item",
        "  - " .. unchecked .. " Nested list item",
      }

      for i = 1, 5 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        local success = require("checkmate").create()
        assert.is_true(success)
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, expected_line in ipairs(expected) do
        assert.equal(expected_line, lines[i])
      end

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should insert a new todo below when cursor is on existing todo", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local default_list_marker = config.get_defaults().default_list_marker

      local content = [[
- ]] .. unchecked .. [[ First todo
Some other content]]

      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(3, #lines)
      assert.equal(default_list_marker .. " " .. unchecked .. " First todo", lines[1])
      assert.equal(default_list_marker .. " " .. unchecked .. " ", lines[2])
      assert.equal("Some other content", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should maintain indentation when inserting new todo", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local default_list_marker = config.get_defaults().default_list_marker

      local content = [[
  - ]] .. unchecked .. [[ Indented todo
Some other content ]]

      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal("  " .. default_list_marker .. " " .. unchecked .. " Indented todo", lines[1])
      assert.equal("  " .. default_list_marker .. " " .. unchecked .. " ", lines[2])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should increment ordered list numbers when inserting", function()
      local unchecked = h.get_unchecked_marker()

      local content = [[
1. ]] .. unchecked .. [[ First item
2. ]] .. unchecked .. [[ Second item
]]
      local bufnr = h.setup_test_buffer(content)

      -- insert after first item
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal("1. " .. unchecked .. " First item", lines[1])
      assert.equal("2. " .. unchecked .. " ", lines[2])
      assert.equal("2. " .. unchecked .. " Second item", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle empty lines correctly", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local default_list_marker = config.get_defaults().default_list_marker

      local content = [[
- Todo1

  - Child1]]
      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal("- Todo1", lines[1])
      assert.equal(default_list_marker .. " " .. unchecked .. " ", lines[2])
      assert.equal("  - Child1", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should convert multiple selected lines to todos", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local default_list_marker = config.get_defaults().default_list_marker

      local content = [[
Line 1
Line 2
  ]] .. default_list_marker .. [[ Line 3]]

      local bufnr = h.setup_test_buffer(content)

      -- select all lines
      vim.cmd("normal! ggVG")

      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(default_list_marker .. " " .. unchecked .. " Line 1", lines[1])
      assert.equal(default_list_marker .. " " .. unchecked .. " Line 2", lines[2])
      assert.equal("  " .. default_list_marker .. " " .. unchecked .. " Line 3", lines[3]) -- preserves indentation
      assert.equal(3, #lines) -- ensure no new line created

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should convert a list item nested in another todo", function()
      local unchecked = h.get_unchecked_marker()

      local content = [[
- [ ] Parent todo
  - Regular list item
      ]]

      local bufnr = h.setup_test_buffer(content)

      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on Regular List item

      local success = require("checkmate").create()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.equal("  - " .. unchecked .. " Regular list item", lines[2])
      assert.matches("^%s*$", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("todo manipulation", function()
    describe("metadata operations", function()
      describe("find_metadata_insert_position", function()
        local api = require("checkmate.api")
        local parser = require("checkmate.parser")

        -- find byte position after a pattern in a line
        local function find_byte_pos_after(line, pattern)
          local _, end_pos = line:find(pattern)
          return end_pos -- returns 1-based, but we'll convert when needed
        end

        -- get the byte position at end of content (excluding trailing whitespace)
        local function get_content_end_pos(line)
          local trimmed = line:match("^(.-)%s*$")
          return #trimmed
        end

        it("should find correct position when no metadata exists", function()
          local cm = require("checkmate")
          cm.setup()

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
          local unchecked = h.get_unchecked_marker()
          expected_col = find_byte_pos_after(lines[1], unchecked)
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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should respect sort_order when metadata exists", function()
          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle complex multi-line scenarios", function()
          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)
      end)

      it("should add metadata to todo items", function()
        local unchecked = h.get_unchecked_marker()

        local content = "# Todo List\n\n- [ ] Task without metadata\n"

        local bufnr, file_path = h.setup_todo_file_buffer(content)

        vim.api.nvim_win_set_cursor(0, { 3, 0 })

        local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 2, 0)
        assert.is_not_nil(todo_item)

        local success = require("checkmate").add_metadata("priority", "high")
        assert.is_true(success)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. vim.pesc(unchecked) .. " Task without metadata @priority%(high%)", lines[3])

        vim.cmd("write")
        vim.cmd("sleep 10m")

        local saved_content = h.read_file_content(file_path)
        if not saved_content then
          error("error reading file content")
        end

        assert.matches("- %[ %] Task without metadata @priority%(high%)", saved_content)

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should add metadata to a nested todo item", function()
        local cm = require("checkmate")
        cm.setup()

        local unchecked = h.get_unchecked_marker()

        local content = [[
- [ ] Parent todo
  - [ ] Child todo A
  - [ ] Child todo B
]]
        local bufnr = h.setup_test_buffer(content)

        -- move cursor to the Child todo A on line 2 (1-indexed)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 1, 0) -- 0-indexed
        assert.is_not_nil(todo_item)

        require("checkmate").add_metadata("priority", "high")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. vim.pesc(unchecked) .. " Parent todo", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child todo A @priority%(high%)", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child todo B", lines[3])

        -- Now repeat for the parent todo

        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 0, 0)
        assert.is_not_nil(todo_item)

        -- Add @priority metadata
        require("checkmate").add_metadata("priority", "medium")

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.matches("- " .. vim.pesc(unchecked) .. " Parent todo @priority%(medium%)", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child todo", lines[2])

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should add metadata to a multi-line todo", function()
        -- NOTE: the expected behavior is that the metadata tag is inserted according to sort_order,
        -- immediately following a lower sort_order tag or before a higher sort_order tag

        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
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

        local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 0, 0)
        assert.is_not_nil(todo_item)
        ---@cast todo_item checkmate.TodoItem

        local success = require("checkmate").add_metadata("test2", "bar")
        assert.is_true(success)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("Todo item @test1%(foo%) @test2%(bar%)$", lines[1])

        success = require("checkmate").add_metadata("test4", "gah")
        assert.is_true(success)

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("     @test3%(baz%) @test4%(gah%)$", lines[2])

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should remove metadata with complex value", function()
        local cm = require("checkmate")
        cm.setup()

        local unchecked = h.get_unchecked_marker()

        local content = [[
- [ ] Task @issue(issue #1 - fix(api): broken! @author)
      ]]

        local bufnr = h.setup_test_buffer(content)

        local todo_map = require("checkmate.parser").discover_todos(bufnr)
        local first_todo = h.find_todo_by_text(todo_map, "- " .. unchecked .. " Task @issue")

        assert.is_not_nil(first_todo)
        ---@cast first_todo checkmate.TodoItem

        assert.is_not_nil(first_todo.metadata)
        assert.is_true(#first_todo.metadata.entries > 0)

        -- remove @issue
        vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 }) -- adjust from 0 index to 1-indexed
        require("checkmate").remove_metadata("issue")

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.no.matches("@issue", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task", lines[1])

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should remove all metadata from todo items", function()
        local tags_on_removed_called = false

        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
          metadata = {
            ---@diagnostic disable-next-line: missing-fields
            tags = {
              on_remove = function()
                tags_on_removed_called = true
              end,
            },
          },
        })

        local unchecked = h.get_unchecked_marker()

        -- content with todos that have multiple metadata tags
        local content = [[
# Todo Metadata Test

- ]] .. unchecked .. [[ Task with @priority(high) @due(2023-05-15) @tags(important,urgent)
- ]] .. unchecked .. [[ Another task @priority(medium) @assigned(john)
  @issue(2)
- ]] .. unchecked .. [[ A todo without metadata
]]

        local bufnr = h.setup_test_buffer(content)

        -- get 1st todo
        local todo_map = require("checkmate.parser").discover_todos(bufnr)
        local first_todo = h.find_todo_by_text(todo_map, "- " .. unchecked .. " Task with")

        assert.is_not_nil(first_todo)
        ---@cast first_todo checkmate.TodoItem

        assert.is_not_nil(first_todo.metadata)
        assert.is_true(#first_todo.metadata.entries > 0)

        -- remove all metadata
        vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 }) -- adjust from 0 index to 1-indexed
        require("checkmate").remove_all_metadata()

        vim.wait(20)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.no.matches("@priority", lines[3])
        assert.no.matches("@due", lines[3])
        assert.no.matches("@tags", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task with", lines[3])

        assert.is_true(tags_on_removed_called)

        local second_todo = h.find_todo_by_text(todo_map, "- " .. unchecked .. " Another task")
        local third_todo = h.find_todo_by_text(todo_map, "- " .. unchecked .. " A todo without")

        assert.is_not_nil(second_todo)
        ---@cast second_todo checkmate.TodoItem

        assert.is_not_nil(third_todo)
        ---@cast third_todo checkmate.TodoItem

        h.make_selection(first_todo.range.start.row + 1, 0, third_todo.range.start.row + 1, 0, "V")

        cm.remove_all_metadata()

        vim.wait(20)

        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- second todo's metadata was removed
        assert.no.matches("@priority", lines[4])
        assert.no.matches("@assigned", lines[4])
        assert.no.matches("@issue", lines[5])

        -- third todo's line text wasn't changed
        assert.matches("A todo without metadata", lines[6])

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should provide static choices", function()
        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
          metadata = {
            status = {
              choices = { "todo", "in-progress", "done", "blocked" },
            },
          },
        })

        local meta_module = require("checkmate.metadata")

        local unchecked = h.get_unchecked_marker()
        local content = [[- ]] .. unchecked .. [[ Task with metadata @status()]]

        local bufnr = h.setup_test_buffer(content)

        local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 0, 0)
        assert.is_not_nil(todo_item)
        ---@cast todo_item checkmate.TodoItem

        local results
        meta_module.get_choices("status", function(items)
          results = items
        end, todo_item, bufnr)
        assert.same({ "todo", "in-progress", "done", "blocked" }, results)

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should support synchronous 'choices' functions", function()
        local choices_fn_called = false
        local received_context = nil

        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
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

        local unchecked = h.get_unchecked_marker()

        local content = [[- ]] .. unchecked .. [[ Task @assignee(john)]]

        local bufnr = h.setup_test_buffer(content)

        local parser = require("checkmate.parser")
        local todo_map = parser.discover_todos(bufnr)
        local todo_item = h.find_todo_by_text(todo_map, "Task @assignee")
        assert.is_not_nil(todo_item)
        ---@cast todo_item checkmate.TodoItem

        local results
        meta_module.get_choices("assignee", function(items)
          results = items
        end, todo_item, bufnr)

        assert.is_true(choices_fn_called)
        assert.is_not_nil(received_context)
        ---@cast received_context checkmate.MetadataContext
        assert.is_true(type(received_context) == "table")

        assert.equal("assignee", received_context.name)
        assert.equal(bufnr, received_context.buffer)
        assert.same({ "john", "jane", "jack", "jill", "bob", "alice" }, results)

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should support asynchronous 'choices' functions", function()
        local choices_fn_called = false
        local received_context = nil

        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
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

        local parser = require("checkmate.parser")
        local todo_map = parser.discover_todos(bufnr)
        local todo_item = h.find_todo_by_text(todo_map, "Task needing data")
        assert.is_not_nil(todo_item)
        ---@cast todo_item checkmate.TodoItem

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
        ---@cast received_context checkmate.MetadataContext
        assert.is_true(type(received_context) == "table")

        assert.same({ "project-a", "project-b", "project-c" }, results)

        finally(function()
          cm.stop()
          h.cleanup_buffer(bufnr)
        end)
      end)

      describe("metadata callbacks", function()
        it("should call on_add only when metadata is successfully added", function()
          -- spy to track callback execution
          local on_add_called = false
          local test_todo_item = nil

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              test = {
                on_add = function(todo_item)
                  on_add_called = true
                  test_todo_item = todo_item
                end,
                select_on_insert = false,
              },
            },
          })

          local unchecked = h.get_unchecked_marker()

          local content = [[
# Metadata Callbacks Test

- ]] .. unchecked .. [[ A test todo]]

          local bufnr = h.setup_test_buffer(content)

          -- todo item at row 2 (0-indexed)
          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "A test todo")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          local success = require("checkmate").add_metadata("test", "test_value")

          vim.wait(10)
          vim.cmd("redraw")

          assert.is_true(success)
          assert.is_true(on_add_called)
          -- check that the todo item was passed to the callback
          assert.is_not_nil(test_todo_item)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@test%(test_value%)", lines[3])

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_remove only when metadata is successfully removed", function()
          -- spy to track callback execution
          local on_remove_called = false
          local test_todo_item = nil

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              test = {
                on_remove = function(todo_item)
                  on_remove_called = true
                  test_todo_item = todo_item
                end,
              },
            },
          })

          local unchecked = h.get_unchecked_marker()

          local content = [[
# Metadata Callbacks Test

- ]] .. unchecked .. [[ A test todo @test(test_value)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "A test todo")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 }) -- set the cursor on the todo item
          local success = require("checkmate").remove_metadata("test")

          vim.wait(10)
          vim.cmd("redraw")

          assert.is_true(success)
          assert.is_true(on_remove_called)
          -- check that the todo item was passed to the callback
          assert.is_not_nil(test_todo_item)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.no.matches("@test", lines[3])

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_add callback for all todos in bulk (normal and visual mode)", function()
          local unchecked = h.get_unchecked_marker()
          local on_add_calls = {}

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              bulk = {
                on_add = function(todo_item)
                  -- record the todo's line (1-based)
                  table.insert(on_add_calls, todo_item.range.start.row + 1)
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
          require("checkmate").toggle_metadata("bulk")

          vim.wait(10)
          vim.cmd("redraw")

          -- callback fired once for todo with added metadata
          assert.equal(1, #on_add_calls, "on_add should be called once")

          -- remove all metadata for next test (reset state)
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          require("checkmate").remove_metadata("bulk")

          vim.wait(10)
          vim.cmd("redraw")

          -- Test Visual mode

          -- move to first todo
          -- extend to last todo line
          h.make_selection(3, 0, 2 + total_todos, 0, "V")

          on_add_calls = {}
          require("checkmate").toggle_metadata("bulk")
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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should not call on_add when updating existing metadata value", function()
          local unchecked = h.get_unchecked_marker()
          local on_add_called = false
          local on_change_called = false

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
- ]] .. unchecked .. [[ Task with existing metadata @test(old_value)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "Task with existing")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          -- called on existing metadata - should NOT trigger on_add
          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          require("checkmate").add_metadata("test", "new_value")

          vim.wait(10)

          assert.is_false(on_add_called)
          assert.is_true(on_change_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@test%(new_value%)", lines[1])

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change when metadata value is updated", function()
          local unchecked = h.get_unchecked_marker()
          local on_change_called = false
          local received_todo = nil
          local received_old_value = nil
          local received_new_value = nil

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              priority = {
                on_change = function(todo_item, old_value, new_value)
                  on_change_called = true
                  received_todo = todo_item
                  received_old_value = old_value
                  received_new_value = new_value
                end,
              },
            },
          })

          local content = [[
- ]] .. unchecked .. [[ Task with metadata @priority(low)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "Task with metadata")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          require("checkmate").add_metadata("priority", "high")

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
          require("checkmate").add_metadata("priority", "high")

          vim.wait(10)
          assert.is_false(on_change_called)

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change via metadata picker selection", function()
          local unchecked = h.get_unchecked_marker()
          local on_change_called = false
          local received_old_value = nil
          local received_new_value = nil

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
- ]] .. unchecked .. [[ Task @priority(medium)]]

          local bufnr = h.setup_test_buffer(content)

          local parser = require("checkmate.parser")
          local api = require("checkmate.api")
          local transaction = require("checkmate.transaction")

          local todo_map = parser.discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "Task @priority")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          local metadata_entry = todo_item.metadata.by_tag["priority"]
          assert.is_not_nil(metadata_entry)

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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle on_change callbacks that trigger other metadata operations", function()
          local unchecked = h.get_unchecked_marker()
          local on_change_called = false
          local on_add_called = false

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
- ]] .. unchecked .. [[ Task @status(in-progress)]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "Task @status")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          require("checkmate").add_metadata("status", "done")

          vim.wait(10)

          assert.is_true(on_change_called)
          assert.is_true(on_add_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@status%(done%)", lines[1])
          assert.matches("@completed%(today%)", lines[1])

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should call on_change for bulk operations in visual mode", function()
          local unchecked = h.get_unchecked_marker()
          local change_count = 0
          local changes = {}

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
            metadata = {
              ---@diagnostic disable-next-line: missing-fields
              priority = {
                on_change = function(todo_item, old_value, new_value)
                  change_count = change_count + 1
                  table.insert(changes, {
                    text = todo_item.todo_text,
                    old = old_value,
                    new = new_value,
                  })
                end,
              },
            },
          })

          local content = [[
- ]] .. unchecked .. [[ Task 1 @priority(low)
- ]] .. unchecked .. [[ Task 2 @priority(medium)
- ]] .. unchecked .. [[ Task 3 @priority(high)]]

          local bufnr = h.setup_test_buffer(content)

          h.make_selection(1, 0, 3, 0, "V")

          require("checkmate").add_metadata("priority", "urgent")

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
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)

        it("should handle errors in metadata callbacks gracefully", function()
          local unchecked = h.get_unchecked_marker()
          local on_add_called = false
          local on_change_called = false
          local on_remove_called = false

          local cm = require("checkmate")
          ---@diagnostic disable-next-line: missing-fields
          cm.setup({
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
- ]] .. unchecked .. [[ Task for testing callback errors]]

          local bufnr = h.setup_test_buffer(content)

          local todo_map = require("checkmate.parser").discover_todos(bufnr)
          local todo_item = h.find_todo_by_text(todo_map, "Task for testing")
          assert.is_not_nil(todo_item)
          ---@cast todo_item checkmate.TodoItem

          -- add
          vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
          local add_success = require("checkmate").add_metadata("errortest", "initial")

          vim.wait(10)

          assert.is_true(add_success)
          assert.is_true(on_add_called)

          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@errortest%(initial%)", lines[1])

          -- update
          local change_success = require("checkmate").add_metadata("errortest", "changed")

          vim.wait(10)

          assert.is_true(change_success)
          assert.is_true(on_change_called)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.matches("@errortest%(changed%)", lines[1])

          -- remove
          local remove_success = require("checkmate").remove_metadata("errortest")

          vim.wait(10)

          assert.is_true(remove_success)
          assert.is_true(on_remove_called)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.no.matches("@errortest", lines[1])

          local todo_map_after = require("checkmate.parser").discover_todos(bufnr)
          assert.is_not_nil(todo_map_after)
          assert.equal(1, vim.tbl_count(todo_map_after), "Todo map should still be valid")

          -- can still perform operations
          local toggle_success = require("checkmate").toggle()
          assert.is_true(toggle_success)

          vim.wait(10)

          lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local checked = h.get_checked_marker()
          assert.matches("- " .. vim.pesc(checked) .. " Task for testing", lines[1])

          finally(function()
            cm.stop()
            h.cleanup_buffer(bufnr)
          end)
        end)
      end)
    end)

    it("should handle todo hierarchies with correct write to file", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
# Todo Hierarchy

- [ ] Parent task
  - [ ] Child task 1
  - [ ] Child task 2
    - [ ] Grandchild task
  - [ ] Child task 3
- [ ] Another parent
]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      local todo_map = require("checkmate.parser").discover_todos(bufnr)

      -- Find parent todo
      local parent_todo = h.find_todo_by_text(todo_map, "- " .. unchecked .. " Parent task")
      assert.is_not_nil(parent_todo)
      ---@cast parent_todo checkmate.TodoItem

      assert.equal(3, #parent_todo.children)

      require("checkmate").set_todo_item(parent_todo, "checked")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[3])

      vim.cmd("write")
      vim.cmd("sleep 10m")

      local saved_content = h.read_file_content(file_path)

      if not saved_content then
        error("error reading file content")
      end

      local saved_lines = {}
      for line in saved_content:gmatch("([^\n]*)\n?") do
        table.insert(saved_lines, line)
      end

      assert.equal("# Todo Hierarchy", saved_lines[1])
      assert.equal("", saved_lines[2])
      assert.equal("- [x] Parent task", saved_lines[3])
      assert.equal("  - [ ] Child task 1", saved_lines[4])
      assert.equal("  - [ ] Child task 2", saved_lines[5])
      assert.equal("    - [ ] Grandchild task", saved_lines[6])
      assert.equal("  - [ ] Child task 3", saved_lines[7])
      assert.equal("- [ ] Another parent", saved_lines[8])

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should handle multiple todo operations in sequence", function()
      local config = require("checkmate.config")

      local content = [[
# Todo Sequence

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
]]

      local bufnr, file_path = h.setup_todo_file_buffer(content)

      -- toggle task 1, add metadata to task 2, check task 3

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

      local checked = config.get_defaults().todo_markers.checked
      local unchecked = config.get_defaults().todo_markers.unchecked

      assert.matches("- " .. vim.pesc(checked) .. " Task 1", lines[3])
      assert.matches("- " .. vim.pesc(unchecked) .. " Task 2 @priority%(high%)", lines[4])
      assert.matches("- " .. vim.pesc(checked) .. " Task 3", lines[5])

      vim.cmd("write")
      vim.cmd("sleep 10m")

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
  end)

  describe("movement", function()
    local cm
    before_each(function()
      cm = require("checkmate")
      cm.setup()
    end)
    after_each(function()
      cm.stop()
    end)

    it("should move cursor to next metadata entry and wrap around", function()
      local parser = require("checkmate.parser")
      local api = require("checkmate.api")

      local content = "- [ ] Task @foo(1) @bar(2) @baz(3)"
      local bufnr = h.setup_test_buffer(content)

      local todo_item = parser.get_todo_item_at_position(bufnr, 0, 0)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem
      local row = todo_item.range.start.row + 1

      vim.api.nvim_win_set_cursor(0, { row, 0 })

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
      local parser = require("checkmate.parser")
      local api = require("checkmate.api")

      local content = "- [ ] Task @foo(1) @bar(2) @baz(3)"
      local bufnr = h.setup_test_buffer(content)

      local todo_item = parser.get_todo_item_at_position(bufnr, 0, 0)
      assert.is_not_nil(todo_item)
      ---@cast todo_item checkmate.TodoItem
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

      return h.setup_todo_file_buffer(content, { config = config_override })
    end

    describe("downward propagation", function()
      it("should check all direct children when parent is checked (check_down='direct_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])
        -- grandchild should NOT be checked (only direct children)
        assert.matches("- " .. vim.pesc(unchecked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should check all descendants when parent is checked (check_down='all_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
      - ]] .. unchecked .. [[ Great-grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "all_children" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- all descendants should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])
        assert.matches("- " .. vim.pesc(checked) .. " Grandchild 1", lines[4])
        assert.matches("- " .. vim.pesc(checked) .. " Great%-grandchild 1", lines[5])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should not affect children when parent is checked (check_down='none')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "none" })

        -- cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- only parent is checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should uncheck direct children when parent is unchecked (uncheck_down='direct_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. checked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { uncheck_down = "direct_children" })

        -- cursor to parent task and toggle (uncheck it)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])
        -- grandchild should remain checked (only direct children affected)
        assert.matches("- " .. vim.pesc(checked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)

    describe("upward propagation", function()
      it("should check parent when all direct children are checked (check_up='direct_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
  - ]] .. checked .. [[ Child 3
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_up = "direct_children" })

        -- check the remaining unchecked child
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- parent should now be checked since all direct children are checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])
        assert.matches("- " .. vim.pesc(checked) .. " Child 3", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should check parent when all descendants are checked (check_up='all_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
    - ]] .. checked .. [[ Grandchild 1
    - ]] .. unchecked .. [[ Grandchild 2
]]

        -- we use a check_down = "none" here to test only the check_up functionality,
        -- otherwise, the first check with propagate the check to all children
        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_up = "all_children", check_down = "none" })

        -- check Child 2 first
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        require("checkmate").toggle()
        vim.wait(20)

        -- parent should NOT be checked yet (grandchild 2 is still unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])

        -- now check Grandchild 2
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        require("checkmate").toggle()
        vim.wait(20)

        -- now parent should be checked (all descendants are checked)
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])
        assert.matches("- " .. vim.pesc(checked) .. " Grandchild 1", lines[4])
        assert.matches("- " .. vim.pesc(checked) .. " Grandchild 2", lines[5])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should uncheck parent when any direct child is unchecked (uncheck_up='direct_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { uncheck_up = "direct_children" })

        -- uncheck one child
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- parent should be unchecked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should uncheck parent when any descendant is unchecked (uncheck_up='all_children')", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. checked .. [[ Grandchild 1
]]

        local bufnr, file_path =
          setup_smart_toggle_buffer(content, { uncheck_up = "all_children", uncheck_down = "none" })

        -- uncheck the grandchild
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- parent should be unchecked (because a descendant is unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        -- child 2 is unchecked as it is a parent of Grandchild 1
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)

    describe("complex scenarios", function()
      it("should handle multiple selection with smart toggle", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Task A
  - ]] .. unchecked .. [[ Task A.1
- ]] .. unchecked .. [[ Task B
  - ]] .. unchecked .. [[ Task B.1
    - ]] .. unchecked .. [[ Task B.1.1
- ]] .. unchecked .. [[ Task C
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- select both parent tasks in visual mode
        h.make_selection(1, 0, 3, 0, "V")

        require("checkmate").toggle()

        vim.wait(20)

        -- all tasks should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Task A", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Task A%.1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Task B", lines[3])
        assert.matches("- " .. vim.pesc(checked) .. " Task B%.1", lines[4])
        -- should not propagate check to grandchild if check_down = "direct_children"
        assert.matches("- " .. vim.pesc(unchecked) .. " Task B%.1%.1", lines[5])
        -- should not check sibling parent Task C
        assert.matches("- " .. vim.pesc(unchecked) .. " Task C", lines[6])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should handle cascading propagation correctly", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Grandparent
  - ]] .. unchecked .. [[ Parent 1
    - ]] .. checked .. [[ Child 1.1
    - ]] .. unchecked .. [[ Child 1.2
  - ]] .. checked .. [[ Parent 2
    - ]] .. checked .. [[ Child 2.1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, {
          check_down = "none",
          check_up = "direct_children",
        })

        -- check Child 1.2 - this should cascade up
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- should check Child 1.2, Parent 1, and Grandparent
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Grandparent", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Parent 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1%.1", lines[3])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1%.2", lines[4])
        assert.matches("- " .. vim.pesc(checked) .. " Parent 2", lines[5])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2%.1", lines[6])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)
    describe("edge cases", function()
      it("should not propagate when smart_toggle is disabled", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local content = [[
- ]] .. unchecked .. [[ Task A
  - ]] .. unchecked .. [[ Task A.1
  - ]] .. unchecked .. [[ Task A.2
- ]] .. unchecked .. [[ Task B
]]

        local bufnr, file_path = setup_smart_toggle_buffer(
          content,
          { enabled = false, check_down = "direct_children", check_up = "direct_children" }
        )

        -- toggle first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- only first task should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Task A", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task A%.1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task A%.2", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task B", lines[4])

        -- reset first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").uncheck()

        -- select both child tasks in visual mode
        h.make_selection(2, 0, 3, 0, "V")

        require("checkmate").check()
        vim.wait(20)

        -- first task should not be checked (no propagation from children)
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Task A", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Task A%.1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Task A%.2", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task B", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)
  end)

  describe("archive system", function()
    it("should not create archive section when no checked todos exist", function()
      local cm = require("checkmate")
      cm.setup()

      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()

      local content = [[
# Todo List
- ]] .. unchecked .. [[ Task 1
- ]] .. unchecked .. [[ Task 2
  - ]] .. unchecked .. [[ Subtask 2.1
]]

      local bufnr = h.setup_test_buffer(content)

      local success = require("checkmate").archive()
      assert.is_false(success) -- should return false when nothing to archive

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- no archive section should have been created
      local archive_heading_string = require("checkmate.util").get_heading_string(
        config.get_defaults().archive.heading.title,
        config.get_defaults().archive.heading.level
      )
      assert.no.matches(vim.pesc(archive_heading_string), buffer_content)

      local expected_main_content = {
        "# Todo List",
        "- " .. unchecked .. " Task 1",
        "- " .. unchecked .. " Task 2",
        "  - " .. unchecked .. " Subtask 2.1",
      }

      -- original content is unchanged
      local result, err = h.verify_content_lines(buffer_content, expected_main_content)
      assert.equal(result, true, err)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should archive completed todo items to specified section", function()
      local cm = require("checkmate")
      cm.setup()

      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
# Todo List

- ]] .. unchecked .. [[ Unchecked task 1
- ]] .. checked .. [[ Checked task 1
  - ]] .. checked .. [[ Checked subtask 1.1
  - ]] .. unchecked .. [[ Unchecked subtask 1.2
- ]] .. unchecked .. [[ Unchecked task 2
- ]] .. checked .. [[ Checked task 2
  - ]] .. checked .. [[ Checked subtask 2.1

## Existing Section
Some content here
]]

      local bufnr = h.setup_test_buffer(content)

      local heading_title = "Completed Todos"
      local success = require("checkmate").archive({ heading = { title = heading_title } })

      vim.wait(10)
      vim.cmd("redraw")

      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string =
        require("checkmate.util").get_heading_string(heading_title, config.get_defaults().archive.heading.level)

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      -- checked top-level tasks were removed
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 1", main_section)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 2", main_section)

      -- unchecked tasks remain
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 1", main_section)
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 2", main_section)

      -- archive section was created
      assert.matches(archive_heading_string, buffer_content)

      -- contents were moved to archive section
      local archive_section = buffer_content:match(archive_heading_string .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. heading_title,
        "",
        "- " .. checked .. " Checked task 1",
        "  - " .. checked .. " Checked subtask 1.1",
        "  - " .. unchecked .. " Unchecked subtask 1.2",
        "- " .. checked .. " Checked task 2",
        "  - " .. checked .. " Checked subtask 2.1",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      -- 'Existing Section' should still be present
      assert.matches("## Existing Section", buffer_content)
      assert.matches("Some content here", buffer_content)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should work with custom archive heading", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      -- setup with custom archive heading
      local heading_title = "Completed Items"
      local heading_level = 4 -- ####

      local cm = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        archive = { heading = { title = heading_title, level = heading_level } },
      })

      local content = [[
# Custom Archive Heading Test

- ]] .. unchecked .. [[ Unchecked task
- ]] .. checked .. [[ Checked task
]]

      local bufnr = h.setup_test_buffer(content)

      local success = require("checkmate").archive()
      vim.wait(10)
      vim.cmd("redraw")

      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(heading_title, heading_level)

      -- custom heading was used
      assert.matches(archive_heading_string, buffer_content)

      -- content was archived correctly
      local archive_section = buffer_content:match("#### Completed Items" .. ".*$")
      assert.is_not_nil(archive_section)
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", archive_section)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should merge with existing archive section", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        ---@diagnostic disable-next-line: missing-fields
        archive = {
          newest_first = false, -- ensure newly added todos end up at top of archive section
        },
      })

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local content = [[
# Existing Archive Test

- ]] .. unchecked .. [[ Unchecked task
- ]] .. checked .. [[ Checked task to archive

]] .. archive_heading_string .. [[

- ]] .. checked .. [[ Previously archived task
]]

      local bufnr = h.setup_test_buffer(content)

      local success = require("checkmate").archive()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- checked task was removed from main content
      local main_content = buffer_content:match("^(.-)" .. archive_heading_string)
      assert.is_not_nil(main_content)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task to archive", main_content)

      -- unchecked task remains in main content
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", main_content)

      local archive_section = buffer_content:match(archive_heading_string .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. config.get_defaults().archive.heading.title,
        "",
        "- " .. checked .. " Previously archived task",
        "- " .. checked .. " Checked task to archive",
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
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should insert the configured parent_spacing between archived parent blocks", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      for _, spacing in ipairs({ 0, 1, 2 }) do
        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({ archive = { parent_spacing = spacing } })
        local content = [[
# Tasks
- ]] .. unchecked .. [[ Active task
- ]] .. checked .. [[ Done task A
  - ]] .. checked .. [[ Done subtask A.1
- ]] .. checked .. [[ Done task B
]]

        local bufnr = h.setup_test_buffer(content)

        local success = require("checkmate").archive()
        vim.wait(20)
        vim.cmd("redraw")
        assert.equal(true, success, "Archive failed for parent_spacing = " .. spacing)

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local buffer_content = table.concat(lines, "\n")

        local archive_heading_string = require("checkmate.util").get_heading_string(
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
        local first_root = "- " .. checked .. " Done task A"
        local second_root = "- " .. checked .. " Done task B"
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

        cm.stop()
        h.cleanup_buffer(bufnr)
      end
    end)

    it("should preserve single blank line when todo has spacing on both sides", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      cm.setup()

      local content = [[
# Todo List

- ]] .. unchecked .. [[ Task A

- ]] .. checked .. [[ Task B (to archive)

- ]] .. unchecked .. [[ Task C
]]

      local bufnr = h.setup_test_buffer(content)

      local arch_success = require("checkmate").archive()
      assert.is_true(arch_success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "# Todo List",
        "",
        "- " .. unchecked .. " Task A",
        "",
        "- " .. unchecked .. " Task C",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should not create double spacing when archiving adjacent todos", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      cm.setup()

      local content = [[
- ]] .. unchecked .. [[ Task A

- ]] .. checked .. [[ Task B (to archive)
- ]] .. checked .. [[ Task C (to archive)

- ]] .. unchecked .. [[ Task D
]]

      local bufnr = h.setup_test_buffer(content)

      local arch_success = require("checkmate").archive()
      assert.is_true(arch_success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "- " .. unchecked .. " Task A",
        "",
        "- " .. unchecked .. " Task D",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle no spacing between todos correctly", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      cm.setup()

      local content = [[
- ]] .. unchecked .. [[ Task A
- ]] .. checked .. [[ Task B (to archive)
- ]] .. unchecked .. [[ Task C
]]

      local bufnr = h.setup_test_buffer(content)

      local arch_success = require("checkmate").archive()
      assert.is_true(arch_success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "- " .. unchecked .. " Task A",
        "- " .. unchecked .. " Task C",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle spacing for complex mixed content correctly", function()
      local config = require("checkmate.config")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      cm.setup()

      local content = [[
# Project

Some intro text.

- ]] .. unchecked .. [[ Task A

- ]] .. checked .. [[ Task B (to archive)
  - ]] .. checked .. [[ Subtask B.1

## Section 1

Content for section 1.

- ]] .. checked .. [[ Task C (to archive)

More content.

- ]] .. unchecked .. [[ Task D

## Section 2

Final content.
]]

      local bufnr = h.setup_test_buffer(content)

      local arch_success = require("checkmate").archive()
      assert.is_true(arch_success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.get_defaults().archive.heading.title),
        config.get_defaults().archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "# Project",
        "",
        "Some intro text.",
        "",
        "- " .. unchecked .. " Task A",
        "",
        "## Section 1",
        "",
        "Content for section 1.",
        "",
        "More content.",
        "",
        "- " .. unchecked .. " Task D",
        "",
        "## Section 2",
        "",
        "Final content.",
        "",
      }

      local success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(success, true, err)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("diffs", function()
    it("should compute correct diff hunk for toggling a single todo item", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local cm = require("checkmate")
      cm.setup()

      -- create a one-line todo
      local content = [[
- ]] .. unchecked .. [[ MyTask]]
      local bufnr = h.setup_test_buffer(content)

      local parser = require("checkmate.parser")
      local api = require("checkmate.api")

      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "MyTask")
      assert.is_not_nil(todo)
      ---@cast todo checkmate.TodoItem

      assert.equal("unchecked", todo.state)

      local hunks = api.compute_diff_toggle({ { item = todo, target_state = "checked" } })
      assert.equal(1, #hunks)

      local hunk = hunks[1]
      -- start/end row should be the todo line
      assert.equal(todo.todo_marker.position.row, hunk.start_row)
      assert.equal(todo.todo_marker.position.row, hunk.end_row)
      -- start col is marker col, end col is marker col + marker‐length
      assert.equal(todo.todo_marker.position.col, hunk.start_col)
      assert.equal(todo.todo_marker.position.col + #unchecked, hunk.end_col)
      -- replacement should be the checked marker
      assert.same({ checked }, hunk.insert)

      finally(function()
        cm.stop()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)
end)
