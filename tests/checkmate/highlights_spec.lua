describe("Highlights", function()
  ---@module "tests.checkmate.helpers"
  local h
  ---@module "checkmate"
  local checkmate

  before_each(function()
    _G.reset_state()

    checkmate = require("checkmate")
    h = require("tests.checkmate.helpers")

    checkmate.setup(h.DEFAULT_TEST_CONFIG)
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
        h.cleanup_file(file_path)
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
  describe("performance", function()
    it("should region-scope highlights on insert edits (TextChangedI path) for large files", function()
      local config = require("checkmate.config")
      local api = require("checkmate.api")
      local highlights = require("checkmate.highlights")

      -- large markdown-todo buffer: 2,000 top-level todos
      local unchecked = h.get_unchecked_marker()
      local lines = {}
      for i = 1, 2000 do
        lines[#lines + 1] = ("- %s Item %d %s %s"):format(unchecked, i, "@priority(high)", "@started(today)")
      end
      local content = table.concat(lines, "\n") .. "\n"

      local bufnr = h.setup_test_buffer(content)
      assert.is_true(api.setup_buffer(bufnr))

      -- initial extmarks
      local before_marks = highlights.get_hl_marks(bufnr)
      assert.truthy(#before_marks > 0)

      -- Track actual apply_highlighting calls
      local orig_apply = highlights.apply_highlighting
      local captured_opts = nil
      local apply_called = false
      local stub_apply_highlighting = stub(highlights, "apply_highlighting", function(buf, opts)
        captured_opts = opts
        apply_called = true
        return orig_apply(buf, opts)
      end)

      -- Track clearing operations
      local orig_clear_ns = highlights.clear_hl_ns
      local full_clear_calls = 0
      local stub_clear_hl_ns = stub(highlights, "clear_hl_ns", function(buf)
        full_clear_calls = full_clear_calls + 1
        return orig_clear_ns(buf)
      end)

      local orig_clear_range = highlights.clear_hl_ns_range
      local range_clear_calls = 0
      local cleared_ranges = {}
      local stub_clear_hl_ns_range = stub(highlights, "clear_hl_ns_range", function(buf, start_row, end_row)
        range_clear_calls = range_clear_calls + 1
        table.insert(cleared_ranges, { start_row = start_row, end_row = end_row })
        return orig_clear_range(buf, start_row, end_row)
      end)

      -- Get extmark far away to verify it survives
      local ns = config.ns_hl
      local far_row = 1995
      local far_marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { far_row, 0 }, { far_row, 0 }, { details = true })
      assert.truthy(#far_marks > 0)
      local far_id = far_marks[1][1]

      -- Edit in the middle of the file
      local edit_row = 1000
      local edit_col = 6
      vim.api.nvim_buf_set_text(bufnr, edit_row, edit_col, edit_row, edit_col, { "X" })

      -- Trigger TextChangedI autocmd
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr, modeline = false })

      if api._debounced_processors and api._debounced_processors[bufnr] then
        local processor = api._debounced_processors[bufnr]["highlight_only"]
        if processor and processor.flush then
          processor:flush()
        end
      else
        -- Option 2: Wait for the debounce timeout (50ms for highlight_only)
        vim.wait(100)
      end

      -- Now wait for apply_highlighting to actually be called
      local ok = vim.wait(500, function()
        return apply_called
      end, 10)
      assert.is_true(ok)

      -- Verify the call had a region
      captured_opts = h.exists(captured_opts)
      assert.truthy(captured_opts.region)

      -- Strategy should be nil or "adaptive" (both default to adaptive)
      if captured_opts.strategy then
        assert.equal("adaptive", captured_opts.strategy)
      end

      -- Should NOT have done a full clear
      assert.equal(0, full_clear_calls, "expected no full namespace clear in region pass")

      -- Should have done a regional clear
      assert.truthy(range_clear_calls > 0)

      -- Verify the cleared range includes our edit
      local found_relevant_clear = false
      for _, range in ipairs(cleared_ranges) do
        if range.start_row <= edit_row and range.end_row >= edit_row then
          found_relevant_clear = true
          break
        end
      end
      assert.is_true(found_relevant_clear)

      -- Far extmark should still exist
      local got = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, far_id, { details = true })
      assert.no.same({}, got, "far extmark should persist (no full clear)")

      -- Should have highlights in the edited region
      local region_marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { edit_row - 1, 0 },
        { edit_row + 1, -1 },
        { details = true }
      )
      assert.truthy(#region_marks > 0)

      finally(function()
        stub_apply_highlighting:revert()
        stub_clear_hl_ns:revert()
        stub_clear_hl_ns_range:revert()
      end)
    end)
  end)
end)
