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
  describe("performance", function()
    it("should region-scope highlights on insert edits (TextChangedI path) for large files", function()
      local config = require("checkmate.config")
      local api = require("checkmate.api")
      local highlights = require("checkmate.highlights")
      local parser = require("checkmate.parser")

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

      local spy_process_buffer = spy.on(api, "process_buffer")

      local orig_apply = highlights.apply_highlighting
      local captured_opts = nil
      local call_count_apply = 0
      local stub_apply_highlighting = stub(highlights, "apply_highlighting", function(buf, opts)
        captured_opts = opts
        call_count_apply = call_count_apply + 1
        return orig_apply(buf, opts)
      end)
      local call_count_before = call_count_apply
      call_count_apply = 0

      -- stub clear_hl_ns to detect any full-buffer clears during the post-edit pass
      local orig_clear_ns = highlights.clear_hl_ns
      local clear_calls = 0
      local stub_clear_hl_ns = stub(highlights, "clear_hl_ns", function(buf)
        clear_calls = clear_calls + 1
        return orig_clear_ns(buf)
      end)

      -- edit in the middle of the file
      local edit_row = 1000
      local edit_col = 6
      vim.api.nvim_buf_set_text(bufnr, edit_row, edit_col, edit_row, edit_col, { "X" })

      -- so our debounced highlight_only path runs
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = bufnr, modeline = false })

      local saw_call = vim.wait(800, function()
        local called, _ = spy_process_buffer:called(1)
        return called
      end, 10)
      assert.is_true(saw_call)
      assert.spy(spy_process_buffer).called_with(bufnr, "highlight_only", "TextChangedI")

      -- get extmark id far away to verify it survives (no full clear)
      local ns = config.ns_hl
      local far_row = 1995
      local far_id = nil
      for _, m in ipairs(before_marks) do
        if m[2] >= far_row then
          far_id = m[1]
          break
        end
      end
      far_id = h.exists(far_id)

      local ok = vim.wait(800, function()
        return (call_count_apply > call_count_before)
      end, 10)
      assert.is_true(ok)

      assert.truthy(captured_opts)
      ---@diagnostic disable-next-line: need-check-nil, undefined-field
      assert.truthy(captured_opts.region)

      assert.equal(0, clear_calls, "expected no full namespace clear in region pass")

      local got = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, far_id, { details = true })
      assert.no.same({}, got, "far extmark should persist (no full clear)")

      local region_marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { edit_row - 1, 0 },
        { edit_row + 1, -1 },
        { details = true }
      )
      assert.truthy(#region_marks > 0)

      -- Benchmark (informational)
      local RUN_BENCHMARK = false
      if RUN_BENCHMARK then
        local todo_map = parser.get_todo_map(bufnr)

        local target_root
        for _, it in pairs(todo_map) do
          if not it.parent_id and it.range.start.row == edit_row then
            target_root = it
            break
          end
        end

        if target_root then
          local region = {
            start_row = target_root.range.start.row,
            end_row = target_root.range["end"].row,
            affected_roots = { target_root },
          }

          local t1 = vim.uv.hrtime()
          orig_apply(bufnr, { todo_map = todo_map })
          local full_ms = (vim.uv.hrtime() - t1) / 1e6

          local t2 = vim.uv.hrtime()
          orig_apply(bufnr, { todo_map = todo_map, region = region })
          local region_ms = (vim.uv.hrtime() - t2) / 1e6

          print(
            string.format(
              "[checkmate bench] (highlights unit) full=%.2fms  region=%.2fms  span=%d line(s)",
              full_ms,
              region_ms,
              region.end_row - region.start_row + 1
            )
          )
        end
      end

      finally(function()
        spy_process_buffer:revert()
        stub_apply_highlighting:revert()
        stub_clear_hl_ns:revert()

        h.cleanup_buffer(bufnr)
      end)
    end)
  end)
end)
