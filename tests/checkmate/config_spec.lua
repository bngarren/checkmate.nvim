describe("Config", function()
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

    -- Back up any global state
    _G.loaded_checkmate_bak = vim.g.loaded_checkmate
    _G.checkmate_config_bak = vim.g.checkmate_config

    -- Reset global state
    vim.g.loaded_checkmate = nil
    vim.g.checkmate_config = nil
  end)

  after_each(function()
    -- Restore global state
    vim.g.loaded_checkmate = _G.loaded_checkmate_bak
    vim.g.checkmate_config = _G.checkmate_config_bak

    -- Clean up any state
    local config = require("checkmate.config")
    if config.is_running() then
      config.stop()
    end
  end)

  describe("initializaiton", function()
    it("should load with default options", function()
      local config = require("checkmate.config")

      assert.is_true(config.options.enabled)
      assert.is_true(config.options.notify)
      assert.equal("□", config.options.todo_markers.unchecked)
      assert.equal("✔", config.options.todo_markers.checked)
      assert.equal("-", config.options.default_list_marker)
      assert.equal(1, config.options.todo_action_depth)
      assert.is_true(config.options.enter_insert_after_new)
    end)
  end)

  describe("setup function", function()
    it("should overwrite defaults with user options", function()
      local config = require("checkmate.config")

      -- Default checks
      assert.equal("□", config.options.todo_markers.unchecked)
      assert.equal("✔", config.options.todo_markers.checked)

      -- Call setup with new options
      ---@diagnostic disable-next-line: missing-fields
      config.setup({
        todo_markers = {
          unchecked = "⬜",
          checked = "✅",
        },
        default_list_marker = "+",
        enter_insert_after_new = false,
      })

      -- Check that options were updated
      assert.equal("⬜", config.options.todo_markers.unchecked)
      assert.equal("✅", config.options.todo_markers.checked)
      assert.equal("+", config.options.default_list_marker)
      assert.is_false(config.options.enter_insert_after_new)
    end)
  end)

  describe("file pattern matching", function()
    it("should correctly determine if a buffer should activate Checkmate", function()
      local should_activate = require("checkmate.init").should_activate_for_buffer

      -- Test a variety of patterns and file combinations
      local tests = {
        -- Extension-less patterns match both with and without extensions
        {
          pattern = "TODO",
          filename = "/path/to/TODO.md",
          expect = true,
          desc = "Pattern without ext matches file with ext",
        },
        {
          pattern = "TODO",
          filename = "/path/to/TODO",
          expect = true,
          desc = "Pattern without ext matches file without ext",
        },

        -- Patterns with extensions match only that exact extension
        { pattern = "TODO.md", filename = "/path/to/TODO.md", expect = true, desc = "Exact match with extension" },
        {
          pattern = "TODO.md",
          filename = "/path/to/TODO",
          expect = false,
          desc = "Pattern with ext doesn't match file without ext",
        },
        {
          pattern = "TODO.txt",
          filename = "/path/to/TODO.md",
          expect = false,
          desc = "Different extensions don't match",
        },

        -- Test case sensitivity
        { pattern = "TODO", filename = "/path/to/todo.md", expect = false, desc = "Case sensitive matching" },

        -- Test wildcard patterns
        {
          pattern = "*TODO*",
          filename = "/path/to/myTODOlist.md",
          expect = true,
          desc = "Wildcard match with extension",
        },
        {
          pattern = "*TODO*",
          filename = "/path/to/myTODOlist",
          expect = true,
          desc = "Wildcard match without extension",
        },
        { pattern = "*todo*", filename = "/path/to/myTODOlist.md", expect = false, desc = "Case sensitive wildcard" },

        -- Test directory patterns
        {
          pattern = "notes/*.md",
          filename = "/path/to/notes/list.md",
          expect = true,
          desc = "Directory pattern match with extension",
        },
        {
          pattern = "notes/*",
          filename = "/path/to/notes/list.md",
          expect = true,
          desc = "Directory pattern without extension",
        },
        {
          pattern = "notes/*.md",
          filename = "/path/to/notes/list",
          expect = false,
          desc = "Directory pattern with ext doesn't match file without ext",
        },
        {
          pattern = "notes/*",
          filename = "/path/to/notes/list",
          expect = true,
          desc = "Directory pattern without ext matches file without ext",
        },

        -- Test complex combinations
        {
          pattern = "*/TODO/*",
          filename = "/path/to/TODO/list.md",
          expect = true,
          desc = "Complex wildcard with directories",
        },
        {
          pattern = "TODO/list",
          filename = "/path/to/TODO/list.md",
          expect = true,
          desc = "Path match with extension",
        },
        {
          pattern = "TODO/list",
          filename = "/path/to/TODO/list",
          expect = true,
          desc = "Path match without extension",
        },
      }

      for _, test in ipairs(tests) do
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, test.filename)

        local result = should_activate(bufnr, { test.pattern })
        assert.equal(
          test.expect,
          result,
          string.format("Pattern '%s' on file '%s': %s", test.pattern, test.filename, test.desc)
        )

        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)
  end)
end)
