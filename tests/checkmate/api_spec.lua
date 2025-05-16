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

  -- Set up a todo file in a buffer with autocmds
  local function setup_todo_buffer(file_path, content, config_override)
    h.write_file_content(file_path, content)

    -- Open the file in a buffer
    vim.cmd("edit " .. file_path)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Ensure filetype is set to markdown
    vim.bo[bufnr].filetype = "markdown"

    require("checkmate").start()

    config_override = config_override or {}
    -- We need some specific global overrides for the tests
    -- - Disable callbacks that have mode changes as these can interfere with expected behaviors
    require("checkmate.config").setup(vim.tbl_deep_extend("force", {
      metadata = {
        ---@diagnostic disable-next-line: missing-fields
        priority = {
          select_on_insert = false,
        },
      },
      enter_insert_after_new = false,
    }, config_override))

    -- For testing, explicitly call setup instead of relying on autocmd
    local api = require("checkmate.api")

    local success = api.setup(bufnr)

    if not success then
      error("Failed to set up Checkmate for test buffer")
    end

    -- Ensure any initial processing is complete
    vim.cmd("redraw")

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

      -- Use the setup helper instead of manual setup
      local bufnr = setup_todo_buffer(file_path, content)

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify content was converted to Unicode
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", buffer_content)
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", buffer_content)

      -- Verify the node structure is properly built
      local todo_map = require("checkmate.parser").discover_todos(bufnr)
      local found_items = 0
      for _, _ in pairs(todo_map) do
        found_items = found_items + 1
      end
      assert.is_true(found_items == 2)

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
      vim.wait(20)

      -- 2. Add metadata to task 2
      vim.api.nvim_win_set_cursor(0, { 4, 3 }) -- Position on Task 2
      require("checkmate").add_metadata("priority", "high")
      vim.cmd(" ")
      vim.wait(20)

      -- 3. Check task 3
      vim.api.nvim_win_set_cursor(0, { 5, 3 }) -- Position on Task 3
      require("checkmate").check()
      vim.wait(20)

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

      -- Initial content with todos that have multiple metadata tags
      local content = [[
# Todo Metadata Test

- ]] .. unchecked .. [[ Task with @priority(high) @due(2023-05-15) @tags(important,urgent)
- ]] .. unchecked .. [[ Another task @priority(medium) @assigned(john)
- ]] .. unchecked .. [[ A todo without metadata
]]

      -- Setup buffer with the content
      local bufnr = setup_todo_buffer(file_path, content, {
        metadata = {
          ---@diagnostic disable-next-line: missing-fields
          tags = {
            on_remove = function()
              tags_on_removed_called = true
            end,
          },
        },
      })

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
        vim.cmd("normal! \27") -- Escape to normal mode

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    pending("should preserve cursor position in all operations", function()
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

      local bufnr = setup_todo_buffer(file_path, content)

      -- Helper function to ensure we're in normal mode between tests
      local function reset_mode()
        local mode = vim.fn.mode()
        if mode ~= "n" then
          vim.cmd("normal! \27") -- Escape to normal mode
          vim.cmd("redraw!") -- Process any pending events
        end
      end

      -- Test 1: Normal mode with cursor on todo item
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 4, 10 }) -- Line 4, column 10
      local cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle()
      local cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Normal mode: cursor should be preserved on todo toggle")

      -- Test 2: Normal mode with cursor on non-todo line
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 9, 5 }) -- Non-todo line
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle() -- This should fail (no todo)
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Normal mode: cursor should be preserved when no todo found")

      -- Test 3: Visual mode with multiple todo items
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- Start at line 3
      vim.cmd("normal! V2j") -- Visual line mode selecting 3 lines
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").toggle()
      vim.cmd("normal! \27") -- Exit visual mode
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Visual mode: cursor should be preserved after multi-line operation")

      -- Test 4: Adding metadata in normal mode
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 5, 15 }) -- On a todo line
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").add_metadata("priority", "high")
      vim.wait(20, function()
        return false
      end) -- Wait for any scheduled operations
      reset_mode() -- Ensure normal mode after operation
      cursor_after = vim.api.nvim_win_get_cursor(0)
      -- Only verify the line hasn't changed, column will change when adding metadata
      assert.equal(cursor_before[1], cursor_after[1], "Cursor line should be preserved when adding metadata")

      -- Test 5: Adding metadata in visual mode
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- Start at line 3
      vim.cmd("normal! V") -- Start visual line mode
      vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- End at line 4
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").add_metadata("priority", "medium")
      vim.cmd("normal! \27") -- Exit visual mode
      vim.wait(20, function()
        return false
      end) -- Wait for any scheduled operations
      reset_mode() -- Ensure normal mode after operation
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when adding metadata in visual mode")

      -- Test 6: Removing metadata in normal mode
      reset_mode()
      vim.api.nvim_win_set_cursor(0, { 6, 15 }) -- Child todo item
      require("checkmate").add_metadata("due", "tomorrow")
      vim.wait(20, function()
        return false
      end) -- Wait for any scheduled operations
      reset_mode() -- Ensure normal mode

      -- Now test removing it
      cursor_before = vim.api.nvim_win_get_cursor(0)
      require("checkmate").remove_metadata("due")
      vim.wait(20, function()
        return false
      end) -- Wait for any scheduled operations
      reset_mode() -- Ensure normal mode
      cursor_after = vim.api.nvim_win_get_cursor(0)
      assert.are.same(cursor_before, cursor_after, "Cursor should be preserved when removing metadata in normal mode")

      -- Ensure we end in normal mode
      reset_mode()

      -- Final test with one buffer operation
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      require("checkmate").check()

      -- Process any remaining operations
      vim.cmd("redraw!")
      vim.wait(20, function()
        return false
      end)

      finally(function()
        -- Ensure we're in normal mode before cleanup
        reset_mode()

        -- Clean up
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, file_path)
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

      -- Create a spy to track callback execution
      local on_add_called = false
      local test_todo_item = nil

      local bufnr = setup_todo_buffer(file_path, content, {
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

      vim.wait(20)
      vim.cmd("redraw")

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

      vim.wait(20)
      vim.cmd("redraw")

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

      vim.wait(20)
      vim.cmd("redraw")

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

      vim.wait(20)
      vim.cmd("redraw")

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

  describe("archive system", function()
    it("should archive completed todo items to specified section", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local file_path = h.create_temp_file()

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

      local bufnr = setup_todo_buffer(file_path, content)

      local success = require("checkmate").archive()

      vim.wait(20)
      vim.cmd("redraw")

      assert.is_true(success)

      -- Get the modified buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local main_section = buffer_content:match("^(.-)## " .. vim.pesc(config.options.archive.heading))

      -- Verify that checked top-level tasks were removed
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 1", main_section)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 2", main_section)

      -- Verify unchecked tasks remain
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 1", main_section)
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 2", main_section)

      -- Verify archive section was created
      assert.matches("## " .. config.options.archive.heading, buffer_content)

      -- Verify contents were moved to archive section
      local archive_section = buffer_content:match("## " .. vim.pesc(config.options.archive.heading) .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. vim.pesc(config.options.archive.heading),
        "",
        "- " .. checked .. " Checked task 1",
        "  - " .. checked .. " Checked subtask 1.1",
        "  - " .. unchecked .. " Unchecked subtask 1.2",
        "- " .. checked .. " Checked task 2",
        "  - " .. checked .. " Checked subtask 2.1",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      -- The existing section should still be present
      assert.matches("## Existing Section", buffer_content)
      assert.matches("Some content here", buffer_content)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should work with custom archive heading", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local file_path = h.create_temp_file()

      local content = [[
# Custom Archive Heading Test

- ]] .. unchecked .. [[ Unchecked task
- ]] .. checked .. [[ Checked task
]]

      -- Setup with custom archive heading
      local custom_heading = "Completed Items"
      local bufnr = setup_todo_buffer(file_path, content, {
        archive = { heading = custom_heading },
      })

      -- Archive checked todos
      local success = require("checkmate").archive()
      vim.wait(20)
      vim.cmd("redraw")

      assert.is_true(success)

      -- Get buffer content after archiving
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify custom heading was used
      assert.matches("## " .. custom_heading, buffer_content)

      -- Verify content was archived correctly
      local archive_section = buffer_content:match("## " .. vim.pesc(custom_heading) .. ".*$")
      assert.is_not_nil(archive_section)
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", archive_section)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)

    it("should merge with existing archive section", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local file_path = h.create_temp_file()

      local content = [[
# Existing Archive Test

- ]] .. unchecked .. [[ Unchecked task
- ]] .. checked .. [[ Checked task to archive

## ]] .. config.options.archive.heading .. [[

- ]] .. checked .. [[ Previously archived task
]]

      local bufnr = setup_todo_buffer(file_path, content)

      -- Archive checked todos
      local success = require("checkmate").archive()
      assert.is_true(success)

      -- Get buffer content after archiving
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify that checked task was removed from main content
      local main_content = buffer_content:match("^(.-)" .. vim.pesc("## " .. config.options.archive.heading))
      assert.is_not_nil(main_content)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task to archive", main_content)

      -- Verify unchecked task remains in main content
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", main_content)

      -- Verify archive section contains both the previously archived task and newly archived task
      local archive_section = buffer_content:match("## " .. vim.pesc(config.options.archive.heading) .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## " .. vim.pesc(config.options.archive.heading),
        "",
        "- " .. checked .. " Previously archived task",
        "- " .. checked .. " Checked task to archive",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
        os.remove(file_path)
      end)
    end)
  end)
end)
