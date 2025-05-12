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
  end)

  -- Set up a todo file in a buffer with autocmds
  local function setup_todo_buffer(file_path, content)
    h.write_file_content(file_path, content)

    -- Open the file in a buffer
    vim.cmd("edit " .. file_path)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Ensure filetype is set to markdown
    vim.bo[bufnr].filetype = "markdown"

    -- Set up the API for this buffer
    require("checkmate.api").setup(bufnr)

    return bufnr
  end

  describe("file operations", function()
    it("should save todo file with correct Markdown syntax", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with Unicode symbols, hierarchical structure, and different list markers
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

      local bufnr = setup_todo_buffer(file_path, content)

      -- Force a write operation - triggering our BufWriteCmd handler
      vim.cmd("write")

      vim.cmd("sleep 10m")

      -- Read the saved file content directly (should be in Markdown format)
      local saved_content = h.read_file_content(file_path)

      if not saved_content then
        error("error reading file content")
      end

      -- Split into lines and check each line individually
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

      -- Verify Unicode symbols are NOT present in the saved file
      assert.no.matches(vim.pesc(unchecked), saved_content)
      assert.no.matches(vim.pesc(checked), saved_content)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should load todo file with Markdown checkboxes converted to Unicode", function()
      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with Markdown format
      local content = "# Todo List\n\n- [ ] Unchecked task\n- [x] Checked task\n"
      h.write_file_content(file_path, content)

      -- Open the file in Neovim
      vim.cmd("edit " .. file_path)
      local bufnr = vim.api.nvim_get_current_buf()

      -- Ensure filetype is set to markdown
      vim.bo[bufnr].filetype = "markdown"

      -- Set up the API for this buffer - this should trigger conversion
      require("checkmate.api").setup(bufnr)

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify content was converted to Unicode
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", buffer_content)
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", buffer_content)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should maintain todo state through edit-save-reload cycle", function()
      local config = require("checkmate.config")
      local api = require("checkmate.api")
      local unchecked = config.options.todo_markers.unchecked

      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with just unchecked items
      local content = "# Todo List\n\n- [ ] Task 1\n- [ ] Task 2\n- [ ] Task 3\n"

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- Get the task we want to toggle
      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local task_2 = nil

      for _, todo in pairs(todo_map) do
        if vim.startswith(todo.todo_text, "- " .. unchecked .. " Task 2") then
          task_2 = todo
          break
        end
      end

      if not task_2 then
        error("missing todo item (task_2)")
      end

      -- Toggle task 2 to checked
      local success = require("checkmate").set_todo_item(task_2, "checked")

      assert.is_true(success)

      -- Save the file
      vim.cmd("write")
      vim.cmd("sleep 10m")

      -- Close and reopen the file
      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.cmd("edit " .. file_path)
      bufnr = vim.api.nvim_get_current_buf()

      -- Ensure filetype is set to markdown
      vim.bo[bufnr].filetype = "markdown"

      -- Set up the API for this buffer - this should trigger conversion
      api.setup(bufnr)

      -- Check that Task 2 is still checked
      todo_map = require("checkmate.parser").discover_todos(bufnr)
      ---@type checkmate.TodoItem
      local task_2_reloaded = nil

      for _, todo in pairs(todo_map) do
        if vim.startswith(todo.todo_text, "- " .. config.options.todo_markers.checked .. " Task 2") then
          task_2_reloaded = todo
          break
        end
      end

      assert.is_not_nil(task_2_reloaded)
      assert.equal("checked", task_2_reloaded.state)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)
  end)

  describe("todo creation and manipulation", function()
    it("should create a new todo item", function()
      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with no todos
      local content = "# Todo List\n\nThis is a regular line\n"

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- Move cursor to the regular line
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      -- Create a todo item
      require("checkmate").create()

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify a todo was created on line 3
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      assert.matches("- " .. vim.pesc(unchecked) .. " This is a regular line", lines[3])

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should add metadata to todo items", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked

      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with a todo
      local content = "# Todo List\n\n- [ ] Task without metadata\n"

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- Move cursor to the todo line
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      -- Find the todo item at cursor
      local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 2, 0)
      assert.is_not_nil(todo_item)

      -- Add priority metadata
      require("checkmate").add_metadata("priority", "high")

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify metadata was added
      assert.matches("- " .. vim.pesc(unchecked) .. " Task without metadata @priority%(high%)", lines[3])

      -- Save the file
      vim.cmd("write")
      vim.cmd("sleep 10m")

      -- Read file directly
      local saved_content = h.read_file_content(file_path)
      if not saved_content then
        error("error reading file content")
      end

      -- Verify metadata was saved
      assert.matches("- %[ %] Task without metadata @priority%(high%)", saved_content)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should work with todo hierarchies", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- Create a test todo file with nested todos
      local file_path = h.create_temp_file()

      -- Initial content with hierarchical todos
      local content = [[
# Todo Hierarchy

- [ ] Parent task
  - [ ] Child task 1
  - [ ] Child task 2
    - [ ] Grandchild task
  - [ ] Child task 3
- [ ] Another parent
]]

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- Get parent and child todos
      local todo_map = require("checkmate.parser").discover_todos(bufnr)

      -- Find parent todo
      ---@type checkmate.TodoItem
      local parent_todo = nil
      for _, todo in pairs(todo_map) do
        if vim.startswith(todo.todo_text, "- " .. unchecked .. " Parent task") then
          parent_todo = todo
          break
        end
      end

      assert.is_not_nil(parent_todo)
      assert.equal(3, #parent_todo.children)

      -- Toggle parent to checked
      require("checkmate").set_todo_item(parent_todo, "checked")

      -- Get updated content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify parent is checked
      assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[3])

      -- Save
      vim.cmd("write")
      vim.cmd("sleep 10m")

      -- Read directly
      local saved_content = h.read_file_content(file_path)

      if not saved_content then
        error("error reading file content")
      end

      -- Split the content into lines for precise line-by-line verification
      local saved_lines = {}
      for line in saved_content:gmatch("([^\n]*)\n?") do
        table.insert(saved_lines, line)
      end

      -- Verify saved correctly with exact indentation
      assert.equal("# Todo Hierarchy", saved_lines[1])
      assert.equal("", saved_lines[2])
      assert.equal("- [x] Parent task", saved_lines[3])
      assert.equal("  - [ ] Child task 1", saved_lines[4])
      assert.equal("  - [ ] Child task 2", saved_lines[5])
      assert.equal("    - [ ] Grandchild task", saved_lines[6])
      assert.equal("  - [ ] Child task 3", saved_lines[7])
      assert.equal("- [ ] Another parent", saved_lines[8])

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should handle multiple todo operations in sequence", function()
      local config = require("checkmate.config")

      -- Create a test todo file
      local file_path = h.create_temp_file()

      -- Initial content with todos
      local content = [[
# Todo Sequence

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
]]

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- Operations: toggle task 1, add metadata to task 2, check task 3

      -- 1. Toggle task 1
      vim.api.nvim_win_set_cursor(0, { 3, 3 }) -- Position on Task 1
      require("checkmate").toggle()

      -- 2. Add metadata to task 2
      vim.api.nvim_win_set_cursor(0, { 4, 3 }) -- Position on Task 2
      require("checkmate").add_metadata("priority", "high")

      -- 3. Check task 3
      vim.api.nvim_win_set_cursor(0, { 5, 3 }) -- Position on Task 3
      require("checkmate").check()

      -- Get updated content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify all changes
      local checked = config.options.todo_markers.checked
      local unchecked = config.options.todo_markers.unchecked

      assert.matches("- " .. vim.pesc(checked) .. " Task 1", lines[3])
      assert.matches("- " .. vim.pesc(unchecked) .. " Task 2 @priority%(high%)", lines[4])
      assert.matches("- " .. vim.pesc(checked) .. " Task 3", lines[5])

      -- Save
      vim.cmd("write")
      vim.cmd("sleep 10m")

      -- Read directly
      local saved_content = h.read_file_content(file_path)
      if not saved_content then
        error("error reading file content")
      end

      -- Verify saved correctly
      assert.matches("- %[x%] Task 1", saved_content)
      assert.matches("- %[ %] Task 2 @priority%(high%)", saved_content)
      assert.matches("- %[x%] Task 3", saved_content)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should remove all metadata from todo items", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked

      local file_path = h.create_temp_file()

      local tags_on_removed_called = false

      --Setup an on_remove callback so that we can verify it is called when the tag is removed
      ---@diagnostic disable-next-line: missing-fields
      config.setup({
        metadata = {
          ---@diagnostic disable-next-line: missing-fields
          tags = {
            on_remove = function()
              tags_on_removed_called = true
            end,
          },
        },
      })

      -- Initial content with todos that have multiple metadata tags
      local content = [[
# Todo Metadata Test

- ]] .. unchecked .. [[ Task with @priority(high) @due(2023-05-15) @tags(important,urgent)
- ]] .. unchecked .. [[ Another task @priority(medium) @assigned(john)
- ]] .. unchecked .. [[ A todo without metadata
]]

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content)

      -- 1. Find the first todo item
      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local first_todo = nil

      for _, todo in pairs(todo_map) do
        if vim.startswith(todo.todo_text, "- " .. unchecked .. " Task with") then
          first_todo = todo
          break
        end
      end

      if not first_todo then
        error("missing first todo")
      end

      -- Verify it has multiple metadata entries
      assert.is_not_nil(first_todo.metadata)
      assert.is_true(#first_todo.metadata.entries > 0)

      -- 2. Remove all metadata
      vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 }) -- adjust from 0 index to 1-indexed
      require("checkmate").remove_all_metadata()

      vim.cmd("sleep 10m")
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- 3. Verify metadata was removed
      assert.no.matches("@priority", lines[3])
      assert.no.matches("@due", lines[3])
      assert.no.matches("@tags", lines[3])
      assert.matches("- " .. vim.pesc(unchecked) .. " Task with", lines[3])

      -- Also verify that on_remove callback was called for @tags tag
      assert.is_true(tags_on_removed_called)

      -- 4. Test removal in visual mode for multiple todos
      local second_todo = nil
      local third_todo = nil
      for _, todo in pairs(todo_map) do
        if vim.startswith(todo.todo_text, "- " .. unchecked .. " Another task") then
          second_todo = todo
        end
        if vim.startswith(todo.todo_text, "- " .. unchecked .. " A todo without") then
          third_todo = todo
        end
      end

      if not second_todo then
        error("missing second todo!")
      end
      if not third_todo then
        error("missing third todo!")
      end

      vim.api.nvim_win_set_cursor(0, { first_todo.range.start.row + 1, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(0, { third_todo.range.start.row + 1, 0 })

      -- Remove all metadata in visual mode
      require("checkmate").remove_all_metadata()

      vim.cmd("sleep 10m")
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify second todo's metadata was removed
      assert.no.matches("@priority", lines[4])
      assert.no.matches("@assigned", lines[4])

      -- Verify third todo's line text wasn't changed
      assert.matches("A todo without metadata", lines[5])

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should preserve cursor position in all operations", function()
      local file_path = h.create_temp_file()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- Content with multiple todos for testing
      local content = [[
# Cursor Position Test

- ]] .. unchecked .. [[ First todo item
- ]] .. unchecked .. [[ Second todo item
  - ]] .. unchecked .. [[ Child of second todo
- ]] .. unchecked .. [[ Third todo item
- ]] .. checked .. [[ Fourth todo item (already checked)

Normal content line (not a todo)]]

      h.write_file_content(file_path, content)
      vim.cmd("edit " .. file_path)
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"
      require("checkmate.api").setup(bufnr)

      -- Test 1: Normal mode with cursor on todo item
      vim.api.nvim_win_set_cursor(0, { 4, 10 }) -- Line 4, column 10
      local cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle()
      local cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Normal mode: cursor should be preserved on todo toggle")

      -- Test 2: Normal mode with cursor on non-todo line
      vim.api.nvim_win_set_cursor(0, { 9, 5 }) -- Non-todo line
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle() -- This should fail (no todo)
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Normal mode: cursor should be preserved when no todo found")

      -- Test 3: Visual mode with multiple todo items
      -- Enter visual line mode on lines 3-5
      vim.cmd("normal! 3GV5G")
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle()
      vim.cmd("normal! \27") -- Escape from any remaining visual mode
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Visual mode: cursor should be preserved after multi-line operation")

      -- Test 4: Adding metadata in normal mode
      vim.api.nvim_win_set_cursor(0, { 5, 15 }) -- On a todo line
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").add_metadata("priority", "high")
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when adding metadata in normal mode")

      -- Test 5: Adding metadata in visual mode
      vim.cmd("normal! 3GV4G") -- Select first and second todo items
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").add_metadata("priority", "medium")
      vim.cmd("normal! \27") -- Escape from any remaining visual mode
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when adding metadata in visual mode")

      -- Test 6: Removing metadata in normal and visual modes
      -- First add metadata to a todo item
      vim.api.nvim_win_set_cursor(0, { 6, 15 }) -- Child todo item
      require("checkmate").add_metadata("due", "tomorrow")

      -- Now test removing it in normal mode
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").remove_metadata("due")
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when removing metadata in normal mode")

      -- Add metadata to multiple items for visual mode test
      vim.cmd("normal! 3GV4G") -- Select first and second todo items
      require("checkmate").add_metadata("tags", "test")
      vim.cmd("normal! \27") -- Escape

      -- Now test removing in visual mode
      vim.cmd("normal! 3GV4G") -- Select same items again
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").remove_metadata("tags")
      vim.cmd("normal! \27") -- Escape
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when removing metadata in visual mode")

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)
  end)

  describe("metadata callbacks", function()
    it("should call on_add only when metadata is successfully added", function()
      -- Set up a test file
      local file_path = h.create_temp_file()
      local unchecked = require("checkmate.config").options.todo_markers.unchecked

      -- Initial content with one todo
      local content = "# Metadata Callbacks Test\n\n- " .. unchecked .. " A test todo"

      local bufnr = setup_todo_buffer(file_path, content)

      -- Create a spy to track callback execution
      local on_add_called = false
      local test_todo_item = nil

      -- Configure a test metadata tag with on_add callback
      local config = require("checkmate.config")
      ---@diagnostic disable-next-line: missing-fields
      config.setup({
        metadata = {
          ---@diagnostic disable-next-line: missing-fields
          test = {
            on_add = function(todo_item)
              on_add_called = true
              test_todo_item = todo_item
            end,
          },
        },
      })

      -- Get the todo item at row 2 (0-indexed)
      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local todo_item = nil
      for _, item in pairs(todo_map) do
        if item.range.start.row == 2 then
          todo_item = item
          break
        end
      end

      -- Verify we found the todo
      if not todo_item then
        error("missing todo item!")
      end

      -- Apply the metadata
      local success = require("checkmate.api").apply_metadata(todo_item, {
        meta_name = "test",
        custom_value = "test_value",
      })

      -- Check that the operation succeeded
      assert.is_true(success)
      -- Check that the callback was called
      assert.is_true(on_add_called)
      -- Check that the todo item was passed to the callback
      assert.is_not_nil(test_todo_item)
      -- Verify the metadata was added
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.matches("@test%(test_value%)", lines[3])

      -- Reset the callback flag
      on_add_called = false

      -- Try to apply metadata to a non-existent todo
      local fake_todo = {
        range = { start = { row = 999, col = 0 } },
        metadata = { entries = {}, by_tag = {} },
      }

      -- This should fail and the callback should not be called
      success = require("checkmate.api").apply_metadata(fake_todo, {
        meta_name = "test",
        custom_value = "test_value",
      })

      -- Check that the operation failed
      assert.is_false(success)

      -- Check that the callback was not called
      assert.is_false(on_add_called)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should call on_remove only when metadata is successfully removed", function()
      local file_path = h.create_temp_file()
      local unchecked = require("checkmate.config").options.todo_markers.unchecked

      -- Initial content with one todo with metadata
      local content = "# Metadata Callbacks Test\n\n- " .. unchecked .. " A test todo @test(test_value)"

      local bufnr = setup_todo_buffer(file_path, content)

      -- Create a spy to track callback execution
      local on_remove_called = false
      local test_todo_item = nil

      -- Configure a test metadata tag with on_remove callback
      local config = require("checkmate.config")
      ---@diagnostic disable-next-line: missing-fields
      config.setup({
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

      -- Get the todo item at row 2 (0-indexed)
      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local todo_item = nil
      for _, item in pairs(todo_map) do
        if item.range.start.row == 2 then
          todo_item = item
          break
        end
      end

      -- Verify we found the todo
      if not todo_item then
        error("missing todo item!")
      end

      -- Remove the metadata
      local success = require("checkmate.api").remove_metadata(todo_item, {
        meta_name = "test",
      })

      -- Check that the operation succeeded
      assert.is_true(success)
      -- Check that the callback was called
      assert.is_true(on_remove_called)
      -- Check that the todo item was passed to the callback
      assert.is_not_nil(test_todo_item)
      -- Verify the metadata was removed
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.no.matches("@test", lines[3])

      -- Reset the callback flag
      on_remove_called = false

      -- Try to remove metadata from a non-existent todo
      local fake_todo = {
        range = { start = { row = 999, col = 0 } },
        metadata = { entries = {}, by_tag = {} },
      }

      -- This should fail and the callback should not be called
      success = require("checkmate.api").remove_metadata(fake_todo, {
        meta_name = "test",
      })

      -- Check that the operation failed
      assert.is_false(success)
      -- Check that the callback was not called
      assert.is_false(on_remove_called)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)
  end)
end)
