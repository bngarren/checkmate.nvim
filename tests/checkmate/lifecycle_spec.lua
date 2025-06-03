describe("checkmate init and lifecycle", function()
  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()

    _G.reset_state()
  end)

  before_each(function()
    _G.reset_state()
  end)

  describe("setup", function()
    it("should initialize with default configuration", function()
      local checkmate = require("checkmate")
      local config = require("checkmate.config")
      local result = checkmate.setup()
      assert.is_true(result)
      assert.is_true(checkmate.is_running())
      local actual = vim.deepcopy(config.options)
      actual.style = {} -- to match expected because default has style = {}
      local expected = config.get_defaults()
      assert.same(expected, actual)
      checkmate.stop()
    end)

    it("should accept custom configuration", function()
      local custom_config = {
        enabled = true,
        files = { "tasks.md", "*.task" },
        todo_markers = {
          checked = "x",
          unchecked = "o",
        },
        notify = false,
      }

      local checkmate = require("checkmate")
      local config = require("checkmate.config")

      local result = checkmate.setup(custom_config)
      assert.is_true(result)
      assert.equal(2, #config.options.files)
      assert.equal("tasks.md", config.options.files[1])
      assert.equal("*.task", config.options.files[2])
      assert.equal("x", config.options.todo_markers.checked)
      assert.equal("o", config.options.todo_markers.unchecked)
      assert.is_false(config.options.notify)

      checkmate.stop()
    end)

    it("should handle invalid configuration gracefully", function()
      local checkmate = require("checkmate")

      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ enabled = "not a boolean" })
      assert.is_false(result)
      assert.is_false(checkmate.is_running())

      _G.reset_state()
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      result = checkmate.setup({ files = "not a table" })
      assert.is_false(result)
      assert.is_false(checkmate.is_running())

      -- Reset and try with invalid todo marker length
      _G.reset_state()
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      result = checkmate.setup({ todo_markers = { checked = "too long" } })
      assert.is_false(result)
      assert.is_false(checkmate.is_running())

      checkmate.stop()
    end)

    it("should stop existing instance before starting new one", function()
      local checkmate = require("checkmate")
      local config = require("checkmate.config")

      checkmate.setup()
      assert.is_true(checkmate.is_running())

      -- Second setup should stop first instance
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ notify = false })
      assert.is_true(result)
      assert.is_true(checkmate.is_running())
      assert.is_false(config.options.notify)

      checkmate.stop()
    end)

    it("should not start when enabled is false", function()
      local checkmate = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ enabled = false })
      assert.is_true(result)
      assert.is_false(checkmate.is_running())

      checkmate.stop()
    end)

    it("should activate existing markdown buffers on setup", function()
      local checkmate = require("checkmate")

      vim.cmd("edit todo.md")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"

      -- setup should activate this buffer
      checkmate.setup()

      vim.wait(10)

      assert.is_true(vim.b[bufnr].checkmate_setup_complete or false)

      checkmate.stop()
    end)
  end)

  describe("plugin state", function()
    before_each(function()
      _G.reset_state()
    end)

    it("should track running state correctly", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      -- checkmate.setup() has already run during the before_each block above
      assert.is_true(checkmate.is_running())

      checkmate.stop()
      assert.is_false(checkmate.is_running())
    end)

    it("should handle multiple start calls", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      assert.is_true(checkmate.is_running())

      checkmate.start()
      assert.is_true(checkmate.is_running())

      checkmate.stop()
    end)

    it("should handle multiple stop calls", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      checkmate.stop()
      assert.is_false(checkmate.is_running())

      checkmate.stop()
      assert.is_false(checkmate.is_running())
    end)

    it("should clean up resources on stop", function()
      local checkmate = require("checkmate")

      checkmate.setup()

      assert.equal(0, checkmate.count_active_buffers())

      vim.cmd("edit todo.md")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"

      vim.wait(50, function()
        return vim.b[bufnr].checkmate_setup_complete == true
      end, 10)

      assert.equal(1, checkmate.count_active_buffers())

      checkmate.stop()

      local config = require("checkmate.config")
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, 0, -1, {})
      assert.equal(0, #extmarks)

      assert.equal(0, checkmate.count_active_buffers())

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
  describe("buffer activation", function()
    it("should activate on FileType autocmd for matching files", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      -- Create a buffer with matching filename
      vim.cmd("edit TODO")
      local bufnr = vim.api.nvim_get_current_buf()

      vim.bo[bufnr].filetype = "markdown"

      assert.is_true(vim.b[bufnr].checkmate_setup_complete or false)

      checkmate.stop()
    end)

    it("should not activate for non-matching files", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      vim.cmd("edit NOPE.md") -- does not match defaults
      local bufnr = vim.api.nvim_get_current_buf()

      vim.bo[bufnr].filetype = "markdown"

      assert.is_falsy(vim.b[bufnr].checkmate_setup_complete)

      checkmate.stop()
    end)

    it("should handle buffer deletion", function()
      local checkmate = require("checkmate")

      checkmate.setup()

      vim.cmd("edit todo.md")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"

      local active_buffers = checkmate.get_active_buffer_map()

      assert.is_true(active_buffers[bufnr] or false)

      vim.api.nvim_buf_delete(bufnr, { force = true })

      active_buffers = checkmate.get_active_buffer_map()
      assert.is_nil(active_buffers[bufnr])
    end)
  end)

  -- TODO: finish
  pending("file patterns", function()
    local config = require("checkmate.config")
    local checkmate = require("checkmate")

    lazy_setup(function()
      checkmate.setup()
    end)

    lazy_teardown(function()
      checkmate.stop()
    end)

    local function test_pattern(filename, should_match)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, filename)
      local result = checkmate.should_activate_for_buffer(bufnr, config.options.files)
      assert.equal(
        should_match,
        result,
        string.format("Pattern match failed for '%s' (expected %s)", filename, should_match)
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    it("should match exact filenames", function()
      test_pattern("todo", true)
      test_pattern("TODO", true)
      test_pattern("todo.md", true)
      test_pattern("TODO.md", true)
    end)

    it("should match wildcard patterns", function()
      test_pattern("my.todo", true)
      test_pattern("project.todo.md", true)
      test_pattern(".todo", true)
      test_pattern("todo.txt", true) -- matches *.todo*
    end)

    it("should not match non-matching files", function()
      test_pattern("notes.md", false)
      test_pattern("readme.txt", false)
      test_pattern("task.md", false)
    end)

    it("should handle directory patterns", function()
      ---@diagnostic disable-next-line: missing-fields
      checkmate.setup({ files = { "docs/todo", "*/TODO.md" } })

      test_pattern("docs/todo", true)
      test_pattern("docs/todo.md", true)
      test_pattern("any/TODO.md", true)
      test_pattern("todo", false)
      test_pattern("TODO.md", false) -- not in subdirectory
    end)

    it("should handle case sensitivity correctly", function()
      -- Default patterns are case-sensitive
      test_pattern("Todo", false)
      test_pattern("tODO", false)

      -- Users need to include both cases if they want case-insensitive
      ---@diagnostic disable-next-line: missing-fields
      checkmate.setup({ files = { "todo", "Todo", "TODO" } })
      test_pattern("todo", true)
      test_pattern("Todo", true)
      test_pattern("TODO", true)
    end)

    it("should handle patterns without extensions", function()
      ---@diagnostic disable-next-line: missing-fields
      checkmate.setup({ files = { "tasks" } })

      test_pattern("tasks", true)
      test_pattern("tasks.md", true) -- .md extension is automatically considered
      test_pattern("tasks.txt", false)
    end)
  end)
end)
