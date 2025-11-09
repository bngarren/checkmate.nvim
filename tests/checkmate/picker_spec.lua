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

  it("should use native vim.ui.select when ui.picker is 'native'", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "native",
      },
    })
    h.setup_test_buffer("- [ ] Todo")

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

  it("should use native vim.ui.select when ui.picker is nil (and no other picker plugins installed)", function()
    assert.is_false(pcall(require, "telescope"))
    assert.is_false(pcall(require, "snacks"))
    assert.is_false(pcall(require, "mini"))

    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = nil,
      },
    })
    h.setup_test_buffer("- [ ] Todo")

    local select_received_items

    local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
      select_received_items = items
      on_choice(items[1])
    end)

    picker.pick({ "a", "b", "c" })

    assert.is_table(select_received_items)
    assert.equal(3, #select_received_items)

    finally(function()
      ui_select_stub:revert()
    end)
  end)

  it("should use correct backend when ui.picker is 'telescope', 'snacks', or 'mini'", function()
    local backends = { "telescope", "snacks", "mini" }
    for _, backend_name in ipairs(backends) do
      ---@diagnostic disable-next-line: missing-fields
      h.cm_setup({
        ui = {
          picker = backend_name,
        },
      })
      local bufnr = h.setup_test_buffer("- [ ] Todo")

      -- should not be called
      local spy_ui_select = spy.on(vim.ui, "select")

      local backend = require("checkmate.picker.backends." .. backend_name)

      local called_ctx ---@type checkmate.picker.AdapterContext
      local orig_backend_pick = backend.pick

      backend.pick = function(ctx)
        called_ctx = ctx

        assert.is_table(ctx.items)
        assert.equal(3, #ctx.items)

        assert.same("a", ctx.items[1].text)
        assert.same("a", ctx.items[1].value)
        assert.same("b", ctx.items[2].text)
        assert.same("b", ctx.items[2].value)
        assert.same("c", ctx.items[3].text)
        assert.same("c", ctx.items[3].value)

        assert.is_function(ctx.on_select_item)

        ctx.on_select_item(ctx.items[1])
      end

      local selected_value
      local selected_item
      picker.pick({ "a", "b", "c" }, {
        on_select = function(v, i)
          selected_value = v
          selected_item = i
        end,
        picker_opts = {
          [backend_name] = { title = "Picker" },
        },
      })

      assert.spy(spy_ui_select).called(0)
      -- on_select should receive the value from normalized item
      assert.equal("a", selected_value)
      -- on_select should receive the checkmate.picker.Item as 2nd arg
      assert.same({ text = "a", value = "a" }, selected_item)
      -- assert some backend_opts were received
      assert.is_table(called_ctx.backend_opts)
      assert.equal("Picker", called_ctx.backend_opts.title)

      h.cleanup_test(bufnr)
      spy_ui_select:revert()
      backend.pick = orig_backend_pick
    end
  end)

  it("uses picker_fn override instead of backend", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({ ui = { picker = "telescope" } })

    local backend = require("checkmate.picker.backends.snacks")

    local spy_backend_pick = spy.on(backend, "pick")

    local seen_items
    local selected
    picker.pick({ "a", "b" }, {
      picker_fn = function(items, _, done)
        seen_items = items
        done(items[2])
      end,
      on_select = function(v)
        selected = v
      end,
    })

    assert.spy(spy_backend_pick).called(0)
    assert.is_table(seen_items)
    assert.equal(2, #seen_items)
    assert.equal("b", selected)

    finally(function()
      spy_backend_pick:revert()
    end)
  end)

  -- Test that picker_opts.picker overrides config.ui.picker
  -- Test that config.ui.picker works when picker_opts.picker is nil
  -- Test auto-detection fallback
  -- Test that invalid config types are caught
  -- Test that each backend receives correct options
  -- Test empty items array
  -- Test items with nil/missing text fields
  -- Test on_select callback failures
  -- Test backend not available (plugin not installed)
end)
