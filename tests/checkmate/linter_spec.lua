describe("Linter", function()
  local h = require("tests.checkmate.helpers")

  before_each(function()
    _G.reset_state()
  end)

  describe("linting functionality", function()
    it("should identify indentation issues", function()
      local linter = require("checkmate.linter")

      -- Setup test content with deliberate misalignment
      local content = [[
# Misaligned List
- Parent item
 - Misaligned child (indented only 1 space)
   - Grandchild (properly indented from misaligned parent)
]]

      local bufnr = h.create_test_buffer(content)

      -- Run linter
      local diagnostics = linter.lint_buffer(bufnr)

      -- Should find at one issue
      assert.equal(#diagnostics, 1)

      -- Verify it is also in vim.diagnostics
      local vim_diagnostics = vim.diagnostic.get(bufnr, { namespace = linter.ns })
      assert.equal(#vim_diagnostics, 1)

      -- Verify issue is about alignment
      local found_alignment_issue = false
      for _, diag in ipairs(diagnostics) do
        if diag.message:match(linter.ISSUES.UNALIGNED_MARKER) then
          found_alignment_issue = true
          break
        end
      end

      assert.is_true(found_alignment_issue)

      -- TODO: Test auto-fix functionality

      --[[ local result, fixed = linter.fix_issues(bufnr)
      assert.is_true(result)
      assert.equal(fixed, 1)

      -- Verify that after fixing, there are no more issues
      local post_fix_diagnostics = linter.lint_buffer(bufnr)
      assert.equal(0, #post_fix_diagnostics)

      -- Verify the content was actually fixed
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      -- Second line should now be indented with 2 spaces
      assert.matches("^  %- ", lines[3]) ]]

      -- Clean up
      finally(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)

    it("should respect config severity levels", function()
      local linter = require("checkmate.linter")

      -- Save original config
      local original_config = vim.deepcopy(linter.config)

      -- Modify severity to ERROR
      linter.config.severity[linter.ISSUES.UNALIGNED_MARKER] = vim.diagnostic.severity.ERROR

      -- Create test content
      local content = [[
# Test
- Parent
 - Misaligned child
]]

      local bufnr = h.create_test_buffer(content)

      -- Run linter
      local diagnostics = linter.lint_buffer(bufnr)

      -- Verify severity
      assert.is_true(#diagnostics == 1)
      assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity, "Should use configured severity level")

      -- Restore original config
      linter.config = original_config

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    pending("should correctly fix indentation issues across list item subtrees", function()
      local linter = require("checkmate.linter")
      local parser = require("checkmate.parser")

      -- test content with deliberately complex misalignments
      local content = [[
# Indentation Fix Test
- Parent item
 - Misaligned child (1 space instead of 2)
   With continuation line
   - Grandchild (aligned with misaligned parent)
     With its own continuation
- Next parent (should not be modified)
  - Its child (should not be modified)
# Another section
Text paragraph]]

      local bufnr = h.create_test_buffer(content)

      local original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      local diagnostics = linter.lint_buffer(bufnr)

      assert.is_true(#diagnostics > 0)

      -- Check that only misaligned child is detected
      local misaligned_row = nil
      for _, diag in ipairs(diagnostics) do
        if diag.lnum == 2 then -- The misaligned child is on line 3 (0-indexed = 2)
          misaligned_row = diag.lnum
          -- Confirm it's fixable
          assert.is_not_nil(diag.user_data)
          assert.is_not_nil(diag.user_data.fix_fn)
        end
      end

      assert.is_not_nil(misaligned_row)

      -- Apply fixes
      local fixed = linter.fix_issues(bufnr)
      assert.is_true(fixed)

      local fixed_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify fix applied correctly

      -- Check lines that should be modified:
      -- 1. Misaligned child should now be properly indented with 2 spaces
      assert.matches("  %- Misaligned", fixed_lines[3])

      -- 2. Child's continuation line should maintain relative indentation (4 spaces)
      assert.matches("    With continuation", fixed_lines[4])

      -- 3. Grandchild should maintain relative indentation (4 spaces to child)
      assert.matches("    %- Grandchild", fixed_lines[5])

      -- 4. Grandchild's continuation should maintain relative indentation
      assert.matches("^     With its own", fixed_lines[6])

      -- Check lines that should NOT be modified:
      -- 1. Header should remain unchanged
      assert.equal(original_lines[1], fixed_lines[1])

      -- 2. Parent item should remain unchanged
      assert.equal(original_lines[2], fixed_lines[2])

      -- 3. Next parent should remain unchanged
      assert.equal(original_lines[7], fixed_lines[7])

      -- 4. Next parent's child should remain unchanged
      assert.equal(original_lines[8], fixed_lines[8])

      -- 5. Another section and text should remain unchanged
      assert.equal(original_lines[9], fixed_lines[9])
      assert.equal(original_lines[10], fixed_lines[10])

      -- Run linter again to ensure no remaining issues
      local remaining_diagnostics = linter.lint_buffer(bufnr)
      assert.equal(0, #remaining_diagnostics)

      -- Verify structure is now correct by checking for parent-child relationships
      local list_items = parser.get_all_list_items(bufnr)

      -- Build a simple row-indexed map for easier lookup
      local items_by_row = {}
      for _, item in ipairs(list_items) do
        items_by_row[item.range.start.row] = item
      end

      -- Check parent-child relationship is properly established
      local parent = items_by_row[1] -- Parent on line 2 (0-indexed = 1)
      local child = items_by_row[2] -- Child on line 3 (0-indexed = 2)
      local grandchild = items_by_row[4] -- Grandchild on line 5 (0-indexed = 4)

      assert.is_not_nil(parent)
      assert.is_not_nil(child)
      assert.is_not_nil(grandchild)

      -- Verify parent-child relationships through Treesitter
      assert.equal(parent.node:id(), child.parent_node:id())
      assert.equal(child.node:id(), grandchild.parent_node:id())

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
