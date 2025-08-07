--[[
Some notes on this test suite:
- Ideally we could open a Checkmate buffer and fire off the registered keymaps and then assert on the buffer,
but I can't get this to work
- So instead, we call the `expr_newline` function directly with the cursor position we want to test
- In non-testing env, `expr_newline` uses vim.schedule to modify the buffer after the keymap handling is complete
- In testing env, we use the `_test_mode` flag to run this synchronously instead, for simplicity
- We use the `run_expr_newline` helper to help with mode switching and cursor positioning
- Since `expr_newline` modifies the buffer, this will auto-convert Markdown to unicode syntax, thus all tests
need to make assertions on the unicode form, even if it starts in Markdown...This is a limitation
]]

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
    lc._test_mode = true
  end)

  after_each(function()
    cm.stop()
    lc._test_mode = false
  end)

  -- helper to run the expr_newline function that we are testing with correct cursor positioning
  -- row: 1 indexed
  -- col: 0 indexed position in INSERT mode. This puts the cursor between/before the corresponding pos in NORMAL mode
  -- E.g. to insert at the EOL, col should be #line (1 after the last char) which puts the insert mode cursor after the last char
  local function run_expr_newline(opts)
    local row = opts.row
    local col = opts.col
    vim.cmd("startinsert")
    vim.api.nvim_win_set_cursor(0, { row, col })
    local i_row, i_col = unpack(vim.api.nvim_win_get_cursor(0))
    local expr_opts = vim.tbl_extend("force", { cursor = { row = i_row - 1, col = i_col } }, opts.expr_opts or {})
    lc.expr_newline(expr_opts)
    h.ensure_normal_mode()
  end

  describe("expr_newline()", function()
    describe("with eol_only = true (default)", function()
      it("should fall back to <CR> when not at end of line", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- [ ] Test"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = 3, expr_opts = { eol_only = true } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(1, #lines)
        assert.equal("- " .. unchecked .. " Test", lines[1])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should create sibling todo when cursor at end of line (markdown)", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- [ ] Test"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = false } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " Test", lines[1])
        assert.equal("- " .. unchecked .. " ", lines[2])
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should create nested todo when cursor at end of line (markdown)", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- [ ] Test"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = true } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " Test", lines[1])
        assert.equal("  - " .. unchecked .. " ", lines[2]) -- indent 2 spaces
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should create sibling todo when cursor at end of line (unicode)", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- " .. unchecked .. " Test"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = false } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " Test", lines[1])
        assert.equal("- " .. unchecked .. " ", lines[2])
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should create nested todo when cursor at end of line (unicode)", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- " .. unchecked .. " Test"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = true } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " Test", lines[1])
        assert.equal("  - " .. unchecked .. " ", lines[2]) -- indent 2 spaces
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should respect indentation of parent", function()
        local unchecked = h.get_unchecked_marker()
        local content = "  - " .. unchecked .. " Test" -- parent indented 2 spaces
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = false } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("  - " .. unchecked .. " Test", lines[1])
        assert.equal("  - " .. unchecked .. " ", lines[2]) -- indent 2 spaces (same as parent)
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should inherit state when enabled", function()
        local checked = h.get_checked_marker()
        local content = "- " .. checked .. " Test"
        local config = require("checkmate.config")

        config.options.list_continuation.inherit_state = true

        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = false } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. checked .. " Test", lines[1])
        assert.equal("- " .. checked .. " ", lines[2])
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)

    describe("with eol_only = false", function()
      it("should split line and carry text to new sibling todo", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- " .. unchecked .. " foo bar baz"
        local bufnr = h.setup_test_buffer(content)

        -- position cursor after bar
        -- this will move " baz" to the new line
        run_expr_newline({ row = 1, col = #content - 4, expr_opts = { eol_only = false, nested = false } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " foo bar", lines[1])
        assert.equal("- " .. unchecked .. "  baz", lines[2])
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should split line and carry text to new nested todo", function()
        local unchecked = h.get_unchecked_marker()
        local content = "- " .. unchecked .. " foo bar baz"
        local bufnr = h.setup_test_buffer(content)

        -- position cursor after bar
        -- this will move " baz" to the new line
        run_expr_newline({ row = 1, col = #content - 4, expr_opts = { eol_only = false, nested = true } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("- " .. unchecked .. " foo bar", lines[1])
        assert.equal("  - " .. unchecked .. "  baz", lines[2]) -- indented 2 spaces
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)

    describe("edge cases", function()
      it("should handle different list markers", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()
        local content = [[
* [ ] Star
+ [x] Plus
1. [ ] Number dot
50) [ ] Number parenthesis]]
        local bufnr = h.setup_test_buffer(content)

        -- start at line 4
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        run_expr_newline({ row = 4, col = #lines[4], expr_opts = { eol_only = true, nested = false } })
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal("50) " .. unchecked .. " Number parenthesis", lines[4])
        assert.equal("51) " .. unchecked .. " ", lines[5])

        -- line 3
        run_expr_newline({ row = 3, col = #lines[3], expr_opts = { eol_only = true, nested = false } })
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal("1. " .. unchecked .. " Number dot", lines[3])
        assert.equal("2. " .. unchecked .. " ", lines[4])

        -- line 2
        run_expr_newline({ row = 2, col = #lines[2], expr_opts = { eol_only = true, nested = false } })
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal("+ " .. checked .. " Plus", lines[2])
        assert.equal("+ " .. unchecked .. " ", lines[3])

        -- line 1
        run_expr_newline({ row = 1, col = #lines[1], expr_opts = { eol_only = true, nested = false } })
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal("* " .. unchecked .. " Star", lines[1])
        assert.equal("* " .. unchecked .. " ", lines[2])

        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)

      it("should reset ordered numbering on nested new todo", function()
        local unchecked = h.get_unchecked_marker()
        local content = "100. " .. unchecked .. " Todo"
        local bufnr = h.setup_test_buffer(content)

        run_expr_newline({ row = 1, col = #content, expr_opts = { eol_only = true, nested = true } })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal(2, #lines)
        assert.equal("100. " .. unchecked .. " Todo", lines[1])
        -- indent the length of the preceding/parent list marker + 1 whitespace
        assert.equal("     1. " .. unchecked .. " ", lines[2]) -- reset to 1.
        finally(function()
          h.cleanup_buffer(bufnr)
        end)
      end)
    end)
  end)

  describe("cursor position validation", function()
    it("should not create todo when cursor is before checkbox", function()
      local unchecked = h.get_unchecked_marker()
      local content = "- " .. unchecked .. " Test"
      local bufnr = h.setup_test_buffer(content)

      -- cursor at position 0 (before '-')
      run_expr_newline({ row = 1, col = 0, expr_opts = { eol_only = false } })
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(1, #lines) -- no new lines
      assert.equal(content, lines[1])

      -- cursor at position 1 (on '-')
      run_expr_newline({ row = 1, col = 1, expr_opts = { eol_only = false } })
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(1, #lines) -- no new lines

      -- cursor at position 2 (after '-', before space)
      run_expr_newline({ row = 1, col = 2, expr_opts = { eol_only = false } })
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(1, #lines) -- no new lines

      -- cursor at position 3 (after '- ', before checkbox)
      run_expr_newline({ row = 1, col = 3, expr_opts = { eol_only = false } })
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equal(1, #lines) -- Should not create new line

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)
end)
