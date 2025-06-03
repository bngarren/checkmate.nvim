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

    -- Back up globals
    _G.loaded_checkmate_bak = vim.g.loaded_checkmate
    _G.checkmate_config_bak = vim.g.checkmate_config
    _G.checkmate_user_opts_bak = vim.g.checkmate_user_opts

    -- Reset globals
    vim.g.loaded_checkmate = nil
    vim.g.checkmate_config = nil
    vim.g.checkmate_user_opts = nil
  end)

  after_each(function()
    local ok, checkmate = pcall(require, "checkmate")
    if ok and checkmate.is_running() then
      checkmate.stop()
    end

    -- Restore globals
    vim.g.loaded_checkmate = _G.loaded_checkmate_bak
    vim.g.checkmate_config = _G.checkmate_config_bak
    vim.g.checkmate_user_opts = _G.checkmate_user_opts_bak
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
        ---@diagnostic disable-next-line: missing-fields
        todo_markers = {
          -- unchecked = "□", -- this is the default
          checked = "✅",
        },
        default_list_marker = "+",
        enter_insert_after_new = false,
      })

      -- Check that options were updated
      assert.equal("✅", config.options.todo_markers.checked)
      assert.equal("+", config.options.default_list_marker)
      assert.is_false(config.options.enter_insert_after_new)

      -- untouched keys inside the same table must survive
      assert.equal("□", config.options.todo_markers.unchecked)

      -- shouldn't touch unrelated options
      assert.is_true(config.options.enabled)
    end)

    describe("style merging", function()
      local config = require("checkmate.config")
      local theme
      before_each(function()
        theme = require("checkmate.theme")
        stub(theme, "generate_style_defaults", function()
          return {
            unchecked_marker = { fg = "#111111", bold = true },
            checked_marker = { fg = "#222222", bold = true },
            list_marker_unordered = { fg = "#333333" },
          }
        end)
      end)
      after_each(function()
        theme.generate_style_defaults:revert()
      end)

      it("fills in missing nested keys but keeps user-supplied values", function()
        ---@diagnostic disable-next-line: missing-fields
        config.setup({
          style = {
            unchecked_marker = { fg = "#ff0000" }, -- user overrides fg only
          },
        })

        local st = config.options.style

        if not st or not st.unchecked_marker then
          error()
        end

        -- user wins on explicit key
        assert.equal("#ff0000", st.unchecked_marker.fg)

        -- default sub-key is retained
        assert.is_true(st.unchecked_marker.bold)

        -- untouched style tables are copied wholesale from defaults
        assert.same({ fg = "#222222", bold = true }, st.checked_marker)
        assert.same({ fg = "#333333" }, st.list_marker_unordered)

        assert.stub(theme.generate_style_defaults).was.called(1)
      end)

      it("never overwrites an explicit user value on back-fill", function()
        ---@diagnostic disable-next-line: missing-fields
        config.setup({
          style = {
            unchecked_marker = { fg = "#00ff00", bold = false }, -- user sets both
          },
        })

        local st = config.options.style

        if not st or not st.unchecked_marker then
          error()
        end

        assert.equal("#00ff00", st.unchecked_marker.fg)
        assert.is_false(st.unchecked_marker.bold)

        -- Again, ensure we only called the style factory once
        assert.stub(theme.generate_style_defaults).was.called(1)
      end)
    end)

    it("should pass validation with opts = {}", function()
      local config = require("checkmate.config")
      local opts = {} ---@cast opts checkmate.Config
      local valid, err = config.validate_options(opts)
      assert.equal(true, valid, err)
    end)

    it("should not start if validation fails", function()
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      require("checkmate").setup({ enabled = "cant be string" })
      vim.wait(20)
      assert.is_not_true(require("checkmate").is_running())
    end)

    pending("should successfully validate default options", function() end)
  end)

  describe("file pattern matching", function()
    it("should correctly determine if a buffer should activate Checkmate", function()
      local should_activate = require("checkmate").should_activate_for_buffer

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
