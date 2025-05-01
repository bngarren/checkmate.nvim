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

      assert.equals("# Complex Todo List", lines[1])
      assert.equals("## Work Tasks", lines[2])
      assert.equals("- [ ] Major project planning", lines[3]:gsub("%s+$", ""))
      assert.equals("  * [ ] Research competitors", lines[4]:gsub("%s+$", ""))
      assert.equals("  * [x] Create timeline", lines[5]:gsub("%s+$", ""))
      assert.equals("  * [ ] Assign resources", lines[6]:gsub("%s+$", ""))
      assert.equals("    + [x] Allocate budget", lines[7]:gsub("%s+$", ""))
      assert.equals("    + [ ] Schedule meetings", lines[8]:gsub("%s+$", ""))
      assert.equals("    + [ ] Set milestones", lines[9]:gsub("%s+$", ""))
      assert.equals("  * [x] Draft proposal", lines[10]:gsub("%s+$", ""))
      assert.equals("- [x] Email weekly report", lines[11]:gsub("%s+$", ""))
      assert.equals("## Personal Tasks", lines[12])
      assert.equals("1. [ ] Grocery shopping", lines[13]:gsub("%s+$", ""))
      assert.equals("2. [x] Call dentist", lines[14]:gsub("%s+$", ""))
      assert.equals("3. [ ] Plan vacation", lines[15]:gsub("%s+$", ""))
      assert.equals("   - [ ] Research destinations", lines[16]:gsub("%s+$", ""))
      assert.equals("   - [x] Check budget", lines[17]:gsub("%s+$", ""))

      -- Verify Unicode symbols are NOT present in the saved file
      assert.not_matches(vim.pesc(unchecked), saved_content)
      assert.not_matches(vim.pesc(checked), saved_content)

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

      assert.is_not_nil(task_2)

      -- Toggle task 2 to checked
      local err, toggled = api.handle_toggle(bufnr, nil, nil, {
        existing_todo_item = task_2,
      })

      assert.is_nil(err)
      ---@diagnostic disable-next-line: need-check-nil
      assert.equals("checked", toggled.state)

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
      assert.equals("checked", task_2_reloaded.state)

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
      assert.equals(3, #parent_todo.children, "Parent should have 3 children")

      -- Toggle parent to checked
      require("checkmate.api").handle_toggle(bufnr, nil, nil, {
        existing_todo_item = parent_todo,
        target_state = "checked",
      })

      -- Get updated content
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify parent is checked
      assert.matches("- " .. vim.pesc(checked) .. " Parent task", lines[3], "Parent should be checked after toggle")

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
      assert.equals("# Todo Hierarchy", saved_lines[1])
      assert.equals("", saved_lines[2])
      assert.equals("- [x] Parent task", saved_lines[3])
      assert.equals("  - [ ] Child task 1", saved_lines[4], "Child task 1 should preserve 2-space indentation")
      assert.equals("  - [ ] Child task 2", saved_lines[5], "Child task 2 should preserve 2-space indentation")
      assert.equals("    - [ ] Grandchild task", saved_lines[6], "Grandchild task should preserve 4-space indentation")
      assert.equals("  - [ ] Child task 3", saved_lines[7], "Child task 3 should preserve 2-space indentation")
      assert.equals("- [ ] Another parent", saved_lines[8])

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
  end)
end)
