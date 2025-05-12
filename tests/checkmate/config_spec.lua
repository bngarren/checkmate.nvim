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
end)
