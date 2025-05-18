-- tests/checkmate/linter_spec.lua
describe("Linter", function()
  local h = require("tests.checkmate.helpers")
  local linter = require("checkmate.linter")

  before_each(function()
    _G.reset_state()
  end)

  -- helper to run linter & fetch diags in one go
  local function run(bufnr, linter_opts)
    linter.setup(linter_opts)
    local diags = linter.lint_buffer(bufnr)
    local vdiag = vim.diagnostic.get(bufnr, { namespace = linter.ns })
    assert.equal(#diags, #vdiag, "internal vs vim.diagnostic count mismatch")
    return diags
  end

  ---@param diag_msg string
  local function starts_with(diag_msg, issue_const)
    assert.equal(
      diag_msg:sub(1, #issue_const) == issue_const,
      true,
      string.format("expected message to start with %q, got %q", issue_const, diag_msg)
    )
  end

  it("emits no diagnostics for a perfectly aligned list", function()
    local content = [[
- Parent
  - Child
    - Grandchild]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)
    assert.equal(0, #diags)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("flags a child indented before the parent’s content (INDENT_SHALLOW)", function()
    local content = [[
- Parent
 - Bad child   ]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(1, #diags)
    starts_with(diags[1].message, linter.RULES.INDENT_SHALLOW.message)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("flags a child indented >3 cols past parent content (INDENT_DEEP)", function()
    local content = [[
- Parent
      - Too deep by spec ]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(1, #diags)
    starts_with(diags[1].message, linter.RULES.INDENT_DEEP.message)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("flags mixed ordered/unordered markers at same indent (INCONSISTENT_MARKER)", function()
    local content = [[
- unordered
1. ordered sibling ]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(1, #diags)
    assert.equal(linter.RULES.INCONSISTENT_MARKER.message, diags[1].message)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("respects severity overrides in config", function()
    local content = [[
- Parent
 - Bad child]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr, { severity = {
      INDENT_SHALLOW = vim.diagnostic.severity.ERROR,
    } })

    assert.equal(vim.diagnostic.severity.ERROR, diags[1].severity)

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles list items with and without spaces after marker", function()
    local content = [[
-Parent with no space (not a valid list in CommonMark)
- Parent with space (valid list)
 -Child with no space (not valid)
  - Child with space (valid)]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    -- Should not detect any list items for no-space variants
    assert.equal(0, #diags, "No diagnostics because invalid items are not recognized as lists")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("properly aligns against actual content position, not just marker end", function()
    local content = [[
- Parent
  text on next line
  - Child (correctly aligned with parent's content)
 - Bad child (before parent's content)]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(1, #diags, "Only the bad child should be flagged")
    assert.equal(3, diags[1].lnum, "The bad child is on the 4th line (0-indexed = 3)")
    starts_with(diags[1].message, linter.RULES.INDENT_SHALLOW.message)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles empty lines correctly", function()
    local content = [[
- Item 1

- Item 2
  - Child of item 2

  - Still a child of item 2 despite blank line]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(0, #diags, "Empty lines should not cause issues")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles non-list content mixed with lists", function()
    local content = [[
# Heading
- Item 1
Regular paragraph
- Item 2
  - Child of item 2
Code block:
    var x = 1;
  - Not a child (this is code, not a list)]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    -- Only items that parse as valid list items should be analyzed
    assert.equal(0, #diags, "Non-list content should be ignored")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles list items with multiple paragraphs correctly", function()
    local content = [[
- Item 1
  with a second paragraph line
  
  and a third paragraph
  - Child item (properly aligned with content)
 - Bad child (too shallow)]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(1, #diags, "Only bad alignment should be flagged")
    starts_with(diags[1].message, linter.RULES.INDENT_SHALLOW.message)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("handles continuation lines without creating false positives", function()
    local content = [[
- Item 1
  continuation line
  more continuation
- Item 2
  - Child item]]
    local bufnr = h.create_test_buffer(content)
    local diags = run(bufnr)

    assert.equal(0, #diags, "Continuation lines should not affect list item detection")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
