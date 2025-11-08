describe("Picker", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.picker"
  local picker

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

    h = require("tests.checkmate.helpers")
    picker = require("checkmate.picker")

    h.ensure_normal_mode()
  end)

  describe("internal picker", function()
    it("should use native vim.ui.select when ui.picker is 'select'", function()
      ---@diagnostic disable-next-line: missing-fields
      h.cm_setup({
        ui = {
          picker = "select",
        },
      })
      local bufnr = h.setup_test_buffer("- [ ] Todo")

      local select_received_items

      local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
        select_received_items = items
        on_choice(items[1])
      end)

      local got
      picker.pick({ "a", "b", "c" }, {
        on_select = function(v)
          got = v
        end,
      })

      assert.is_table(select_received_items)
      assert.equal(3, #select_received_items)
      assert.equal("a", got)

      finally(function()
        ui_select_stub:revert()
      end)
    end)
  end)
end)
