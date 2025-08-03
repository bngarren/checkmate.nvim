describe("List continuation", function()
  ---@module "tests.checkmate.helpers"
  local h
  ---@module "checkmate"
  local cm
  ---@module "checkmate.list_continuation"
  local lc

  lazy_setup(function()
    -- suppress any echoes
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    cm = require("checkmate")
    cm.setup(h.DEFAULT_TEST_CONFIG)

    lc = require("checkmate.list_continuation")
    lc._disable_async = true
  end)

  after_each(function()
    cm.stop()
    lc._disable_async = false
  end)

  local function setup_mocks(content, opts)
    opts = opts or {}

    local s_get_cursor = stub(vim.api, "nvim_win_get_cursor", function()
      return opts.cursor_pos or { 1, 0 }
    end)

    local s_get_lines = stub(vim.api, "nvim_get_current_line", function()
      return content or ""
    end)

    return {
      get_cursor = s_get_cursor,
      get_lines = s_get_lines,
      revert = function()
        s_get_cursor:revert()
        s_get_lines:revert()
      end,
    }
  end

  describe("expr_newline()", function()
    describe("with eol_only = true (default)", function()
      it("should fall back to <CR> when not at end of line", function()
        local content = "- [ ] Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, 3 } })
        local result = lc.expr_newline()
        assert.equal(lc._get_termcode("cr"), result)
        finally(function()
          mocks.revert()
        end)
      end)

      it("should create sibling todo when cursor at end of line (markdown)", function()
        local content = "- [ ] Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline()
        assert.equal(lc._build_expr("- [ ] ", { is_eol = true }), result)
        finally(function()
          mocks.revert()
        end)
      end)

      it("should create nested todo when cursor at end of line (markdown)", function()
        local content = "- [ ] Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline({ nested = true })
        assert.equal(lc._build_expr("  - [ ] ", { is_eol = true }), result) -- indented 2 spaces
        finally(function()
          mocks.revert()
        end)
      end)

      it("should create sibling todo when cursor at end of line (unicode)", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()
        local content = "- " .. checked .. " Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline()
        assert.equal(lc._build_expr("- " .. unchecked .. " ", { is_eol = true }), result)
        finally(function()
          mocks.revert()
        end)
      end)

      it("should create nested todo when cursor at end of line (unicode)", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()
        local content = "- " .. checked .. " Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline({ nested = true })
        assert.equal(lc._build_expr("  - " .. unchecked .. " ", { is_eol = true }), result) -- indented 2 spaces
        finally(function()
          mocks.revert()
        end)
      end)

      it("should respect indentation of parent", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()
        local content = "  - " .. checked .. " Test" -- indented 2 spaces
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline({ nested = true })
        assert.equal(lc._build_expr("    - " .. unchecked .. " ", { is_eol = true }), result) -- indented 4 spaces
        finally(function()
          mocks.revert()
        end)
      end)

      it("should inherit state when enabled", function()
        local config = require("checkmate.config")
        config.options.list_continuation.inherit_state = true

        local checked = h.get_checked_marker()
        local content = "- " .. checked .. " Test"
        local mocks = setup_mocks(content, { cursor_pos = { 1, #content } })
        local result = lc.expr_newline()
        assert.equal(lc._build_expr("- " .. checked .. " ", { is_eol = true }), result) -- checked is inherited from parent
        finally(function()
          mocks.revert()
        end)
      end)
    end)

    describe("with eol_only = false", function()
      it("should split line and carry text to next todo", function()
        local content = "- [ ] foo bar baz"
        local mocks = setup_mocks(content, { cursor_pos = { 1, 9 } }) -- cursor at "bar"
        local result = lc.expr_newline({ eol_only = false })
        assert.equal(lc._build_expr("- [ ] bar baz", { is_eol = false }), result)
        finally(function()
          mocks.revert()
        end)
      end)
    end)
  end)
end)
