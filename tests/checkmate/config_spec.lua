describe("Config", function()
  ---@module "tests.checkmate.helpers"
  local h

  lazy_setup(function()
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")

    -- back up globals
    _G.loaded_checkmate_bak = vim.g.loaded_checkmate
    _G.checkmate_config_bak = vim.g.checkmate_config

    -- reset globals
    vim.g.loaded_checkmate = nil
    vim.g.checkmate_config = nil

    vim.g.mapleader = " "
  end)

  after_each(function()
    -- restore globals
    vim.g.loaded_checkmate = _G.loaded_checkmate_bak
    vim.g.checkmate_config = _G.checkmate_config_bak
  end)

  describe("initializaiton", function()
    it("should load with default options", function()
      local cm = require("checkmate")
      cm.setup()

      local config = require("checkmate.config")

      assert.is_true(config.options.enabled)
      assert.is_true(config.options.notify)
      assert.equal("□", config.options.todo_states.unchecked.marker)
      assert.equal("✔", config.options.todo_states.checked.marker)
      assert.equal("-", config.options.default_list_marker)
      assert.is_true(config.options.enter_insert_after_new)

      cm.stop()
    end)

    it("should correctly setup keymaps", function()
      local cm = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        keys = {
          ["<leader>Ta"] = { -- cmd
            rhs = "<cmd>Checkmate archive<CR>",
            desc = "Archive todos",
            modes = { "n" },
          },
          ["<leader>Tc"] = { -- callback
            rhs = function()
              require("checkmate").check()
            end,
            desc = "Check todo",
            modes = { "n", "v" },
          },
          ["<leader>Tu"] = { "<cmd>lua require('checkmate').uncheck()<CR>", "UNCHECK", { "n", "v" } },
        },
      })

      local bufnr = h.setup_test_buffer("")

      -- keymaps were created
      local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")

      local found_archive = false
      local found_check = false
      local found_uncheck = false

      for _, keymap in ipairs(keymaps) do
        if keymap.lhs == " Ta" then
          found_archive = true
        elseif keymap.lhs == " Tc" then
          found_check = true
        elseif keymap.lhs == " Tu" then
          found_uncheck = true
        end
      end

      assert.is_true(found_archive)
      assert.is_true(found_check)
      assert.is_true(found_uncheck)

      local archive_stub = stub(cm, "archive")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>Ta", true, false, true), "x", false)
      assert.stub(archive_stub).called(1)

      local check_stub = stub(cm, "check")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>Tc", true, false, true), "x", false)
      assert.stub(check_stub).called(1)

      local uncheck_stub = stub(cm, "uncheck")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>Tu", true, false, true), "x", false)
      assert.stub(uncheck_stub).called(1)

      finally(function()
        h.cleanup_buffer(bufnr)

        archive_stub:revert()
        check_stub:revert()
        uncheck_stub:revert()
      end)
    end)
  end)

  describe("setup function", function()
    it("should overwrite defaults with user options", function()
      local cm = require("checkmate")

      local config = require("checkmate.config")

      -- Default markers
      assert.equal("□", h.get_unchecked_marker())
      assert.equal("✔", h.get_checked_marker())

      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        todo_states = {
          ---@diagnostic disable-next-line: missing-fields
          checked = {
            marker = "✅",
          },
        },
        default_list_marker = "+",
        enter_insert_after_new = false,
      })

      assert.equal("✅", config.options.todo_states.checked.marker)
      assert.equal("+", config.options.default_list_marker)
      assert.is_false(config.options.enter_insert_after_new)

      -- untouched keys inside the same table must survive
      assert.equal("□", h.get_unchecked_marker())

      -- shouldn't touch unrelated options
      assert.is_true(config.options.enabled)

      cm.stop()
    end)

    it("should not duplicate user configured + default `keys`", function()
      local cm = require("checkmate")

      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        -- overwrite the keys
        keys = {
          ["<leader>Ct"] = {
            rhs = "<cmd>Checkmate toggle<CR>",
            desc = "Toggle todo item",
            modes = { "n", "v" },
          },
        },
      })

      local config = require("checkmate.config")

      assert.equal(1, vim.tbl_count(config.options.keys))
      assert.is_true(vim.list_contains(vim.tbl_keys(config.options.keys), "<leader>Ct"))

      cm.stop()
    end)

    describe("style", function()
      local theme
      local orig_theme

      before_each(function()
        theme = require("checkmate.theme")
        orig_theme = theme.generate_style_defaults()
        stub(theme, "generate_style_defaults", function()
          return vim.tbl_deep_extend("keep", {
            CheckmateUncheckedMarker = { fg = "#111111", bold = true },
            CheckmateCheckedMarker = { fg = "#222222", bold = true },
            CheckmateListMarkerUnordered = { fg = "#333333" },
          }, orig_theme)
        end)
      end)

      after_each(function()
        theme.generate_style_defaults:revert()
      end)

      it("should not generate checkmate highlights if style == false", function()
        vim.cmd("hi clear")

        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
          style = false,
        })

        local bufnr = h.setup_test_buffer("- [ ] Todo")

        local hls = vim.api.nvim_get_hl(0, { create = false })

        local r = vim.iter(hls):find(function(hl_name)
          return string.match(hl_name, "Checkmate*") ~= nil
        end)

        assert.is_nil(r)

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("fills in missing style but keeps user-supplied values", function()
        local cm = require("checkmate")
        local config = require("checkmate.config")

        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
          style = {
            CheckmateUncheckedMarker = { fg = "#ff0000" }, -- user overrides fg only
          },
        })

        local st = config.options.style

        if not st or not st.CheckmateUncheckedMarker then
          error()
        end

        -- user wins on explicit key
        assert.equal("#ff0000", st.CheckmateUncheckedMarker.fg)

        -- otherwise use theme defaults
        assert.same(orig_theme.CheckmateCheckedMainContent, st.CheckmateCheckedMainContent)

        assert.stub(theme.generate_style_defaults).was.called(1)

        cm.stop()
      end)

      it("never overwrites an explicit user value on style back-fill", function()
        local cm = require("checkmate")
        local config = require("checkmate.config")

        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
          style = {
            CheckmateUncheckedMarker = { fg = "#00ff00", bold = false }, -- user sets both
          },
        })

        local st = config.options.style

        if not st or not st.CheckmateUncheckedMarker then
          error()
        end

        assert.equal("#00ff00", st.CheckmateUncheckedMarker.fg)
        assert.is_false(st.CheckmateUncheckedMarker.bold)

        -- Again, ensure we only called the style factory once
        assert.stub(theme.generate_style_defaults).was.called(1)

        cm.stop()
      end)
    end)

    describe("validate_options", function()
      it("should pass validation with opts = {}", function()
        local validate = require("checkmate.config.validate")
        local opts = {} ---@cast opts checkmate.Config
        local valid, err = validate.validate_options(opts)
        assert.equal(true, valid, err)
      end)

      it("should not start if validation fails", function()
        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
        cm.setup({ enabled = "cant be string" })
        vim.wait(20)
        assert.is_not_true(require("checkmate").is_running())
        cm.stop()
      end)

      it("should successfully validate default options", function()
        local config = require("checkmate.config")
        local validate = require("checkmate.config.validate")
        assert.is_true(validate.validate_options(config.get_defaults()))
      end)

      it("should allow user to redefine a default metadata entry while keeping other defaults", function()
        local cm = require("checkmate")
        ---@diagnostic disable-next-line: missing-fields
        cm.setup({
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

        cm.stop()
      end)

      it("should fail to validate bad opts", function()
        local config = require("checkmate.config")
        local validate = require("checkmate.config.validate")

        ---@type table<integer, checkmate.Config>
        local keys_iters = {
          ---@diagnostic disable-next-line: missing-fields
          {
            keys = {
              ["<leader>Tt"] = { 1 },
            },
          },
          ---@diagnostic disable-next-line: missing-fields
          {
            keys = {
              ["<leader>Tt"] = { desc = "test", modes = { "n" } }, -- missing rhs
            },
          },
        }

        for _, iter in ipairs(keys_iters) do
          local defaults = config.get_defaults()
          defaults.keys = nil
          local opts = vim.tbl_deep_extend("force", defaults, iter)
          local ok, _ = validate.validate_options(opts)
          assert.is_false(ok)
        end
      end)
    end)
  end)
end)
