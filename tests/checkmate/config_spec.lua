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
    -- Restore globals
    vim.g.loaded_checkmate = _G.loaded_checkmate_bak
    vim.g.checkmate_config = _G.checkmate_config_bak
    vim.g.checkmate_user_opts = _G.checkmate_user_opts_bak
  end)

  describe("initializaiton", function()
    it("should load with default options", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      local config = require("checkmate.config")

      assert.is_true(config.options.enabled)
      assert.is_true(config.options.notify)
      assert.equal("□", config.options.todo_markers.unchecked)
      assert.equal("✔", config.options.todo_markers.checked)
      assert.equal("-", config.options.default_list_marker)
      assert.equal(1, config.options.todo_action_depth)
      assert.is_true(config.options.enter_insert_after_new)

      checkmate.stop()
    end)
  end)

  describe("setup function", function()
    it("should overwrite defaults with user options", function()
      local checkmate = require("checkmate")

      local config = require("checkmate.config")

      -- Default checks
      assert.equal("□", h.get_unchecked_marker())
      assert.equal("✔", h.get_checked_marker())

      ---@diagnostic disable-next-line: missing-fields
      checkmate.setup({
        ---@diagnostic disable-next-line: missing-fields
        todo_markers = {
          -- unchecked = "□", -- this is the default
          checked = "✅",
        },
        default_list_marker = "+",
        enter_insert_after_new = false,
      })

      assert.equal("✅", config.options.todo_markers.checked)
      assert.equal("+", config.options.default_list_marker)
      assert.is_false(config.options.enter_insert_after_new)

      -- untouched keys inside the same table must survive
      assert.equal("□", h.get_unchecked_marker())

      -- shouldn't touch unrelated options
      assert.is_true(config.options.enabled)

      checkmate.stop()
    end)

    describe("style merging", function()
      local theme
      local orig_theme

      before_each(function()
        theme = require("checkmate.theme")
        orig_theme = theme.generate_style_defaults()
        stub(theme, "generate_style_defaults", function()
          return vim.tbl_deep_extend("keep", {
            unchecked_marker = { fg = "#111111", bold = true },
            checked_marker = { fg = "#222222", bold = true },
            list_marker_unordered = { fg = "#333333" },
          }, orig_theme)
        end)
      end)
      after_each(function()
        theme.generate_style_defaults:revert()
      end)

      it("fills in missing style but keeps user-supplied values", function()
        local checkmate = require("checkmate")
        local config = require("checkmate.config")

        ---@diagnostic disable-next-line: missing-fields
        checkmate.setup({
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

        -- otherwise use theme defaults
        assert.same(orig_theme.checked_main_content, st.checked_main_content)

        assert.stub(theme.generate_style_defaults).was.called(1)

        checkmate.stop()
      end)

      it("never overwrites an explicit user value on style back-fill", function()
        local checkmate = require("checkmate")
        local config = require("checkmate.config")

        ---@diagnostic disable-next-line: missing-fields
        checkmate.setup({
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

        checkmate.stop()
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

    it("should successfully validate default options", function()
      local config = require("checkmate.config")
      assert.is_true(config.validate_options(config.get_defaults()))
    end)

    it("should allow user to redefine a default metadata entry while keeping other defaults", function()
      local checkmate = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields
      checkmate.setup({
        metadata = {
          ---@diagnostic disable-next-line: missing-fields
          done = {
            key = "test",
          },
        },
      })

      local config = require("checkmate.config")

      assert.equal(vim.tbl_count(config.options.metadata.done), 1)
      assert.equal(config.options.metadata.done.key, "test")

      assert.same(config.options.metadata.started, config.get_defaults().metadata.started)

      checkmate.stop()
    end)
  end)
end)
