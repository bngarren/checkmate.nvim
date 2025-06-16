local h = require("tests.checkmate.helpers")
local checkmate = require("checkmate")

describe("Picker", function()
  lazy_setup(function()
    -- suppress echo
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()
    h.ensure_normal_mode()
    checkmate.setup()
  end)

  after_each(function()
    checkmate.stop()
  end)

  it("should fall back to vim.ui.select when ui.picker is false", function()
    local config = require("checkmate.config")
    local picker = require("checkmate.picker")

    config.options.ui = { picker = false }
    local items = { "x", "y" }
    local select_stub = stub(vim.ui, "select")

    picker.select(items, {})

    assert.stub(select_stub).was.called(1)
    ---@diagnostic disable-next-line: undefined-field
    vim.ui.select:revert()
  end)

  it("should use a ui.picker function as the backend", function()
    local config = require("checkmate.config")
    local picker = require("checkmate.picker")

    local picker_called = false
    local received_items
    local received_on_choice

    local custom_picker = function(items, opts)
      picker_called = true
      received_items = items
      received_on_choice = opts.on_choice
    end

    config.options.ui = { picker = custom_picker }
    local items = { "x", "y" }

    picker.select(items, { on_choice = function() end })

    assert.is_true(picker_called)
    assert.are_equal(items, received_items)
    assert.is_function(received_on_choice)
  end)
end)
