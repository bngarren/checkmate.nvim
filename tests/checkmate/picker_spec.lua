describe("Picker", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.picker"
  local picker

  local function setup_picker_buffer(ui_picker)
    ---@diagnostic disable-next-line: missing-fields
    h.cm_setup({
      ui = {
        picker = ui_picker,
      },
    })
    return h.setup_test_buffer({})
  end

  local function run_named_case(name, fn)
    local ok, err = pcall(fn)
    if not ok then
      error(("%s: %s"):format(tostring(name), tostring(err)), 0)
    end
  end

  local function with_picker_buffer(ui_picker, fn)
    local bufnr = setup_picker_buffer(ui_picker)
    local ok, err = pcall(fn, bufnr)
    h.cleanup_test(bufnr)
    if not ok then
      error(err)
    end
  end

  local function with_checkmate_buffer(content, fn)
    local bufnr, cm = h.setup_checkmate_test_buffer(content)
    local ok, err = pcall(fn, bufnr, cm)
    h.cleanup_test(bufnr)
    if not ok then
      error(err)
    end
  end

  local function with_native_select(handler, fn)
    local ui_select_stub = stub(vim.ui, "select", function(items, opts, on_choice)
      handler(items, opts, on_choice)
    end)

    local ok, err = pcall(fn)
    ui_select_stub:revert()
    if not ok then
      error(err)
    end
  end

  local function with_loaded_module(name, value, fn)
    local original = package.loaded[name]
    package.loaded[name] = value

    local ok, err = pcall(fn)
    package.loaded[name] = original
    if not ok then
      error(err)
    end
  end

  local function with_preload(name, value, fn)
    local original = package.preload[name]
    package.preload[name] = value

    local ok, err = pcall(fn)
    package.preload[name] = original
    if not ok then
      error(err)
    end
  end

  local function with_metadata_value_at_cursor(fn)
    local unchecked = h.get_unchecked_marker()

    with_checkmate_buffer({ "- " .. unchecked .. " Task @priority(low)" }, function(bufnr, cm)
      local line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
      local col = h.exists(line:find("@priority")) - 1
      vim.api.nvim_win_set_cursor(0, { 1, col })

      fn(bufnr, cm, unchecked)
    end)
  end

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

  describe("backend resolution and options", function()
    it("deep merges picker_opts.opts with picker_opts[backend]", function()
      with_picker_buffer("snacks", function()
        local backend = require("checkmate.picker.backends.snacks")
        local original_pick = backend.pick
        local received_ctx

        backend.pick = function(ctx)
          received_ctx = ctx
          ctx.on_select_item(ctx.items[1])
        end

        finally(function()
          backend.pick = original_pick
        end)

        local launched = picker.pick({ "item" }, {
          picker_opts = {
            opts = {
              title = "Pick One",
              layout = "sidebar",
              win = {
                border = "rounded",
                height = 20,
              },
            },
            snacks = {
              layout = "ivy",
              previewer = true,
              win = {
                height = 10,
              },
            },
          },
        })

        assert.is_true(launched)
        assert.is_table(received_ctx.backend_opts)
        assert.equal("ivy", received_ctx.backend_opts.layout)
        assert.equal(true, received_ctx.backend_opts.previewer)
        assert.equal("Pick One", received_ctx.backend_opts.title)
        assert.equal("rounded", received_ctx.backend_opts.win.border)
        assert.equal(10, received_ctx.backend_opts.win.height)
      end)
    end)

    it("routes through native for configured, auto-detected, and per-call override paths", function()
      local cases = {
        {
          name = "configured native",
          config_picker = "native",
          items = { "a", "b", "c" },
          expected_len = 3,
          expected_value = "a",
        },
        {
          name = "auto-detected native",
          config_picker = nil,
          items = { "a", "b", "c" },
          expected_len = 3,
          expected_value = "a",
          assert_no_plugins = true,
        },
        {
          name = "picker_opts override",
          config_picker = "snacks",
          items = { "x", "y" },
          opts = {
            picker_opts = {
              picker = "native",
            },
          },
          expected_len = 2,
          expected_value = "x",
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          if tc.assert_no_plugins then
            assert.is_false(pcall(require, "telescope"))
            assert.is_false(pcall(require, "snacks"))
            assert.is_false(pcall(require, "mini"))
          end

          with_picker_buffer(tc.config_picker, function()
            local received_items
            local selected
            local launched

            with_native_select(function(items, _, on_choice)
              received_items = items
              on_choice(items[1], 1)
            end, function()
              local opts = vim.tbl_deep_extend("force", {}, tc.opts or {})
              opts.on_select = function(value)
                selected = value
              end

              launched = picker.pick(tc.items, opts)
            end)

            assert.is_true(launched)
            assert.is_table(received_items)
            assert.equal(tc.expected_len, #received_items)
            vim.wait(100, function()
              return selected ~= nil
            end)
            assert.equal(tc.expected_value, selected)
          end)
        end)
      end
    end)

    it("dispatches normalized items and backend opts to configured plugin adapters", function()
      for _, backend_name in ipairs({ "telescope", "snacks", "mini" }) do
        run_named_case(backend_name, function()
          with_picker_buffer(backend_name, function()
            local spy_ui_select = spy.on(vim.ui, "select")
            local backend = require("checkmate.picker.backends." .. backend_name)
            local original_pick = backend.pick
            local called_ctx

            backend.pick = function(ctx)
              called_ctx = ctx
              ctx.on_select_item(ctx.items[1])
            end

            local ok, err = pcall(function()
              local selected_value
              local selected_item

              local launched = picker.pick({ "a", "b", "c" }, {
                on_select = function(value, item)
                  selected_value = value
                  selected_item = item
                end,
                picker_opts = {
                  [backend_name] = { title = "Picker" },
                },
              })

              assert.spy(spy_ui_select).called(0)
              assert.is_true(launched)
              assert.is_table(called_ctx.items)
              assert.same({
                { text = "a", value = "a" },
                { text = "b", value = "b" },
                { text = "c", value = "c" },
              }, called_ctx.items)
              assert.is_function(called_ctx.on_select_item)
              assert.equal("a", selected_value)
              assert.same({ text = "a", value = "a" }, selected_item)
              assert.equal("Picker", called_ctx.backend_opts.title)
            end)

            backend.pick = original_pick
            spy_ui_select:revert()
            if not ok then
              error(err)
            end
          end)
        end)
      end
    end)

    it("auto-detects an available picker backend before falling back to native", function()
      with_loaded_module("snacks", { picker = {} }, function()
        with_loaded_module("checkmate.picker.backends.snacks", {
          pick = function(ctx)
            ctx.on_select_item(ctx.items[1])
          end,
        }, function()
          with_picker_buffer(nil, function()
            local spy_ui_select = spy.on(vim.ui, "select")
            local selected

            finally(function()
              spy_ui_select:revert()
            end)

            local launched = picker.pick({ "a", "b" }, {
              on_select = function(value)
                selected = value
              end,
            })

            assert.spy(spy_ui_select).called(0)
            assert.is_true(launched)
            assert.equal("a", selected)
          end)
        end)
      end)
    end)

    it("falls back to native when configured backends are unavailable or fail", function()
      local function assert_native_fallback(setup_mock)
        setup_mock(function()
          with_picker_buffer("snacks", function()
            local ran_native = false
            local selected
            local launched

            with_native_select(function(items, _, on_choice)
              ran_native = true
              on_choice(items[1], 1)
            end, function()
              local ok
              ok, launched = pcall(function()
                return picker.pick({ "fallback" }, {
                  on_select = function(value)
                    selected = value
                  end,
                })
              end)

              assert.is_true(ok)
            end)

            assert.is_true(launched)
            assert.is_true(ran_native)
            vim.wait(100, function()
              return selected ~= nil
            end)
            assert.equal("fallback", selected)
          end)
        end)
      end

      assert_native_fallback(function(run)
        with_loaded_module("snacks", nil, run)
      end)

      assert_native_fallback(function(run)
        with_loaded_module("snacks", { picker = {} }, function()
          with_loaded_module("checkmate.picker.backends.snacks", {
            pick = function()
              error("BOOM")
            end,
          }, run)
        end)
      end)

      assert_native_fallback(function(run)
        local backend_name = "checkmate.picker.backends.snacks"
        with_loaded_module(backend_name, nil, function()
          with_preload(backend_name, function()
            error("adapter load failed")
          end, run)
        end)
      end)
    end)
  end)

  describe("picker_fn and completion contracts", function()
    it("uses picker_fn instead of backend adapters", function()
      ---@diagnostic disable-next-line: missing-fields
      h.cm_setup({ ui = { picker = "snacks" } })

      local backend = require("checkmate.picker.backends.snacks")
      local spy_backend_pick = spy.on(backend, "pick")
      local seen_items
      local selected

      finally(function()
        spy_backend_pick:revert()
      end)

      local launched = picker.pick({ "a", "b" }, {
        picker_fn = function(items, _, complete)
          seen_items = items
          complete(items[2])
        end,
        on_select = function(value)
          selected = value
        end,
      })

      assert.spy(spy_backend_pick).called(0)
      assert.is_true(launched)
      assert.same({
        { text = "a", value = "a" },
        { text = "b", value = "b" },
      }, seen_items)
      vim.wait(100, function()
        return selected ~= nil
      end)
      assert.equal("b", selected)
    end)

    it("enforces picker_fn launch, cancellation, one-shot, and invalid completion behavior", function()
      local cases = {
        {
          name = "nil cancels and wins",
          picker_fn = function(items, _, complete)
            complete(nil)
            complete(items[1])
          end,
          launched = true,
          selections = {},
        },
        {
          name = "first item completion wins",
          picker_fn = function(items, _, complete)
            complete(items[1])
            complete(items[2])
          end,
          launched = true,
          selections = { "a" },
        },
        {
          name = "invalid completion is ignored",
          picker_fn = function(_, _, complete)
            complete("a")
          end,
          launched = true,
          selections = {},
        },
        {
          name = "picker_fn error returns false",
          picker_fn = function()
            error("BOOM")
          end,
          launched = false,
          selections = {},
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          with_picker_buffer("native", function()
            local selections = {}
            local launched
            local ok = pcall(function()
              launched = picker.pick({ "a", "b" }, {
                picker_fn = tc.picker_fn,
                on_select = function(value)
                  selections[#selections + 1] = value
                end,
              })
            end)

            assert.is_true(ok)
            assert.equal(tc.launched, launched)
            if #tc.selections > 0 then
              vim.wait(100, function()
                return #selections == #tc.selections
              end)
            end
            assert.same(tc.selections, selections)
          end)
        end)
      end
    end)

    it("keeps completion helpers one-shot, scheduled by default, and error-safe", function()
      local picker_util = require("checkmate.picker.util")
      local selected
      local scheduled
      local item = { text = "a", value = { id = 1 } }
      local entry = { __cm_item = item }
      local events = {}

      picker_util.make_item_completion({
        items = { item },
        backend_opts = {},
        format_item_text = function(value)
          return value.text
        end,
        on_select_item = function(value)
          events[#events + 1] = { "select", value }
        end,
      }, {
        schedule = false,
        after_item_select = function(value, selected_entry)
          events[#events + 1] = { "after", value, selected_entry }
        end,
      })(entry)

      assert.same({
        { "select", item },
        { "after", item, entry },
      }, events)

      local complete = picker_util.make_value_completion(function(value)
        selected = value
      end, {
        schedule = false,
        source = "[test]",
      })

      complete(nil)
      complete("later")
      assert.is_nil(selected)

      picker_util.make_value_completion(function(value)
        scheduled = value
      end, {
        source = "[test]",
      })("queued")

      assert.is_nil(scheduled)
      vim.wait(100, function()
        return scheduled == "queued"
      end)
      assert.equal("queued", scheduled)

      local ok = pcall(function()
        picker_util.make_value_completion(function()
          error("BOOM")
        end, {
          schedule = false,
          source = "[test]",
        })("value")
      end)

      assert.is_true(ok)
    end)
  end)

  describe("item normalization and callback safety", function()
    it("preserves structured, false, fallback, and formatted item values", function()
      local native_backend = "checkmate.picker.backends.native"

      local cases = {
        {
          name = "structured value",
          input = {
            {
              text = "Heading: Inbox",
              value = {
                kind = "heading",
                destination = {
                  heading = { title = "Inbox", level = 2 },
                },
              },
            },
          },
          expected_item = {
            text = "Heading: Inbox",
            value = {
              kind = "heading",
              destination = {
                heading = { title = "Inbox", level = 2 },
              },
            },
          },
          expected_value = {
            kind = "heading",
            destination = {
              heading = { title = "Inbox", level = 2 },
            },
          },
        },
        {
          name = "false value",
          input = {
            { text = "No", value = false },
          },
          expected_item = { text = "No", value = false },
          expected_value = false,
        },
        {
          name = "missing value falls back to text",
          input = {
            { text = "display" },
          },
          expected_item = { text = "display", value = "display" },
          expected_value = "display",
        },
        {
          name = "format_item_text updates text only",
          input = { "raw" },
          opts = {
            format_item_text = function(item)
              return item.text .. "!"
            end,
          },
          expected_item = { text = "raw!", value = "raw" },
          expected_value = "raw",
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          local received_items

          with_loaded_module(native_backend, {
            pick = function(ctx)
              received_items = ctx.items
              ctx.on_select_item(ctx.items[1])
            end,
          }, function()
            with_picker_buffer("native", function()
              local selected
              local called = false
              local opts = vim.tbl_deep_extend("force", {}, tc.opts or {})
              opts.on_select = function(value)
                selected = value
                called = true
              end

              local launched = picker.pick(tc.input, opts)

              assert.is_true(launched)
              assert.is_true(called)
              assert.same({ tc.expected_item }, received_items)
              assert.same(tc.expected_value, selected)
            end)
          end)
        end)
      end
    end)

    it("returns false for empty lists and contains on_select errors", function()
      with_picker_buffer("native", function()
        local select_called = false
        local on_select_called = false

        with_native_select(function()
          select_called = true
        end, function()
          local launched = picker.pick({}, {
            on_select = function()
              on_select_called = true
            end,
          })

          assert.is_false(launched)
          assert.is_false(select_called)
          assert.is_false(on_select_called)
        end)

        with_native_select(function(items, _, on_choice)
          on_choice(items[1], 1)
        end, function()
          local launched
          local ok = pcall(function()
            launched = picker.pick({ "item" }, {
              on_select = function()
                error("BOOM")
              end,
            })
          end)

          assert.is_true(ok)
          assert.is_true(launched)
        end)
      end)
    end)
  end)

  describe("validation", function()
    it("rejects invalid picker options before backend dispatch", function()
      local cases = {
        {
          name = "non-table picker_opts",
          opts = {
            ---@diagnostic disable-next-line: assign-type-mismatch
            picker_opts = "native",
          },
        },
        {
          name = "non-callable picker_fn",
          opts = {
            ---@diagnostic disable-next-line: assign-type-mismatch
            picker_fn = "not callable",
          },
        },
        {
          name = "non-string method",
          opts = {
            ---@diagnostic disable-next-line: assign-type-mismatch
            method = {},
          },
        },
        {
          name = "unknown method",
          opts = {
            ---@diagnostic disable-next-line: assign-type-mismatch
            method = "missing_method",
          },
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          with_picker_buffer("native", function()
            local select_called = false
            local launched
            local ok

            with_native_select(function()
              select_called = true
            end, function()
              ok, launched = pcall(function()
                return picker.pick({ "item" }, tc.opts)
              end)
            end)

            assert.is_true(ok)
            assert.is_false(launched)
            assert.is_false(select_called)
          end)
        end)
      end
    end)
  end)

  describe("todo picker integration", function()
    it("jumps to a todo through the shared todo util", function()
      local unchecked = h.get_unchecked_marker()

      with_checkmate_buffer({
        "- " .. unchecked .. " First",
        "- " .. unchecked .. " Second",
      }, function(bufnr)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        ---@diagnostic disable-next-line: missing-fields
        local ok = require("checkmate.todo.util").jump_to_todo({
          bufnr = bufnr,
          row = 1,
        })

        local cursor = vim.api.nvim_win_get_cursor(0)
        assert.is_true(ok)
        assert.equal(2, cursor[1])
      end)
    end)

    it("supports select_todo custom picker completion variants", function()
      local unchecked = h.get_unchecked_marker()
      local content = {
        "- " .. unchecked .. " First",
        "- " .. unchecked .. " Second",
      }

      local cases = {
        {
          name = "raw todo selection jumps once",
          custom_picker = function(ctx)
            return function(todos, complete)
              ctx.seen_todos = todos
              complete(todos[2])
              complete(todos[1])
            end
          end,
          expected_cursor = 2,
          assert = function(ctx)
            assert.is_table(ctx.seen_todos)
            assert.equal(2, #ctx.seen_todos)
          end,
        },
        {
          -- the was the signature in v0.12, i.e., no arg for complete fn
          name = "custom_picker(todos) compatibility",
          custom_picker = function(ctx)
            return function(todos)
              ctx.seen_count = #todos
            end
          end,
          expected_cursor = 1,
          assert = function(ctx)
            assert.equal(2, ctx.seen_count)
          end,
        },
        {
          name = "nil completion cancels and wins",
          custom_picker = function()
            return function(todos, complete)
              complete(nil)
              complete(todos[2])
            end
          end,
          expected_cursor = 1,
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          with_checkmate_buffer(content, function(_, cm)
            vim.api.nvim_win_set_cursor(0, { 1, 0 })

            local ctx = {}
            local ok = cm.select_todo({
              custom_picker = tc.custom_picker(ctx),
            })

            vim.wait(100, function()
              return vim.api.nvim_win_get_cursor(0)[1] == tc.expected_cursor
            end)

            local cursor = vim.api.nvim_win_get_cursor(0)
            assert.is_true(ok)
            assert.equal(tc.expected_cursor, cursor[1])

            if tc.assert then
              tc.assert(ctx)
            end
          end)
        end)
      end
    end)

    it("rejects non-callable select_todo custom_picker values", function()
      local unchecked = h.get_unchecked_marker()

      with_checkmate_buffer({ "- " .. unchecked .. " First" }, function(_, cm)
        local ok = cm.select_todo({
          ---@diagnostic disable-next-line: assign-type-mismatch
          custom_picker = "nope",
        })

        assert.is_false(ok)
      end)
    end)
  end)

  describe("metadata picker integration", function()
    it("handles select_metadata_value custom picker errors and cancellation", function()
      local cases = {
        {
          name = "custom picker error returns false",
          expected_ok = false,
          custom_picker = function()
            error("BOOM")
          end,
        },
        {
          name = "nil completion cancels and wins",
          expected_ok = true,
          custom_picker = function(_, complete)
            complete(nil)
            complete("high")
          end,
        },
      }

      for _, tc in ipairs(cases) do
        run_named_case(tc.name, function()
          with_metadata_value_at_cursor(function(bufnr, cm, unchecked)
            local ok = cm.select_metadata_value({
              custom_picker = tc.custom_picker,
            })

            vim.wait(50)

            local line = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
            assert.equal(tc.expected_ok, ok)
            assert.equal("- " .. unchecked .. " Task @priority(low)", line)
          end)
        end)
      end
    end)
  end)
end)
