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

    -- Create a fresh buffer instead of using edit
    local bufnr = vim.api.nvim_create_buf(false, false)

    -- Set buffer name and load content
    vim.api.nvim_buf_set_name(bufnr, file_path)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!") -- Force reload from disk
    end)

    -- Ensure we're in the correct window
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)

    -- Ensure filetype is set to markdown
    vim.bo[bufnr].filetype = "markdown"

    -- Clear any existing buffer-local variables
    for k, _ in pairs(vim.b[bufnr]) do
      if type(k) == "string" and k:match("^checkmate_") then
        vim.b[bufnr][k] = nil
      end
    end

    require("checkmate").start()

    config_override = config_override or {}
    -- We need some specific global overrides for the tests
    -- - Disable callbacks that have mode changes as these can interfere with expected behaviors
    local config_ok = require("checkmate.config").setup(vim.tbl_deep_extend("force", {
      metadata = {
        ---@diagnostic disable-next-line: missing-fields
        priority = {
          select_on_insert = false,
        },
      },
      enter_insert_after_new = false,
      smart_toggle = {
        enabled = false,
      },
    }, config_override))

    if not config_ok then
      error("Could not setup config in setup_todo_buffer")
    end

    -- For testing, explicitly call setup instead of relying on autocmd
    local api = require("checkmate.api")

    local success = api.setup(bufnr)

    if not success then
      error("Failed to set up Checkmate for test buffer")
    end

    vim.wait(50, function()
      -- Check if any pending operations
      return vim.fn.jobwait({}, 0) == 0
    end)

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
        h.cleanup_buffer(bufnr, file_path)
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
        h.cleanup_buffer(bufnr, file_path)
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
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    describe("BufWriteCmd compatibility", function()
      it("should not require double :wq to exit", function()
        local file_path = h.create_temp_file()
        local content = "- [ ] Test"
        local bufnr = setup_todo_buffer(file_path, content)

        -- Modify buffer
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] Modified" })

        -- Track if BufWriteCmd was called
        local write_count = 0
        local original_autocmd = vim.api.nvim_create_autocmd("BufWriteCmd", {
          buffer = bufnr,
          callback = function()
            write_count = write_count + 1
          end,
        })

        -- First write should clear modified flag
        vim.cmd("write")
        assert.equal(1, write_count)
        assert.is_false(vim.bo[bufnr].modified)

        -- Second write should work but not be necessary
        vim.cmd("write")
        assert.equal(2, write_count)
        assert.is_false(vim.bo[bufnr].modified)

        -- Clean up
        vim.api.nvim_del_autocmd(original_autocmd)

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should handle :wa (write all modified buffers)", function()
        local file1 = h.create_temp_file()
        local file2 = h.create_temp_file()

        local bufnr1 = setup_todo_buffer(file1, "- [ ] File 1 todo")
        local bufnr2 = setup_todo_buffer(file2, "- [ ] File 2 todo")

        -- Modify both buffers - REPLACE content instead of appending
        vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, { "- [ ] File 1 new" })
        vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, { "- [ ] File 2 new" })

        -- Both should be modified
        assert.is_true(vim.bo[bufnr1].modified)
        assert.is_true(vim.bo[bufnr2].modified)

        -- Write all
        vim.cmd("wa")

        -- Both should be unmodified now
        assert.is_false(vim.bo[bufnr1].modified)
        assert.is_false(vim.bo[bufnr2].modified)

        -- Verify both files saved
        local content1 = h.read_file_content(file1)
        if not content1 then
          error("failed read file1")
        end

        local content2 = h.read_file_content(file2)
        if not content2 then
          error("failed read file2")
        end

        assert.equal("- [ ] File 1 new", content1)
        assert.equal("- [ ] File 2 new", content2)

        finally(function()
          h.cleanup_buffer(bufnr1, file1)
          h.cleanup_buffer(bufnr2, file2)
        end)
      end)

      it("should not trigger multiple writes on single save command", function()
        local file_path = h.create_temp_file()
        local bufnr = setup_todo_buffer(file_path, "- [ ] Test")

        -- Track write attempts
        local write_attempts = 0
        local original_writefile = vim.fn.writefile
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.writefile = function(...)
          write_attempts = write_attempts + 1
          return original_writefile(...)
        end

        -- Modify and save
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] New line" })
        vim.cmd("write")

        -- Should only write once
        assert.equal(1, write_attempts, "Write was called multiple times")

        -- Restore original function
        vim.fn.writefile = original_writefile

        finally(function()
          vim.fn.writefile = original_writefile -- ensure cleanup
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)
  end)

  describe("todo collection", function()
    it("should collect a single todo under cursor in normal mode", function()
      local unchecked = require("checkmate.config").options.todo_markers.unchecked

      -- Create a buffer with two todos
      local file_path = h.create_temp_file()
      local content = [[
- ]] .. unchecked .. [[ Task A
- ]] .. unchecked .. [[ Task B
]]
      local bufnr = setup_todo_buffer(file_path, content)

      -- Move cursor to the first todo line
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      -- Collect only the todo under the cursor
      local items = require("checkmate.api").collect_todo_items_from_selection(false)
      assert.equal(1, #items)
      -- Verify it's Task A
      assert.matches("Task A", items[1].todo_text)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should collect multiple todos within a visual selection", function()
      local unchecked = require("checkmate.config").options.todo_markers.unchecked

      -- Create a buffer with two todos
      local file_path = h.create_temp_file()
      local content = [[
- ]] .. unchecked .. [[ Task A
- ]] .. unchecked .. [[ Task B
]]
      local bufnr = setup_todo_buffer(file_path, content)

      -- Linewise select both todo lines
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- move to Task A
      vim.cmd("normal! V") -- start linewise visual
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- extend to Task B
      -- Collect all selected todos
      local items = require("checkmate.api").collect_todo_items_from_selection(true)
      assert.equal(2, #items)

      -- Verify we got exactly Task A and Task B (order doesn't matter)
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
        h.cleanup_buffer(bufnr, file_path)
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
      local success = require("checkmate").create()
      assert.is_true(success)

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify a todo was created on line 3
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      assert.matches("- " .. vim.pesc(unchecked) .. " This is a regular line", lines[3])

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
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
      local success = require("checkmate").add_metadata("priority", "high")
      assert.is_true(success)

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
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should add metadata to a nested todo item", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked

      local file_path = h.create_temp_file()

      local content = [[
- [ ] Parent todo
  - [ ] Child todo A
  - [ ] Child todo B
]]
      local bufnr = setup_todo_buffer(file_path, content)

      -- Move cursor to the Child todo A on line 2 (1-indexed)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      -- Find the todo item at cursor
      local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 1, 0) -- 0-indexed
      assert.is_not_nil(todo_item)

      -- Add @priority metadata
      require("checkmate").add_metadata("priority", "high")

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify metadata was added
      assert.matches("- " .. vim.pesc(unchecked) .. " Parent todo", lines[1])
      assert.matches("- " .. vim.pesc(unchecked) .. " Child todo A @priority%(high%)", lines[2])
      assert.matches("- " .. vim.pesc(unchecked) .. " Child todo B", lines[3])

      -- Now repeat for the parent todo

      -- Move cursor to the todo line
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Find the todo item at cursor
      local todo_item = require("checkmate.parser").get_todo_item_at_position(bufnr, 0, 0)
      assert.is_not_nil(todo_item)

      -- Add @priority metadata
      require("checkmate").add_metadata("priority", "medium")

      -- Get the buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify metadata was added
      assert.matches("- " .. vim.pesc(unchecked) .. " Parent todo @priority%(medium%)", lines[1])
      assert.matches("- " .. vim.pesc(unchecked) .. " Child todo", lines[2])
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
        h.cleanup_buffer(bufnr, file_path)
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
        h.cleanup_buffer(bufnr, file_path)
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
        h.cleanup_buffer(bufnr, file_path)
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

        h.cleanup_buffer(bufnr, file_path)
      end)
    end)
  end)

  describe("smart toggle", function()
    local config = require("checkmate.config")

    local function setup_smart_toggle_buffer(content, smart_toggle_config)
      local file_path = h.create_temp_file()

      -- Merge smart_toggle config with base config
      local config_override = {
        smart_toggle = vim.tbl_extend("force", {
          enabled = true,
          check_down = "direct_children",
          uncheck_down = "none",
          check_up = "direct_children",
          uncheck_up = "direct_children",
        }, smart_toggle_config or {}),
      }

      return setup_todo_buffer(file_path, content, config_override), file_path
    end

    describe("downward propagation", function()
      it("should check all direct children when parent is checked (check_down='direct_children')", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- Move cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Verify the results
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])
        -- Grandchild should NOT be checked (only direct children)
        assert.matches("- " .. vim.pesc(unchecked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should check all descendants when parent is checked (check_down='all')", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
      - ]] .. unchecked .. [[ Great-grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "all_children" })

        -- Move cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Verify ALL descendants are checked
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
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. unchecked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "none" })

        -- Move cursor to parent task and toggle
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Verify only parent is checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should uncheck direct children when parent is unchecked (uncheck_down='direct_children')", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. checked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { uncheck_down = "direct_children" })

        -- Move cursor to parent task and toggle (uncheck it)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Verify results
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])
        -- Grandchild should remain checked (only direct children affected)
        assert.matches("- " .. vim.pesc(checked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)

    describe("upward propagation", function()
      it("should check parent when all direct children are checked (check_up='direct_children')", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. unchecked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. unchecked .. [[ Child 2
  - ]] .. checked .. [[ Child 3
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_up = "direct_children" })

        -- Check the remaining unchecked child
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Parent should now be checked since all children are checked
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
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

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

        -- Check Child 2 first
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        require("checkmate").toggle()
        vim.wait(20)

        -- Parent should NOT be checked yet (grandchild 2 is still unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])

        -- Now check Grandchild 2
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
        require("checkmate").toggle()
        vim.wait(20)

        -- Now parent should be checked (all descendants are checked)
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
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. unchecked .. [[ Grandchild 1
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { uncheck_up = "direct_children" })

        -- Uncheck one child
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Parent should be unchecked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 1", lines[2])
        assert.matches("- " .. vim.pesc(checked) .. " Child 2", lines[3])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)

      it("should uncheck parent when any descendant is unchecked (uncheck_up='all_children')", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. checked .. [[ Parent task
  - ]] .. checked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
    - ]] .. checked .. [[ Grandchild 1
]]

        local bufnr, file_path =
          setup_smart_toggle_buffer(content, { uncheck_up = "all_children", uncheck_down = "none" })

        -- Uncheck the grandchild
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Parent should be unchecked (because a descendant is unchecked)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(unchecked) .. " Parent task", lines[1])
        assert.matches("- " .. vim.pesc(checked) .. " Child 1", lines[2])
        -- Child 2 is unchecked as it is a parent of Grandchild 1
        assert.matches("- " .. vim.pesc(unchecked) .. " Child 2", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Grandchild 1", lines[4])

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end)
    end)

    describe("complex scenarios", function()
      it("should handle multiple selection with smart toggle", function()
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        local content = [[
- ]] .. unchecked .. [[ Task A
  - ]] .. unchecked .. [[ Task A.1
- ]] .. unchecked .. [[ Task B
  - ]] .. unchecked .. [[ Task B.1
    - ]] .. unchecked .. [[ Task B.1.1
- ]] .. unchecked .. [[ Task C
]]

        local bufnr, file_path = setup_smart_toggle_buffer(content, { check_down = "direct_children" })

        -- Select both parent tasks in visual mode
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! V")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })

        -- Toggle both
        require("checkmate").toggle()

        vim.wait(20)

        -- All tasks should be checked
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
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

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

        -- Check Child 1.2 - this should cascade up
        vim.api.nvim_win_set_cursor(0, { 4, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Should check Child 1.2, Parent 1, and Grandparent
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
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

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

        -- Toggle first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").toggle()

        vim.wait(20)

        -- Only first task should be checked
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.matches("- " .. vim.pesc(checked) .. " Task A", lines[1])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task A%.1", lines[2])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task A%.2", lines[3])
        assert.matches("- " .. vim.pesc(unchecked) .. " Task B", lines[4])

        -- Reset first task
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("checkmate").uncheck()

        -- Select both child tasks in visual mode
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.cmd("normal! V")
        vim.api.nvim_win_set_cursor(0, { 3, 0 })

        require("checkmate").check()
        vim.wait(20)

        -- First task should not be checked (no propagation from children)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
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
      ---@cast todo_item checkmate.TodoItem

      -- Apply the metadata
      vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 })
      local success = require("checkmate").add_metadata("test", "test_value")

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

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
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
      ---@cast todo_item checkmate.TodoItem

      -- Remove the metadata
      vim.api.nvim_win_set_cursor(0, { todo_item.range.start.row + 1, 0 }) -- set the cursor on the todo item
      local success = require("checkmate").remove_metadata("test")

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

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should apply metadata with on_add callback to all todos in bulk (normal and visual mode)", function()
      local config = require("checkmate.config")
      local api = require("checkmate.api")

      local unchecked = config.options.todo_markers.unchecked

      -- Create a test todo file with many todos
      local total_todos = 30
      local file_path = h.create_temp_file()

      -- Generate content: N todos, each on its own line
      local todo_lines = {}
      for i = 1, total_todos do
        table.insert(todo_lines, "- " .. unchecked .. " Bulk task " .. i)
      end
      local content = "# Bulk Metadata Test\n\n" .. table.concat(todo_lines, "\n")

      local on_add_calls = {}

      -- Register the metadata tag with a callback that tracks which todos are affected
      local bufnr = nil
      bufnr = setup_todo_buffer(file_path, content, {
        metadata = {
          ---@diagnostic disable-next-line: missing-fields
          bulk = {
            on_add = function(todo_item)
              -- Record the todo's line (1-based)
              table.insert(on_add_calls, todo_item.range.start.row + 1)
            end,
            select_on_insert = false,
          },
        },
      })

      -- ========== NORMAL MODE BULK TOGGLE ==========
      -- Cursor at first todo; normal mode; toggle_metadata should apply to all todos
      vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- First todo line (after 2 header lines)
      on_add_calls = {}
      require("checkmate").toggle_metadata("bulk")
      vim.wait(20)
      vim.cmd("redraw")

      -- Assert: callback fired once for todo with added metadata
      assert.equal(1, #on_add_calls, "on_add should be called once")

      -- Remove all metadata for next test (reset state)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      require("checkmate").remove_metadata("bulk")
      vim.wait(10)
      vim.cmd("redraw")

      -- ========== VISUAL MODE BULK TOGGLE ==========
      -- Select all todos visually, then apply toggle_metadata again
      -- Move to first todo
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.cmd("normal! V")
      -- Extend to last todo line
      vim.api.nvim_win_set_cursor(0, { 2 + total_todos, 0 })
      on_add_calls = {}
      require("checkmate").toggle_metadata("bulk")
      vim.cmd("normal! \27") -- Exit visual mode
      vim.wait(20)
      vim.cmd("redraw")

      -- Assert: callback fired once per selected todo (should be all)
      assert.equal(total_todos, #on_add_calls, "on_add should be called for every visually-selected todo")
      -- Each line should have metadata
      for i = 3, 2 + total_todos do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
        assert.matches("@bulk", line)
      end

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)
  end)

  describe("archive system", function()
    it("should not create archive section when no checked todos exist", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked

      local file_path = h.create_temp_file()
      local content = [[
# Todo List
- ]] .. unchecked .. [[ Task 1
- ]] .. unchecked .. [[ Task 2
  - ]] .. unchecked .. [[ Subtask 2.1
]]

      local bufnr = setup_todo_buffer(file_path, content)

      local success = require("checkmate").archive()
      assert.is_false(success) -- Should return false when nothing to archive

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify no archive section was created
      local archive_heading_string = require("checkmate.util").get_heading_string(
        config.options.archive.heading.title,
        config.options.archive.heading.level
      )
      assert.no.matches(vim.pesc(archive_heading_string), buffer_content)

      local expected_main_content = {
        "# Todo List",
        "- " .. unchecked .. " Task 1",
        "- " .. unchecked .. " Task 2",
        "  - " .. unchecked .. " Subtask 2.1",
      }

      -- Verify original content is unchanged
      local result, err = h.verify_content_lines(buffer_content, expected_main_content)
      assert.equal(result, true, err)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

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

      local heading_title = "Completed Todos"
      local success = require("checkmate").archive({ heading = { title = heading_title } })

      vim.wait(20)
      vim.cmd("redraw")

      assert.is_true(success)

      -- Get the modified buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string =
        require("checkmate.util").get_heading_string(heading_title, config.options.archive.heading.level)

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      -- Verify that checked top-level tasks were removed
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 1", main_section)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task 2", main_section)

      -- Verify unchecked tasks remain
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 1", main_section)
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task 2", main_section)

      -- Verify archive section was created
      assert.matches(archive_heading_string, buffer_content)

      -- Verify contents were moved to archive section
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

      -- The existing section should still be present
      assert.matches("## Existing Section", buffer_content)
      assert.matches("Some content here", buffer_content)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should only leave max 1 line between remaining todo items after archive", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local file_path = h.create_temp_file()

      local content = [[
# Todo List

- ]] .. unchecked .. [[ Unchecked task 1

- ]] .. checked .. [[ Checked task 1
  - ]] .. checked .. [[ Checked subtask 1.1

- ]] .. checked .. [[ Checked task 2
  - ]] .. checked .. [[ Checked subtask 2.1

- ]] .. unchecked .. [[ Unchecked task 2

]]

      local bufnr = setup_todo_buffer(file_path, content)

      local success = require("checkmate").archive()

      vim.wait(20)
      vim.cmd("redraw")

      assert.is_true(success)

      -- Get the modified buffer content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.options.archive.heading.title),
        config.options.archive.heading.level
      )

      local main_section = buffer_content:match("^(.-)" .. archive_heading_string)

      local expected_main_content = {
        "# Todo List",
        "",
        "- " .. unchecked .. " Unchecked task 1",
        "",
        "- " .. unchecked .. " Unchecked task 2",
        "",
      }

      local archive_success, err = h.verify_content_lines(main_section, expected_main_content)
      assert.equal(archive_success, true, err)
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
      local heading_title = "Completed Items"
      local heading_level = 4 -- ####
      local bufnr = setup_todo_buffer(file_path, content, {
        archive = { heading = { title = heading_title, level = heading_level } },
      })

      -- Archive checked todos
      local success = require("checkmate").archive()
      vim.wait(20)
      vim.cmd("redraw")

      assert.is_true(success)

      -- Get buffer content after archiving
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      local archive_heading_string = require("checkmate.util").get_heading_string(heading_title, heading_level)

      -- Verify custom heading was used
      assert.matches(archive_heading_string, buffer_content)

      -- Verify content was archived correctly
      local archive_section = buffer_content:match("#### Completed Items" .. ".*$")
      assert.is_not_nil(archive_section)
      assert.matches("- " .. vim.pesc(checked) .. " Checked task", archive_section)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should merge with existing archive section", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local file_path = h.create_temp_file()

      local archive_heading_string = require("checkmate.util").get_heading_string(
        vim.pesc(config.options.archive.heading.title),
        config.options.archive.heading.level
      )

      local content = [[
# Existing Archive Test

- ]] .. unchecked .. [[ Unchecked task
- ]] .. checked .. [[ Checked task to archive

]] .. archive_heading_string .. [[

- ]] .. checked .. [[ Previously archived task
]]

      local bufnr = setup_todo_buffer(file_path, content)

      local success = require("checkmate").archive()
      assert.is_true(success)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buffer_content = table.concat(lines, "\n")

      -- Verify that checked task was removed from main content
      local main_content = buffer_content:match("^(.-)" .. archive_heading_string)
      assert.is_not_nil(main_content)
      assert.no.matches("- " .. vim.pesc(checked) .. " Checked task to archive", main_content)

      -- Verify unchecked task remains in main content
      assert.matches("- " .. vim.pesc(unchecked) .. " Unchecked task", main_content)

      local archive_section = buffer_content:match(archive_heading_string .. ".*$")
      assert.is_not_nil(archive_section)

      local expected_archive = {
        "## Archive", -- default title and level. *This must match the config
        "",
        "- " .. checked .. " Previously archived task",
        "- " .. checked .. " Checked task to archive",
      }

      local archive_success, err = h.verify_content_lines(archive_section, expected_archive)
      assert.equal(archive_success, true, err)

      -- Verify that parent_spacing is respected when merging with existing archive
      -- This assumes default parent_spacing = 0, so no extra blank lines between archived items
      local lines_array = vim.split(archive_section, "\n", { plain = true })
      for i = 2, #lines_array - 1 do -- Skip heading and last line
        if lines_array[i] == "" and lines_array[i + 1] and lines_array[i + 1] == "" then
          error("Found multiple consecutive blank lines in archive section")
        end
      end

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)

    it("should insert the configured parent_spacing between archived parent blocks", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- Test with different spacing values
      for _, spacing in ipairs({ 0, 1, 2 }) do
        -- test setup
        local file_path = h.create_temp_file()
        local content = [[
# Tasks
- ]] .. unchecked .. [[ Active task
- ]] .. checked .. [[ Done task A
  - ]] .. checked .. [[ Done subtask A.1
- ]] .. checked .. [[ Done task B
]]

        local bufnr = setup_todo_buffer(file_path, content, { archive = { parent_spacing = spacing } })

        local success = require("checkmate").archive()
        vim.wait(20)
        vim.cmd("redraw")
        assert.equal(true, success, "Archive failed for parent_spacing = " .. spacing)

        -- assertions
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local buffer_content = table.concat(lines, "\n")

        local archive_heading_string = require("checkmate.util").get_heading_string(
          vim.pesc(config.options.archive.heading.title),
          config.options.archive.heading.level
        )

        -- Find the archive section
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

        -- Count blank lines between the two roots
        -- We need to count from after the last line of the first block
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

        finally(function()
          h.cleanup_buffer(bufnr, file_path)
        end)
      end
    end)
  end)
  describe("diffs", function()
    it("should compute correct diff hunk for toggling a single todo item", function()
      local config = require("checkmate.config")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- create a one-line todo
      local file_path = h.create_temp_file()
      local content = [[
- ]] .. unchecked .. [[ MyTask
]]
      local bufnr = setup_todo_buffer(file_path, content)

      local parser = require("checkmate.parser")
      local api = require("checkmate.api")

      -- discover the todo and verify initial state
      local todo_map = parser.discover_todos(bufnr)
      local todo = h.find_todo_by_text(todo_map, "MyTask")
      assert.is_not_nil(todo)
      ---@cast todo checkmate.TodoItem

      assert.equal("unchecked", todo.state)

      -- compute the diff to check it
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
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)
  end)
end)
