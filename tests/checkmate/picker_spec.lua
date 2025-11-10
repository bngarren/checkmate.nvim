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

  it("should deep merge picker_opts.opts with picker_opts[backend]", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "snacks",
      },
    })
    h.setup_test_buffer({})

    local backend = require("checkmate.picker.backends.snacks")
    local received_ctx

    local orig_pick = backend.pick
    backend.pick = function(ctx)
      received_ctx = ctx
      ctx.on_select_item(ctx.items[1])
    end

    picker.pick({ "item" }, {
      picker_opts = {
        opts = {
          title = "Pick One",
          layout = "sidebar",
        },
        snacks = {
          layout = "ivy",
          previewer = true,
        },
      },
    })

    assert.is_table(received_ctx.backend_opts)
    -- backend-specific opts should override picker.opts
    assert.equal("ivy", received_ctx.backend_opts.layout)
    assert.equal(true, received_ctx.backend_opts.previewer)
    assert.equal("Pick One", received_ctx.backend_opts.title)

    backend.pick = orig_pick
  end)

  it("should use native vim.ui.select when ui.picker is 'native'", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "native",
      },
    })
    h.setup_test_buffer({})

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
    h.setup_test_buffer({})

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
      local bufnr = h.setup_test_buffer({})

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

  it("should use specific backend when available and config.ui.picker is nil", function()
    -- mock snacks and backend/snacks
    package.loaded["snacks"] = { picker = {} }
    package.loaded["checkmate.picker.backends.snacks"] = {
      pick = function(ctx)
        ctx.on_select_item(ctx.items[1])
      end,
    }

    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = nil, -- nil means auto-detect
      },
    })
    h.setup_test_buffer({})

    local spy_ui_select = spy.on(vim.ui, "select")

    local selected
    picker.pick({ "a", "b" }, {
      on_select = function(v)
        selected = v
      end,
    })

    -- should NOT use native vim.ui.select
    assert.spy(spy_ui_select).called(0)
    assert.equal("a", selected)

    finally(function()
      spy_ui_select:revert()
      package.loaded["snacks"] = nil
      package.loaded["checkmate.picker.backends.snacks"] = nil
    end)
  end)

  it("should fallback to native when configured backend is not available", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "snacks",
      },
    })

    local orig_snacks = package.loaded["snacks"]
    package.loaded["snacks"] = nil

    h.setup_test_buffer({})

    local select_called = false
    local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
      select_called = true
      on_choice(items[1])
    end)

    local selected
    picker.pick({ "fallback" }, {
      on_select = function(v)
        selected = v
      end,
    })

    assert.is_true(select_called)
    assert.equal("fallback", selected)

    finally(function()
      ui_select_stub:revert()
      package.loaded["snacks"] = orig_snacks
    end)
  end)

  it("should use picker_fn override instead of backend", function()
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

  it("should allow picker_opts.picker to override config.ui.picker", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        -- should use native despite config saying snacks
        picker = "snacks",
      },
    })
    h.setup_test_buffer({})

    local select_received_items
    local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
      select_received_items = items
      on_choice(items[1])
    end)

    local got
    picker.pick({ "x", "y" }, {
      picker_opts = {
        picker = "native", -- override to native
      },
      on_select = function(v)
        got = v
      end,
    })

    assert.is_table(select_received_items)
    assert.equal(2, #select_received_items)
    assert.equal("x", got)

    finally(function()
      ui_select_stub:revert()
    end)
  end)

  it("should handle empty items array gracefully", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "native",
      },
    })
    h.setup_test_buffer({})

    local select_called = false
    local ui_select_stub = stub(vim.ui, "select", function(_, _, on_choice)
      select_called = true
      on_choice(nil)
    end)

    local on_select_called = false
    -- empty items
    picker.pick({}, {
      on_select = function()
        on_select_called = true
      end,
    })

    assert.is_true(select_called)
    -- on_select should not be called
    assert.is_false(on_select_called)

    finally(function()
      ui_select_stub:revert()
    end)
  end)

  it("should handle items with nil values gracefully", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "native",
      },
    })
    h.setup_test_buffer({})

    local received_items
    package.loaded["checkmate.picker.backends.native"] = {
      pick = function(ctx)
        received_items = ctx.items
        ctx.on_select_item(ctx.items[1])
      end,
    }

    -- item with nil value should be normalized to {text, value=text}
    picker.pick({ { text = "display" } })

    assert.is_table(received_items)
    assert.equal(1, #received_items)
    assert.same({ text = "display", value = "display" }, received_items[1])

    finally(function()
      package.loaded["checkmate.picker.backends.native"] = nil
    end)
  end)

  it("should handle on_select callback errors gracefully", function()
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "native",
      },
    })
    h.setup_test_buffer({})

    local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
      on_choice(items[1])
    end)

    -- dont throw when on_select errors
    local did_complete = false
    local ok = pcall(function()
      picker.pick({ "item" }, {
        on_select = function()
          error("BOOM")
        end,
      })
      did_complete = true
    end)

    assert.is_true(ok)
    assert.is_true(did_complete)

    finally(function()
      ui_select_stub:revert()
    end)
  end)

  it("should handle backend pick errors gracefully", function()
    -- mock snacks and backend/snacks
    package.loaded["snacks"] = { picker = {} }
    package.loaded["checkmate.picker.backends.snacks"] = {
      pick = function(_)
        error("BOOM")
      end,
    }

    local ran_native = false
    local ui_select_stub = stub(vim.ui, "select", function(items, _, on_choice)
      ran_native = true
      on_choice(items[1])
    end)

    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = "snacks",
      },
    })
    h.setup_test_buffer({})

    local ok = pcall(function()
      picker.pick({ "item" })
    end)

    assert.is_true(ok)
    assert.is_true(ran_native)

    finally(function()
      ui_select_stub:revert()
      package.loaded["snacks"] = nil
      package.loaded["checkmate.picker.backends.snacks"] = nil
    end)
  end)
end)
