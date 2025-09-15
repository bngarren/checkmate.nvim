describe("Highlights", function()
  ---@module "tests.checkmate.helpers"
  local h
  ---@module "checkmate"
  local checkmate

  before_each(function()
    _G.reset_state()

    checkmate = require("checkmate")
    h = require("tests.checkmate.helpers")

    checkmate.setup()
  end)

  after_each(function()
    checkmate.stop()
  end)

  describe("list marker", function()
    it("should correctly highlight the todo LIST marker", function()
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
- ]] .. unchecked .. [[ Todo A 
- ]] .. unchecked .. [[ Todo B 
  - ]] .. checked .. [[ Todo B.1 
    - ]] .. checked .. [[ Todo B.1.1 
]]

      local bufnr = h.setup_test_buffer(content)

      highlights.clear_hl_ns(bufnr)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = highlights.get_hl_marks(bufnr)
      local got = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerUnordered" then
          table.insert(got, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      local expected = {
        { start = { row = 0, col = 0 }, ["end"] = { row = 0, col = 1 } },
        { start = { row = 1, col = 0 }, ["end"] = { row = 1, col = 1 } },
        { start = { row = 2, col = 2 }, ["end"] = { row = 2, col = 3 } },
        { start = { row = 3, col = 4 }, ["end"] = { row = 3, col = 5 } },
      }

      assert.equal(#expected, #got)
      assert.same(expected, got)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should correctly highlight within-todo list markers", function()
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_unchecked_marker()

      local content = [[
- ]] .. unchecked .. [[ Todo A 
  - Non Todo 1
    - Non Todo 1.1
  1. Ordered
]]

      local bufnr = h.setup_test_buffer(content)

      highlights.clear_hl_ns(bufnr)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = highlights.get_hl_marks(bufnr)

      -- UNORDERED

      local got_unordered = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerUnordered" then
          table.insert(got_unordered, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      local expected = {
        { start = { row = 0, col = 0 }, ["end"] = { row = 0, col = 1 } },
        { start = { row = 1, col = 2 }, ["end"] = { row = 1, col = 3 } },
        { start = { row = 2, col = 4 }, ["end"] = { row = 2, col = 5 } },
      }

      assert.equal(#expected, #got_unordered)
      assert.same(expected, got_unordered)

      -- ORDERED

      local got_ordered = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerOrdered" then
          table.insert(got_ordered, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      expected = {
        { start = { row = 3, col = 2 }, ["end"] = { row = 3, col = 4 } },
      }

      assert.equal(#expected, #got_ordered)
      assert.same(expected, got_ordered)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should correctly highlight the todo marker", function()
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
- ]] .. unchecked .. [[ Todo A 
- ]] .. unchecked .. [[ Todo B 
  - ]] .. checked .. [[ Todo B.1 
    - ]] .. checked .. [[ Todo B.1.1 
]]

      local bufnr = h.setup_test_buffer(content)

      highlights.clear_hl_ns(bufnr)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = highlights.get_hl_marks(bufnr)

      -- UNCHECKED marker

      local got_unchecked = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateUncheckedMarker" then
          table.insert(got_unchecked, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      -- remember, this is byte length here...
      local expected = {
        { start = { row = 0, col = 2 }, ["end"] = { row = 0, col = 2 + #unchecked } },
        { start = { row = 1, col = 2 }, ["end"] = { row = 1, col = 2 + #unchecked } },
      }

      assert.equal(#expected, #got_unchecked)
      assert.same(expected, got_unchecked)

      -- CHECKED marker

      local got_checked = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateCheckedMarker" then
          table.insert(got_checked, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      expected = {
        { start = { row = 2, col = 4 }, ["end"] = { row = 2, col = 4 + #checked } },
        { start = { row = 3, col = 6 }, ["end"] = { row = 3, col = 6 + #checked } },
      }

      assert.equal(#expected, #got_checked)
      assert.same(expected, got_checked)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("content", function()
    it("should correctly highlight main and additional content", function()
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
- [ ] Todo A first line
  This is still part of the main content (same paragraph)
  And so is this line
  
  This is additional content (new paragraph after blank line)
- [x] Todo B main content that wraps
  to multiple lines within the same paragraph
  - Regular nested list item (additional content)
  More additional content
]]

      local bufnr, file_path = h.setup_test_buffer(content)
      highlights.clear_hl_ns(bufnr)
      highlights.apply_highlighting(bufnr, { debug_reason = "test" })
      local extmarks = highlights.get_hl_marks(bufnr)

      -- MAIN CONTENT
      local got_main = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == "CheckmateUncheckedMainContent" or d.hl_group == "CheckmateCheckedMainContent") then
          table.insert(got_main, {
            hl_group = d.hl_group,
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      -- Todo A: 3 lines of main content (all part of first inline)
      -- Todo B: 2 lines of main content
      local expected_main = {
        -- Todo A - line 1
        {
          hl_group = "CheckmateUncheckedMainContent",
          start = { row = 0, col = 2 + #unchecked + 1 },
          ["end"] = { row = 0, col = #("- " .. unchecked .. " Todo A first line") },
        },
        -- Todo A - line 2 (continuation)
        {
          hl_group = "CheckmateUncheckedMainContent",
          start = { row = 1, col = 2 },
          ["end"] = { row = 1, col = #"  This is still part of the main content (same paragraph)" },
        },
        -- Todo A - line 3 (continuation)
        {
          hl_group = "CheckmateUncheckedMainContent",
          start = { row = 2, col = 2 },
          ["end"] = { row = 2, col = #"  And so is this line" },
        },
        -- Todo B - line 1
        {
          hl_group = "CheckmateCheckedMainContent",
          start = { row = 5, col = 2 + #checked + 1 },
          ["end"] = { row = 5, col = #("- " .. checked .. " Todo B main content that wraps") },
        },
        -- Todo B - line 2 (continuation)
        {
          hl_group = "CheckmateCheckedMainContent",
          start = { row = 6, col = 2 },
          ["end"] = { row = 6, col = #"  to multiple lines within the same paragraph" },
        },
      }

      assert.equal(#expected_main, #got_main, "Should have correct number of main content highlights")
      assert.same(expected_main, got_main)

      -- ADDITIONAL CONTENT (content after first inline/paragraph)
      local got_additional = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if
          d
          and (d.hl_group == "CheckmateUncheckedAdditionalContent" or d.hl_group == "CheckmateCheckedAdditionalContent")
        then
          table.insert(got_additional, {
            hl_group = d.hl_group,
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      local expected_additional = {
        -- Todo A's additional content
        {
          hl_group = "CheckmateUncheckedAdditionalContent",
          start = { row = 4, col = 2 },
          ["end"] = { row = 4, col = #"  This is additional content (new paragraph after blank line)" },
        },
        -- Todo B's nested list item
        {
          hl_group = "CheckmateCheckedAdditionalContent",
          start = { row = 7, col = 4 },
          ["end"] = { row = 7, col = #"  - Regular nested list item (additional content)" },
        },
        -- Todo B's last line
        {
          hl_group = "CheckmateCheckedAdditionalContent",
          start = { row = 8, col = 2 },
          ["end"] = { row = 8, col = #"  More additional content" },
        },
      }

      assert.equal(#expected_additional, #got_additional, "Should have correct number of additional content highlights")
      assert.same(expected_additional, got_additional)

      finally(function()
        h.cleanup_buffer(bufnr, file_path)
      end)
    end)
  end)

  describe("metadata", function()
    it("should apply metadata tag highlights", function()
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_checked_marker()

      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Todo with @priority(high) metadata
]]

      local bufnr = h.setup_test_buffer(content)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = highlights.get_hl_marks(bufnr)

      local found_metadata = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.hl_group:match("^CheckmateMeta_") then
          found_metadata = true
          break
        end
      end

      assert.is_true(found_metadata)

      finally(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)
  end)
  describe("todo count", function()
    it("should display todo count when configured", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      config.options.show_todo_count = true

      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Parent todo
  - ]] .. unchecked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
  - ]] .. unchecked .. [[ Child 3
]]

      local bufnr = h.setup_test_buffer(content)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = highlights.get_hl_marks(bufnr)

      local found_count = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.virt_text then
          for _, text_part in ipairs(details.virt_text) do
            -- virtual text has the expected format (1/3)
            if text_part[1]:match("%d+/%d+") then
              found_count = true
              break
            end
          end
        end
      end

      assert.is_true(found_count)

      finally(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)
  end)
end)
